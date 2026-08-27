# RB-003 — Incident Audit Reconstruction: AI Agent Action Evidence Chain

**Runbook ID:** RB-003
**Type:** Compliance / Incident Response
**Owner:** Platform Security
**Prerequisites:** ADR-013 deployed; Grafana Tempo + MinIO + Boundary accessible
**SLO:** Evidence chain fully reconstructed within 5 minutes of receiving the trigger event

---

## When to Use This Runbook

Use this runbook when:
- A compliance reviewer or CISO requests audit evidence for a specific AI agent action
- A security alert fires on an anomalous MCP tool call pattern
- A Boundary session recording has been flagged for review by the SOC team
- A data breach investigation requires proving whether the AI agent accessed specific data

You will receive one of two trigger artifacts:
- **Trigger A:** A Boundary session ID (format: `s_xxxxxxxxxxxxxxxxxx`)
- **Trigger B:** A Grafana Tempo trace ID (format: 32-character hex string)

Both resolve to the same complete evidence chain.

---

## Step 1 — Identify the OTel Trace ID (5 minutes)

### From Trigger A (Boundary session ID):

```bash
SESSION_ID="s_xxxxxxxxxxxxxxxxxx"   # substitute actual session ID

# Option 1: Boundary CLI (if you have boundary CLI access)
boundary sessions read -id "${SESSION_ID}" -format json | \
  jq '.item.computed_attributes // .item.annotations // empty'
# Look for: otel_trace_id field

# Option 2: MinIO metadata (always available; does not require Boundary admin access)
# The recording metadata is written by the Boundary worker at session end.
MINIO_ENDPOINT="http://minio.platform.svc.cluster.local:9000"
mc alias set local ${MINIO_ENDPOINT} minioadmin minioadmin  # lab credentials
mc cat local/boundary-recordings/${SESSION_ID}/metadata.json | jq .
# Expected output:
# {
#   "session_id": "s_xxxxxxxxxxxxxxxxxx",
#   "otel_trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
#   "mcp_tool": "execute_query",
#   "spiffe_identity": "spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa"
# }

TRACE_ID=$(mc cat local/boundary-recordings/${SESSION_ID}/metadata.json | jq -r .otel_trace_id)
echo "Trace ID: ${TRACE_ID}"
```

### From Trigger B (Trace ID):

```bash
TRACE_ID="4bf92f3577b34da6a3ce929d0e0e4736"  # substitute actual trace ID
# Proceed to Step 2 directly
```

---

## Step 2 — Pull the Full OTel Trace from Grafana Tempo (2 minutes)

```bash
TEMPO_ADDR="http://tempo.monitoring.svc.cluster.local:3200"

# Fetch all spans in the trace
curl -s "${TEMPO_ADDR}/api/traces/${TRACE_ID}" | jq '
  .batches[].scopeSpans[].spans[] |
  {
    name:       .name,
    start:      .startTimeUnixNano,
    duration_ms: ((.endTimeUnixNano - .startTimeUnixNano) / 1000000),
    attributes: [.attributes[] | {key: .key, value: (.value.stringValue // .value.intValue)}]
  }
'
```

**What to look for in the trace:**
- `span.name = "tools/call"` → the tool the AI agent called
- `span.mcp_tool_name` → specific tool name (e.g., `execute_query`)
- `span.tool_args_keys` → argument names logged (values may be redacted by DLP)
- `span.opa_decision` → `allow` or `deny` from Gap A OPA evaluation
- `span.boundary_session_id` → confirms the Boundary session was created for this trace
- `span.identity` → SPIFFE URI of the workload that made the call

**Grafana UI equivalent:**
Navigate to: Grafana → Explore → Tempo datasource → TraceQL
Query: `{ span.boundary_session_id = "s_xxxxxxxxxx" }`

---

## Step 3 — Retrieve the Boundary Session Recording (3 minutes)

```bash
# The session recording is an asciinema-format cast file in MinIO
# It captures the complete TCP session byte stream through the Boundary worker

# List available recording files for this session
mc ls local/boundary-recordings/${SESSION_ID}/
# Expected:
# 2025-01-01 12:00:45  recording.cast
# 2025-01-01 12:00:45  metadata.json

# Download the recording for review
mc get local/boundary-recordings/${SESSION_ID}/recording.cast /tmp/${SESSION_ID}.cast

# Play the recording (requires asciinema)
asciinema play /tmp/${SESSION_ID}.cast

# Or inspect raw TCP frames without playback
cat /tmp/${SESSION_ID}.cast | jq -r 'select(.[0] == "o") | .[2]' | head -100
```

