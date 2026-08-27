# =============================================================================
# ai-platform-lab — HashiCorp Boundary: Zero-Trust Administrative Access
# =============================================================================
#
# Purpose:
#   Provides Just-In-Time (JIT) access to the KinD cluster control plane and
#   internal platform services WITHOUT exposing long-lived credentials or
#   persistent network paths. Engineers authenticate to Boundary, receive a
#   time-limited session credential, and connect through a Boundary worker
#   acting as a TCP proxy. No VPN. No shared bastion SSH keys.
#
# Architecture:
#   Developer workstation
#     └─▶ Boundary Desktop / CLI
#           └─▶ Boundary Controller (this Terraform provisions the config)
#                 └─▶ Boundary Worker (local Docker container in lab)
#                       └─▶ TCP proxy to KinD API (127.0.0.1:6443)
#                             └─▶ Kubernetes control plane
#
# Provider: hashicorp/boundary ~> 1.1
#
# Prerequisites (local lab):
#   1. Boundary dev server running:
#        boundary dev &
#        # Dev mode starts controller + worker on localhost:9200 (API) / :9201 (cluster) / :9202 (worker)
#        # Dev mode admin login: admin / password
#   2. Set environment:
#        export BOUNDARY_ADDR=http://127.0.0.1:9200
#        export BOUNDARY_TOKEN=$(boundary authenticate password \
#          -auth-method-id=ampw_1234567890 \
#          -login-name=admin \
#          -password=password \
#          -format=json | jq -r .item.attributes.token)
#
# Usage after apply:
#   boundary connect kube -target-id=<ttcp_...> -- get pods -n inference
#   # ↑ Opens a transparent kubectl proxy through Boundary — no raw kubeconfig sharing
#
# Production equivalent:
#   Replace dev mode with HCP Boundary or self-hosted HA controller.
#   Integrate with OIDC (Okta / Azure AD) for auth-method.
#   Deploy Boundary workers in each VPC/cloud region as Kubernetes DaemonSets.
#   Issue credentials via Vault SSH secrets engine (dynamic host credentials).
# =============================================================================

