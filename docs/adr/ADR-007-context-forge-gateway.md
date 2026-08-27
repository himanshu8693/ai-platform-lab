# ADR-007 — MCP AI Gateway: IBM Context Forge as Central MCP Proxy

| Field       | Value                                                          |
|-------------|----------------------------------------------------------------|
| **Status**  | Accepted                                                       |
| **Date**    | 2025-01-01                                                     |
| **Author**  | Platform Engineering                                           |
| **Refs**    | ADR-001, ADR-002, ADR-005, ADR-006, Phase 6 curriculum         |

---

## Context

ADR-006 established the MCP server topology: `ai-assistant` pod talks directly to
`mcp-kubernetes` and `mcp-prometheus` over HTTP+SSE. This works for a two-server lab
but introduces scaling problems as the server count grows:

- Each new MCP server requires new NetworkPolicy rules, new Consul Intentions, and new
  client-side discovery code in the assistant.
- There is no centralised tool audit trail — each server logs independently.
- There is no single point of control over which tools the LLM can discover and call.
  An upstream MCP server update that adds new tools is immediately visible to the LLM.
- There is no unified auth boundary — each server exposes its own HTTP endpoint and each
  requires its own per-service security controls.

This ADR documents the decision to insert **IBM Context Forge (`mcp-context-forge`)** as
a centralised AI gateway that solves all four problems.

---

## Decision

**Deploy Context Forge as the single MCP endpoint the AI assistant communicates with.**

The `ai-assistant` pod has exactly one downstream connection: Context Forge on port 4444.
It never speaks directly to `mcp-kubernetes` or `mcp-prometheus`. Context Forge:

1. **Proxies and federates** all registered backend MCP servers.
2. **Enforces a Virtual Server tool whitelist** — the LLM sees only the specific tools
   declared in the Virtual Server definition, nothing else.
3. **Authenticates every client request** with a short-lived JWT bearer token issued by
   Vault Agent and validated against the `JWT_SECRET_KEY` that Vault also injects.
4. **Emits OpenTelemetry traces** for every tool call dispatched — plugged into the
   existing Grafana Tempo backend.
5. **Provides a governance Admin UI** at `/admin` for real-time inspection of registered
   servers, tool call history, and token usage — locked behind the same JWT auth.

---

## New Traffic Map (replaces ADR-006 direct paths)

```
                                    ┌─────────────────────────────────────────────────┐
                                    │            inference namespace                    │
                                    │                                                   │
  User query ──▶  ai-assistant      │  ai-assistant → context-forge :4444              │
                       │            │     (JWT bearer token from Vault)                 │
                       ▼            │                                                   │
               context-forge :4444  │  context-forge → mcp-kubernetes :8080             │
                  (MCP gateway)     │  context-forge → mcp-prometheus :8081             │
                       │            │     (server-to-server, no auth required           │
              ┌────────┴───────┐    │      — Consul mTLS provides transport security)  │
              ▼                ▼    │                                                   │
      mcp-kubernetes    mcp-prometheus                                                  │
         :8080              :8081   │  mcp-kubernetes → K8s API :6443                  │
              │                │    │  mcp-prometheus → Prometheus :9090                │
              ▼                ▼    └─────────────────────────────────────────────────┘
          K8s API         Prometheus
           :6443            :9090
```

---

## Security Architecture Changes vs ADR-006

| Control | ADR-006 | ADR-007 (this ADR) |
|---|---|---|
| AI assistant auth to MCP servers | No auth — relies on NetworkPolicy + Consul intention | JWT bearer token validated by Context Forge |
| Tool discovery surface | Full tool list of each server | Restricted to Virtual Server whitelist only |
| NetworkPolicy client egress | ai-assistant → mcp-kubernetes, ai-assistant → mcp-prometheus | ai-assistant → context-forge only |
| Consul intention client | ai-assistant directly to each MCP server | ai-assistant → context-forge only |
| Backend MCP server exposure | Each server's Consul intention allows ai-assistant | Only context-forge is allowed (ai-assistant removed from server intentions) |
| Audit trail | None (tool calls are in-process) | Context Forge OTel traces + Admin UI token usage log |

---

## Key Context Forge Primitives for This Platform

### 1. Gateway Registration

A "Gateway" in Context Forge is a registered upstream MCP server. Context Forge connects
to it, discovers its tools, and federates them. Registration is via the Admin API:

```bash
POST /api/gateways
{
  "name": "mcp-kubernetes",
  "url":  "http://mcp-kubernetes.inference.svc.cluster.local:8080/sse",
  "transport": "SSE",
  "description": "Read-only Kubernetes API bridge — inference namespace"
}
```

Context Forge stores this in its PostgreSQL backend (or SQLite in the lab). On startup,
it connects to each registered gateway, calls `tools/list`, and caches the tool schemas.

### 2. Virtual Server

A Virtual Server is a curated, named set of tools selected from one or more registered
gateways. The AI assistant connects to a Virtual Server endpoint, not to the root gateway.

