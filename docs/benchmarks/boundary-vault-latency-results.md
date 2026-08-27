# Boundary + Vault Latency Benchmark Results

**Tool:** k6 (`scripts/harness/boundary-vault-latency.js`)
**Reference:** ADR-011 — Credential Lease Reuse Strategy

---

## How to Run

```bash
# Prerequisites
brew install k6   # or: https://k6.io/docs/get-started/installation/

# Ensure Boundary and Vault are running (local kind cluster)
export BOUNDARY_ADDR="http://localhost:9200"
export BOUNDARY_TOKEN="at_1234567890"           # dev-mode token
export BOUNDARY_TARGET_ID="ttcp_xxxxxxxxxx"     # from: boundary targets list -recursive

# Create results directory
mkdir -p results

# Run all three concurrency scenarios
k6 run \
  --out csv=results/boundary-vault-latency.csv \
  scripts/harness/boundary-vault-latency.js

# View summary
cat results/boundary-vault-latency-summary.json | jq .
```

---

## Results Template

> Replace placeholder values with your actual measured results.
> Commit updated results after each benchmark run. Tag with cluster version and date.

### Cluster Under Test

| Parameter | Value |
|---|---|
| Cluster | KinD (local M4 Max) |
| Boundary version | TBD |
| Vault version | TBD |
| PostgreSQL version | TBD |
| Test date | TBD |
| SPIFFE enabled | Yes (ADR-009) |

### Latency Results

| Metric | Baseline (1 VU) | Moderate (10 VU) | High (50 VU) | SLO |
|---|---|---|---|---|
| Session establish p50 (ms) | TBD | TBD | TBD | — |
| Session establish p95 (ms) | TBD | TBD | TBD | — |
| Session establish p99 (ms) | TBD | TBD | TBD | 200 / 500 / 1000 |
| Vault cred gen p50 (ms) | TBD | TBD | TBD | — |
| Vault cred gen p99 (ms) | TBD | TBD | TBD | < 200 |
| Total session p95 (ms) | TBD | TBD | TBD | < 2000 |
| Success rate (%) | TBD | TBD | TBD | > 99% |
| Session failures | TBD | TBD | TBD | 0 |

### SLO Pass/Fail

| SLO | Target | Result | Pass? |
|---|---|---|---|
| Baseline p99 session establish | < 200ms | TBD | TBD |
| Moderate p99 session establish | < 500ms | TBD | TBD |
| High p99 session establish | < 1000ms | TBD | TBD |
| Vault cred gen p99 | < 200ms | TBD | TBD |
| Total session p95 | < 2000ms | TBD | TBD |
| Success rate | > 99% | TBD | TBD |

---

## Interpretation Guide

### If baseline p99 > 200ms:
- Check Vault dev mode startup: `kubectl logs -n vault deploy/vault | tail -50`
- Verify PostgreSQL is reachable from the Boundary worker: `vault read database/creds/mcp-server-role`
- Check if SPIRE SVID validation adds latency: compare `vault write auth/jwt/spire/login jwt=...` vs previous `auth/kubernetes/login` baseline

### If high-concurrency p99 > 1000ms:
- Enable the session pre-warm pool (see ADR-011 concurrency tier 3)
- Check Vault connection pool: `vault_database_secret_backend_connection.postgres.max_open_connections` (default: 5)
  Increase to 20 for 50 VU benchmark
- Check PostgreSQL `max_connections` limit: `SHOW max_connections;` — default is 100, reduce `max_open_connections` if lower

### If Vault cred gen p99 > 200ms:
- Check Vault unsealed + performance: `vault status`
- PostgreSQL CREATE ROLE latency: run `time vault read database/creds/mcp-server-role` directly
- Consider enabling Vault performance standbys for production load

---

## Historical Results

| Date | Cluster | Boundary | Vault | Baseline p99 | High p99 | Notes |
|---|---|---|---|---|---|---|
| TBD | KinD M4 Max | TBD | TBD | TBD | TBD | Initial baseline |

---

## Raw k6 Output Storage

Raw k6 CSV output is stored at `results/boundary-vault-latency.csv` (gitignored — too large).
The summary JSON at `results/boundary-vault-latency-summary.json` IS committed.

```bash
# Add to .gitignore:
results/*.csv

# Commit summary only:
git add results/boundary-vault-latency-summary.json
git commit -m "perf: update Boundary+Vault latency benchmark results"
```