terraform {
  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.1"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment. Accepted values: dev | staging | production. Setting production triggers the dev-mode guard (see ADR-005)."

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "boundary_addr" {
  type        = string
  default     = "http://127.0.0.1:9200"
  description = "Boundary controller API address. Override via TF_VAR_boundary_addr."
}

variable "boundary_token" {
  type        = string
  sensitive   = true
  description = "Boundary auth token. Set via TF_VAR_boundary_token or BOUNDARY_TOKEN env var."
}

variable "kind_api_address" {
  type        = string
  default     = "127.0.0.1"
  description = "KinD cluster API server host. Resolved from the Boundary worker's perspective."
}

variable "kind_api_port" {
  type        = number
  default     = 6443
  description = "KinD cluster API server port (default 6443)."
}

variable "session_max_seconds" {
  type        = number
  default     = 3600
  description = "Maximum session duration in seconds (1 hour). Rotate down in production."
}

variable "session_connection_limit" {
  type        = number
  default     = -1
  description = "Max connections per session (-1 = unlimited). Set to 1 in high-security prod targets."
}

# =============================================================================
# Provider
# =============================================================================

provider "boundary" {
  addr  = var.boundary_addr
  token = var.boundary_token
}

# =============================================================================
# Dev-Mode Production Guard (ADR-005)
# =============================================================================
# This file deploys Boundary in dev mode: single-process, in-memory database,
# static well-known admin credentials (admin / password), no TLS.
#
# Dev mode is ONLY safe on a localhost-only KinD cluster. It must never be
# applied to a production environment.
#
# This null_resource carries a lifecycle precondition that aborts `terraform apply`
# immediately — before any Boundary resources are created — if the caller sets
# var.environment = "production".
#
# How to trigger the guard (will fail fast with a clear error):
#   terraform apply -var='environment=production'
#
# To deploy production Boundary, use terraform/boundary-prod.tf (not yet
# implemented — see ADR-005 Step 1–5 migration path for the full spec).
#
# Why null_resource and not a local_file or check block:
#   terraform validate / plan evaluates preconditions during the plan phase,
#   so the error surfaces before any API calls reach the Boundary provider.
#   null_resource with lifecycle.precondition is the idiomatic pattern for
#   cross-cutting guards that don't correspond to a real managed resource.
# =============================================================================

resource "null_resource" "boundary_dev_mode_guard" {
  # Triggers: rechecked on every apply. If someone changes environment from
  # dev → production between applies, the guard fires immediately.
  triggers = {
    environment = var.environment
  }

  lifecycle {
    precondition {
      condition     = var.environment != "production"
      error_message = <<-EOT
        ERROR: boundary.tf deploys Boundary in DEV MODE (in-memory DB, static
        admin credentials, no TLS). This configuration MUST NOT be applied to
        environment=production.

        To deploy production-grade Boundary, implement terraform/boundary-prod.tf
        following the migration path in docs/adr/ADR-005-boundary-auth-strategy.md:
          Step 1 — PostgreSQL backend
          Step 2 — OIDC auth method (IBM SSO / Okta)
          Step 3 — Vault-brokered credential injection
          Step 4 — mTLS between worker and controller
          Step 5 — Session recording to S3-compatible storage
      EOT
    }
  }
}

# =============================================================================
# Scope: Organisation
# =============================================================================
# The global scope is the root. All org scopes live under it.
# One org per business unit — here "IBM_AI_Platform_Lab" models the
# IBM Software Division AI infrastructure team.

resource "boundary_scope" "org" {
  name                     = "IBM_AI_Platform_Lab"
  description              = "Zero-Trust Administrative Scope — AI Platform Engineering Lab (IBM Band 8 transition portfolio)"
  scope_id                 = "global"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

# =============================================================================
# Scope: Projects
# =============================================================================
# Projects are sub-scopes inside an org. Each maps to one logical blast radius.
# Engineers are granted access to specific projects — not the entire org.

resource "boundary_scope" "project_inference" {
  name                   = "AI_Inference_Cluster"
  description            = "JIT access management for KinD local cluster — inference workloads and control plane"
  scope_id               = boundary_scope.org.id
  auto_create_admin_role = true
}

resource "boundary_scope" "project_platform" {
  name                   = "Platform_Services"
  description            = "JIT access for Vault UI, Grafana, ArgoCD — platform operator access (higher privilege)"
  scope_id               = boundary_scope.org.id
  auto_create_admin_role = true
}

# =============================================================================
# Host Catalog & Hosts
# =============================================================================
# A Host Catalog is a collection of Hosts (target endpoints).
# Static catalog used here — in production, use dynamic catalogs
# (AWS/GCP plugin) to auto-discover EC2/GCE instances by tag.

resource "boundary_host_catalog_static" "kind_cluster" {
  name        = "kind-cluster-hosts"
  description = "Static host catalog for local KinD cluster endpoints"
  scope_id    = boundary_scope.project_inference.id
}

# ── Host: KinD API server ─────────────────────────────────────────────────────
resource "boundary_host_static" "kind_api" {
  name            = "kind-control-plane"
  description     = "KinD cluster API server — kubectl proxy target"
  address         = var.kind_api_address
  host_catalog_id = boundary_host_catalog_static.kind_cluster.id
}

# ── Host: Vault UI ────────────────────────────────────────────────────────────
resource "boundary_host_catalog_static" "platform_services" {
  name        = "platform-services-hosts"
  description = "Static host catalog for platform operator UIs"
  scope_id    = boundary_scope.project_platform.id
}

resource "boundary_host_static" "vault_ui" {
  name            = "vault-dev-ui"
  description     = "HashiCorp Vault dev-mode UI (NodePort 30820)"
  address         = "127.0.0.1"
  host_catalog_id = boundary_host_catalog_static.platform_services.id
}

resource "boundary_host_static" "argocd_ui" {
  name            = "argocd-ui"
  description     = "ArgoCD UI (NodePort or port-forward on 8080)"
  address         = "127.0.0.1"
  host_catalog_id = boundary_host_catalog_static.platform_services.id
}

# ── Host Sets (group hosts for target binding) ────────────────────────────────
resource "boundary_host_set_static" "kind_api_set" {
  name            = "kind-api-hostset"
  host_catalog_id = boundary_host_catalog_static.kind_cluster.id
  host_ids        = [boundary_host_static.kind_api.id]
}

resource "boundary_host_set_static" "platform_ui_set" {
  name            = "platform-ui-hostset"
  host_catalog_id = boundary_host_catalog_static.platform_services.id
  host_ids = [
    boundary_host_static.vault_ui.id,
    boundary_host_static.argocd_ui.id,
  ]
}

# =============================================================================
# Targets
# =============================================================================
# A Target ties together: a host set, a port, session duration, and credential
# injection (optional). This is the resource engineers connect to.

# ── Target: KinD API (kubectl access) ─────────────────────────────────────────
resource "boundary_target" "kind_api" {
  type                     = "tcp"
  name                     = "kind-cluster-control-plane"
  description              = "JIT kubectl proxy to KinD API server (6443). Session auto-expires after ${var.session_max_seconds}s. No persistent kubeconfig sharing."
  scope_id                 = boundary_scope.project_inference.id
  session_max_seconds      = var.session_max_seconds
  session_connection_limit = var.session_connection_limit
  default_port             = var.kind_api_port

  host_source_ids = [boundary_host_set_static.kind_api_set.id]

  # Ingress worker filter: only allow connections through workers
  # tagged with type=local. In production, use datacenter=us-east-1 etc.
  ingress_worker_filter = "\"local\" in \"/tags/type\""
}

# ── Target: Vault UI ──────────────────────────────────────────────────────────
resource "boundary_target" "vault_ui" {
  type                     = "tcp"
  name                     = "vault-ui"
  description              = "JIT access to HashiCorp Vault dev UI (NodePort 30820). Operator access only."
  scope_id                 = boundary_scope.project_platform.id
  session_max_seconds      = 1800 # Shorter session for operator UI access
  session_connection_limit = 1    # One connection per session for UI targets
  default_port             = 30820

  host_source_ids = [boundary_host_set_static.platform_ui_set.id]

  ingress_worker_filter = "\"local\" in \"/tags/type\""
}

# ── Target: ArgoCD UI ─────────────────────────────────────────────────────────
resource "boundary_target" "argocd_ui" {
  type                     = "tcp"
  name                     = "argocd-ui"
  description              = "JIT access to ArgoCD UI (port 8080). GitOps operator access."
  scope_id                 = boundary_scope.project_platform.id
  session_max_seconds      = 1800
  session_connection_limit = 1
  default_port             = 8080

  host_source_ids = [boundary_host_set_static.platform_ui_set.id]

  ingress_worker_filter = "\"local\" in \"/tags/type\""
}

# =============================================================================
# Outputs
# =============================================================================

output "boundary_org_id" {
  value       = boundary_scope.org.id
  description = "Boundary organisation scope ID"
}

output "boundary_project_inference_id" {
  value       = boundary_scope.project_inference.id
  description = "Inference cluster project scope ID"
}

output "boundary_target_kind_api_id" {
  value       = boundary_target.kind_api.id
  description = "Target ID for KinD API server — use with: boundary connect kube -target-id=<id>"
}

output "connect_kind_api_cmd" {
  value       = "boundary connect kube -target-id=${boundary_target.kind_api.id} -- get pods -A"
  description = "JIT kubectl command — authenticates through Boundary, no raw kubeconfig required"
}

output "connect_vault_ui_cmd" {
  value       = "boundary connect -target-id=${boundary_target.vault_ui.id} -listen-port=30820"
  description = "Open a JIT proxy to Vault UI on localhost:30820"
}

# =============================================================================
# PRODUCTION UPGRADE PATH (comments — not applied in local lab)
# =============================================================================
#
# 1. Replace dev mode with HCP Boundary (managed controller, no infra to run):
#      variable "boundary_addr" { default = "https://your-cluster.boundary.hashicorp.cloud" }
#
# 2. Add OIDC auth method (Okta / Azure AD):
#      resource "boundary_auth_method_oidc" "okta" {
#        scope_id          = boundary_scope.org.id
#        name              = "Okta OIDC"
#        issuer            = "https://company.okta.com"
#        client_id         = var.okta_client_id
#        client_secret     = var.okta_client_secret
#        signing_algorithms = ["RS256"]
#        api_url_prefix    = var.boundary_addr
#      }
#
# 3. Credential injection from Vault (zero secrets on client):
#      resource "boundary_credential_library_vault" "k8s_sa_token" {
#        credential_store_id = boundary_credential_store_vault.main.id
#        name                = "k8s-inference-sa-token"
#        path                = "kubernetes/creds/inference-role"
#        http_method         = "POST"
#        credential_type     = "kubernetes"
#      }
#      # Attach to target — engineer connects, gets a time-limited SA token injected
#      # automatically, never sees the raw token.
#
# 4. Deploy workers as Kubernetes DaemonSet in each cluster:
#      # boundary-worker.yaml (separate from Terraform)
#      # Workers register to controller via HCP Boundary upstream.
# =============================================================================
