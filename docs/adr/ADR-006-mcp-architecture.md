# ADR-006 — AI Assistant Architecture: Model Context Protocol (MCP)

| Field       | Value                                                      |
|-------------|------------------------------------------------------------|
| **Status**  | Accepted                                                   |
| **Date**    | 2025-01-01                                                 |
| **Author**  | Platform Engineering                                       |
| **Refs**    | ADR-001, ADR-002, Phase 6 curriculum, PM-001               |

---

## Context

Phase 6 of the AI Platform Lab deploys an AI assistant workload that can reason about live
cluster state — inference queue depth, TTFT p99, replica counts, pod health. Two architectural
approaches were evaluated for giving the LLM access to this telemetry:

1. **Text-based RAG**: Embed cluster telemetry into a vector database (Qdrant, already deployed
   in Phase 5). At query time, retrieve relevant document chunks and inject them into the prompt.

2. **Model Context Protocol (MCP)**: Deploy open-source MCP server containers in the cluster.
   The LLM assistant acts as an MCP client, calling structured tools that execute live queries
   against the Kubernetes API and Prometheus in real time.

---

## Decision Drivers

1. **Vendor neutrality**: No proprietary agent control plane. Any MCP-compatible LLM host
   can use the same MCP servers without modification.
2. **Structural security**: The LLM must not be able to mutate cluster state, even under
   adversarial prompting or model jailbreak. This must be a structural guarantee, not a
   behavioural one.
3. **Data freshness**: Infrastructure telemetry is meaningless if stale. A live PromQL
   query returns the current value; an embedded vector chunk returns whatever was indexed
   minutes or hours ago.
4. **Auditability**: Every tool call is a discrete JSON-RPC 2.0 request that can be logged,
   replayed, and audited. RAG retrieval operations are opaque by comparison.
5. **Consistency with zero-trust posture**: The security model must integrate with the
   existing Consul mTLS mesh, Vault secret injection, and NetworkPolicy stack.

---

## Options Considered

### Option A: Text-Based RAG (rejected)

Deploy a vector database (Qdrant — already in `workloads/ai-assistant/qdrant.yaml`). Run a
scheduled Argo Workflow that scrapes Prometheus and Kubernetes events, embeds them, and
stores them in Qdrant. At query time, the assistant retrieves relevant chunks and injects
them into the prompt.

**Rejected because:**
- Telemetry staleness is structurally unavoidable. A pod OOMKill at 15:03 is not in the
  index until the next scheduled ingestion run, which may be 15:15.
- The retrieval operation returns text chunks — the LLM must parse structure from unstructured
  text, which introduces hallucination surface when field names or units are ambiguous.
- RAG does not address the mutation risk. If the ingestion pipeline also writes to the cluster
  (e.g., updates a ConfigMap to record the index state), you have an LLM-adjacent process with
  write permissions.

**Retained use case:** RAG remains appropriate for static knowledge (runbooks, ADRs, postmortem
summaries). Phase 5's Qdrant deployment is kept for this purpose. MCP serves live telemetry;
RAG serves static documentation.

### Option B: Direct Kubernetes API Access via ServiceAccount (rejected)

Grant the ai-assistant pod a Kubernetes ServiceAccount with `get`, `list`, `watch` verbs and
access the API directly from the assistant code using the Python kubernetes client.

**Rejected because:**
- The SA permissions travel with the pod. If the ai-assistant pod is compromised (prompt
  injection, container escape), the attacker has direct K8s API access.
- There is no standard protocol layer between the LLM and the API. The LLM is making
  raw function calls — if the model host changes, the integration must be rewritten.
- Extending to more data sources (Prometheus, Vault audit logs, Grafana annotations) requires
  adding more permissions to the SA, expanding the blast radius over time.

### Option C: Proprietary Agent Control Plane (rejected)

Use a proprietary hosted agent orchestration platform (Coder, Langfuse agent mode,
LangSmith tracing + LangGraph execution) to manage tool calling.

**Rejected because:**
- Vendor lock-in: If the vendor changes pricing, deprecates the API, or is acquired, the
  entire Phase 6 architecture requires replacement.
