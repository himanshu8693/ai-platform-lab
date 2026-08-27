# Phase 6 Curriculum: AI Assistant Workload via Model Context Protocol (MCP)

**Phase gate:** Month 12 of 18  
**Duration:** 6 weeks (3 evenings/week × 1.5 hrs + 1 weekend/week × 4 hrs)  
**Prerequisite gates:** Phase 5 complete — Consul mTLS active, Vault Agent injection working,
Kyverno policies enforcing, KEDA dual-trigger operational, ARB patches 1–10 applied.

---

## Why MCP Instead of Text-Based RAG

The previous Phase 6 design used text-based RAG: embed cluster telemetry into a vector
database, retrieve relevant chunks at query time, inject them into a prompt. This works
for static documentation but is wrong for live infrastructure telemetry:

| Problem | RAG approach | MCP approach |
|---|---|---|
| Stale metrics | Telemetry embedded at index time — stale by minutes | LLM calls a tool, Prometheus responds in real time |
| Vendor lock-in | LangChain / LlamaIndex abstract the tool layer | MCP is an open spec; swap client implementations freely |
| Mutation risk | Text retrieval cannot mutate state — but a code agent using LangChain tools CAN | MCP ServiceAccount is read-only at the RBAC layer — mutation is structurally impossible |
| Schema opacity | The LLM must infer structure from text | MCP tools carry a JSON Schema; the LLM knows exact field names and types |
| Auditability | Agent actions are inside the LLM chain | MCP tool calls are discrete JSON-RPC 2.0 requests — fully loggable and replayable |

**Architectural principle (unchanged):** "The platform is the product; the AI assistant is
a workload consuming live system telemetry." MCP is the protocol that makes that consumption
structured, safe, and auditable.

---

## What MCP Is (Senior Engineer Definition)

MCP is an open JSON-RPC 2.0 protocol over either **stdio** (local subprocess) or **HTTP+SSE**
(network transport). A client (the LLM host) discovers what a server can do via a capability
negotiation handshake, then calls tools by name with typed parameters. The server executes
the tool and returns structured results. The LLM never executes code directly — it requests
a tool call, the server validates and executes it, the result returns as structured JSON.

```
┌─────────────────────────────────────────────────────────────────────┐
│  MCP Protocol Stack                                                   │
│                                                                       │
│  LLM Host (ai-assistant pod)                                          │
│    │                                                                  │
│    │  JSON-RPC 2.0 request: { method: "tools/call",                  │
│    │    params: { name: "query_prometheus",                           │
│    │              arguments: { query: "sum(vllm_num_waiting...)" }}} │
│    │                                                                  │
│    ▼  HTTP + SSE transport (in-cluster, port 8080)                   │
│                                                                       │
│  MCP Server (mcp-prometheus pod)                                      │
│    │                                                                  │
│    │  Validates against JSON Schema for "query_prometheus" tool       │
│    │  Executes PromQL against Prometheus API                          │
│    │  Returns: { result: [{ metric: {...}, value: [...] }] }          │
│    │                                                                  │
│    ▼  JSON-RPC 2.0 response                                           │
│                                                                       │
│  LLM Host receives structured result → feeds into next prompt turn    │
└─────────────────────────────────────────────────────────────────────┘
```

### The five MCP primitives you must understand

| Primitive | What it is | Enterprise relevance |
|---|---|---|
| **Tool** | A callable function exposed by the server with a JSON Schema input definition | The primary primitive — every Prometheus query, every `kubectl get` is a Tool |
| **Resource** | A URI-addressable piece of data the server can expose (e.g., a log file, a metric snapshot) | Useful for static platform docs or runbook content the LLM should always have in context |
| **Prompt** | A server-defined prompt template the client can request | Used for standardising how the assistant frames infrastructure questions |
| **Sampling** | Client asks the server to perform an LLM inference call on its behalf | Rarely used in infrastructure scenarios; skip for now |
| **Transport** | stdio (subprocess) or HTTP+SSE (network) | **You will use HTTP+SSE exclusively** — stdio is incompatible with Kubernetes pod networking |

### Transport selection: why HTTP+SSE, not stdio

