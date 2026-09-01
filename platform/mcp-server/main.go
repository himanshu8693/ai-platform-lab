// =============================================================================
// F3 — Custom Go MCP Server  (platform/mcp-server/main.go)
// =============================================================================
//
// A purpose-built MCP (Model Context Protocol) server that exposes read-only
// tools for the Platform AI lab's model registry and Kubernetes workloads.
//
// Transport: HTTP + Server-Sent Events (SSE) on :8080
//   - GET  /sse        — SSE stream; MCP client connects here
//   - POST /messages   — JSON-RPC 2.0 tool call endpoint
//   - GET  /healthz    — liveness probe
//   - GET  /            — MCP capability advertisement
//
// Tools registered (see tools.go):
//   - list_model_deployments   : lists ModelDeployment CRs from the K8s API
//   - get_model_deployment     : returns spec + status for a named deployment
//   - promote_model_version    : updates ModelDeployment image tag (write-guarded)
//   - query_inference_metrics  : executes a PromQL query via Prometheus HTTP API
//
// Security:
//   The server holds NO static credentials. It uses the pod's in-cluster
//   ServiceAccount token for K8s API calls. Prometheus access is unauthenticated
//   inside the Consul mTLS mesh. The promote_model_version tool requires the
//   caller to include an X-Promote-Token header matching PROMOTE_TOKEN env var
//   (injected by Vault Agent at /var/run/secrets/promote-token).
//
// Running locally:
//   go run ./platform/mcp-server -kubeconfig ~/.kube/config
// =============================================================================

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	var (
		addr       = flag.String("addr", envOrDefault("MCP_ADDR", ":8080"), "Listen address")
		kubeconfig = flag.String("kubeconfig", "", "Path to kubeconfig (empty = in-cluster)")
		promURL    = flag.String("prometheus-url",
			envOrDefault("PROMETHEUS_URL", "http://prometheus-operated.monitoring.svc.cluster.local:9090"),
			"Prometheus base URL")
	)
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg, err := loadKubeConfig(*kubeconfig)
	if err != nil {
		logger.Error("load kubeconfig", slog.String("error", err.Error()))
		os.Exit(1)
	}

	tools := NewToolRegistry(ToolRegistryOptions{
		KubeConfig:    cfg,
		PrometheusURL: *promURL,
		PromoteToken:  os.Getenv("PROMOTE_TOKEN"), // Vault Agent injected
		Logger:        logger,
	})

	srv := NewServer(ServerOptions{
		Addr:   *addr,
		Tools:  tools,
		Logger: logger,
	})

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	logger.Info("mcp-server starting", slog.String("addr", *addr))
	if err := srv.Run(ctx); err != nil {
		logger.Error("mcp-server exit", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func loadKubeConfig(kubeconfigPath string) (*rest.Config, error) {
	if kubeconfigPath != "" {
		return clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
	}
	return cfg, nil
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// =============================================================================
// MCP HTTP+SSE Server
// =============================================================================

// ServerOptions configures the MCP HTTP server.
type ServerOptions struct {
	Addr   string
	Tools  *ToolRegistry
	Logger *slog.Logger
}

// Server is the MCP HTTP+SSE server.
type Server struct {
	opts    ServerOptions
	clients sync.Map // key: clientID string → chan sseEvent
}

// NewServer constructs a Server.
func NewServer(opts ServerOptions) *Server {
	return &Server{opts: opts}
}

// Run starts the HTTP server and blocks until ctx is cancelled.
func (s *Server) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/sse", s.handleSSE)
	mux.HandleFunc("/messages", s.handleMessages)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", s.handleCapabilities)

	httpSrv := &http.Server{
		Addr:              s.opts.Addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	l, err := net.Listen("tcp", s.opts.Addr)
	if err != nil {
		return fmt.Errorf("mcp-server: listen: %w", err)
	}

	errCh := make(chan error, 1)
	go func() {
		if serveErr := httpSrv.Serve(l); serveErr != nil && serveErr != http.ErrServerClosed {
			errCh <- serveErr
		}
		close(errCh)
	}()

	select {
	case <-ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return httpSrv.Shutdown(shutCtx)
	case err := <-errCh:
		return err
	}
}

// sseEvent is a JSON-RPC 2.0 notification pushed to SSE clients.
type sseEvent struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// handleSSE streams JSON-RPC notifications to long-lived SSE clients.
func (s *Server) handleSSE(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	clientID := req.RemoteAddr
	ch := make(chan sseEvent, 16)
	s.clients.Store(clientID, ch)
	defer s.clients.Delete(clientID)

	// Send MCP server hello.
	s.writeSSE(w, flusher, sseEvent{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
		Params:  map[string]string{"serverName": "ai-platform-mcp", "serverVersion": "0.1.0"},
	})

	for {
		select {
		case <-req.Context().Done():
			return
		case evt, ok := <-ch:
			if !ok {
				return
			}
			s.writeSSE(w, flusher, evt)
		}
	}
}

func (s *Server) writeSSE(w http.ResponseWriter, flusher http.Flusher, evt sseEvent) {
	b, err := json.Marshal(evt)
	if err != nil {
		s.opts.Logger.Error("mcp-server: marshal SSE event", slog.String("error", err.Error()))
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
	flusher.Flush()
}

// MCPRequest is the JSON-RPC 2.0 request envelope.
type MCPRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// MCPResponse is the JSON-RPC 2.0 response envelope.
type MCPResponse struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id,omitempty"`
	Result  any       `json:"result,omitempty"`
	Error   *MCPError `json:"error,omitempty"`
}

// MCPError is the JSON-RPC 2.0 error object.
type MCPError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// handleMessages processes JSON-RPC 2.0 POST /messages requests.
func (s *Server) handleMessages(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var rpcReq MCPRequest
	if err := json.NewDecoder(req.Body).Decode(&rpcReq); err != nil {
		writeJSON(w, http.StatusBadRequest, MCPResponse{
			JSONRPC: "2.0",
			Error:   &MCPError{Code: -32700, Message: "parse error"},
		})
		return
	}

	result, rpcErr := s.dispatch(req.Context(), req, rpcReq)
	if rpcErr != nil {
		writeJSON(w, http.StatusOK, MCPResponse{JSONRPC: "2.0", ID: rpcReq.ID, Error: rpcErr})
		return
	}
	writeJSON(w, http.StatusOK, MCPResponse{JSONRPC: "2.0", ID: rpcReq.ID, Result: result})
}

// dispatch routes a JSON-RPC method to the appropriate handler.
func (s *Server) dispatch(ctx context.Context, req *http.Request, rpcReq MCPRequest) (any, *MCPError) {
	switch rpcReq.Method {
	case "initialize":
		return s.opts.Tools.Capabilities(), nil

	case "tools/list":
		return map[string]any{"tools": s.opts.Tools.List()}, nil

	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(rpcReq.Params, &p); err != nil {
			return nil, &MCPError{Code: -32602, Message: "invalid params"}
		}
		result, err := s.opts.Tools.Call(ctx, req, p.Name, p.Arguments)
		if err != nil {
			return nil, &MCPError{Code: -32000, Message: err.Error()}
		}
		return result, nil

	default:
		return nil, &MCPError{Code: -32601, Message: fmt.Sprintf("method not found: %s", rpcReq.Method)}
	}
}

// handleCapabilities returns the MCP capability advertisement.
func (s *Server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.opts.Tools.Capabilities())
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
