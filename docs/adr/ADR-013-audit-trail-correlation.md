# ADR-013 — Audit Trail Correlation: OTel Trace ID as the Cross-System Join Key

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-007, ADR-008, ADR-009, terraform/vault-boundary-auth.tf, context-forge-deployment.yaml |

---

## Context

The zero-trust AI tool execution flow (ADR-008) produces two independent audit trails:

1. **Grafana Tempo** — OTel spans from Context Forge: tool name, latency, agent identity, status
2. **MinIO** — Boundary session recordings: immutable byte-stream of every TCP session

These are isolated systems with no common key. A compliance reviewer investigating a
suspicious AI agent action must manually correlate two systems using only approximate
timestamps — not a defensible audit methodology for SOC-2 Type II, FedRAMP, or HIPAA.

**The panel's challenge (Gap E):** *"If I give you a suspicious Boundary session recording
ID, can you show me the full AI agent intent trace in under 30 seconds?"*

The current answer: no. The recording file is named by session UUID; the OTel trace
contains no reference to that UUID.

---

## Decision

**Propagate the W3C `traceparent` header from the initial Context Forge request through
to the Boundary session metadata as a `session.annotation`. Use the OTel trace ID as the
single correlation key joining Tempo spans to Boundary session recordings.**

### Propagation Path

```
① AI assistant sends MCP tools/call to Context Forge
     │  W3C traceparent: 00-<trace_id>-<span_id>-01
     ▼
② Context Forge (OTel instrumented)
     │  Extracts trace_id from traceparent header
     │  Creates child span for this tool call
     │  Sets span attribute: boundary.session_id = (populated in step ④)
     ▼
③ Context Forge calls OPA sidecar (evaluation)
     │  OPA receives: { tool: "...", args: {...}, trace_id: "<trace_id>" }
     │  OPA decision log includes trace_id for join with OPA audit log
     ▼
④ MCP server receives proxied call from Context Forge
     │  traceparent header propagated (W3C standard)
     │  MCP server calls Boundary authorize-session with annotation:
     │    { "otel_trace_id": "<trace_id>", "mcp_tool": "<tool_name>" }
     ▼
⑤ Boundary session is created with the trace ID annotation
     │  Session recording is stored in MinIO with metadata:
     │    recordings/<session_id>/metadata.json:
     │      { "otel_trace_id": "<trace_id>", ... }
     ▼
⑥ Compliance reviewer needs to investigate:
     a. From Tempo trace_id → query Boundary API for session with matching annotation
     b. From Boundary session_id → query Tempo for spans with boundary.session_id attribute
     Both queries resolve in < 30 seconds (see RB-003 runbook)
```

### Context Forge Configuration Changes

Added to `context-forge-deployment.yaml` ConfigMap:
```yaml
OTEL_PROPAGATORS: "tracecontext,baggage"     # W3C traceparent propagation
OTEL_TRACES_SAMPLER: "always_on"             # 100% sampling in lab; tune for production
BOUNDARY_TRACE_HEADER: "X-Correlation-ID"    # header injected into Boundary calls
```

### Tempo TraceQL Query for Correlation

```
# Find all Context Forge spans that spawned a Boundary session:
{ span.boundary_session_id != "" }
| select(span.boundary_session_id, span.mcp_tool_name, span.otel.identity)

# Find the Context Forge span for a specific Boundary session ID:
{ span.boundary_session_id = "s_xxxxxxxxxxxxxxxxxx" }
```

### MinIO Metadata Schema

Every Boundary session recording directory in MinIO will include a `metadata.json`:

```json
{
  "session_id":     "s_xxxxxxxxxxxxxxxxxx",
  "target_id":      "ttcp_xxxxxxxxxx",
  "otel_trace_id":  "4bf92f3577b34da6a3ce929d0e0e4736",
  "mcp_tool":       "execute_query",
  "mcp_gateway":    "context-forge",
  "spiffe_identity": "spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa",
  "started_at":     "2025-01-01T12:00:00Z",
  "ended_at":       "2025-01-01T12:00:45Z"
}
```

---

## Grafana Dashboard: Audit Correlation Panel

A new Grafana dashboard panel provides the compliance reviewer workflow:

1. **Input:** Boundary session ID or OTel trace ID
2. **Query:** Tempo TraceQL for `span.boundary_session_id = <input>` OR `traceId = <input>`
3. **Output:** Linked panel showing the matching recording URL in MinIO

The Grafana variable `$boundary_session_id` drives the panel via the Tempo datasource.

---

## Files Changed

| File | Change |
|---|---|
| `workloads/ai-assistant/context-forge-deployment.yaml` | PATCHED — OTEL_PROPAGATORS, BOUNDARY_TRACE_HEADER env vars; OPA sidecar (Gap A) |
| `terraform/vault-boundary-auth.tf` | PATCHED — session_connection_limit annotation comment (Gap C/E) |
| `docs/runbooks/RB-003-incident-audit-reconstruction.md` | NEW — 5-step compliance reconstruction workflow |

---

## Validation

```bash
# 1. Trigger a tool call and capture the trace ID from Context Forge logs
TRACE_ID=$(kubectl logs deploy/context-forge -n inference | \
  grep 'tools/call' | tail -1 | jq -r '.trace_id')

# 2. Find the Boundary session with that trace ID
boundary sessions list -recursive -filter "\"${TRACE_ID}\" in \"/item/annotations/values\""
# Expected: session entry with otel_trace_id matching ${TRACE_ID}

# 3. Find the Tempo trace from the Boundary session ID
SESSION_ID="s_xxxxxxxxxx"
curl -s "http://tempo.monitoring.svc.cluster.local:3200/api/search?tags=boundary.session_id%3D${SESSION_ID}"
# Expected: trace entry with boundary.session_id span attribute

# 4. Pull the MinIO recording metadata
mc cat minio/boundary-recordings/${SESSION_ID}/metadata.json | jq .otel_trace_id
# Expected: matches ${TRACE_ID}
```