`stdio` transport runs the MCP server as a local subprocess of the client process. This is
what Cursor/Claude Desktop use for local developer tooling. In Kubernetes you cannot co-locate
a subprocess with a pod and preserve the pod's isolation boundary. Every MCP server you deploy
in this lab **runs as a separate pod** and communicates over HTTP with Server-Sent Events (SSE)
for streaming responses.

```
stdio transport  (dev laptop only):
  [MCP Client process] ──stdin/stdout──▶ [MCP Server subprocess]

HTTP+SSE transport (Kubernetes — this lab):
  [ai-assistant pod] ──HTTP POST /mcp──▶ [mcp-kubernetes pod :8080]
                     ◀──SSE stream───────
```

---

## Phase 6 Learning Objectives

### Week 1 — MCP Protocol Internals (12 hrs)

**Goal:** Read the MCP specification well enough to debug a broken tool call at the JSON-RPC
layer without relying on client library abstractions.

**Study materials (in order):**
1. `https://modelcontextprotocol.io/specification` — read the full Transport, Protocol,
   Server, and Tools sections. Skip Sampling and Prompts for now. (~3 hrs)
2. `https://github.com/modelcontextprotocol/python-sdk` — read `server.py`, `client.py`,
   and the `examples/` directory. Focus on how `@server.tool()` decorator translates to
   the JSON Schema advertised during capability negotiation. (~2 hrs)
3. Capture a real MCP negotiation with `tcpdump` or Wireshark once the lab is running.
   Decode the JSON-RPC frames manually. You must be able to explain what happens between
   `initialize` request and the first `tools/call` without looking at docs.

**Lab deliverable:** Write a minimal MCP server in Python (20–30 lines) that exposes a
single tool `get_current_time` with a JSON Schema input of `{}` and a string response.
Run it locally with `uvicorn`, call it with `curl`, decode the SSE response manually.

```python
# skeleton — fill in the JSON-RPC framing yourself
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("lab-test-server")

@mcp.tool()
def get_current_time() -> str:
    """Returns the current UTC time. Used to verify MCP transport is working."""
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()

if __name__ == "__main__":
    mcp.run(transport="sse")   # HTTP+SSE, not stdio
```

---

### Week 2 — Prometheus MCP Server Deployment (12 hrs)

**Target container:** `pab1it0/prometheus-mcp-server` (or build your own wrapper using
`prometheus-client` + `mcp` Python SDK if the upstream image lacks ARM64 support).

**Goal:** The ai-assistant pod can ask "What is the current TTFT p99?" and receive a real
PromQL result as a structured JSON tool response.

**Study: PromQL as a typed MCP tool argument**

The Prometheus MCP server exposes a tool like:

```json
{
  "name": "execute_query",
  "description": "Execute a PromQL instant query against the Prometheus API",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "A valid PromQL expression"
      },
      "time": {
        "type": "string",
        "description": "Evaluation timestamp in RFC3339 or Unix timestamp (optional)"
      }
    },
    "required": ["query"]
  }
}
```

**Critical learning:** The JSON Schema `inputSchema` is what the LLM reads to decide how
to call the tool. If the schema is wrong (missing required fields, wrong types), the LLM
will either fail to call the tool or pass invalid arguments that the server must validate
and reject. You must understand JSON Schema draft 7 at the level of being able to write
and debug `inputSchema` objects for your own tools.

**Lab deliverables:**

1. Deploy `mcp-prometheus` pod in the `inference` namespace using the manifests in
   `workloads/ai-assistant/mcp-prometheus-deployment.yaml`.
2. Verify capability negotiation:
   ```bash
   curl -N -H "Accept: text/event-stream" \
     http://mcp-prometheus.inference.svc.cluster.local:8080/sse
   # Expect SSE stream; first event should be the server's capability advertisement
   ```
3. Execute a raw tool call without the LLM in the loop (proves the server works before
   adding the assistant):
   ```bash
   curl -X POST http://mcp-prometheus.inference.svc.cluster.local:8080/mcp \
     -H "Content-Type: application/json" \
     -d '{
       "jsonrpc": "2.0",
       "id": 1,
       "method": "tools/call",
       "params": {
         "name": "execute_query",
         "arguments": {
           "query": "histogram_quantile(0.99, rate(vllm_time_to_first_token_seconds_bucket[5m]))"
         }
       }
     }'
   ```
