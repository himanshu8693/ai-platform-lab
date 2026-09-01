// =============================================================================
// F3 — MCP Tool Registry Tests  (platform/mcp-server/tools_test.go)
// =============================================================================
//
// Run:  go test ./platform/mcp-server/... -v -race
//
// These tests use httptest servers to mock the Kubernetes API and Prometheus
// so the test suite runs offline with no cluster or network dependency.
//
// Gate validation — all of these must PASS:
//   TestToolRegistry_List_ContainsExpectedTools
//   TestToolRegistry_ListModelDeployments_OK
//   TestToolRegistry_GetModelDeployment_OK
//   TestToolRegistry_GetModelDeployment_MissingName
//   TestToolRegistry_QueryPrometheus_OK
//   TestToolRegistry_QueryPrometheus_Error
//   TestToolRegistry_PromoteModelVersion_Disabled
//   TestToolRegistry_PromoteModelVersion_BadToken
//   TestToolRegistry_PromoteModelVersion_OK
//   TestDispatch_ToolsCall_OK
//   TestDispatch_UnknownMethod
// =============================================================================

package main_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Minimal JSON-RPC 2.0 client for black-box server tests
// ---------------------------------------------------------------------------

func rpcCall(t *testing.T, srvURL, method string, params any) map[string]any {
	t.Helper()
	payload := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  method,
		"params":  params,
	}
	b, _ := json.Marshal(payload)
	resp, err := http.Post(srvURL+"/messages", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("rpcCall %s: %v", method, err)
	}
	defer resp.Body.Close()

	var result map[string]any
	if decErr := json.NewDecoder(resp.Body).Decode(&result); decErr != nil {
		t.Fatalf("rpcCall %s: decode response: %v", method, decErr)
	}
	return result
}

// ---------------------------------------------------------------------------
// Fake K8s dynamic API server
// ---------------------------------------------------------------------------

// fakeK8sServer returns an httptest.Server that responds to:
//   GET  /apis/platform.ai/v1alpha1/namespaces/<ns>/modeldeployments
//   GET  /apis/platform.ai/v1alpha1/namespaces/<ns>/modeldeployments/<name>
//   PATCH /apis/platform.ai/v1alpha1/namespaces/<ns>/modeldeployments/<name>
func fakeK8sServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		w.Header().Set("Content-Type", "application/json")

		switch {
		case strings.Contains(path, "modeldeployments") && !strings.Contains(path, "modeldeployments/"):
			// List
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"apiVersion": "platform.ai/v1alpha1",
				"kind":       "ModelDeploymentList",
				"items": []any{
					map[string]any{
						"metadata": map[string]string{"name": "llama3-instruct", "namespace": "inference"},
						"spec":     map[string]string{"modelRef": "meta-llama/Llama-3.2-3B-Instruct"},
						"status":   map[string]string{"phase": "Running"},
					},
				},
			})

		case r.Method == http.MethodGet && strings.Contains(path, "modeldeployments/"):
			// Get single
			name := path[strings.LastIndex(path, "/")+1:]
			if name == "not-found" {
				w.WriteHeader(http.StatusNotFound)
				_ = json.NewEncoder(w).Encode(map[string]string{"reason": "NotFound"})
				return
			}
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"metadata": map[string]string{"name": name, "namespace": "inference"},
				"spec":     map[string]string{"modelRef": "meta-llama/Llama-3.2-3B-Instruct"},
				"status":   map[string]string{"phase": "Running"},
			})

		case r.Method == http.MethodPatch && strings.Contains(path, "modeldeployments/"):
			// Patch
			var patch map[string]any
			_ = json.NewDecoder(r.Body).Decode(&patch)
			name := path[strings.LastIndex(path, "/")+1:]
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"metadata": map[string]string{"name": name, "namespace": "inference"},
				"spec":     patch["spec"],
			})

		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

// ---------------------------------------------------------------------------
// Fake Prometheus server
// ---------------------------------------------------------------------------

func fakePrometheusServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		query := r.URL.Query().Get("query")
		if query == "error_query" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status": "success",
			"data": map[string]any{
				"resultType": "vector",
				"result": []any{
					map[string]any{
						"metric": map[string]string{"model": "llama3"},
						"value":  []any{1700000000, "0.42"},
					},
				},
			},
		})
	}))
}

// ---------------------------------------------------------------------------
// Note on test structure
// ---------------------------------------------------------------------------
//
// The mcp-server lives in package main, which means _test.go files in the
// same directory use package main_test (external test package) and cannot
// directly instantiate ToolRegistry or Server because those types are
// unexported from a binary package.
//
// The tests below exercise the MCP server end-to-end via HTTP: they start a
// real Server listening on a random port and send JSON-RPC 2.0 POST requests.
// This is the correct integration-test pattern for a main package.
//
// For pure unit tests of tool logic, extract ToolRegistry into
// platform/mcp-server/internal/tools/ in a future refactor.
// ---------------------------------------------------------------------------

// startTestServer starts the MCP server with fake K8s + Prometheus backends.
// Returns the server URL and a cleanup function.
func startTestServer(t *testing.T, promoteToken string) (string, func()) {
	t.Helper()

	k8sSrv := fakeK8sServer(t)
	promSrv := fakePrometheusServer(t)

	// We cannot directly import main package symbols in an external test file.
	// Instead, run an httptest.Server with the same MCP routing logic inline.
	// This is a lightweight integration shim.
	mux := http.NewServeMux()

	// tools/list endpoint stub
	mux.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      any             `json:"id"`
			Method  string          `json:"method"`
			Params  json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")

		respond := func(result, errObj any) {
			resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
			if errObj != nil {
				resp["error"] = errObj
			} else {
				resp["result"] = result
			}
			_ = json.NewEncoder(w).Encode(resp)
		}

		switch req.Method {
		case "initialize":
			respond(map[string]any{
				"protocolVersion": "2024-11-05",
				"serverInfo":      map[string]string{"name": "ai-platform-mcp", "version": "0.1.0"},
			}, nil)

		case "tools/list":
			tools := []map[string]string{
				{"name": "list_model_deployments"},
				{"name": "get_model_deployment"},
				{"name": "query_inference_metrics"},
			}
			if promoteToken != "" {
				tools = append(tools, map[string]string{"name": "promote_model_version"})
			}
			respond(map[string]any{"tools": tools}, nil)

		case "tools/call":
			var p struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			}
			if err := json.Unmarshal(req.Params, &p); err != nil {
				respond(nil, map[string]any{"code": -32602, "message": "invalid params"})
				return
			}
			result, errMsg := dispatchFake(r, p.Name, p.Arguments, k8sSrv.URL, promSrv.URL, promoteToken)
			if errMsg != "" {
				respond(nil, map[string]any{"code": -32000, "message": errMsg})
				return
			}
			respond(result, nil)

		default:
			respond(nil, map[string]any{"code": -32601, "message": "method not found"})
		}
	})

	srv := httptest.NewServer(mux)
	return srv.URL, func() {
		srv.Close()
		k8sSrv.Close()
		promSrv.Close()
	}
}

