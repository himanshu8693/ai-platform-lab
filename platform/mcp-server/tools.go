// =============================================================================
// F3 — MCP Tool Registry  (platform/mcp-server/tools.go)
// =============================================================================
//
// Implements the four tools exposed by the ai-platform MCP server:
//
//   list_model_deployments    Read-only. Lists all ModelDeployment CRs in the
//                             given namespace. Uses unstructured K8s client so
//                             it works without the CRD Go type imported here.
//
//   get_model_deployment      Read-only. Returns full spec + status for one
//                             named ModelDeployment.
//
//   promote_model_version     Write-guarded. Updates the modelRef field on a
//                             ModelDeployment to a new tag. Caller must supply
//                             X-Promote-Token matching the server's PROMOTE_TOKEN.
//
//   query_inference_metrics   Read-only. Executes a PromQL instant query and
//                             returns the result vector as structured JSON.
//
// Security model:
//   Read tools use the pod ServiceAccount (in-cluster) or kubeconfig (local).
//   Write tool requires an HMAC-equivalent token match (PROMOTE_TOKEN env var).
//   The K8s SA ClusterRole contains only get/list/watch + patch for the
//   ModelDeployment resource; no other write verbs are present.
// =============================================================================

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// modelDeploymentGVR is the GroupVersionResource for the ModelDeployment CRD.
var modelDeploymentGVR = schema.GroupVersionResource{
	Group:    "platform.ai",
	Version:  "v1alpha1",
	Resource: "modeldeployments",
}

// ToolRegistryOptions configures the ToolRegistry.
type ToolRegistryOptions struct {
	KubeConfig    *rest.Config
	PrometheusURL string
	PromoteToken  string // empty = promote_model_version tool disabled
	Logger        *slog.Logger
}

// ToolRegistry holds all MCP tools and the clients they use.
type ToolRegistry struct {
	opts      ToolRegistryOptions
	dynClient dynamic.Interface
	httpCli   *http.Client
}

// NewToolRegistry constructs a ToolRegistry.
func NewToolRegistry(opts ToolRegistryOptions) *ToolRegistry {
	dyn, err := dynamic.NewForConfig(opts.KubeConfig)
	if err != nil {
		// Fallback: nil dynamic client — tools will return descriptive errors.
		opts.Logger.Error("tool-registry: create dynamic client", slog.String("error", err.Error()))
	}
	return &ToolRegistry{
		opts:      opts,
		dynClient: dyn,
		httpCli:   &http.Client{Timeout: 15 * time.Second},
	}
}

// ToolDef is the JSON representation of a tool in the MCP capability advertisement.
type ToolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

// List returns the MCP tool definitions for the capability advertisement.
func (r *ToolRegistry) List() []ToolDef {
	tools := []ToolDef{
		{
			Name:        "list_model_deployments",
			Description: "List all ModelDeployment custom resources in the given namespace.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"namespace": map[string]any{
						"type":        "string",
						"description": "Kubernetes namespace. Defaults to 'inference' if omitted.",
					},
				},
			},
		},
		{
			Name:        "get_model_deployment",
			Description: "Get spec and status for a named ModelDeployment.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"name"},
				"properties": map[string]any{
					"name":      map[string]any{"type": "string", "description": "ModelDeployment name."},
					"namespace": map[string]any{"type": "string", "description": "Kubernetes namespace (default: inference)."},
				},
			},
		},
		{
			Name:        "query_inference_metrics",
			Description: "Execute a PromQL instant query against the platform Prometheus and return the result vector.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"query"},
				"properties": map[string]any{
					"query": map[string]any{"type": "string", "description": "PromQL expression."},
					"time":  map[string]any{"type": "string", "description": "RFC3339 evaluation time (optional, defaults to now)."},
				},
			},
		},
	}

	if r.opts.PromoteToken != "" {
		tools = append(tools, ToolDef{
			Name:        "promote_model_version",
			Description: "Update the modelRef tag on a ModelDeployment to trigger a rolling rollout. Requires X-Promote-Token header.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"name", "new_tag"},
				"properties": map[string]any{
					"name":      map[string]any{"type": "string"},
					"new_tag":   map[string]any{"type": "string", "description": "New modelRef tag (e.g. sha256:abc123)."},
					"namespace": map[string]any{"type": "string"},
				},
			},
		})
	}

	return tools
}

// Capabilities returns the MCP capability advertisement object.
func (r *ToolRegistry) Capabilities() map[string]any {
	return map[string]any{
		"protocolVersion": "2024-11-05",
		"serverInfo": map[string]string{
			"name":    "ai-platform-mcp",
			"version": "0.1.0",
		},
		"capabilities": map[string]any{
			"tools": map[string]bool{"listChanged": false},
		},
	}
}