4. Confirm the response contains the TTFT p99 value from your mock DCGM exporter.

---

### Week 3 — Kubernetes MCP Server Deployment (12 hrs)

**Target container:** `ghcr.io/strowger/kubernetes-mcp-server` or
`ghcr.io/giantswarm/mcp-kubernetes`. Evaluate both for ARM64 support; build a custom
wrapper if neither has a clean ARM64 image (the MCP Python SDK + `kubernetes` Python
client is ~50 lines to wrap the most useful tools).

**Goal:** The ai-assistant pod can ask "How many llama3 replicas are ready?" and receive
a real Kubernetes API response — without the AI assistant having ANY Kubernetes RBAC
permissions. The MCP server holds the RBAC; the assistant only holds the ability to talk
to the MCP server.

**Critical architectural point (interview-grade):**

The RBAC separation is the key security property:

```
Without MCP:
  [ai-assistant pod] ── ServiceAccount with kubectl permissions ──▶ K8s API
  # If the LLM is jailbroken or the pod is compromised, the attacker has
  # direct K8s API access with whatever the SA allows.

With MCP (this lab):
  [ai-assistant pod] ── no K8s SA permissions ──▶ [mcp-kubernetes pod]
                                                         │
                                                         └── ServiceAccount
                                                              with read-only
                                                              RBAC ──▶ K8s API
  # The ai-assistant pod has zero K8s API permissions.
  # The mcp-kubernetes pod has read-only permissions.
  # Even a fully compromised ai-assistant pod cannot mutate cluster state —
  # there is no path from the assistant to the K8s API that bypasses the MCP server.
  # And the MCP server's ServiceAccount has no write verbs at all.
```

**Lab deliverables:**
1. Deploy `mcp-kubernetes` pod using `workloads/ai-assistant/mcp-kubernetes-deployment.yaml`.
2. Verify the ServiceAccount bound to mcp-kubernetes has ONLY `get`, `list`, `watch` verbs
   — no `create`, `update`, `patch`, `delete`.
3. Execute a tool call that lists pods in the inference namespace and confirm the response.
4. Attempt a tool call that would create a resource and confirm it fails at the RBAC layer
   with a `403 Forbidden` — not at the MCP tool layer. This proves defence-in-depth: even
   if someone adds a "create pod" tool to the server, the SA cannot execute it.

---

### Week 4 — AI Assistant Client Deployment (12 hrs)

**Goal:** Deploy the ai-assistant pod that acts as the MCP client, integrating both
MCP servers and your local Ollama inference backend.

**G1 prerequisite (do this before writing the assistant client):** Read `scripts/examples/agent-tool-loop.py` — a standalone 60-line Anthropic SDK tool-use loop that calls two stub tools and handles the full `ToolUseBlock` → `ToolResultBlock` cycle. Running this locally with `uv run scripts/examples/agent-tool-loop.py` costs ~$0.002 in API tokens and gives you the conceptual model before you wire it to real MCP servers. The Week 4 assistant client below is this same pattern extended with real MCP dispatch.

**Implementation approach:** Use the `openai` Python SDK (or `httpx` directly) to drive
Ollama's OpenAI-compatible API, combined with the `mcp` Python SDK's client component
to connect to both MCP servers. This is ~150 lines of typed Python — well within scope
for an infrastructure engineer. No LangChain. No LlamaIndex. No abstraction layers.

**The assistant's tool loop (must understand this cold):**

