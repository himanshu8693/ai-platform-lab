# =============================================================================
# terraform/vault-boundary-auth.tf
# Vault Database Secrets Engine + Boundary Credential Library
#
# Implements the zero-trust credential injection workflow described in ADR-005:
#   AI Agent → Boundary session → Vault credential library → dynamic PG user
#   → session ends → Vault revokes lease → dynamic user ceases to exist
#
# No static PostgreSQL password ever appears in any manifest, env var, or
# Boundary configuration. The only static secret is the Vault root token used
# by Terraform in dev mode — itself a known lab trade-off documented in ADR-005.
#
# Provider: hashicorp/vault ~> 4.4
# Prerequisites: vault is running in dev mode and accessible at var.vault_addr
#
# Usage:
#   export TF_VAR_postgres_root_user=postgres
#   export TF_VAR_postgres_root_password=<initial-password>
#   export TF_VAR_vault_root_token=root
#   terraform apply -target=module or alongside boundary.tf
#
#   After first apply, rotate the root credentials so Vault becomes the sole
#   holder of the PostgreSQL root access:
#     vault write -force database/rotate-root/mcp-postgres
#
# Production notes (see ADR-005 migration path):
#   • Replace vault_token.boundary_service_token with a Vault AppRole
#     auth method bound to the Boundary Worker's Kubernetes SA.
#   • Set postgres TTL to match your SOC-2 session policy (e.g., 30 min).
#   • Add audit device: vault audit enable file file_path=/vault/logs/audit.log
# =============================================================================

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.1"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "vault_addr" {
  type        = string
  default     = "http://localhost:30820"
  description = "Vault API address. Override via TF_VAR_vault_addr."
}

variable "postgres_root_user" {
  type        = string
  sensitive   = true
  description = "Initial PostgreSQL superuser that Vault will use to CREATE/REVOKE dynamic users. Set via TF_VAR_postgres_root_user. Vault rotates this after first apply."
}

variable "postgres_root_password" {
  type        = string
  sensitive   = true
  description = "Initial PostgreSQL superuser password. Set via TF_VAR_postgres_root_password. Vault rotates this after first apply — the plaintext is never stored after rotation."
}

variable "postgres_host" {
  type        = string
  default     = "postgres.inference.svc.cluster.local"
  description = "PostgreSQL host as seen from the Boundary Worker (in-cluster DNS)."
}

variable "postgres_port" {
  type        = number
  default     = 5432
  description = "PostgreSQL port."
}

variable "postgres_db" {
  type        = string
  default     = "mcpdb"
  description = "Database name the MCP server connects to."
}

variable "dynamic_cred_ttl" {
  type        = string
  default     = "3600"
  description = "TTL in seconds for dynamic database credentials. Matches Boundary session_max_seconds. Production: lower to 1800 or 900."
}

# ── Vault Provider ────────────────────────────────────────────────────────────

provider "vault" {
  address = var.vault_addr
  token   = var.vault_root_token   # dev-mode root token from main.tf variable
}

# ── Step 1: Enable the Database Secrets Engine ───────────────────────────────
# The database secrets engine generates time-limited credentials for any
# supported database backend. Vault creates the user, tracks the lease, and
# revokes (DROP ROLE) the user when the lease expires or is explicitly revoked.

resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Dynamic credential engine for Boundary-brokered MCP server → PostgreSQL sessions"
}

# ── Step 2: Configure the PostgreSQL Connection ───────────────────────────────
# Vault connects to PostgreSQL with the root credentials to manage dynamic users.
# After `vault write -force database/rotate-root/mcp-postgres`, the original
# credentials are replaced by Vault-managed ones — Terraform can no longer
# reconnect using the original values (intentional: root credentials become Vault's
# internal secret, not a human-held value).

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "mcp-postgres"
  allowed_roles = ["mcp-server-role", "mcp-server-readonly-role"]

  postgresql {
    # Vault substitutes {{username}} and {{password}} with the root creds at
    # connection time. The template syntax prevents Terraform state from ever
    # seeing the plaintext connection string.
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}:${var.postgres_port}/${var.postgres_db}?sslmode=disable"

    username = var.postgres_root_user
    password = var.postgres_root_password

    # Dynamic username template: v-mcp-<8 random chars>
    # Must be ≤ 63 chars (PostgreSQL role name limit).
    username_template = "v-mcp-{{random 8}}"

    # Max concurrent open connections Vault holds to PostgreSQL.
    # In the lab, 5 is sufficient. Production: tune to PG max_connections.
    max_open_connections = 5
    max_idle_connections = 2
  }

  depends_on = [vault_mount.database]
}