```
POST /api/virtual-servers
{
  "name": "ai-platform-ops",
  "description": "Curated read-only tool set for the AI assistant",
  "gateway_ids": ["<mcp-kubernetes-id>", "<mcp-prometheus-id>"],
  "tool_ids":    ["<get_pod>", "<list_pods>", "<get_deployment>",
                  "<get_events>", "<execute_query>", "<execute_range_query>"],
  "expose_tools":     true,
  "expose_resources": false,
  "expose_prompts":   false
}
```

The `tool_ids` list is the blast-radius containment mechanism. Any tool NOT in this list
is invisible to the LLM. A future upstream MCP server update that adds a write-capable tool
does not automatically reach the LLM — it requires an explicit update to this list.

The AI assistant then connects to:
```
http://context-forge.inference.svc.cluster.local:4444/virtual-servers/<id>/sse
```

### 3. JWT Auth Flow

```
Vault Agent sidecar (context-forge pod)
  → renders JWT_SECRET_KEY to /vault/secrets/jwt-secret-key  (32-byte hex, TTL 24h)
  → renders AUTH_ENCRYPTION_SECRET to /vault/secrets/auth-encryption-secret

Context Forge startup
  → reads JWT_SECRET_KEY from /vault/secrets/jwt-secret-key
  → signs all issued tokens with this key

Vault Agent sidecar (ai-assistant pod)
  → calls: python3 -m mcpgateway.utils.create_jwt_token \
       --username ai-assistant@platform \
       --exp 60 \
       --secret $(cat /vault/secrets/context-forge-jwt-key)
  → renders the resulting bearer token to /vault/secrets/context-forge-token  (TTL 55 min)
  → renews automatically before expiry via Vault Agent template watch

ai-assistant application
  → reads MCPGATEWAY_BEARER_TOKEN from /vault/secrets/context-forge-token
  → presents as Authorization: Bearer <token> on every MCP request
```

The `JWT_SECRET_KEY` that signs tokens and the `MCPGATEWAY_BEARER_TOKEN` that the client
presents are both generated from Vault. They share the same KV path family under
`secret/data/ai-platform/context-forge/`. No static secret ever appears in a Kubernetes
manifest, environment variable, or ConfigMap.

### 4. OTel Observability

Context Forge exposes OpenTelemetry traces for every tool call dispatched. Wire into the
existing Grafana Tempo backend:

```
OTEL_ENABLED=true
OTEL_EXPORTER=otlp
OTEL_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4317
OTEL_SERVICE_NAME=context-forge-gateway
```

Grafana dashboard additions (Phase 6 Week 6):
- Tool call rate by gateway (mcp-kubernetes vs mcp-prometheus)
- Tool call p99 latency per tool name
- JWT authentication failure rate (spikes = misconfigured Vault rotation)
- Virtual Server tool whitelist coverage (how many of the whitelisted tools are being called)

---

## Local Lab Simplifications (KinD on M4 Max)

| Production config | Lab simplification | Rationale |
|---|---|---|
| PostgreSQL backend | SQLite (`DATABASE_URL=sqlite:////vault/secrets/mcp.db`) | No PostgreSQL operator in local KinD lab |
| Redis cache backend | `CACHE_TYPE=memory` | Single-replica lab — no session affinity needed |
| TLS on gateway service | HTTP only inside cluster (Consul mTLS provides transport security) | Consul mTLS handles the encryption layer |
| `replicaCount: 2` | `replicaCount: 1` | Lab only; no HA requirement |
| HPA | Disabled | Fixed single replica in lab |

---

## Consequences

**Positive:**
- Single NetworkPolicy rule on ai-assistant: egress to context-forge:4444 only. All other
  paths are gone from the ai-assistant's NetworkPolicy.
- Virtual Server whitelist is the canonical blast-radius control. Tool surface is explicit,
  version-controlled in the bootstrap ConfigMap, and auditable.
- OTel traces for every tool call flow into the existing Grafana Tempo backend with zero
  additional instrumentation code in the ai-assistant application.
- IBM internal transfer signal: Context Forge is an IBM open-source project. Running it in
  a production-grade Kubernetes deployment with Vault-injected secrets and GitOps management
  is the strongest possible IBM watsonx.ai platform credibility signal.

**Negative / Risks:**
- Context Forge is a Python/FastAPI application — it introduces an additional latency hop
  between the assistant and the backend MCP servers (~5–20ms per tool call at low load).
  This is acceptable for infrastructure observation use cases.
- SQLite in the lab means the Context Forge database is on ephemeral pod storage. The
  gateway registration and Virtual Server definitions are idempotent via the bootstrap Job
  so the cluster can be rebuilt from scratch without manual re-registration.
- The AI assistant must now refresh its bearer token before it expires. Vault Agent's
  `template` block handles this automatically with a `change_mode: signal` directive.

**Open questions:**
- Context Forge's Virtual Server `tool_ids` field requires the internal tool UUIDs assigned
  at gateway registration time, not the MCP tool names. The bootstrap Job must capture the
  UUID returned from `POST /api/gateways` and use it in the Virtual Server registration.
  This ordering dependency is handled by the bootstrap Job's sequential execution logic.