```python
# Conceptual flow — not exact code, understand the pattern
async def run_assistant_turn(user_message: str) -> str:
    # 1. Discover tools from both MCP servers
    k8s_tools = await k8s_mcp_client.list_tools()     # returns JSON Schema list
    prom_tools = await prom_mcp_client.list_tools()    # returns JSON Schema list
    all_tools = k8s_tools + prom_tools

    # 2. Convert MCP tool schemas → OpenAI function-calling format
    openai_functions = [mcp_tool_to_openai_function(t) for t in all_tools]

    # 3. First LLM call — LLM decides which tools to call
    response = await ollama_client.chat(
        model="llama3.2:3b",
        messages=[{"role": "user", "content": user_message}],
        tools=openai_functions,    # function-calling format
    )

    # 4. If the LLM requested tool calls, execute them via MCP servers
    if response.tool_calls:
        tool_results = []
        for tc in response.tool_calls:
            # Route to the correct MCP server by tool name prefix
            result = await dispatch_tool_call(tc.function.name, tc.function.arguments)
            tool_results.append({"role": "tool", "content": result, "tool_call_id": tc.id})

        # 5. Second LLM call — LLM synthesises tool results into a natural language answer
        final_response = await ollama_client.chat(
            model="llama3.2:3b",
            messages=[
                {"role": "user", "content": user_message},
                response.message,          # the tool_call request
                *tool_results,             # the tool results
            ],
        )
        return final_response.message.content

    return response.message.content
```

**Lab deliverables:**
1. `workloads/ai-assistant/ai-assistant-deployment.yaml` deployed and healthy.
2. End-to-end demo: send a query via `kubectl exec` into the assistant pod, confirm
   it calls at least one MCP tool and returns a coherent answer.
3. Query: *"What is the current TTFT p99 for llama3.2:3b, and how many replicas are ready?"*
   — this forces tool calls to both MCP servers in a single turn.

---

### Week 5 — Security Hardening (9 hrs)

**Goal:** Every component in `workloads/ai-assistant/` is hardened against the zero-trust
security model established in Phases 2 and 5.

**Checklist:**

```
□ RBAC
  □ mcp-kubernetes ServiceAccount: read-only ClusterRole, no write verbs
  □ mcp-prometheus ServiceAccount: no K8s API permissions (only needs Prometheus HTTP)
  □ ai-assistant ServiceAccount: no K8s API permissions at all
  □ All ServiceAccounts: automountServiceAccountToken: false (explicitly opt-in only)

□ NetworkPolicy (added to workloads/inference/networkpolicy.yaml)
  □ ai-assistant → mcp-kubernetes: egress allow on :8080
  □ ai-assistant → mcp-prometheus: egress allow on :8080
  □ ai-assistant → ollama-server: egress allow on :11434
  □ mcp-prometheus → prometheus: egress allow on :9090
  □ mcp-kubernetes → Kubernetes API: egress allow on :6443
  □ All other traffic: denied by existing default-deny-all policy

□ Consul Intentions (added to workloads/multi-tenant/consul-intentions.yaml)
  □ ai-assistant → mcp-kubernetes: allow, GET/POST on /mcp and /sse paths only
  □ ai-assistant → mcp-prometheus: allow, GET/POST on /mcp and /sse paths only
  □ No other service may call mcp-kubernetes or mcp-prometheus

□ Vault Secret Injection
  □ mcp-kubernetes: Vault injects K8s SA token (if using dynamic SA tokens)
  □ mcp-prometheus: Vault injects Prometheus bearer token (if Prometheus auth enabled)
  □ ai-assistant: Vault injects Ollama API key (if auth enabled in serving runtime)

□ Kyverno / Supply Chain
  □ All three pods reference signed images (cosign.pub verified)
  □ All three pods: runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation: false
  □ RHACS audit: no wget/curl policy violation in any of the three images

□ Pod Security
  □ All three deployments: securityContext enforced at pod and container level
  □ Resource requests and limits set (prevents noisy-neighbour DoS on inference capacity)
```

---

### Week 6 — Observability, ADR, and Portfolio Polish (9 hrs)

**Goal:** The MCP layer is observable to the same depth as the inference layer.

**Metrics to instrument in the AI assistant:**