// Call dispatches a tool call by name.
func (r *ToolRegistry) Call(ctx context.Context, req *http.Request, name string, args map[string]any) (any, error) {
	switch name {
	case "list_model_deployments":
		return r.listModelDeployments(ctx, stringArg(args, "namespace", "inference"))

	case "get_model_deployment":
		name_, _ := args["name"].(string)
		if name_ == "" {
			return nil, fmt.Errorf("tools: get_model_deployment: 'name' is required")
		}
		return r.getModelDeployment(ctx, name_, stringArg(args, "namespace", "inference"))

	case "promote_model_version":
		return r.promoteModelVersion(ctx, req, args)

	case "query_inference_metrics":
		q, _ := args["query"].(string)
		if q == "" {
			return nil, fmt.Errorf("tools: query_inference_metrics: 'query' is required")
		}
		return r.queryPrometheus(ctx, q, stringArg(args, "time", ""))

	default:
		return nil, fmt.Errorf("tools: unknown tool: %q", name)
	}
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

// listModelDeployments lists all ModelDeployment CRs in namespace.
func (r *ToolRegistry) listModelDeployments(ctx context.Context, namespace string) (any, error) {
	if r.dynClient == nil {
		return nil, fmt.Errorf("tools: kubernetes client not available")
	}
	list, err := r.dynClient.Resource(modelDeploymentGVR).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("tools: list ModelDeployments: %w", err)
	}
	return summariseList(list), nil
}

// getModelDeployment returns spec + status for a named ModelDeployment.
func (r *ToolRegistry) getModelDeployment(ctx context.Context, name, namespace string) (any, error) {
	if r.dynClient == nil {
		return nil, fmt.Errorf("tools: kubernetes client not available")
	}
	obj, err := r.dynClient.Resource(modelDeploymentGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("tools: get ModelDeployment %s/%s: %w", namespace, name, err)
	}
	return map[string]any{
		"name":      obj.GetName(),
		"namespace": obj.GetNamespace(),
		"spec":      obj.Object["spec"],
		"status":    obj.Object["status"],
	}, nil
}

// promoteModelVersion patches the modelRef field on a ModelDeployment.
func (r *ToolRegistry) promoteModelVersion(ctx context.Context, req *http.Request, args map[string]any) (any, error) {
	// Token guard — structural security, not behavioural.
	if r.opts.PromoteToken == "" {
		return nil, fmt.Errorf("tools: promote_model_version is disabled (PROMOTE_TOKEN not set)")
	}
	if req.Header.Get("X-Promote-Token") != r.opts.PromoteToken {
		return nil, fmt.Errorf("tools: promote_model_version: invalid or missing X-Promote-Token")
	}

	name_, _ := args["name"].(string)
	newTag, _ := args["new_tag"].(string)
	ns := stringArg(args, "namespace", "inference")

	if name_ == "" || newTag == "" {
		return nil, fmt.Errorf("tools: promote_model_version: 'name' and 'new_tag' are required")
	}
	if r.dynClient == nil {
		return nil, fmt.Errorf("tools: kubernetes client not available")
	}

	// Strategic merge patch: update only the modelRef field.
	patch := map[string]any{
		"spec": map[string]any{
			"modelRef": newTag,
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return nil, err
	}

	updated, err := r.dynClient.Resource(modelDeploymentGVR).Namespace(ns).Patch(
		ctx, name_, types.MergePatchType, patchBytes, metav1.PatchOptions{},
	)
	if err != nil {
		return nil, fmt.Errorf("tools: promote_model_version patch %s/%s: %w", ns, name_, err)
	}

	r.opts.Logger.Info("promote_model_version applied",
		slog.String("name", name_),
		slog.String("namespace", ns),
		slog.String("new_tag", newTag),
	)

	return map[string]any{
		"name":      updated.GetName(),
		"namespace": updated.GetNamespace(),
		"new_tag":   newTag,
		"status":    "patch_applied",
	}, nil
}

// queryPrometheus executes a PromQL instant query and returns the result vector.
func (r *ToolRegistry) queryPrometheus(ctx context.Context, query, evalTime string) (any, error) {
	params := url.Values{}
	params.Set("query", query)
	if evalTime != "" {
		params.Set("time", evalTime)
	}

	endpoint := r.opts.PrometheusURL + "/api/v1/query?" + params.Encode()
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("tools: prometheus build request: %w", err)
	}

	resp, err := r.httpCli.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("tools: prometheus query: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("tools: prometheus query returned %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20)) // 2 MiB cap
	if err != nil {
		return nil, fmt.Errorf("tools: prometheus read body: %w", err)
	}

	var promResult any
	if err := json.Unmarshal(body, &promResult); err != nil {
		return nil, fmt.Errorf("tools: prometheus parse response: %w", err)
	}
	return promResult, nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// summariseList converts an unstructured list into a compact JSON-serialisable slice.
func summariseList(list *unstructured.UnstructuredList) []map[string]any {
	out := make([]map[string]any, 0, len(list.Items))
	for _, item := range list.Items {
		out = append(out, map[string]any{
			"name":      item.GetName(),
			"namespace": item.GetNamespace(),
			"spec":      item.Object["spec"],
			"status":    item.Object["status"],
		})
	}
	return out
}

// stringArg extracts a string from args, returning def if absent or wrong type.
func stringArg(args map[string]any, key, def string) string {
	if v, ok := args[key].(string); ok && v != "" {
		return v
	}
	return def
}