- High abstraction overhead: these platforms hide the JSON-RPC tool call layer, which is
  exactly the layer that needs to be understood and debugged at the platform-engineer level.
- Most are SaaS with data egress: tool call inputs/outputs (which may include metric values
  and pod names) leave the cluster boundary.

### Option D: Open-Source MCP Servers (selected)

Deploy two open-source MCP server containers in the `inference` namespace:
- `mcp-kubernetes`: translates LLM tool calls into read-only Kubernetes API requests
- `mcp-prometheus`: translates LLM tool calls into PromQL queries against the platform's
  Prometheus instance

The ai-assistant pod is the MCP client. It has **no Kubernetes RBAC permissions**. It calls
tools via HTTP+SSE JSON-RPC 2.0 and receives structured JSON results.

---

## Decision

**Use open-source MCP servers (HTTP+SSE transport) as the interface between the AI assistant
and all live cluster data sources.**

**Architectural boundaries:**

| Component | K8s RBAC | Vault Secrets | Consul Sidecar | Network Egress |
|---|---|---|---|---|
| ai-assistant | None | Ollama API key | Yes | mcp-kubernetes:8080, mcp-prometheus:8080, ollama-server:11434 |
| mcp-kubernetes | Read-only ClusterRole | None required | Yes | K8s API :6443 only |
| mcp-prometheus | None | Prometheus bearer token (if auth) | Yes | Prometheus :9090 only |

**Transport:** HTTP+SSE. stdio transport is incompatible with Kubernetes pod networking and
is explicitly not used. See Phase 6 curriculum Week 1 for the rationale.

**MCP server tool whitelist (Kubernetes):**

```
ALLOWED:  get_pod, list_pods, get_deployment, list_deployments, get_events, get_logs
BLOCKED:  create_*, delete_*, patch_*, apply_*, exec_*, port_forward_*
```

The "BLOCKED" tools are enforced at two independent layers:
1. **MCP server tool registry**: blocked tools are simply not registered in the server.
   The LLM never sees them in the capability advertisement, so it cannot call them.
2. **RBAC**: the `mcp-kubernetes` ServiceAccount's ClusterRole has only `get`, `list`,
   `watch` verbs. Even if a blocked tool is somehow called, the K8s API returns 403.
   This is the structural defence-in-depth guarantee.

---

## Security Architecture

### RBAC — least privilege for mcp-kubernetes

```yaml
# ClusterRole: read-only access scoped to inference-relevant resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mcp-kubernetes-readonly
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "events", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["keda.sh"]
    resources: ["scaledobjects"]
    verbs: ["get", "list", "watch"]
# Explicitly absent: create, update, patch, delete, exec, portforward
```

### Consul Intentions — mesh-layer isolation

The Consul intention set enforces that only the ai-assistant can call the MCP servers.
Even if another pod in the cluster is compromised and attempts to call mcp-kubernetes,
the Consul mesh's L7 policy rejects the connection.

See `workloads/multi-tenant/consul-intentions.yaml` for the full intention set.

### Vault Secret Injection — no static credentials

The mcp-prometheus pod's Prometheus bearer token (if Prometheus auth is enabled) is
injected via Vault Agent sidecar, identical to the HuggingFace token pattern in ADR-002.

---

## Consequences

**Positive:**
- The AI assistant has zero Kubernetes RBAC permissions. Structural guarantee against
  cluster mutation, not a behavioural one.
- MCP is an open standard. Swapping the LLM model host (Ollama → vLLM → future model)
  requires only changing the OpenAI API client call — the MCP servers are unchanged.
- Tool calls are discrete JSON-RPC requests — fully loggable. Audit trail is automatic.
- RAG (Qdrant) is retained for static knowledge; MCP handles live telemetry. Clean
  separation of concerns.

**Negative / Risks:**
- MCP is a newer standard (~2024). The open-source server ecosystem is early-stage;
  some upstream images may lack ARM64 builds, requiring custom wrapper images.
- HTTP+SSE is less battle-tested than gRPC for high-frequency streaming. For this lab
  (low query volume), this is not a concern, but should be noted for production scale.