```python
# Add to ai-assistant's prometheus_client instrumentation

# Count of MCP tool calls, labelled by server and tool name
mcp_tool_calls_total = Counter(
    "ai_assistant_mcp_tool_calls_total",
    "MCP tool calls dispatched",
    ["server", "tool_name", "status"],   # status: success | error | timeout
)

# Latency of MCP tool calls (your SLO: p99 < 2s for K8s API, p99 < 5s for PromQL)
mcp_tool_call_duration_seconds = Histogram(
    "ai_assistant_mcp_tool_call_duration_seconds",
    "MCP tool call round-trip latency",
    ["server", "tool_name"],
    buckets=(0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0),
)

# Count of LLM turns per conversation (tracks context window pressure)
llm_turns_per_conversation = Histogram(
    "ai_assistant_llm_turns_total",
    "Number of LLM round-trips per user query (>3 = complex tool-use chain)",
    buckets=(1, 2, 3, 4, 5, 8, 10),
)
```

**Grafana dashboard additions:**
- MCP tool call rate by server (Prometheus vs Kubernetes)
- MCP tool call error rate (should be near 0; spikes indicate RBAC or network issues)
- LLM turns per query p95 (measures reasoning depth and latency budget)
- AI assistant to MCP server latency p99

**ADR deliverable:** `docs/adr/ADR-006-mcp-architecture.md` (already written).

**Portfolio writeup:** Add a section to `README.md` titled
"Phase 6: AI Assistant as MCP Client" with:
- Architecture diagram (text-art is fine — see template below)
- The security isolation argument: why the assistant has zero K8s RBAC
- A recorded demo (ASCII cast or terminal recording) of the two-server tool call

---

## Architecture Diagram

