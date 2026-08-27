# ADR-009 — Workload Identity: SPIFFE/SPIRE SVID Binding for MCP Server

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-005, ADR-008, terraform/spiffe-vault-auth.tf, workloads/ai-assistant/spire-registration.yaml |

---

## Context

ADR-008 documents the zero-trust AI tool execution flow. The credential chain requires
the MCP server to authenticate to HashiCorp Boundary, which in turn calls Vault to generate
dynamic PostgreSQL credentials. The authentication gap identified by the ARB panel (Gap B):

**The Confused-Deputy Attack Vector:**

```
BEFORE (ADR-008 state):
  MCP server pod → raw Kubernetes SA token → vault write auth/kubernetes/login
                                             → Vault issues token with boundary-mcp-credential-policy
                                             → vault read database/creds/mcp-server-role
                                             → RETURNS CREDENTIALS DIRECTLY (no Boundary required)

Result: the MCP server pod can generate unlimited PostgreSQL credentials by calling
Vault directly, completely bypassing the Boundary session broker. Any compromised
pod with this SA token becomes a credential factory.
```

The root cause is that the Kubernetes SA token is a static, long-lived credential with no
binding to the intended execution context (a Boundary session). Any process that can read the
SA token from `/var/run/secrets/kubernetes.io/serviceaccount/token` can impersonate the MCP server.

---

## Decision

**Replace the raw Kubernetes SA token as the Vault authentication credential with a SPIFFE X.509 SVID issued by SPIRE.**

Two-layer defence:

1. **SPIFFE SVID as Vault auth credential:** The Vault JWT auth backend (path: `jwt/spire`)
   validates SVID JWT tokens signed by the SPIRE server's CA. The role's `bound_claims["sub"]`
   is set to the exact SPIFFE URI of the MCP server's workload identity:
   `spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa`.
   Any other identity — including other pods in the inference namespace — is rejected.

2. **Remove the Kubernetes auth role for mcp-server-sa:** The `auth/kubernetes/role/mcp-server-role`
   is deleted after applying `terraform/spiffe-vault-auth.tf`. The direct SA-token→Vault path
   no longer exists.

---

## SPIFFE URI Construction

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account-name>
spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa
```

This URI is:
- Attested by the SPIRE agent via the Kubernetes workload attestor (verifies pod's actual SA)
- Embedded as the Subject Alternative Name (URI type) in the X.509 SVID
- The `sub` claim in the JWT form of the SVID
- Matched exactly in the Vault JWT auth role's `bound_claims`

---

## Component Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SPIFFE/SPIRE Workload Identity Flow                                         │
│                                                                              │
│  SPIRE Server (spire namespace)                                              │
│    │  Maintains trust bundle + issues SVIDs                                  │
│    │  Exposes JWKS at :8081/jwks (Vault fetches public keys here)            │
│    ▼                                                                         │
│  SPIRE Agent (DaemonSet on each node)                                        │
│    │  Attests pods via Kubernetes workload attestor                          │
│    │  Delivers X.509 SVID to pod via Unix domain socket                     │
│    ▼                                                                         │
│  MCP Server Pod (inference namespace, SA: mcp-server-sa)                    │
│    │  SVID: spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa     │
│    │  Auto-rotated every 3600s (at 80% of TTL = 2880s)                      │
│    │                                                                         │
│    │  To authenticate to Vault:                                              │
│    │    POST vault/auth/jwt/spire/login                                      │
│    │    Body: { jwt: <SVID in JWT form> }                                   │
│    │    → Vault validates signature against SPIRE JWKS                      │
│    │    → Vault checks sub == expected SPIFFE URI                           │
│    │    → Returns token with boundary-mcp-credential-policy (1h TTL)        │
│    ▼                                                                         │
│  HashiCorp Boundary (receives the Vault token as credential-store config)   │
│    │  Calls Vault to generate dynamic PostgreSQL credentials per session     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Blast-Radius Table

| Compromise Scenario | Before (SA token) | After (SPIFFE SVID) |
|---|---|---|
| Attacker reads SA token from pod filesystem | Can call Vault directly, generate unlimited PG creds | SA token has no Vault auth role — 403 |
| Attacker steals SVID JWT from pod | Can call Vault, gets 1h token, reads PG creds directly | Accepted residual risk (1h TTL, no Boundary required) — see below |
| Attacker compromises SPIRE server | Can issue arbitrary SVIDs for any registered workload | SPIRE server is in a dedicated namespace with restricted RBAC — blast radius is the entire SPIFFE trust domain |
| Pod is scheduled with wrong SA | SPIRE workload registration rejects attestation — no SVID issued | |

**Accepted residual risk:** A stolen SVID JWT can still call Vault directly (bypassing Boundary)
for up to 1 hour until the SVID expires. Mitigation: Vault audit logging captures every
`database/creds/mcp-server-role` read with the SPIFFE URI as the entity alias. Anomalous
direct reads (not originating from a Boundary session) are detectable via alerting on
audit log patterns.

The full mitigation (requiring Boundary session token as a precondition to Vault cred issuance)
would require a Vault EGP (Endpoint Governing Policy) — a Vault Enterprise feature. This is
documented as the production migration path in ADR-005.

---

## Migration Path

| Stage | Auth Method | Notes |
|---|---|---|
| **Lab (current)** | SPIFFE SVID JWT → Vault JWT auth | Eliminates raw SA token path |
| **Production** | SPIFFE SVID + Vault EGP policy requiring Boundary session token | Full confused-deputy elimination — requires Vault Enterprise |
| **HCP Vault** | SPIFFE SVID + HCP Vault Sentinel policies | Cloud-managed equivalent of EGP |

---

## Files Changed

| File | Change |
|---|---|
| `terraform/spiffe-vault-auth.tf` | NEW — Vault JWT auth backend + role for SPIRE SVIDs |
| `workloads/ai-assistant/spire-registration.yaml` | NEW — SPIRE server, agent, ClusterSPIFFEID |
| `workloads/ai-assistant/mcp-server-sa.yaml` | NEW — mcp-server-sa with no SA token automount |

---

## Validation

```bash
# 1. Verify SVID is issued to the MCP server pod
kubectl exec -n inference deploy/mcp-prometheus -- \
  cat /run/spire/svid/tls.crt | openssl x509 -noout -ext subjectAltName
# Expected: URI:spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa

# 2. Verify Vault JWT auth works with SVID
kubectl exec -n inference deploy/mcp-prometheus -- \
  vault write auth/jwt/spire/login jwt=$(cat /run/spire/svid/svid.jwt)
# Expected: token with policy=boundary-mcp-credential-policy, ttl=1h

# 3. Verify legacy Kubernetes auth role is gone
vault read auth/kubernetes/role/mcp-server-role
# Expected: Error reading auth/kubernetes/role/mcp-server-role: Error making API request.
#           Code: 404.

# 4. Verify direct SA token auth is rejected
TOKEN=$(kubectl exec -n inference deploy/mcp-prometheus -- \
        cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || echo "no-sa-token")
vault write auth/kubernetes/login role=mcp-server-role jwt="${TOKEN}"
# Expected: 403 — no kubernetes auth role exists for mcp-server-sa
```
