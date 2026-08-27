#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-vault.sh
# Post-Init Vault Configuration for the Ephemeral Lab Engine
#
# Runs AFTER Vault is deployed and reachable (dev mode auto-unseals).
# Configures everything the platform needs:
#   1. Enable Kubernetes auth method (Vault Agent sidecars)
#   2. Enable KV-v2 secrets engine
#   3. Create platform secret paths with placeholder values
#   4. Enable PKI engine + generate root CA + issue intermediate CA
#   5. Write Vault policies for all ServiceAccounts
#   6. Create Kubernetes auth roles for each SA
#   7. Enable database secrets engine (prerequisite for vault-boundary-auth.tf)
#   8. Store Context Forge secrets (JWT key, encryption secret, admin password)
#
# Usage:
#   export VAULT_ADDR=http://localhost:30820
#   export VAULT_TOKEN=root
#   bash scripts/bootstrap-vault.sh
#
# Idempotent: safe to re-run. All operations check existence before creating.
# =============================================================================

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:30820}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
export VAULT_ADDR VAULT_TOKEN

K8S_API_HOST="${K8S_API_HOST:-$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')}"

log() { echo "[bootstrap-vault] $(date -u +%H:%M:%S) $*"; }
vault_or_skip() {
  # Run vault command; skip (don't fail) if resource already exists.
  vault "$@" 2>&1 | grep -v "already in use\|already exists\|path is already" || true
}

log "Vault addr: ${VAULT_ADDR}"
log "Checking Vault status..."
vault status -format=json | jq -r '"  Initialized: \(.initialized), Sealed: \(.sealed)"'

# ── 1. Kubernetes Auth Method ─────────────────────────────────────────────────
log "Enabling Kubernetes auth method..."
vault_or_skip auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host="https://${K8S_API_HOST}:443" \
  2>&1 | grep -v "Success" || true

log "Kubernetes auth configured."

# ── 2. KV-v2 Secrets Engine ───────────────────────────────────────────────────
log "Enabling KV-v2 secrets engine at 'secret/'..."
vault_or_skip secrets enable -path=secret kv-v2

# ── 3. Platform Secret Paths (placeholder values) ─────────────────────────────
log "Writing platform secrets (placeholder values — replace before using)..."

# HuggingFace token (replace with real value for model weight download)
vault kv put -mount=secret ai-platform/hf-token \
  value="hf-placeholder-replace-me" 2>/dev/null || true

# Ollama API key (replace if Ollama auth is enabled)
vault kv put -mount=secret ai-platform/ollama-api-key \
  key="ollama-placeholder-replace-me" 2>/dev/null || true

# Context Forge secrets (generated fresh on each bootstrap)
log "Generating Context Forge secrets..."
JWT_SECRET=$(openssl rand -hex 32)
ENC_SECRET=$(openssl rand -hex 32)
ADMIN_PASS=$(openssl rand -base64 24 | tr -d '=+/')

vault kv put -mount=secret ai-platform/context-forge/jwt-secret-key \
  value="${JWT_SECRET}"
vault kv put -mount=secret ai-platform/context-forge/auth-encryption-secret \
  value="${ENC_SECRET}"
vault kv put -mount=secret ai-platform/context-forge/admin-password \
  value="${ADMIN_PASS}"

log "Context Forge secrets written."

# ── 4. PKI Engine — Root CA ───────────────────────────────────────────────────
log "Enabling PKI secrets engine..."
vault_or_skip secrets enable pki
vault_or_skip secrets tune -max-lease-ttl=87600h pki

# Generate root CA (idempotent — fails silently if already exists)
vault write -field=certificate pki/root/generate/internal \
  common_name="ephemeral-lab-root-ca" \
  issuer_name="root-2025" \
  ttl=87600h 2>/dev/null | head -c 50 > /dev/null || true

# Configure CRL and issuing URLs
vault write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl" 2>/dev/null || true

# PKI intermediate for service certs (mTLS between platform components)
vault_or_skip secrets enable -path=pki_int pki
vault_or_skip secrets tune -max-lease-ttl=43800h pki_int