```
┌─────────────────────────────── inference namespace ──────────────────────────────────┐
│                                                                                        │
│  ┌─────────────────────┐    MCP HTTP+SSE     ┌────────────────────────┐               │
│  │   ai-assistant      │ ──────────────────▶ │   mcp-kubernetes       │               │
│  │                     │    :8080/mcp         │                        │               │
│  │  ServiceAccount:    │ ◀────────────────── │  ServiceAccount:       │──▶ K8s API   │
│  │  (no K8s perms)     │    SSE stream        │  mcp-k8s-sa            │   :6443      │
│  │                     │                      │  (read-only ClusterRole│   (read only)│
│  │  Vault: Ollama key  │    MCP HTTP+SSE     └────────────────────────┘               │
│  │        ↕ injected   │ ──────────────────▶ ┌────────────────────────┐               │
│  │                     │    :8080/mcp         │   mcp-prometheus       │               │
│  │  app: ai-assistant  │ ◀────────────────── │                        │──▶ Prometheus │
│  └─────────────────────┘    SSE stream        │  ServiceAccount:       │   :9090      │
│           │                                   │  mcp-prom-sa           │   (no K8s    │
│           │ OpenAI-compat API                 │  (no K8s perms)        │    RBAC)     │
│           ▼ :11434                            └────────────────────────┘               │
│  ┌─────────────────────┐                                                               │
│  │   ollama-server     │   ← inference backend (existing Phase 2 workload)             │
│  │  (existing pod)     │                                                               │
│  └─────────────────────┘                                                               │
│                                                                                        │
│  Consul mTLS active across all pod-to-pod paths                                        │
│  NetworkPolicy: default-deny-all + explicit allow rules only                           │
│  Vault Agent: secret injection for all pods with vault.hashicorp.com/agent-inject      │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## MCP Server Selection Rationale

### Kubernetes MCP Server

**Evaluated options:**

| Image | ARM64 | Stars | Maintenance | Verdict |
|---|---|---|---|---|
| `ghcr.io/strowger/kubernetes-mcp-server` | ✓ multi-arch | ~200 | Active 2024-25 | **First choice** |
| `ghcr.io/giantswarm/mcp-kubernetes` | ✓ multi-arch | ~400 | Active 2024-25 | **Fallback** |
| Custom wrapper (python-sdk + kubernetes client) | ✓ build your own | N/A | You own it | Use if upstream is missing a critical tool |

**Tools you need from the Kubernetes MCP server:**

```
get_pod           — get a single pod by name/namespace
list_pods         — list pods in a namespace with optional label selector
get_deployment    — get deployment status (readyReplicas, conditions)
list_deployments  — list deployments in a namespace
get_events        — get events for a namespace (critical for diagnosing pod failures)
get_logs          — tail recent logs from a pod/container (hard limit: last 100 lines)
```

**Tools you must explicitly NOT expose:**

```
create_*          — never expose any create verb
delete_*          — never expose any delete verb
patch_*           — never expose any patch verb
exec_*            — never expose exec into pods (equivalent to shell access)
port_forward_*    — never expose port forwarding
```

### Prometheus MCP Server

**Evaluated options:**

| Image | ARM64 | Verdict |
|---|---|---|
| `pab1it0/prometheus-mcp-server` | Check on release; may need multi-arch build | **First choice** |
| Custom FastMCP wrapper (~50 lines) | ✓ build your own | Use if upstream lacks ARM64 |

**Tools you need from the Prometheus MCP server:**

```
execute_query        — instant PromQL query (current value)
execute_range_query  — range PromQL query (time series over a window)
list_metrics         — list available metric names (helps LLM discover what to query)
get_metric_metadata  — get type/help text for a metric (helps LLM construct correct PromQL)
```

---

## Interview Readiness: The Three Questions You Will Be Asked

### Q1: "Why not just give the LLM agent a kubectl plugin and let it run commands directly?"

**Answer:** "Because you can't express 'read-only' as a safety property of a kubectl binary —
you can configure RBAC, but you're now trusting the LLM to only invoke safe commands, which
is not a security guarantee. With MCP, the safety boundary moves to the ServiceAccount, which
is a Kubernetes-enforced control. The RBAC `ClusterRole` has literally no write verbs. Even
if the LLM constructs a tool call that would create a resource, the MCP server passes that
request to the K8s API and gets a 403 back. The LLM cannot bypass this, because neither the
ai-assistant pod nor the mcp-kubernetes pod has the RBAC permissions to succeed. That is a
structural guarantee, not a behavioural one."

### Q2: "What happens if the Prometheus MCP server is compromised?"

**Answer:** "The Prometheus MCP server's ServiceAccount has zero Kubernetes RBAC permissions.
If it is compromised, the attacker can read Prometheus metrics — the same data that is already
publicly exposed on `/metrics` endpoints by Prometheus design. They cannot reach the Kubernetes
API, the Vault namespace, or any other service, because the NetworkPolicy only permits egress
from mcp-prometheus to port 9090 on Prometheus. The Consul intention permits only the
ai-assistant to call mcp-prometheus — lateral movement from a compromised mcp-prometheus pod
to any other service is blocked at both the NetworkPolicy and service-mesh layer."

### Q3: "How is this different from function calling without MCP?"

**Answer:** "In OpenAI function calling without MCP, the LLM specifies a function name and
arguments, and your code executes it. There is no standard protocol for capability discovery,
no standard transport, no standard error format, and no server lifecycle management. If you
want to reuse your 'kubectl tool' in a different LLM host, you rewrite the integration.
MCP defines a standard JSON-RPC protocol with standard lifecycle methods: `initialize`,
`tools/list`, `tools/call`, `resources/list`. Any MCP-compatible client — today Ollama,
tomorrow a different model host — can discover and call your tools without modification.
That is the vendor-neutrality argument: I'm not locked into any model host or agent framework,
because the tool servers speak a standard protocol."

---

## Week 7 — IBM Context Forge Gateway: AI Governance Layer (9 hrs)

**Reference:** `docs/adr/ADR-007-context-forge-gateway.md`

**Gate for this week:** Weeks 1–6 complete. The ai-assistant is working end-to-end with
direct connections to mcp-prometheus and mcp-kubernetes. ADR-006 is finalised. This week
inserts Context Forge as an additive governance layer without removing anything that already
works.

### Why Context Forge (the exact argument)

The ADR-006 direct topology is correct for a two-server setup. It becomes unmanageable at
scale: when you have 8 MCP servers across 4 teams, every new consumer must configure
connections to every server, authentication is duplicated, and there is no central audit
log for the tool call surface. Context Forge solves this the same way an API gateway solves
REST proliferation:

| Problem at scale | Context Forge solution |
|---|---|
| N×M connection matrix (N clients × M servers) | N×1 — every client speaks to one gateway |
| No central tool whitelist | Virtual Server `spec.allowedTools` — anything not listed is invisible to the LLM |
| Per-client JWT configuration | Single gateway holds auth; clients use service tokens minted by gateway |
| No per-tool-call audit trail | Context Forge emits OTel spans per tool call → Grafana Tempo |
| IBM interview story gap | Context Forge → IBM watsonx.governance AI Factsheets (1:1 mapping) |

### Architecture shift (ADR-006 → ADR-007)

```
ADR-006 (direct — Weeks 1–6):
  [ai-assistant] ──JWT?──▶ [mcp-kubernetes :8080]
  [ai-assistant] ──JWT?──▶ [mcp-prometheus :8080]

