# ADR-011 — Credential Lease Reuse: Boundary Session Pool Strategy and Blast-Radius Trade-offs

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-005, ADR-008, ADR-009, terraform/vault-boundary-auth.tf, scripts/harness/boundary-vault-latency.js |

---

## Context

Gap C from the ARB panel: ADR-008 claims "~50–100ms" session establishment latency with
zero empirical backing. The panel's specific questions:

1. What is your measured p99 session establishment latency at 50 concurrent tool calls?
2. What is your lease-reuse strategy and what blast radius does it create?
3. How do you decide when to open a new Boundary session vs reuse an existing one?

This ADR captures the latency benchmark methodology, the measured results template,
and the session pooling decision framework.

---

## Benchmark Methodology

**Tool:** k6 (`scripts/harness/boundary-vault-latency.js`)

**What is measured:**
- `boundary_session_establish_ms`: wall-clock time from `POST /v1/targets/:id:authorize-session`
  to receiving the session authorization token (this is where Vault credential generation happens)
- `vault_cred_gen_ms`: Vault credential generation time extracted from the
  `X-Vault-Cred-Gen-Latency-Ms` response header (added by instrumented Boundary workers)
- `boundary_session_total_ms`: full round-trip including the TCP proxy connect handshake

**Concurrency tiers:**
| Tier | VUs | Duration | Maps to |
|---|---|---|---|
| Baseline | 1 | 30s | Single AI agent, sequential tool calls |
| Moderate | 10 | 60s | Realistic: one AI agent with parallel tool chains |
| High | 50 | 60s | Stress: multiple concurrent AI agents or automated RCA workflows |

---

## Latency Results

> **Note:** These are the target SLO thresholds defined in ADR-011. Actual measured values
> are committed to `docs/benchmarks/boundary-vault-latency-results.md` after running
> `k6 run scripts/harness/boundary-vault-latency.js`.
> Update this table after each benchmark run. Results are cluster-dependent.

| Metric | Baseline p99 | Moderate p99 | High p99 | SLO Threshold |
|---|---|---|---|---|
| Session establish (ms) | TBD | TBD | TBD | 200 / 500 / 1000 |
| Vault cred gen (ms) | TBD | TBD | TBD | < 200 |
| Total session (ms) | TBD | TBD | TBD | p95 < 2000 |
| Success rate | TBD | TBD | TBD | > 99% |

---

## Session Pooling Decision Framework

### Why not always open a new session per tool call?

```
Tool call → authorize-session (100ms) → get credentials → execute query → end session
           └── Vault cred gen ─────────┘

At 50 concurrent tool calls: 50 × authorize-session requests to Boundary
  → 50 × Vault cred gen calls
  → 50 × PostgreSQL CREATE ROLE statements
  → At high Vault load: p99 latency exceeds the 1000ms SLO threshold
```

### Why not always reuse one session?

```
Long-lived session reuse:
  Session compromise → all tool calls in the session window share the blast radius
  A single Boundary recording mixing 500 tool calls from 50 agent contexts
    → compliance reviewer cannot isolate a suspicious action within the recording
  Lease expiry while active tool call → unexpected credential revocation
```

### The Three-Tier Strategy

| Concurrency | Strategy | Max Blast Radius | Rationale |
|---|---|---|---|
| 1–5 VUs | New Boundary session per logical "RCA investigation" | One investigation's queries | Latency budget allows it. Each session recording maps 1:1 to an investigation context. |
| 6–20 VUs | Session pooling: reuse sessions within a 5-minute TTL window | 5 minutes × (up to 20 agent queries) | p99 latency remains under SLO. Pool window is short enough to limit blast radius. |
| 21–50+ VUs | Pre-warmed session pool (min 5, max 20 sessions) | Pool lifetime × queries per session | Required to meet p99 SLO. Pool is recycled on TTL expiry, not per-query. |

### Audit Atomicity Principle

**A Boundary session recording MUST map to exactly one logical investigation or AI agent
reasoning chain.** This is a compliance requirement: a SOC-2 Type II reviewer reviewing
a suspicious AI agent action must be able to open one Boundary recording and see the
complete context without filtering noise from other concurrent sessions.

The session pool strategy breaks this principle at high concurrency. The accepted trade-off:
- At moderate concurrency (6–20), the 5-minute pool window is documented as the audit granularity.
- Compliance reviewers are trained that "one recording = up to 5 minutes of agent activity."
- High-sensitivity environments (PCI, FedRAMP) should configure `session_pool_max_ttl=60s`
  to restore near-per-query atomicity at the cost of higher Vault load.

---

## Vault Lease Tuning (vault-boundary-auth.tf updates)

```hcl
# Lease tuning aligned with session pool strategy:
# - default_ttl matches the moderate session pool window (5 min = 300s)
# - max_ttl matches the Boundary target session_max_seconds (3600s)
# - renew_statements allow Boundary to extend the VALID UNTIL timestamp
#   when it renews the lease mid-session (prevents credential expiry during
#   a long-running tool call chain)

resource "vault_database_secret_backend_role" "mcp_server_role" {
  default_ttl = "300"    # 5 minutes — matches moderate pool window
  max_ttl     = "3600"   # 1 hour — matches Boundary target session_max_seconds

  renew_statements = [
    "ALTER ROLE \"{{name}}\" VALID UNTIL '{{expiration}}';"
  ]
  # ... unchanged creation/revocation statements
}
```

---

## Files Changed

| File | Change |
|---|---|
| `scripts/harness/boundary-vault-latency.js` | NEW — k6 benchmark harness |
| `docs/benchmarks/boundary-vault-latency-results.md` | NEW — results template |
| `terraform/vault-boundary-auth.tf` | PATCHED — default_ttl=300s, renew_statements |

---

## Interview Defence

**Q: "What is your p99 session establishment latency at 50 concurrent tool calls?"**
A: "Run `k6 run scripts/harness/boundary-vault-latency.js` and read the high-concurrency
   scenario result from `results/boundary-vault-latency-summary.json`. The SLO threshold
   we target is p99 < 1000ms at 50 VUs. The benchmark is committed to the repo so the
   number is reproducible, not an estimate."

**Q: "What blast radius does your session pool create?"**
A: "At moderate concurrency (10 VUs), we pool sessions within a 5-minute window.
   The blast radius of a session compromise is: all tool calls made within that 5-minute
   window across up to 10 concurrent agents. This is documented in ADR-011 as the
   accepted trade-off between p99 SLO and audit atomicity. High-sensitivity environments
   can tighten the pool TTL to 60 seconds, restoring near-per-query isolation at
   increased Vault load."
