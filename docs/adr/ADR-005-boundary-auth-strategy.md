# ADR-005 — Boundary Authentication Strategy: Dev Mode vs Production

| Field       | Value                                        |
|-------------|----------------------------------------------|
| **Status**  | Accepted                                     |
| **Date**    | 2025-01-01                                   |
| **Author**  | Platform Engineering                         |
| **Refs**    | ADR-002, `terraform/boundary.tf`             |

---

## Context

HashiCorp Boundary provides zero-trust Just-In-Time (JIT) access to infrastructure
targets (Kubernetes API, Ollama inference pods, Vault UI, DCGM exporter). The
platform lab deploys Boundary via `terraform/boundary.tf`.

Boundary has two operational modes that have materially different security postures:

- **Dev mode** (`boundary dev`): single-process, in-memory database, static
  admin credentials, no TLS. Intended exclusively for local development.
- **Production mode**: PostgreSQL backend, OIDC/LDAP/Vault-managed auth,
  mTLS between workers and controllers, PKI-issued session tokens.

The ARB panel flagged that `terraform/boundary.tf` deploys Boundary in dev mode
with a static auth token. This ADR documents the conscious decision to use dev
mode in the local lab context, the exact security risks accepted, the migration
path to production mode, and the runtime guard that prevents dev mode from being
applied to a real cluster.

---

## Decision

**Lab environment (KinD, local M4 Max): Use dev mode.**

Rationale:
1. The local KinD cluster has no externally reachable IP. The Boundary dev
   instance binds to `127.0.0.1:9200` only. There is no attack surface beyond
   the local developer's session.
2. Dev mode removes the PostgreSQL dependency, which would require a production-
   grade database deployment that adds 45 minutes of bootstrap time to every
   `terraform apply` iteration during active development.
3. The static token used in dev mode is `at_1234567890` — hardcoded, publicly
   documented by HashiCorp, known to every Boundary user. This is acceptable
   because the `inference` namespace is also protected by Vault agent sidecar
   injection (ADR-002) and Consul mTLS intentions, providing defence-in-depth
   even if the Boundary layer is bypassed.
4. The Terraform configuration carries an explicit `precondition` guard (see
   below) that refuses to apply if `var.environment == "production"`.

**Production environment: Require OIDC + Vault-issued tokens + PostgreSQL.**

---

## Dev Mode Risk Register

| Risk                              | Likelihood | Impact | Mitigation in this lab                      |
|-----------------------------------|------------|--------|---------------------------------------------|
| Static token stolen                | Low        | High   | Boundary binds localhost-only; no NodePort  |
| In-memory DB lost on restart       | Certain    | Low    | Lab state is ephemeral by design            |
| No session recording               | N/A        | Medium | No PHI/PII in lab; recordings not required  |
| Admin credential brute-force       | Low        | High   | `127.0.0.1` only; no external access        |
| No credential rotation             | Certain    | Low    | Static HuggingFace token is non-sensitive   |

---

## Production Migration Path

The following changes are required to graduate this lab's Boundary deployment
to production. They are tracked as GitHub issues but deliberately not implemented
here to avoid scope creep in the local dev environment.

### Step 1 — PostgreSQL backend

```hcl
# terraform/boundary-prod.tf (not yet implemented)
resource "helm_release" "boundary" {
  name       = "boundary"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "boundary"
  version    = "0.4.0"
  namespace  = "boundary"

  set {
    name  = "controller.config.database.url"
    value = "postgresql://boundary:${var.db_password}@postgres.boundary.svc:5432/boundary"
  }
  set {
    name  = "controller.config.kms.type"
    value = "transit"    # Vault Transit KMS for root/worker/recovery keys
  }
}
```

### Step 2 — OIDC Auth Method (IBM SSO / Okta)