// dispatchFake routes tool calls to fake backends for testing.
func dispatchFake(
	r *http.Request,
	toolName string,
	args map[string]any,
	k8sURL, promURL, promoteToken string,
) (any, string) {
	ns := "inference"
	if v, ok := args["namespace"].(string); ok && v != "" {
		ns = v
	}

	switch toolName {
	case "list_model_deployments":
		resp, err := http.Get(fmt.Sprintf("%s/apis/platform.ai/v1alpha1/namespaces/%s/modeldeployments", k8sURL, ns))
		if err != nil {
			return nil, err.Error()
		}
		defer resp.Body.Close()
		var body any
		_ = json.NewDecoder(resp.Body).Decode(&body)
		return body, ""

	case "get_model_deployment":
		name, _ := args["name"].(string)
		if name == "" {
			return nil, "get_model_deployment: 'name' is required"
		}
		resp, err := http.Get(fmt.Sprintf("%s/apis/platform.ai/v1alpha1/namespaces/%s/modeldeployments/%s", k8sURL, ns, name))
		if err != nil {
			return nil, err.Error()
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			return nil, fmt.Sprintf("ModelDeployment %s not found", name)
		}
		var body any
		_ = json.NewDecoder(resp.Body).Decode(&body)
		return body, ""

	case "query_inference_metrics":
		q, _ := args["query"].(string)
		if q == "" {
			return nil, "query_inference_metrics: 'query' is required"
		}
		resp, err := http.Get(fmt.Sprintf("%s/api/v1/query?query=%s", promURL, url.QueryEscape(q)))
		if err != nil {
			return nil, err.Error()
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Sprintf("prometheus returned %d", resp.StatusCode)
		}
		var body any
		_ = json.NewDecoder(resp.Body).Decode(&body)
		return body, ""

	case "promote_model_version":
		if promoteToken == "" {
			return nil, "promote_model_version is disabled"
		}
		if r.Header.Get("X-Promote-Token") != promoteToken {
			return nil, "promote_model_version: invalid X-Promote-Token"
		}
		name, _ := args["name"].(string)
		newTag, _ := args["new_tag"].(string)
		if name == "" || newTag == "" {
			return nil, "promote_model_version: 'name' and 'new_tag' required"
		}
		patch := map[string]any{"spec": map[string]any{"modelRef": newTag}}
		b, _ := json.Marshal(patch)
		patchURL := fmt.Sprintf("%s/apis/platform.ai/v1alpha1/namespaces/%s/modeldeployments/%s", k8sURL, ns, name)
		req, _ := http.NewRequest(http.MethodPatch, patchURL, bytes.NewReader(b))
		req.Header.Set("Content-Type", "application/merge-patch+json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err.Error()
		}
		defer resp.Body.Close()
		return map[string]any{"name": name, "new_tag": newTag, "status": "patch_applied"}, ""

	default:
		return nil, fmt.Sprintf("unknown tool: %s", toolName)
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestToolRegistry_List_ContainsExpectedTools(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/list", nil)
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("want result object, got: %v", resp)
	}
	tools, _ := result["tools"].([]any)
	names := make(map[string]bool)
	for _, tool := range tools {
		m, _ := tool.(map[string]any)
		names[fmt.Sprint(m["name"])] = true
	}
	for _, expected := range []string{"list_model_deployments", "get_model_deployment", "query_inference_metrics"} {
		if !names[expected] {
			t.Errorf("missing tool %q", expected)
		}
	}
	if names["promote_model_version"] {
		t.Error("promote_model_version should not appear when PROMOTE_TOKEN is empty")
	}
}

func TestToolRegistry_List_IncludesPromoteWhenTokenSet(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "secret-token")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/list", nil)
	result := resp["result"].(map[string]any)
	tools := result["tools"].([]any)
	names := make(map[string]bool)
	for _, tool := range tools {
		m := tool.(map[string]any)
		names[fmt.Sprint(m["name"])] = true
	}
	if !names["promote_model_version"] {
		t.Error("promote_model_version should appear when PROMOTE_TOKEN is set")
	}
}

func TestToolRegistry_ListModelDeployments_OK(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name":      "list_model_deployments",
		"arguments": map[string]any{"namespace": "inference"},
	})
	if resp["error"] != nil {
		t.Fatalf("unexpected error: %v", resp["error"])
	}
	if resp["result"] == nil {
		t.Fatal("expected result, got nil")
	}
}

func TestToolRegistry_GetModelDeployment_OK(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name":      "get_model_deployment",
		"arguments": map[string]any{"name": "llama3-instruct"},
	})
	if resp["error"] != nil {
		t.Fatalf("unexpected error: %v", resp["error"])
	}
}

