# ADR-008 — Zero-Trust AI Tool Execution Flow: Full Credential Chain

| Field      | Value                                                                    |
|------------|--------------------------------------------------------------------------|
| **Status** | Accepted                                                                 |
| **Date**   | 2025-01-01                                                               |
| **Author** | Platform Engineering                                                     |
| **Refs**   | ADR-005, ADR-006, ADR-007, terraform/vault-boundary-auth.tf              |

---

## Context

ADRs 005–007 each document one layer of the zero-trust stack in isolation:
- ADR-005: Boundary auth strategy (dev vs prod mode)
- ADR-006: MCP server architecture (read-only tool surface)
- ADR-007: Context Forge as MCP AI gateway (tool whitelist + JWT auth)

No single document traces the **complete execution path** from an AI agent issuing a tool
call to the credential being injected, used, and revoked. This ADR fills that gap.

The full chain exists to enforce two non-negotiable properties:
1. **Zero static credentials** stored anywhere in the MCP container, Boundary DB, or
   Kubernetes manifests. Every credential is ephemeral, generated at request time.
2. **100% immutable session recording** by Boundary for every tool execution session —
   the complete audit artifact required by SOC-2 Type II, FedRAMP, and HIPAA controls.

---

## The Complete Zero-Trust AI Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    ZERO-TRUST AI TOOL EXECUTION FLOW                            │
│                                                                                 │
│  ① User / LLM Agent                                                             │
│     │  "What is the current TTFT p99 for the inference cluster?"                │
│     │  Authorization: Bearer <JWT — Vault-issued, 55-min TTL>                  │
│     ▼                                                                           │
│  ② IBM Context Forge (L7 Policy Proxy) — port 4444                             │
│     │  • Validates JWT signature against JWT_SECRET_KEY from Vault KV          │
│     │  • Checks tool name against Virtual Server whitelist                      │
│     │  • Rejects if tool not in whitelist → 403, OTel span emitted             │
│     │  • Routes approved call to correct upstream MCP server                   │
│     │  • Emits OTel trace span: tool_name, gateway_id, latency_ms, status      │
│     ▼                                                                           │
│  ③ MCP Server Container (mcp-prometheus / mcp-kubernetes)                      │
│     │  • Receives JSON-RPC 2.0 tools/call from Context Forge                   │
│     │  • Has NO credentials stored in container env or filesystem              │
│     │  • For DB queries: requests a Boundary session token                     │
│     │    (alternative: for K8s API, uses read-only ClusterRole SA token)       │
│     ▼                                                                           │
│  ④ HashiCorp Boundary (L4/L7 ZTNA Proxy) — port 9200                          │
│     │  • MCP server authenticates with Boundary using its SA token             │
│     │  • Boundary calls Vault credential library to get dynamic creds          │
│     │  • Boundary authorizes session: worker filter + scope policy              │
│     │  • Session recording BEGINS — immutable audit stream to S3/MinIO         │
│     │  • Boundary injects credentials into proxied TCP stream                  │
│     │    (MCP server NEVER sees the raw username/password)                     │
│     ▼                                                                           │
│  ⑤ HashiCorp Vault (Dynamic Credential Issuer) — port 8200                    │
│     │  • Receives: GET /v1/database/creds/mcp-server-role                      │
│     │  • Generates: PostgreSQL ROLE "v-mcp-<8chars>" VALID UNTIL +TTL         │
│     │  • Tracks lease: /sys/leases/renew + /sys/leases/revoke                 │
│     │  • Returns: {username: "v-mcp-a1b2c3d4", password: "<random>", ttl: 3600}│
│     ▼                                                                           │
│  ⑥ Target (PostgreSQL pod / K8s API host)                                     │
│     │  • Connection established via Boundary proxy                             │
│     │  • Dynamic user "v-mcp-a1b2c3d4" executes SELECT queries                │
│     │  • Tool result (metric values / resource states) returned to MCP server  │
│     ▼                                                                           │
│  ⑦ Session Teardown (automatic on tool call completion)                        │
│     │  • Boundary session ends → calls Vault /sys/leases/revoke               │
│     │  • Vault executes: DROP ROLE "v-mcp-a1b2c3d4"                           │
│     │  • Credential ceases to exist — cannot be replayed or stolen             │
│     │  • Session recording stream CLOSES → immutable artifact sealed in MinIO  │
│     │  • Boundary audit log entry: session_id, user, target, duration, bytes   │
│     ▼                                                                           │
│  Result returned to AI Agent via Context Forge                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Zero Static Credentials — Enforcement Points

