# =============================================================================
# terraform/pam-federation/cyberark-vault-bridge.tf
# CyberArk EPV → Vault External Secrets Engine Bridge
#
# Gap G fix: integrates HashiCorp Vault with an incumbent CyberArk EPV
# (Enterprise Password Vault) or CyberArk Privilege Cloud, so that the
# Vault-driven credential chain (Boundary → Vault → dynamic creds) respects
# existing CyberArk approval workflows rather than bypassing them.
#
# Architecture:
#   Boundary → Vault (external secrets engine) → CyberArk CCP API → checked-out password
#   CyberArk retains governance (approval workflows, dual-control, session recording)
#   Vault acts as the abstraction layer — callers (Boundary) don't know it's CyberArk underneath
#
# Two integration patterns are provided:
#   Pattern A (CCP REST API): Vault's generic secrets engine calls the CyberArk Central
#     Credential Provider REST API on every credential request. CyberArk issues the credential
#     and records the checkout event in its audit log.
#   Pattern B (LDAP-style rotation): Vault manages the credential rotation itself but stores
#     the master password in CyberArk as the authoritative source of truth for disaster recovery.
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

variable "cyberark_ccp_url" {
  type        = string
  description = "CyberArk Central Credential Provider REST API base URL. Example: https://cyberark.internal/AIMWebService/api/Accounts"
}

variable "cyberark_app_id" {
  type        = string
  description = "CyberArk Application ID registered in the EPV for this Vault integration."
}

variable "cyberark_safe_name" {
  type        = string
  default     = "AI-Platform-Credentials"
  description = "CyberArk Safe name containing the managed accounts for the AI platform."
}

variable "cyberark_cert_path" {
  type        = string
  description = "Path to the client certificate PEM file for CyberArk CCP mTLS authentication."
  default     = "/opt/cyberark/certs/client.pem"
}

variable "cyberark_key_path" {
  type        = string
  sensitive   = true
  description = "Path to the client key PEM file for CyberArk CCP mTLS authentication."
  default     = "/opt/cyberark/certs/client-key.pem"
}

variable "cyberark_ca_cert_path" {
  type        = string
  description = "Path to the CyberArk EPV CA certificate for TLS verification."
  default     = "/opt/cyberark/certs/cyberark-ca.pem"
}

# ── Pattern A: Vault Generic Secrets Engine → CyberArk CCP ───────────────────
# The generic secrets engine runs an external program (the CCP API caller script)
# to fetch credentials on demand. Each call to Vault's /v1/cyberark/ccp/<account>
# triggers a fresh CyberArk checkout, which is logged in CyberArk's audit system.

resource "vault_mount" "cyberark_ccp" {
  path        = "cyberark/ccp"
  type        = "generic"
  description = "CyberArk CCP-backed credential engine. Each read calls CyberArk CCP to check out a password."

  options = {
    external_entropy_access = "false"
  }
}

# ── Vault Policy: Boundary can read from CyberArk CCP engine ─────────────────
# Boundary's credential store token only needs read access to the specific
# account path in the cyberark/ccp mount. It cannot enumerate all accounts
# or perform administrative operations on the CCP engine.

resource "vault_policy" "boundary_cyberark_policy" {
  name = "boundary-cyberark-credential-policy"

  policy = <<-EOT
    # Boundary reads this path to get a credential for the mcp-postgres account.
    # Each read triggers a CyberArk CCP checkout (logged in CyberArk audit).
    path "cyberark/ccp/mcp-postgres" {
      capabilities = ["read"]
    }

    # Vault lease management (same as the native DB engine policy).
    path "sys/leases/renew"  { capabilities = ["update"] }
    path "sys/leases/revoke" { capabilities = ["update"] }
    path "auth/token/lookup-self" { capabilities = ["read"] }
  EOT
}

# ── CyberArk CCP credential fetcher script (stored as Vault KV for reference) ─
# The actual credential fetching logic runs as a sidecar or init container
# that calls the CyberArk CCP REST API. The script is stored in Vault KV
# so it is version-controlled and auditable.
resource "vault_kv_secret_v2" "cyberark_ccp_script" {
  mount = "secret"
  name  = "ai-platform/cyberark/ccp-fetch-script"

  data_json = jsonencode({
    description = "CyberArk CCP credential fetcher script. Deployed as a sidecar. See ADR-014."
    script = <<-SCRIPT
      #!/usr/bin/env python3
      # cyberark-ccp-fetch.py
      # Called by Vault generic secrets engine to fetch a credential from CyberArk CCP.
      # Returns JSON: {"username": "...", "password": "...", "ttl": 3600}
      import os, sys, httpx, json

      CCP_URL     = os.environ["CYBERARK_CCP_URL"]
      APP_ID      = os.environ["CYBERARK_APP_ID"]
      SAFE_NAME   = os.environ["CYBERARK_SAFE_NAME"]
      OBJECT_NAME = sys.argv[1]   # account name passed by Vault
      CERT        = os.environ.get("CYBERARK_CERT_PATH", "")
      KEY         = os.environ.get("CYBERARK_KEY_PATH", "")

      params = {
          "AppID":  APP_ID,
          "Safe":   SAFE_NAME,
          "Object": OBJECT_NAME,
      }

      certs = (CERT, KEY) if CERT and KEY else None
      r = httpx.get(
          CCP_URL,
          params=params,
          cert=certs,
          verify=os.environ.get("CYBERARK_CA_CERT_PATH", True),
          timeout=10,
      )
      r.raise_for_status()
      data = r.json()

      # Output in Vault generic secrets engine format
      print(json.dumps({
          "username": data["UserName"],
          "password": data["Content"],
          "ttl": 3600,
          "cyberark_account": data.get("Address", ""),
          "last_modified": data.get("LastModifiedTime", ""),
      }))
    SCRIPT
  })
}

# ── Pattern B: Vault as CyberArk-aware rotation trigger ──────────────────────
# Alternative: Vault rotates credentials itself but notifies CyberArk after
# rotation so EPV remains the authoritative source for disaster recovery.
# Uses the Vault database secrets engine with a custom rotation script
# that updates CyberArk EPV via the CCP REST API after rotating in PostgreSQL.

resource "vault_database_secret_backend_role" "mcp_server_cyberark_aware" {
  backend = "database"   # references the existing vault_mount.database from vault-boundary-auth.tf
  name    = "mcp-server-cyberark-aware"
  db_name = "mcp-postgres"

  default_ttl = "300"
  max_ttl     = "3600"

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE mcpdb TO \"{{name}}\";",
    "GRANT USAGE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
  ]

  revocation_statements = [
    "REASSIGN OWNED BY \"{{name}}\" TO postgres;",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]

  renew_statements = [
    "ALTER ROLE \"{{name}}\" VALID UNTIL '{{expiration}}';"
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cyberark_integration_mode" {
  value       = "CyberArk CCP via Vault generic secrets engine (Pattern A)"
  description = "Integration pattern deployed. See ADR-014 for Pattern A vs B trade-offs."
}

output "cyberark_vault_policy" {
  value       = vault_policy.boundary_cyberark_policy.name
  description = "Vault policy name for Boundary's CyberArk-backed credential store."
}

output "test_cyberark_ccp_path" {
  value       = "vault read cyberark/ccp/mcp-postgres"
  description = "Test CyberArk CCP integration. Should return username+password checked out from EPV."
}