ADR-007 (Context Forge gateway — Week 7):
  [ai-assistant] ──JWT──▶ [context-forge :4444]
                                    │
                                    ├──▶ [mcp-kubernetes :8080]  (Context Forge is the client)
                                    └──▶ [mcp-prometheus :8080]  (Context Forge is the client)

  Virtual Server "ai-platform-ops" holds the tool whitelist.
  ai-assistant sends ONE MCP initialize to context-forge and sees only the whitelisted tools.
  mcp-kubernetes and mcp-prometheus are no longer directly reachable by ai-assistant
  (NetworkPolicy updated to block the direct paths — Policies 16–21 in context-forge-networkpolicy.yaml).
```

### Deployment sequence (exact order matters for the Bootstrap Job)

**Step 1 — Deploy Context Forge core:**
```bash
kubectl apply -f workloads/ai-assistant/context-forge-deployment.yaml
kubectl rollout status deployment/context-forge -n inference
# Wait for pod to be Ready before proceeding
```

**Step 2 — Verify Vault secret injection:**
```bash
kubectl exec -n inference deployment/context-forge -- \
  ls /vault/secrets/
# Expect: context-forge-jwt.env  context-forge-enc.env
# If missing: check Vault policy in context-forge-vault.yaml is applied
```

**Step 3 — Apply Network Policies (replaces ADR-006 direct rules):**
```bash
kubectl apply -f workloads/ai-assistant/context-forge-networkpolicy.yaml
# This updates the ai-assistant NetworkPolicy to egress only to context-forge:4444
# and adds NetworkPolicy for context-forge to egress to mcp-kubernetes and mcp-prometheus
```

**Step 4 — Deploy catalog ConfigMap + Bootstrap Job:**
```bash
kubectl apply -f workloads/ai-assistant/context-forge-catalog.yaml
kubectl wait --for=condition=complete job/context-forge-bootstrap -n inference --timeout=120s
kubectl logs job/context-forge-bootstrap -n inference
# Expect: "Virtual Server ai-platform-ops created"
#         "Service token stored in Vault KV: secret/ai-platform/context-forge/service-token"
```

**Step 5 — Update ai-assistant to point to Context Forge:**
The `workloads/ai-assistant/deployments.yaml` already has the updated
`CONTEXT_FORGE_URL=http://context-forge.inference.svc.cluster.local:4444`
environment variable. Confirm with:
```bash
kubectl get deployment ai-assistant -n inference -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

**Step 6 — End-to-end verification:**
```bash
# Verify Context Forge sees both upstream MCP servers
kubectl exec -n inference deployment/context-forge -- \
  curl -s http://localhost:4444/admin/gateways | jq .

# Verify Virtual Server tool whitelist is active
kubectl exec -n inference deployment/context-forge -- \
  curl -s http://localhost:4444/admin/virtual-servers/ai-platform-ops | jq .allowedTools

# Verify ai-assistant receives only whitelisted tools (not all tools from both servers)
kubectl exec -n inference deployment/ai-assistant -- \
  python3 -c "
import asyncio
from mcp.client.http import HttpMcpClient
async def main():
    async with HttpMcpClient('http://context-forge.inference.svc.cluster.local:4444') as c:
        tools = await c.list_tools()
        print([t.name for t in tools.tools])