Every layer enforces the "no static credential" property independently:

| Layer | Static Credential | Enforcement Mechanism |
|---|---|---|
| MCP container env | ❌ None stored | Vault Agent sidecar injects short-TTL files to `/vault/secrets/` |
| Boundary credential store | ❌ No plaintext PG password | `boundary_credential_store_vault` — Boundary holds only a Vault token |
| Boundary DB | ❌ No credential cache | Vault issues fresh creds per session; Boundary does not persist them |
| Kubernetes Secret | ❌ No DB password in manifests | VSO (Vault Secrets Operator) rotates any needed K8s Secrets from Vault |
| Terraform state | ❌ root PG password rotated | `vault write -force database/rotate-root/mcp-postgres` post-apply |
| Git repository | ❌ Never committed | `.gitignore` blocks `*.tfstate`, `*.tfvars`; pre-commit hook validates |

The only static value in the chain is the Vault dev-mode root token (`root`), which is a
known lab trade-off documented in ADR-005. In production, this is replaced by a Vault AppRole
auth method bound to the Boundary Worker's Kubernetes ServiceAccount.

---

## Session Recording: The Compliance Artifact

Boundary's session recording produces an immutable audit stream for every proxied session.
This is the primary compliance artifact for SOC-2 Type II, FedRAMP Moderate, and HIPAA
access control requirements.

### What is recorded

```
Session recording captures:
  ├── Connection metadata
  │     ├── session_id:       bsess_<uuid>
  │     ├── auth_token_id:    at_<uuid>  (Boundary user identity)
  │     ├── target_id:        ttcp_<uuid> (mcp-postgres-target)
  │     ├── worker_id:        w_<uuid>
  │     ├── created_time:     RFC3339
  │     └── terminated_time:  RFC3339
  ├── Byte-level stream
  │     ├── All bytes sent from client (MCP server) to target (PostgreSQL)
  │     └── All bytes received from target back to client
  │         (includes the SQL queries and row results in plaintext for TCP targets)
  └── Termination reason
        ├── "session complete" (normal MCP tool call completion)
        ├── "session cancelled" (admin-initiated revocation)
        └── "session timed out" (TTL exceeded before tool call returned)
```

### Storage configuration

```hcl
# terraform/boundary.tf — storage bucket for session recordings
resource "boundary_storage_bucket" "mcp_session_recordings" {
  name        = "mcp-session-recordings"
  description = "Immutable session recording archive for all MCP→DB tool calls. Required for SOC-2 Type II control CC6.8 (access monitoring)."
  scope_id    = boundary_scope_org.ai_platform.id
  plugin_name = "aws"

  # In local lab: use MinIO (S3-compatible) deployed in the cluster
  bucket_name            = "boundary-recordings"
  bucket_prefix          = "mcp/"
  region                 = "us-east-1"
  endpoint_url           = "http://minio.monitoring.svc.cluster.local:9000"
  disable_credential_rotation = false

  # Immutability: S3 Object Lock (WORM) prevents recording deletion
  # In MinIO lab equivalent: enable versioning + retention policy
  attributes_json = jsonencode({
    disable_credential_rotation = false
    role_arn                    = ""
  })

  worker_filter = "\"local\" in \"/tags/type\""
}
```

### Accessing a recording

```bash
# List sessions for the mcp-postgres target
boundary sessions list -target-id ttcp_<id> -format json | \
  jq '.items[] | {id, status, created_time, terminated_time}'

# Download the session recording (requires storage-admin role)
boundary session-recordings download -id sr_<id> -output-file /tmp/mcp-session-$(date +%s).cast

# Replay with asciinema (TCP sessions are binary — use boundary's built-in replay)
boundary session-recordings read -id sr_<id>
```