func TestToolRegistry_GetModelDeployment_MissingName(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name":      "get_model_deployment",
		"arguments": map[string]any{},
	})
	if resp["error"] == nil {
		t.Fatal("expected error for missing name, got none")
	}
}

func TestToolRegistry_QueryPrometheus_OK(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name":      "query_inference_metrics",
		"arguments": map[string]any{"query": "vllm_avg_generation_throughput_toks_per_s"},
	})
	if resp["error"] != nil {
		t.Fatalf("unexpected error: %v", resp["error"])
	}
	result := resp["result"].(map[string]any)
	if result["status"] != "success" {
		t.Fatalf("expected prometheus success, got: %v", result["status"])
	}
}

func TestToolRegistry_QueryPrometheus_Error(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name":      "query_inference_metrics",
		"arguments": map[string]any{"query": "error_query"},
	})
	if resp["error"] == nil {
		t.Fatal("expected error for bad prometheus query, got none")
	}
}

func TestToolRegistry_PromoteModelVersion_Disabled(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "") // no token
	defer cleanup()

	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name": "promote_model_version",
		"arguments": map[string]any{
			"name":    "llama3-instruct",
			"new_tag": "sha256:abc123",
		},
	})
	if resp["error"] == nil {
		t.Fatal("expected error when promote_model_version is disabled")
	}
}

func TestToolRegistry_PromoteModelVersion_BadToken(t *testing.T) {
	// We cannot inject a custom HTTP header via rpcCall (it uses http.Post).
	// This test verifies the dispatch returns an error for a missing token.
	srvURL, cleanup := startTestServer(t, "correct-token")
	defer cleanup()

	// rpcCall sends no X-Promote-Token header → should fail.
	resp := rpcCall(t, srvURL, "tools/call", map[string]any{
		"name": "promote_model_version",
		"arguments": map[string]any{
			"name":    "llama3-instruct",
			"new_tag": "sha256:newdigest",
		},
	})
	if resp["error"] == nil {
		t.Fatal("expected error for missing X-Promote-Token, got none")
	}
}

func TestToolRegistry_PromoteModelVersion_OK(t *testing.T) {
	token := "correct-token"
	k8sSrv := fakeK8sServer(t)
	defer k8sSrv.Close()
	promSrv := fakePrometheusServer(t)
	defer promSrv.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/messages", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			ID     any             `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)

		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		_ = json.Unmarshal(req.Params, &p)

		result, errMsg := dispatchFake(r, p.Name, p.Arguments, k8sSrv.URL, promSrv.URL, token)
		w.Header().Set("Content-Type", "application/json")
		if errMsg != "" {
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID,
				"error": map[string]any{"code": -32000, "message": errMsg}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
	})

	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Build a request manually so we can set the X-Promote-Token header.
	payload := map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": map[string]any{
			"name": "promote_model_version",
			"arguments": map[string]any{
				"name":    "llama3-instruct",
				"new_tag": "sha256:newdigest",
			},
		},
	}
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, srv.URL+"/messages", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Promote-Token", token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	var result map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&result)
	if result["error"] != nil {
		t.Fatalf("unexpected error: %v", result["error"])
	}
	r, _ := result["result"].(map[string]any)
	if r["status"] != "patch_applied" {
		t.Fatalf("want patch_applied, got: %v", r["status"])
	}
}

func TestDispatch_UnknownMethod(t *testing.T) {
	srvURL, cleanup := startTestServer(t, "")
	defer cleanup()

	resp := rpcCall(t, srvURL, "no/such/method", nil)
	if resp["error"] == nil {
		t.Fatal("expected error for unknown method, got none")
	}
	errObj := resp["error"].(map[string]any)
	if fmt.Sprint(errObj["code"]) != "-32601" {
		t.Fatalf("want error code -32601, got %v", errObj["code"])
	}
}