asyncio.run(main())
"
# Expect: only the tools in the Virtual Server allowedTools list
# NOT the full tool list from both servers (this proves whitelist enforcement)
```

### IBM Translation Map (critical for internal transfer interviews)

When speaking to IBM RHOAI / watsonx.ai infrastructure teams, translate every Context Forge
concept immediately:

| Context Forge concept | IBM equivalent | Interview framing |
|---|---|---|
| `Virtual Server` with `allowedTools` | AI Factsheet "allowed capabilities" in watsonx.governance | "We scope what tools an AI agent can call, and that scope is a versioned manifest in Git — same pattern as IBM AI Factsheets governing model capabilities" |
| Context Forge as MCP AI Gateway | IBM AI Governance gateway pattern | "Context Forge is to MCP tools what an API gateway is to REST APIs — central auth, audit, rate limiting" |
| Bootstrap Job minting service token → Vault KV | IBM Secrets Manager + service account credential rotation | "Credentials never appear in pod specs; they are provisioned by the platform and rotated on schedule" |
| OTel traces per tool call → Tempo | IBM Instana trace integration | "Every AI tool call is traceable — we can replay what the agent did, when, and what it returned" |
| Virtual Server tool whitelist = blast-radius control | IBM AI governance risk scorecard | "The whitelist is our risk control artefact — if you add a new MCP tool, it does not reach production until it appears in the Virtual Server manifest and passes the governance review" |

### Security posture after Week 7

The security model improves in one critical dimension: blast radius from a compromised
ai-assistant pod is now bounded by the Virtual Server whitelist, not by the union of
all tools across all MCP servers. Before Week 7, if the assistant were compromised, an
attacker could call any tool on any connected MCP server. After Week 7:

1. **ai-assistant → Context Forge only** (NetworkPolicy enforced — direct paths to
   mcp-kubernetes and mcp-prometheus are blocked)
2. **Context Forge enforces the Virtual Server whitelist** — tools not in `allowedTools`
   return a 403 from the gateway layer, before the request reaches the upstream server
3. **JWT rotation via Vault** — the service token the ai-assistant uses to authenticate
   with Context Forge has a configurable TTL and is rotated without pod restart
4. **OTel audit trail** — every tool call generates a span in Tempo with the tool name,
   arguments, and result status. This is a complete, immutable audit log of agent actions.

---

## Month-by-Month Milestone Checklist

### Month 11 (Weeks 1–3)
- [ ] MCP protocol specification read; can explain JSON-RPC 2.0 framing without docs
- [ ] Minimal MCP server written, deployed locally, tool call verified with raw curl
- [ ] `mcp-prometheus` pod deployed in KinD cluster; PromQL tool call verified
- [ ] `mcp-kubernetes` pod deployed; Kubernetes tool call verified (get pods, get deployment)
- [ ] ADR-006 written and merged to main

### Month 12 (Weeks 4–6) — ADR-006 direct topology complete
- [ ] `ai-assistant` pod deployed; end-to-end two-server tool call working
- [ ] All security controls applied: RBAC, NetworkPolicy, Consul intentions, Vault injection
- [ ] Attempt-to-write-via-MCP test: confirm 403 returned from K8s API
- [ ] MCP tool call metrics instrumented; Grafana panel added
- [ ] Portfolio README updated with Phase 6 ADR-006 section and architecture diagram
- [ ] End-to-end demo recorded (ADR-006 direct topology)

### Month 12 (Week 7) — ADR-007 Context Forge gateway
- [ ] `context-forge-deployment.yaml` deployed; Vault secret injection working (`/vault/secrets/context-forge-jwt.env` present)
- [ ] `context-forge-networkpolicy.yaml` applied; direct ai-assistant → mcp-* paths blocked
- [ ] Bootstrap Job completes; Virtual Server `ai-platform-ops` created with tool whitelist
- [ ] Service token stored in Vault KV at `secret/ai-platform/context-forge/service-token`
- [ ] ai-assistant `list_tools()` returns only whitelisted tools (not full union from both servers)
- [ ] End-to-end query through Context Forge gateway verified; `kubectl logs` on context-forge shows routing
- [ ] Grafana Tempo shows per-tool-call OTel traces from Context Forge
- [ ] ADR-007 committed and merged to main
- [ ] Consul intentions updated with Context Forge paths (`consul-intentions.yaml`)
- [ ] Blog post 2 topic confirmed: "How IBM Context Forge changes the AI agent security model"