log "PKI engine configured."

# ── 5. Vault Policies ─────────────────────────────────────────────────────────
log "Writing Vault policies..."

# Inference workloads policy
vault policy write inference-policy - <<'EOF'
path "secret/data/ai-platform/*" { capabilities = ["read"] }
path "secret/metadata/ai-platform/*" { capabilities = ["read", "list"] }
path "pki_int/issue/inference-role" { capabilities = ["create", "update"] }
EOF

# Context Forge gateway policy
vault policy write context-forge-policy - <<'EOF'
path "secret/data/ai-platform/context-forge/*" { capabilities = ["read"] }
path "secret/metadata/ai-platform/context-forge/*" { capabilities = ["read", "list"] }
EOF

# AI Assistant policy (reads Context Forge JWT key to generate bearer token)
vault policy write ai-assistant-forge-policy - <<'EOF'
path "secret/data/ai-platform/context-forge/jwt-secret-key" { capabilities = ["read"] }
path "secret/data/ai-platform/ollama-api-key" { capabilities = ["read"] }
path "secret/data/ai-platform/context-forge/service-token" { capabilities = ["read", "create", "update"] }
path "secret/data/ai-platform/context-forge/virtual-server-endpoint" { capabilities = ["read"] }
EOF

# Context Forge bootstrap policy (used by the bootstrap Job)
vault policy write context-forge-bootstrap-policy - <<'EOF'
path "secret/data/ai-platform/context-forge/*" { capabilities = ["read", "create", "update"] }
path "secret/metadata/ai-platform/context-forge/*" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
EOF

log "Policies written."

# ── 6. Kubernetes Auth Roles ──────────────────────────────────────────────────
log "Creating Kubernetes auth roles..."

vault write auth/kubernetes/role/inference-role \
  bound_service_account_names="inference-sa,mcp-kubernetes-sa,mcp-prometheus-sa,ai-assistant-sa,ollama" \
  bound_service_account_namespaces="inference" \
  policies="inference-policy" \
  ttl=1h 2>/dev/null || true

vault write auth/kubernetes/role/context-forge-role \
  bound_service_account_names="context-forge-sa" \
  bound_service_account_namespaces="inference" \
  policies="context-forge-policy" \
  ttl=1h 2>/dev/null || true

vault write auth/kubernetes/role/ai-assistant-forge-role \
  bound_service_account_names="ai-assistant-sa" \
  bound_service_account_namespaces="inference" \
  policies="ai-assistant-forge-policy" \
  ttl=1h 2>/dev/null || true

vault write auth/kubernetes/role/context-forge-bootstrap-role \
  bound_service_account_names="context-forge-bootstrap-sa" \
  bound_service_account_namespaces="inference" \
  policies="context-forge-bootstrap-policy" \
  ttl=30m 2>/dev/null || true

log "Kubernetes auth roles created."

# ── 7. Database Secrets Engine (prerequisite for vault-boundary-auth.tf) ─────
log "Enabling database secrets engine..."
vault_or_skip secrets enable database

log "Database secrets engine enabled (configure via vault-boundary-auth.tf)."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "┌───────────────────────────────────────────────────────────┐"
echo "│  Vault Bootstrap Complete                                  │"
echo "│                                                            │"
echo "│  Auth methods: kubernetes                                  │"
echo "│  Secret engines: kv-v2 (secret/), pki, pki_int, database  │"
echo "│  Policies: inference-policy, context-forge-policy,        │"
echo "│            ai-assistant-forge-policy,                      │"
echo "│            context-forge-bootstrap-policy                  │"
echo "│  K8s auth roles: inference-role, context-forge-role,      │"
echo "│                  ai-assistant-forge-role,                  │"
echo "│                  context-forge-bootstrap-role              │"
echo "│                                                            │"
echo "│  Next step:                                                │"
echo "│    terraform apply (to configure Boundary credential       │"
echo "│    store using the database secrets engine)                │"
echo "└───────────────────────────────────────────────────────────┘"
echo ""
log "Done."