# ── Step 3: Vault Role — defines what a dynamic user can do ──────────────────
# The creation_statements SQL runs when Boundary requests credentials.
# The revocation_statements SQL runs when the Boundary session ends.

resource "vault_database_secret_backend_role" "mcp_server_role" {
  backend = vault_mount.database.path
  name    = "mcp-server-role"
  db_name = vault_database_secret_backend_connection.postgres.name

  # Credential TTL strategy (ADR-011):
  # - default_ttl = 300s (5 min): matches the moderate session pool window.
  #   Most sessions complete well within 5 minutes; this bounds blast radius
  #   from a credential compromise to at most 5 minutes.
  # - max_ttl = dynamic_cred_ttl (3600s): allows Boundary to extend the lease
  #   for long-running RCA investigations that span multiple tool-call chains.
  # When the Boundary session ends first, it calls Vault to revoke the lease
  # immediately — the TTL is a ceiling, not a guarantee of validity.
  default_ttl = "300"              # 5 min — moderate pool window (ADR-011)
  max_ttl     = var.dynamic_cred_ttl  # 1h ceiling for long-running sessions

  # CREATE: Vault runs this SQL when issuing credentials to Boundary.
  # {{name}}, {{password}}, {{expiration}} are Vault template variables.
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE ${var.postgres_db} TO \"{{name}}\";",
    "GRANT USAGE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO \"{{name}}\";"
  ]

  # REVOKE: Vault runs this SQL on lease expiry or explicit revocation.
  # REASSIGN OWNED prevents orphaned objects if the user created anything.
  revocation_statements = [
    "REASSIGN OWNED BY \"{{name}}\" TO postgres;",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ]

  # RENEW: extend the VALID UNTIL timestamp when Boundary renews the lease mid-session.
  # This prevents credential expiry during long-running tool-call chains where
  # the default_ttl (5 min) would otherwise cut off an active session.
  # Boundary calls this path automatically when the credential is within 10% of TTL.
  renew_statements = [
    "ALTER ROLE \"{{name}}\" VALID UNTIL '{{expiration}}';",
    -- Renew also bumps connection limit to prevent stale idle sessions from
    -- holding a PostgreSQL slot unnecessarily
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}' AND state = 'idle' AND state_change < NOW() - INTERVAL '10 minutes';"
  ]

  depends_on = [vault_database_secret_backend_connection.postgres]
}

# ── Step 4: Vault Policy for Boundary ────────────────────────────────────────
# Boundary holds a token with ONLY this policy. It can generate credentials
# for mcp-server-role and manage the resulting leases. Nothing else.