---

## Step 4 — Cross-Reference the OPA Decision Log (2 minutes)

```bash
# OPA decision logs are emitted to stdout by the OPA sidecar → collected by Loki

# Query Loki for OPA decisions in the trace's time window
# (Requires Grafana Loki LogQL access)

LOKI_ADDR="http://loki.monitoring.svc.cluster.local:3100"

# Get the trace start time from Tempo (Unix nanoseconds → seconds)
TRACE_START=$(curl -s "${TEMPO_ADDR}/api/traces/${TRACE_ID}" | \
  jq -r '.batches[0].scopeSpans[0].spans[0].startTimeUnixNano' | \
  awk '{print int($1/1e9)}')

# Query OPA decision log around the trace time
curl -s -G "${LOKI_ADDR}/loki/api/v1/query_range" \
  --data-urlencode "query={container=\"opa\",namespace=\"inference\"}" \
  --data-urlencode "start=$((TRACE_START - 10))000000000" \
  --data-urlencode "end=$((TRACE_START + 60))000000000" | \
  jq '.data.result[].values[] | .[1]' | jq -r | jq .
# Expected: OPA decision JSON with tool name, args keys, allow/deny, trace_id
```

---

## Step 5 — Compile the Evidence Package (5 minutes)

Create a named directory with all evidence artifacts:

```bash
INCIDENT_ID="INC-$(date +%Y%m%d-%H%M)"
EVIDENCE_DIR="/tmp/ai-agent-audit/${INCIDENT_ID}"
mkdir -p "${EVIDENCE_DIR}"

# 1. Tempo trace (JSON)
curl -s "${TEMPO_ADDR}/api/traces/${TRACE_ID}" > "${EVIDENCE_DIR}/otel-trace.json"

# 2. Boundary session metadata
mc get local/boundary-recordings/${SESSION_ID}/metadata.json \
   "${EVIDENCE_DIR}/boundary-session-metadata.json"

# 3. Boundary session recording
mc get local/boundary-recordings/${SESSION_ID}/recording.cast \
   "${EVIDENCE_DIR}/boundary-recording.cast"

# 4. OPA decision log (from Step 4 query, save to file)
# ... (pipe Loki query output to file)

# 5. Summary manifest
cat > "${EVIDENCE_DIR}/MANIFEST.md" << EOF
# AI Agent Audit Evidence Package
**Incident ID:** ${INCIDENT_ID}
**Trace ID:** ${TRACE_ID}
**Boundary Session ID:** ${SESSION_ID}
**MCP Tool:** $(cat "${EVIDENCE_DIR}/boundary-session-metadata.json" | jq -r .mcp_tool)
**Agent Identity:** $(cat "${EVIDENCE_DIR}/boundary-session-metadata.json" | jq -r .spiffe_identity)
**Session Start:** $(cat "${EVIDENCE_DIR}/boundary-session-metadata.json" | jq -r .started_at)
**Session End:** $(cat "${EVIDENCE_DIR}/boundary-session-metadata.json" | jq -r .ended_at)

## Evidence Files
- otel-trace.json: Full OpenTelemetry trace (Context Forge → MCP server → Boundary)
- boundary-session-metadata.json: Boundary session annotations including OTel trace ID
- boundary-recording.cast: Immutable TCP session recording (asciinema format)

## Completeness Verification
All three pieces present: OTel trace ✓ | Session metadata ✓ | Recording ✓
EOF

echo "Evidence package compiled at: ${EVIDENCE_DIR}"
ls -la "${EVIDENCE_DIR}"
```

---

## Escalation

If any step fails (Boundary API unreachable, MinIO missing recording, Tempo missing trace):

1. Check Boundary worker status: `kubectl get pods -n boundary -l app=boundary-worker`
2. Check MinIO: `mc ls local/boundary-recordings/` — if recording is missing, session may have ended abnormally before recording was flushed
3. Check Tempo retention: Tempo default retention is 72h; recordings older than this require the raw jaeger export
4. For FedRAMP/SOC-2 evidence: Boundary recordings in MinIO have retention policy `min 7 years` (configured in `terraform/boundary.tf`) — they are NEVER deleted by the platform
