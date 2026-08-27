# ADR-012 — Output-Side Data Control: DLP Redaction on MCP Server Egress

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-007, ADR-010, workloads/ai-assistant/mcp-server-dlp-sidecar.yaml, security/dlp-policies/mcp-redaction-config.yaml |

---

## Context

ADR-010 (OPA semantic authorization, Gap A) controls what the AI agent can *request*.
It does not control what flows *back* through the MCP server response into the LLM
context window.

**The output-side attack surface (Gap D):**

The zero-trust chain controls inbound (request authorization). The outbound path
(MCP server response → Context Forge → LLM context window) has no PII scrubbing.

A PostgreSQL query executed via Boundary returns column values that the MCP server
serializes into JSON and returns to Context Forge. If a dynamic database user has
`SELECT` permission on a table containing SSNs (even accidentally, via a `GRANT SELECT
ON ALL TABLES`), the values flow unredacted into the LLM's context.

Similarly, Kubernetes pod logs requested via the MCP server may contain:
- API keys accidentally printed in application startup logs
- Database connection strings with credentials
- Stack traces with internal IP addresses
- User-submitted data echoed by the application

---

## Decision

**Deploy Presidio Anonymizer as a sidecar on both `mcp-prometheus` and `mcp-kubernetes`.
The MCP server calls the sidecar before returning any response to Context Forge.**

### Why Presidio (not regex-only)

| Approach | Strengths | Weaknesses |
|---|---|---|
| Regex-only | Fast, deterministic, no ML inference overhead | Misses contextual PII: "John Smith transferred $50 to Mary Jones" — regex cannot extract names without a dictionary |
| Presidio (NLP + regex hybrid) | Catches contextual entities (PERSON, LOCATION); configurable score threshold; supports 20+ entity types | 100–200ms inference overhead per response; requires the `spacy` model to be present in the sidecar image |
| Custom ML classifier | Highest accuracy | Requires training data, model management, GPU resources — out of scope |

**Decision:** Presidio with `score_threshold: 0.75`. Entities below the threshold are
passed through without redaction. This is the accepted false-negative rate — documented
in the risk register as: "PII with low detection confidence may pass through; this is
a best-effort control, not a guaranteed PII-free guarantee."

### Integration Pattern

The redaction sidecar is called by the MCP server process via a local HTTP call:

```python
# In the MCP server response handler (pseudo-code):
import httpx

async def redact_response(response_json: dict) -> dict:
    """
    Call the Presidio Anonymizer sidecar to redact PII from the response.
    The sidecar is at http://localhost:3000 (within the same pod).
    If the sidecar is unavailable (timeout / startup), the response is
    returned unredacted (fail-open) with a warning metric emitted.
    """
    try:
        async with httpx.AsyncClient(timeout=0.5) as client:
            r = await client.post(
                "http://localhost:3000/anonymize",
                json={
                    "text": str(response_json),
                    "anonymizers": {},   # uses anonymizer_config.json defaults
                    "analyzer_results": [],  # Presidio will run analysis first
                },
            )
            r.raise_for_status()
            redacted_text = r.json()["text"]
            # Count redacted entities for the Prometheus counter
            for result in r.json().get("items", []):
                dlp_redactions_counter.labels(
                    entity_type=result["entity_type"],
                    mcp_server="mcp-kubernetes",
                ).inc()
            return {"redacted_response": redacted_text}
    except (httpx.TimeoutException, httpx.ConnectError) as e:
        # Fail-open: log the skip but return the original response
        # This prevents the MCP server from becoming unavailable if Presidio is slow
        logger.warning(f"DLP sidecar unavailable: {e}. Returning unredacted response.")
        dlp_skip_counter.inc()
        return response_json
```

### Fail-Open vs Fail-Closed Trade-off

The current implementation is **fail-open**: if the Presidio sidecar is unavailable
(startup, OOM), the MCP server returns the unredacted response. The rationale:

- The MCP server is a diagnostic tool used by engineers during active incidents.
  A fail-closed DLP sidecar would block all MCP tool calls during a P1 incident
  where the Presidio pod has also OOM-killed. This would make the AI assistant
  unavailable precisely when it is most needed.
- The input-side controls (OPA semantic authZ, read-only Vault credentials, restricted
  namespace access) are still active. The fail-open is an accepted residual risk.

**Production migration path:** Regulated environments (FedRAMP, PCI) should set
`DLP_FAIL_CLOSED=true` in the MCP server env to reject responses when the sidecar
is unavailable, accepting the availability trade-off.

---

## Limitations (Accepted Gaps)

| Gap | Description | Mitigation |
|---|---|---|
| Structured data in JSON values | Presidio's NLP model may miss PII embedded in JSON key-value pairs (e.g., `{"user_id": "ssn:123-45-6789"}`) | Custom recognizer patterns can be added to `anonymizer_config.json` for known patterns |
| Binary / encoded data | Base64-encoded PII in log lines passes through Presidio without detection | MCP server tools enforce `--tail=100` log limits; deep log forensics via Boundary session direct access |
| Metric label values | PromQL results return metric labels as values (e.g., `{email="user@example.com"}`) | OPA (Gap A) blocks queries that reference known PII metric namespaces |
| False positives in infrastructure data | Pod names like `payment-processor-abc123` may trigger partial PERSON matches | `score_threshold: 0.75` and `fields_to_skip` list reduce false positives on infra fields |

---

## Files Changed

| File | Change |
|---|---|
| `workloads/ai-assistant/mcp-server-dlp-sidecar.yaml` | NEW — Presidio sidecar + metrics exporter Kustomize patch |
| `security/dlp-policies/mcp-redaction-config.yaml` | NEW — Presidio configuration ConfigMap |

---

## Validation

```bash
# 1. Verify DLP sidecar is running
kubectl get pods -n inference -l platform.ai/dlp-enabled=true
# Expected: mcp-prometheus and mcp-kubernetes pods with 3 containers each

# 2. Test redaction directly against the Presidio sidecar
kubectl exec -n inference deploy/mcp-prometheus -c dlp-sidecar -- \
  curl -s -X POST http://localhost:3000/anonymize \
  -H 'Content-Type: application/json' \
  -d '{"text": "User SSN is 123-45-6789 and email is user@example.com", "anonymizers": {}, "analyzer_results": []}'
# Expected: {"text": "User SSN is <SSN_REDACTED> and email is <EMAIL_REDACTED>", "items": [...]}

# 3. Verify redaction counter in Prometheus
kubectl exec -n monitoring deploy/prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=mcp_dlp_redactions_total'
# Expected: metric present with entity_type labels
```