- Tool schema maintenance: if the Prometheus metric names change (e.g., a vLLM version
  upgrade renames a metric), the PromQL in tool call arguments must be updated manually.
  This is a documentation/operational concern, not a security concern.

**Open questions:**
- MCP authorization layer: the current spec does not define per-tool authorisation scopes.
  A future version may allow the MCP server to enforce that only certain callers can call
  certain tools. Until then, the Consul intention is the authorisation boundary.
- Streaming tool results: if a `get_logs` call returns a large log stream, the SSE transport
  handles this naturally. Validate the LLM host's SSE client can handle multi-chunk responses
  without buffering the entire response in memory.

---

## Amendment — F3: Custom Go MCP Server (platform/mcp-server/)

| Field    | Value                                                     |
|----------|-----------------------------------------------------------|
| **Date** | 2025-07-01                                                |
| **Refs** | ADR-006, Phase 6 curriculum Week 3, F3 FDE Coding Module  |

### Context

During MCP Phase 6 Week 3, a gap was identified: the existing open-source
`mcp-kubernetes` and `mcp-prometheus` containers do not expose a
`promote_model_version` tool — the ability for an AI assistant to trigger
a model rollout via a structured, auditable tool call.

A custom Go MCP server was built in `platform/mcp-server/` to close this gap
and to demonstrate the full MCP server implementation pattern at the
Staff-level.

### Decision

**Deploy a custom Go MCP server (`platform/mcp-server/`) alongside the upstream
open-source containers.** The custom server adds:

| Tool | Type | Notes |
|------|------|-------|
| `list_model_deployments` | Read | Uses dynamic K8s client against `platform.ai/v1alpha1` |
| `get_model_deployment` | Read | Returns spec + status; replaces raw kubectl calls |
| `promote_model_version` | Write (guarded) | Requires X-Promote-Token (Vault-injected, 15-min TTL) |
| `query_inference_metrics` | Read | Executes PromQL against Prometheus HTTP API |

### Security Analysis — `promote_model_version`

The write tool has a **two-layer guard**:

1. **Application layer**: `X-Promote-Token` header must match `PROMOTE_TOKEN`
   env var, which is injected by Vault Agent at pod startup with a 15-minute TTL.
   After TTL expiry, the token file is refreshed by Vault Agent — the old token
   immediately fails.

2. **RBAC layer**: The `mcp-server` ServiceAccount's ClusterRole contains only
   `patch` on `platform.ai/modeldeployments`. No `create`, `delete`, `exec`,
   `apply`, or `escalate` verbs exist in the role. Even if the application-layer
   token guard were bypassed, the K8s API would reject any other write operation.

This matches the defence-in-depth principle established in ADR-005.

### Transport

The custom server uses HTTP+SSE transport (same as the upstream containers).
stdio transport is not used — see the existing ADR-006 rationale above.

The server registers a Consul `ServiceDefaults` entry that forces `protocol: http`
to prevent HTTP/2 upgrade, which is incompatible with SSE long-polling.

### Deployment

See `workloads/ai-assistant/mcp-model-registry-deployment.yaml` for the full
Deployment, ClusterRole, NetworkPolicy, and Consul ServiceDefaults manifests.

The custom server is deployed as a separate `mcp-model-registry` Deployment
alongside the existing `mcp-kubernetes` and `mcp-prometheus` containers.
It does not replace them.

### Updated Architectural Boundaries Table

| Component | K8s RBAC | Vault Secrets | Consul Sidecar | Network Egress |
|---|---|---|---|---|
| ai-assistant | None | Ollama API key | Yes | mcp-kubernetes:8080, mcp-prometheus:8080, **mcp-model-registry:8080**, ollama-server:11434 |
| mcp-kubernetes | Read-only ClusterRole | None | Yes | K8s API :6443 |
| mcp-prometheus | None | Prometheus bearer token | Yes | Prometheus :9090 |
| **mcp-model-registry** | **patch on ModelDeployments only** | **PROMOTE_TOKEN (15-min TTL)** | **Yes** | **K8s API :6443, Prometheus :9090** |
