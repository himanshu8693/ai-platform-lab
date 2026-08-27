# =============================================================================
# terraform/pam-federation/delinea-vault-bridge.tf
# Delinea Secret Server / Privilege Manager → Vault OIDC Auth Bridge
#
# Gap G (alternative): integrates HashiCorp Vault with Delinea Secret Server
# (formerly Thycotic) using Delinea's OIDC identity provider capability.
# Delinea becomes the authoritative identity source; Vault validates tokens
# issued by Delinea before granting access to the credential chain.
#
# Architecture (different from CyberArk pattern):
#   MCP server → Delinea OIDC token (user/service login) → Vault OIDC login
#   Vault validates token against Delinea OIDC endpoint
#   Vault issues a short-lived token with the appropriate credential policy
#   Boundary uses the Vault token (unchanged from base architecture)
#
# When to use Delinea pattern vs CyberArk pattern:
#   Use CyberArk pattern: when customer has CyberArk EPV and wants CyberArk
#     to remain the authoritative credential store (checkout audit trail in EPV)
#   Use Delinea pattern: when customer has Delinea as the identity authority
#     and wants Vault to remain the dynamic credential engine (Delinea provides
#     identity, Vault provides credential issuance)
#
# References: ADR-014, docs/scenarios/FDE-002-cyberark-brownfield.md
# =============================================================================

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "delinea_oidc_discovery_url" {
  type        = string
  description = "Delinea Secret Server OIDC discovery URL. Example: https://delinea.internal/SecretServer/oauth2/v1"
}

variable "delinea_client_id" {
  type        = string
  description = "Vault's registered OAuth client ID in Delinea Secret Server."
}

variable "delinea_client_secret" {
  type      = string
  sensitive = true
  description = "Vault's registered OAuth client secret in Delinea Secret Server. Set via TF_VAR_delinea_client_secret."
}

variable "delinea_allowed_groups" {
  type        = list(string)
  default     = ["AI-Platform-Operators", "MCP-Server-SAs"]
  description = "Delinea user groups allowed to authenticate via this OIDC backend. Service accounts must be members."
}

# ── Vault OIDC Auth Backend → Delinea as Identity Provider ───────────────────

resource "vault_jwt_auth_backend" "delinea_oidc" {
  path               = "oidc/delinea"
  type               = "oidc"
  description        = "Delinea Secret Server as OIDC identity provider for AI platform service accounts."
  oidc_discovery_url = var.delinea_oidc_discovery_url
  oidc_client_id     = var.delinea_client_id
  oidc_client_secret = var.delinea_client_secret

  # OIDC scopes to request from Delinea
  oidc_scopes = ["openid", "profile", "groups"]

  default_role = "mcp-server-delinea-role"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "1h"
    token_type        = "default-service"
  }
}

# ── Vault OIDC Role: MCP server service accounts ──────────────────────────────

resource "vault_jwt_auth_backend_role" "mcp_server_delinea" {
  backend        = vault_jwt_auth_backend.delinea_oidc.path
  role_name      = "mcp-server-delinea-role"
  role_type      = "oidc"
  oidc_scopes    = ["openid", "profile", "groups"]
  callback_mode  = "client"

  # Bind access to members of the allowed Delinea groups
  # "groups" claim in the OIDC token must contain at least one of these
  bound_claims = {
    "groups" = join(",", var.delinea_allowed_groups)
  }

  # Grant the same credential policy as the native Vault path
  token_policies = ["boundary-mcp-credential-policy"]
  token_ttl      = 3600
  token_max_ttl  = 3600
  token_type     = "service"

  # user_claim: use the service account's "sub" as the Vault entity alias
  # This ties every audit log entry to the Delinea identity
  user_claim = "sub"

  # Allowed redirect URIs for the OIDC flow
  # In a headless service account flow, the redirect is to a localhost callback
  # handled by the vault CLI OIDC login helper or by the Boundary worker
  allowed_redirect_uris = [
    "https://localhost:8250/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  depends_on = [vault_jwt_auth_backend.delinea_oidc]
}

# ── Delinea-aware Vault policy ────────────────────────────────────────────────
# Same policy as the core architecture — Delinea identity does not change
# the permission surface, only the authentication path.
# If Delinea group membership implies a different access level, add role variants
# (e.g., "mcp-server-readonly-delinea" vs "mcp-server-admin-delinea").

# The policy is shared with the CyberArk integration and defined in
# terraform/vault-boundary-auth.tf as boundary_credential_policy.
# No duplicate policy resource needed here.

# ── Outputs ───────────────────────────────────────────────────────────────────

output "delinea_oidc_auth_path" {
  value       = vault_jwt_auth_backend.delinea_oidc.path
  description = "Vault OIDC auth path for Delinea identity. MCP server logs in with: vault login -method=oidc -path=oidc/delinea"
}

output "test_delinea_login_cmd" {
  value       = "vault login -method=oidc -path=oidc/delinea -token-only"
  description = "Test Delinea→Vault OIDC login from the MCP server pod. Opens a browser for the OIDC flow (or use device_code for headless service accounts)."
}

output "delinea_vs_cyberark_decision" {
  value = <<-NOTE
    Delinea pattern: Delinea = identity authority, Vault = credential engine
    CyberArk pattern: CyberArk = credential authority, Vault = abstraction layer
    
    Choose Delinea pattern when: customer uses Delinea for IAM/SSO and wants 
    Vault to remain the dynamic credential issuer.
    
    Choose CyberArk pattern when: customer uses CyberArk EPV for privileged 
    credential storage and requires EPV checkout audit trail for compliance.
    
    Both patterns are compatible with the Boundary credential injection chain.
    See ADR-014 for the full decision matrix.
  NOTE
  description = "Decision guide for choosing CyberArk vs Delinea integration pattern."
}
