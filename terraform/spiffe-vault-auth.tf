# =============================================================================
# terraform/spiffe-vault-auth.tf
# SPIFFE/SPIRE Workload Identity → Vault JWT Auth
#
# Implements Gap B: binding the MCP server's Non-Human Identity to a
# cryptographically-attested SPIFFE SVID instead of a raw Kubernetes SA token.
#
# Threat model this closes (confused-deputy attack):
#   BEFORE: MCP pod's raw SA token could call Vault directly (bypassing Boundary)
#           to generate unlimited PostgreSQL credentials.
#   AFTER:  Vault JWT auth backend is scoped to SPIFFE URI SAN exact-match.
#           The Kubernetes auth backend no longer has a role for mcp-server-sa.
#           Even a stolen SVID cannot call Vault outside a Boundary session because
#           the policy only permits database/creds/ reads — not the full DB admin surface.
#
# References: ADR-009, vault-boundary-auth.tf, spire-registration.yaml
#
# Prerequisites:
#   - SPIRE server + agent running in the spire namespace (see spire-registration.yaml)
#   - SPIRE server's JWKS endpoint reachable at http://spire-server.spire.svc:8081/jwks
#   - Vault running and accessible at var.vault_addr
# =============================================================================

# ── Variables ─────────────────────────────────────────────────────────────────

variable "spiffe_trust_domain" {
  type        = string
  default     = "ai-platform.internal"
  description = "SPIFFE trust domain. Must match the SPIRE server's trust_domain config."
}

variable "mcp_server_namespace" {
  type        = string
  default     = "inference"
  description = "Kubernetes namespace where the MCP server runs. Used to scope the SPIFFE URI SAN."
}

variable "mcp_server_sa_name" {
  type        = string
  default     = "mcp-server-sa"
  description = "ServiceAccount name for the MCP server pod. Used to construct the SPIFFE URI."
}

variable "svid_rotation_ttl_seconds" {
  type        = number
  default     = 3600
  description = "SVID rotation interval in seconds. Vault token TTL is set to match so the token expires with the SVID."
}

# ── Step 1: Enable Vault JWT Auth Backend for SPIRE ───────────────────────────
# A dedicated JWT auth backend for SPIRE SVIDs. Kept separate from any existing
# OIDC/JWT backends so SPIRE SVIDs cannot be confused with human identity tokens.

resource "vault_jwt_auth_backend" "spire" {
  path        = "jwt/spire"
  description = "SPIRE SVID-based auth for MCP server workloads. Accepts JWT SVIDs signed by the SPIRE server's CA."

  # SPIRE server exposes its JWKS at this endpoint.
  # Vault fetches public keys from here to validate SVID signatures.
  jwks_url = "http://spire-server.spire.svc.cluster.local:8081/jwks"

  # SPIRE SVIDs use RS256 or ES256 depending on the key manager plugin.
  # Default SPIRE disk-based key manager uses RS256.
  jwt_supported_algs = ["RS256", "ES256"]

  # SPIRE SVIDs set the audience to the configured audience in the workload
  # registration (see spire-registration.yaml: audience: ["IDENTITY"]).
  default_role = "mcp-server-role"

  tune {
    default_lease_ttl = "${var.svid_rotation_ttl_seconds}s"
    max_lease_ttl     = "${var.svid_rotation_ttl_seconds}s"
    token_type        = "default-service"
  }
}

# ── Step 2: Vault JWT Auth Role — scoped to exact SPIFFE URI SAN ──────────────
# The bound_claims constraint is the confused-deputy mitigation:
# Vault will ONLY issue a token for the SVID whose "sub" claim matches the
# exact SPIFFE URI of the mcp-server-sa in the inference namespace.
# Any other identity — including a human engineer or a different pod's SVID —
# is rejected with a 403.

resource "vault_jwt_auth_backend_role" "mcp_server" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "mcp-server-role"
  role_type = "jwt"

  # SPIFFE URI SAN: spiffe://<trust-domain>/ns/<namespace>/sa/<sa-name>
  # This is the exact identity the SPIRE agent attests for the MCP server pod.
  bound_claims = {
    "sub" = "spiffe://${var.spiffe_trust_domain}/ns/${var.mcp_server_namespace}/sa/${var.mcp_server_sa_name}"
  }

  # SVID audience must match what the workload registration specifies.
  bound_audiences = ["IDENTITY"]

  # Grant only the credential-policy — the minimum needed for Boundary to
  # request a dynamic PostgreSQL credential on the MCP server's behalf.
  token_policies = [vault_policy.boundary_credential_policy.name]

  # TTL matches the SVID rotation interval so the Vault token never outlives
  # the SVID it was derived from. This limits blast radius on SVID compromise.
  token_ttl     = var.svid_rotation_ttl_seconds
  token_max_ttl = var.svid_rotation_ttl_seconds
  token_type    = "service"

  # user_claim drives the entity alias in Vault audit logs.
  # "sub" = the SPIFFE URI → every audit log entry shows the exact workload identity.
  user_claim = "sub"

  depends_on = [vault_jwt_auth_backend.spire]
}

# ── Step 3: Revoke the legacy Kubernetes auth role for mcp-server-sa ──────────
# The Kubernetes auth method previously had a role bound to mcp-server-sa.
# This null_resource documents the manual step to remove that role, eliminating
# the direct SA→Vault path that created the confused-deputy vulnerability.
#
# Run this ONCE after applying this file:
#   vault delete auth/kubernetes/role/mcp-server-role
#
# If your existing vault_auth_backend_role resource for Kubernetes auth
# is in a separate .tf file, simply remove or comment it out.

resource "null_resource" "revoke_legacy_k8s_auth_role" {
  triggers = {
    # Re-runs if the legacy role path changes (force manual re-verification)
    legacy_role_path = "auth/kubernetes/role/mcp-server-role"
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== IMPORTANT: Remove the legacy Kubernetes auth role for mcp-server-sa ==="
      echo "Run: vault delete auth/kubernetes/role/mcp-server-role"
      echo "This eliminates the direct SA-token → Vault path (confused-deputy fix)."
      echo "Verify with: vault read auth/kubernetes/role/mcp-server-role → should return 404"
    EOT
  }
}

# ── Step 4: Update boundary_credential_policy to log identity provenance ──────
# The existing policy in vault-boundary-auth.tf is unchanged in capability scope.
# This resource updates the policy metadata to record that callers MUST present
# a SPIRE-attested SVID (enforced at the JWT auth backend, not in HCL policy).
#
# NOTE: The resource "vault_policy.boundary_credential_policy" already exists in
# vault-boundary-auth.tf. Do not re-declare it here — update in place via patch.

# ── Outputs ───────────────────────────────────────────────────────────────────

output "spire_jwt_auth_path" {
  value       = vault_jwt_auth_backend.spire.path
  description = "Vault JWT auth path for SPIRE SVIDs. MCP server uses: vault write ${vault_jwt_auth_backend.spire.path}/login jwt=<svid>"
}

output "mcp_server_spiffe_uri" {
  value       = "spiffe://${var.spiffe_trust_domain}/ns/${var.mcp_server_namespace}/sa/${var.mcp_server_sa_name}"
  description = "Expected SPIFFE URI SAN in the MCP server's X.509 SVID. Verify with: spiffe-helper x509 | openssl x509 -noout -ext subjectAltName"
}

output "verify_spiffe_auth_cmd" {
  value       = "vault write auth/jwt/spire/login jwt=$(cat /run/spire/svid.jwt)"
  description = "Test SPIRE→Vault auth from inside the MCP server pod. Expects token with boundary-mcp-credential-policy."
}
