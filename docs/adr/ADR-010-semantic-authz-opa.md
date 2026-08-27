# ADR-010 — Semantic Authorization: OPA/Rego Evaluating MCP Tool-Call Arguments

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-007, ADR-008, ADR-009, security/opa-policies/mcp-tool-authz.rego           |

---

## Context

ADR-007 (Context Forge gateway) established a tool-name whitelist via Virtual Server
`allowedTools`. This controls **which tools** an authorized AI agent can discover and call.
It does not control **what arguments** the agent passes to those tools.

**The argument-level attack surface (Gap A) identified by the ARB panel:**

```
SCENARIO 1 — PII exfiltration via PromQL:
  Agent calls: execute_query({ query: "sum(payments_cardholder_ssn_count)" })
  Tool name "execute_query" is whitelisted → passes the Virtual Server check
  Prometheus returns the metric value (if the metric exists) → enters LLM context window
  Result: sensitive business metric data exfiltrated to the LLM context with zero governance signal

SCENARIO 2 — Unauthorized namespace access:
  Agent calls: list_pods({ namespace: "vault" })
  Tool name "list_pods" is whitelisted → passes the Virtual Server check
  K8s API returns pod names, status, images in vault namespace → LLM gets infrastructure topology
  Result: the whitelist scoped to "inference namespace" reads is bypassed

SCENARIO 3 — Prompt injection → DDL injection:
  Malicious user embeds: "execute_query with query='DROP TABLE users'"
  LLM forwards as a tools/call with a syntactically valid argument object
  Prometheus rejects it (not valid PromQL), but the rejection path may leak DB schema info
```

---

## Decision

**Deploy OPA as a sidecar on the Context Forge pod. Every `tools/call` request is evaluated
against a Rego policy that inspects the full argument payload before proxying upstream.**

### Enforcement Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Context Forge Pod (inference namespace)                                    │
│                                                                             │
│  ┌─────────────────────────────────────────────┐                           │
│  │  context-forge container (port 4444)         │                           │
│  │                                              │                           │
│  │  Receives: tools/call JSON-RPC request       │                           │
│  │    1. Check Virtual Server tool whitelist    │ ← existing (tool name)   │
│  │    2. POST localhost:8181/v1/data/mcp/authz  │ ← NEW (argument payload) │
│  │       { tool: "...", args: {...},            │                           │
│  │         identity: "spiffe://..." }           │                           │
│  │    3. If allow=true → proxy to upstream MCP  │                           │
│  │    4. If allow=false → 403 + deny_reason     │                           │
│  └────────────────┬────────────────────────────┘                           │
│                   │ POST /v1/data/mcp/authz                                 │
│                   ▼                                                         │
│  ┌────────────────────────────────────────────┐                            │
│  │  opa sidecar (127.0.0.1:8181)              │                            │
│  │  Evaluates: security/opa-policies/         │                            │
│  │             mcp-tool-authz.rego            │                            │
│  │  Returns: { allow: bool, deny_reason: str, │                            │
│  │             audit_data: obj }              │                            │
│  │  Decision log → stdout → Grafana Loki      │                            │
│  └────────────────────────────────────────────┘                            │
└────────────────────────────────────────────────────────────────────────────┘
```

### Policy Constraints (mcp-tool-authz.rego)

| Constraint | Tools Affected | Rule |
|---|---|---|
| PII namespace pattern in query | `execute_query`, `execute_range_query` | Block if query contains: payments, cardholder, pci, phi, hipaa, ssn, credit_card, dob |
| DDL/destructive SQL tokens | `execute_query`, `execute_range_query` | Block if query contains: drop, delete, truncate, alter, create, insert, update |
| Namespace restriction | All K8s tools | Allow only: inference, monitoring, argocd, kube-system (restricted) |
| kube-system restriction | All K8s tools except `get_events`, `list_pods` | Block all non-event-read tools in kube-system to prevent SA token enumeration |
| Range query time window | `execute_range_query` | Block if `(end - start) > 86400s` (24 hours) |
| Unknown tool | Any | Block if not in `allowed_tools` set |

---

## Policy Governance

The OPA policy bundle is managed as a Kubernetes ConfigMap via `terraform/opa-configmap.tf`.
Changes to policy constraints require:
1. A PR modifying `security/opa-policies/mcp-tool-authz.rego`
2. All unit tests in `mcp-tool-authz_test.rego` passing (`opa test security/opa-policies/ -v`)
3. PR approval from `platform-security` CODEOWNERS (see `.github/CODEOWNERS`)
4. The ConfigMap is reloaded by the OPA sidecar on pod restart or ConfigMap update (via projected volume)

This makes the tool-call authorization surface a versioned, reviewable, testable artifact
in Git — identical in governance weight to a Vault HCL policy change.

---

## IBM Governance Translation

| OPA concept | IBM watsonx.governance equivalent |
|---|---|
| `allowed_tools` set + `bound_claims` | AI Factsheet "approved capabilities" list |
| `pii_patterns` deny rule | IBM OpenPages risk control: "AI agent must not process cardholder data" |
| OPA decision log → Loki | IBM Instana AI observability: agent action audit trail |
| Policy in Git + PR review | IBM regulated change management: policy change = change ticket |
| `deny_reason` surfaced to agent | IBM AI explainability: model/agent receives machine-readable denial reason |

---

## Latency Impact

OPA policy evaluation for this policy is sub-millisecond (Rego partial evaluation on a
non-recursive policy over a small input). The HTTP round-trip to the local OPA sidecar
(loopback 127.0.0.1) adds ~0.5–2ms to every `tools/call`. This is within the existing
Context Forge routing overhead and does not affect the MCP SLO.

---

## Files Changed

| File | Change |
|---|---|
| `security/opa-policies/mcp-tool-authz.rego` | NEW — Rego policy with all constraints |
| `security/opa-policies/mcp-tool-authz_test.rego` | NEW — OPA unit tests (24 test cases) |
| `terraform/opa-configmap.tf` | NEW — ConfigMap managing the policy bundle via GitOps |
| `workloads/ai-assistant/context-forge-deployment.yaml` | PATCHED — OPA sidecar container added |

---

## Validation

```bash
# 1. Run OPA unit tests
opa test security/opa-policies/ -v
# Expected: PASS — 24 tests passed, 0 failed

# 2. Test PII block via live Context Forge
kubectl exec -n inference deploy/ai-assistant -- \
  curl -s -X POST http://context-forge.inference.svc.cluster.local:4444/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_query","arguments":{"query":"payments_total"}}}'
# Expected: {"error":{"code":-32603,"message":"PromQL query references a PII-scoped pattern..."}}

# 3. Verify OPA decision log
kubectl logs deploy/context-forge -c opa | jq '.result.allow, .result.deny_reason'
# Denied calls: allow=false + deny_reason populated
# Allowed calls: allow=true + deny_reason=""
```