```bash
# Create OIDC auth method pointing to corporate IdP
boundary auth-methods create oidc \
  -scope-id global \
  -name "corporate-sso" \
  -issuer "https://login.ibm.com/oidc/endpoint/default" \
  -client-id "${OIDC_CLIENT_ID}" \
  -client-secret "${OIDC_CLIENT_SECRET}" \
  -signing-algorithms RS256 \
  -api-url-prefix "https://boundary.internal.company.com"
```

### Step 3 — Vault-Brokered Credential Injection

```hcl
# Credential store backed by Vault (replaces static token in dev mode)
resource "boundary_credential_store_vault" "k8s_creds" {
  name        = "vault-k8s-creds"
  description = "Vault-brokered service account tokens for K8s API access"
  address     = "https://vault.vault.svc.cluster.local:8200"
  token       = data.vault_auth_backend.boundary_sa.token
  scope_id    = boundary_scope_project.inference_project.id

  # Vault dynamic secrets: each Boundary session issues a new K8s SA token
  # valid for the session duration only. Token is never stored in Boundary DB.
}
```

### Step 4 — mTLS between Worker and Controller

```hcl
# Each Boundary worker authenticates to the controller via PKI certificates
# issued by Vault PKI (see ADR-002 — Vault PKI is already deployed).
# Worker node auth:
#   vault write pki/issue/boundary-worker \
#     common_name="boundary-worker-0.internal" ttl=24h
```

### Step 5 — Session Recording (Regulated Workloads)

```hcl
# For SOC2/HIPAA: record all sessions to S3-compatible storage (MinIO in lab)
resource "boundary_storage_bucket" "session_recordings" {
  name             = "inference-session-recordings"
  scope_id         = boundary_scope_org.ai_platform.id
  plugin_name      = "aws"
  bucket_name      = "boundary-recordings"
  region           = "us-east-1"
  disable_credential_rotation = false
}
```

---

## Runtime Guard in Terraform

The following `precondition` block is present in `terraform/boundary.tf`
to prevent accidental production deployment of dev mode:

```hcl
resource "null_resource" "boundary_dev_mode_guard" {
  lifecycle {
    precondition {
      condition     = var.environment != "production"
      error_message = "ERROR: Boundary dev mode cannot be applied to environment=production. Use terraform/boundary-prod.tf with OIDC + PostgreSQL backend."
    }
  }
}
```

This guard means `terraform apply -var='environment=production'` will fail
immediately with a descriptive error, preventing the dev-mode static token
from being deployed to any non-local environment.

---

## IBM-Specific Notes

HashiCorp Boundary's commercial offering (HCP Boundary) maps directly to
**IBM Verify Privilege** (formerly IBM Security Secret Server) in the IBM
software catalogue. The credential injection pattern (Vault-brokered dynamic
secrets into Boundary sessions) is the identical architecture used by IBM's
zero-trust access reference implementation for regulated workloads.

When presenting this ADR during IBM internal transfer interviews:
- Frame the dev-mode decision as "deliberate scope discipline during lab phase"
- Frame the production migration path as demonstrating awareness of the full
  enterprise security control set
- Reference the Vault Transit KMS integration as alignment with IBM Cloud HSM
  (same API surface, different backend)

---

## Consequences

**Positive:**
- The local lab remains fast to iterate (`terraform apply` in <90s vs >10min
  with a real PostgreSQL + OIDC setup).
- The migration path is fully documented, making the production upgrade
  a mechanical execution rather than a design exercise.
- The Terraform guard provides a hard stop against accidental misuse.

**Negative:**
- Dev mode cannot demonstrate session recording, credential injection audit
  trails, or OIDC group-based access policies. These gaps must be acknowledged
  explicitly in portfolio interviews.
- In-memory Boundary DB is lost on pod restart. Lab setup scripts
  (`Makefile: make bootstrap`) must re-seed the Boundary configuration on
  every fresh cluster creation.

**Accepted risk:**
The static dev token at `at_1234567890` on a localhost-only KinD cluster is
an accepted risk. The platform's real security controls (Kyverno admission,
Vault PKI, Consul mTLS, Falco runtime rules) are all active and enforce
defence-in-depth independently of Boundary's auth layer.