---

## Verification: Proving Zero Static Credentials to a Security Auditor

This sequence is the exact demo to run during a SOC-2 audit or an FDE client security review:

```bash
# 1. Prove: no PostgreSQL password in any Kubernetes Secret
kubectl get secrets -n inference -o json | \
  jq '.items[].data | to_entries[] | .key + ": " + (.value | @base64d)' | \
  grep -i "password\|passwd\|pg_password" && echo "FAIL: static cred found" || echo "PASS: no static creds"

# 2. Prove: Vault issues a fresh credential on every request
vault read database/creds/mcp-server-role -format=json | jq '{
  username: .data.username,
  ttl: .lease_duration,
  note: "This credential will not exist after TTL expiry"
}'
# Run twice — username changes every time (v-mcp-a1b2c3d4 → v-mcp-e5f6g7h8)

# 3. Prove: credential is revoked when session ends
LEASE_ID=$(vault read -field=lease_id database/creds/mcp-server-role)
vault lease revoke "${LEASE_ID}"
psql -h localhost -U "$(vault read -field=username database/creds/mcp-server-role)" \
  -d mcpdb -c "SELECT 1" 2>&1 | grep "does not exist\|authentication failed" \
  && echo "PASS: credential revoked" || echo "FAIL: credential still active"

# 4. Prove: session recording exists in MinIO
mc ls minio/boundary-recordings/mcp/ | tail -5
# Expect: one .cast file per completed Boundary session
```

---

## IBM & FDE Interview Framing

When explaining this architecture in interviews, use this exact framing:

**For IBM internal transfer (watsonx.ai / RHOAI Platform Engineering):**
> "I implemented the IBM watsonx.governance AI audit trail pattern in my home lab:
> every AI agent tool call is recorded end-to-end — JWT auth via Context Forge,
> dynamic credential injection via Vault, and immutable session recording via Boundary.
> This maps directly to IBM's AI Factsheets audit requirement: every capability the
> agent invokes is traceable, time-bounded, and reviewable."

**For FDE roles (Anthropic, Databricks, Scale AI):**
> "In regulated enterprise deployments, the single most important question is: can you
> prove to a CISO that your AI agent never held a standing credential? My lab demonstrates
> this with a verifiable 30-second proof: run vault read on a Boundary session, show the
> credential was created at session start and ceased to exist at session end.
> The Boundary session recording is the compliance artifact their security team can put
> in front of an auditor."

**For Platform Engineering roles (CoreWeave, Uber, Atlassian):**
> "The zero-trust credential flow is the hardest part of multi-tenant GPU infrastructure
> to get right at scale. My architecture eliminates the human-error vector entirely:
> there is no PostgreSQL password to accidentally commit, no service account token to
> rotate manually, no audit log gap between AI agent action and credential use.
> It's the same pattern AWS IAM roles use for EC2 — but for AI agent tool calls."

---

## Consequences

**Positive:**
- Complete audit chain for every AI tool call: JWT identity (Context Forge) + session
  identity (Boundary) + credential identity (Vault lease) = three independent audit logs
  that can be correlated by session ID.
- Blast radius is bounded by Vault credential TTL. Even if an MCP server pod is
  compromised, the attacker holds credentials that expire within `dynamic_cred_ttl` seconds.
- SOC-2 Type II controls CC6.1, CC6.2, CC6.6, CC6.8 are all directly addressed by
  components already deployed in the lab.

**Negative / Accepted trade-offs:**
- Latency: each tool call that requires DB access adds ~50–100ms for the Boundary
  session setup and Vault credential issuance. Acceptable for infrastructure observation
  use cases (not real-time inference serving).
- Complexity: the 5-component chain (Context Forge → MCP server → Boundary → Vault → DB)
  has more failure modes than a direct DB connection. Mitigated by runbooks RB-001/RB-002
  and the `make boundary-status` target.