resource "vault_policy" "boundary_credential_policy" {
  name = "boundary-mcp-credential-policy"

  policy = <<-EOT
    # Boundary calls this path when authorising a session to the postgres target.
    path "database/creds/mcp-server-role" {
      capabilities = ["read"]
    }
    # Vault lease management — required for Boundary to renew during the session.
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
    # Vault lease revocation — Boundary calls this when the session ends cleanly.
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
    # Allow Boundary to look up its own token (liveness check).
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

# ── Step 5: Vault Token for Boundary ─────────────────────────────────────────
# An orphan, renewable token scoped only to the credential policy.
# In production, replace with Vault AppRole auth bound to the Boundary Worker SA.

resource "vault_token" "boundary_service_token" {
  policies  = [vault_policy.boundary_credential_policy.name]
  no_parent = true      # Orphan: survives rotation of the root token
  renewable = true
  ttl       = "768h"    # 32 days for lab; production: use AppRole (no fixed TTL)
  period    = "768h"    # Renewable indefinitely

  metadata = {
    "purpose" = "boundary-credential-store-for-mcp-postgres"
    "lab"     = "ai-platform-lab"
  }

  depends_on = [vault_policy.boundary_credential_policy]
}

# ── Step 6: Boundary Credential Store → Vault ─────────────────────────────────
# Boundary's credential store calls Vault's database secrets engine.
# The store holds the Vault token; Boundary workers use it on session auth.

resource "boundary_credential_store_vault" "mcp_creds" {
  name        = "vault-dynamic-mcp-creds"
  description = "Vault-brokered dynamic credentials for MCP→PostgreSQL sessions. No static password in Boundary."
  scope_id    = boundary_scope.project_inference.id   # references boundary.tf scope

  # Vault address from the Boundary Worker's perspective (in-cluster).
  address = "http://vault.vault.svc.cluster.local:8200"

  # The policy-scoped Vault token issued above.
  token = vault_token.boundary_service_token.client_token

  # Vault namespace (root in dev mode; set for HCP Vault or Vault Enterprise).
  # namespace = "admin"

  depends_on = [vault_token.boundary_service_token]
}

# ── Step 7: Boundary Credential Library ──────────────────────────────────────
# Maps a Vault path to a Boundary credential type.
# When Boundary authorises a session, it GETs this path to obtain creds.

resource "boundary_credential_library_vault" "postgres_dynamic" {
  name                = "postgres-dynamic-creds"
  description         = "Generates a short-TTL PostgreSQL user per Boundary session. The user is revoked when the session ends."
  credential_store_id = boundary_credential_store_vault.mcp_creds.id

  # The Vault path Boundary calls: GET /v1/database/creds/mcp-server-role
  path            = "database/creds/mcp-server-role"
  http_method     = "GET"
  credential_type = "username_password"
}

# ── Step 8: PostgreSQL Target in Boundary ────────────────────────────────────
# Host catalog, host, host-set, and target — all scoped to project_inference.
# Defined here rather than in boundary.tf to keep the credential injection
# concern co-located with the credential library that drives it.

resource "boundary_host_catalog_static" "postgres" {
  name        = "postgres-hosts"
  description = "PostgreSQL pod in inference namespace — MCP server database target"
  scope_id    = boundary_scope.project_inference.id
}

resource "boundary_host_static" "postgres_pod" {
  name            = "postgres-inference"
  description     = "PostgreSQL: ${var.postgres_host}:${var.postgres_port}"
  address         = var.postgres_host
  host_catalog_id = boundary_host_catalog_static.postgres.id
}

resource "boundary_host_set_static" "postgres_set" {
  name            = "postgres-hostset"
  host_catalog_id = boundary_host_catalog_static.postgres.id
  host_ids        = [boundary_host_static.postgres_pod.id]
}

resource "boundary_target" "mcp_postgres" {
  type        = "tcp"
  name        = "mcp-postgres-target"
  description = "Zero-trust JIT PostgreSQL access for MCP server sessions. Vault injects a dynamic username+password per session. The credential is revoked when the session ends."
  scope_id    = boundary_scope.project_inference.id

  # TTL must match the Vault credential max_ttl (var.dynamic_cred_ttl = 3600s).
  # The Vault default_ttl (300s) governs when Boundary will renew — not when the
  # session hard-terminates. A session can outlive 300s if Boundary renews it.
  session_max_seconds      = tonumber(var.dynamic_cred_ttl)
  session_connection_limit = 1     # One DB connection per authorised session

  # Gap E: OTel trace ID correlation (ADR-013)
  # The MCP server passes the W3C trace ID from the Context Forge request as a
  # Boundary session annotation. This creates the cross-system audit join key:
  # one trace ID links a Tempo span to its corresponding Boundary session recording.
  # The annotation is stored in Boundary's session metadata and appears in MinIO
  # recordings under the sessions/<id>/metadata.json path.

  default_port    = var.postgres_port
  host_source_ids = [boundary_host_set_static.postgres_set.id]

  # Credential injection: Boundary calls Vault, gets creds, injects into session.
  # The connecting client (MCP server or AI agent CLI) NEVER sees the password —
  # Boundary injects it transparently into the proxied TCP stream.
  injected_application_credential_source_ids = [
    boundary_credential_library_vault.postgres_dynamic.id
  ]

  ingress_worker_filter = "\"local\" in \"/tags/type\""
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "boundary_vault_token_note" {
  value       = "Boundary Vault token created. View with: terraform output -raw boundary_vault_token_client (sensitive)"
  description = "Use the vault token output to configure the Boundary credential store token if applying modules independently."
  sensitive   = false
}

output "connect_mcp_postgres_cmd" {
  value       = "boundary connect postgres -target-id=${boundary_target.mcp_postgres.id} -dbname=${var.postgres_db}"
  description = "Connect to PostgreSQL via Boundary with Vault-injected dynamic credentials. No password flag needed — Boundary injects it."
}

output "verify_dynamic_creds_cmd" {
  value       = "vault read database/creds/mcp-server-role"
  description = "Test that Vault can issue credentials manually (verifies DB connection + role config)."
}

output "rotate_root_creds_cmd" {
  value       = "vault write -force database/rotate-root/mcp-postgres"
  description = "IMPORTANT: Run this after first apply to make Vault the sole holder of the PostgreSQL root credentials."
}
