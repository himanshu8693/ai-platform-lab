#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-boundary.sh
# Boundary Dev-Mode Seeding for the Ephemeral Lab Engine
#
# Seeds the Boundary in-memory database (dev mode) with the org, project scopes,
# host catalogs, and targets defined in terraform/boundary.tf.
#
# This script is called by `make up` AFTER `terraform apply` has been run.
# It is idempotent: each step checks for existing resources before creating.
#
# Usage:
#   export BOUNDARY_ADDR=http://127.0.0.1:9200
#   bash scripts/bootstrap-boundary.sh
#
# Prerequisites:
#   boundary dev server must be running:
#     boundary dev > /tmp/boundary-dev.log 2>&1 &
# =============================================================================

set -euo pipefail

BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://127.0.0.1:9200}"
export BOUNDARY_ADDR

log() { echo "[bootstrap-boundary] $(date -u +%H:%M:%S) $*"; }

# ── Wait for Boundary dev server ──────────────────────────────────────────────
log "Waiting for Boundary dev server at ${BOUNDARY_ADDR}..."
for i in $(seq 1 30); do
  if curl -sf "${BOUNDARY_ADDR}/v1/health" > /dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: Boundary dev server not reachable after 30s." >&2
    echo "       Start it with: boundary dev > /tmp/boundary-dev.log 2>&1 &" >&2
    exit 1
  fi
  sleep 1
done
log "Boundary is reachable."

# ── Authenticate ──────────────────────────────────────────────────────────────
log "Authenticating as dev-mode admin..."
BOUNDARY_TOKEN=$(boundary authenticate password \
  -auth-method-id=ampw_1234567890 \
  -login-name=admin \
  -password=password \
  -format=json 2>/dev/null | jq -r '.item.attributes.token')

if [[ -z "$BOUNDARY_TOKEN" || "$BOUNDARY_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to authenticate to Boundary dev server." >&2
  exit 1
fi
export BOUNDARY_TOKEN
log "Authenticated. Token obtained."

# ── Apply Terraform resources ─────────────────────────────────────────────────
# boundary.tf and vault-boundary-auth.tf define all resources.
# This script runs terraform apply with the pre-authenticated token.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

log "Running terraform apply for Boundary resources..."
cd "${TF_DIR}"

# Set required variables for Terraform.
export TF_VAR_boundary_token="${BOUNDARY_TOKEN}"
export TF_VAR_vault_root_token="${VAULT_TOKEN:-root}"

terraform init -input=false -upgrade -backend=false > /dev/null 2>&1 || true

terraform apply -auto-approve -input=false \
  -target=boundary_scope.org \
  -target=boundary_scope.project_inference \
  -target=boundary_scope.project_platform \
  -target=boundary_host_catalog_static.kind_cluster \
  -target=boundary_host_static.kind_api \
  -target=boundary_host_set_static.kind_api_set \
  -target=boundary_target.kind_api \
  -target=boundary_host_catalog_static.platform_services \
  -target=boundary_host_static.vault_ui \
  -target=boundary_host_static.argocd_ui \
  -target=boundary_host_set_static.platform_ui_set \
  -target=boundary_target.vault_ui \
  -target=boundary_target.argocd_ui \
  2>&1 | tail -20

log "Boundary Terraform resources applied."

# ── Output connection commands ────────────────────────────────────────────────
KIND_API_TARGET=$(terraform output -raw boundary_target_kind_api_id 2>/dev/null || echo "N/A")

cd - > /dev/null

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Boundary Bootstrap Complete                                 │"
echo "│                                                              │"
echo "│  Dev mode admin: admin / password                           │"
printf "│  Boundary UI:    %-44s │\n" "${BOUNDARY_ADDR}"
printf "│  Kind API target: %-43s │\n" "${KIND_API_TARGET}"
echo "│                                                              │"
echo "│  Connect to cluster via Boundary:                           │"
printf "│    boundary connect kube -target-id=%s\n" "${KIND_API_TARGET}" | fold -w 62 | head -1
echo "│    -- get pods -A                                           │"
echo "│                                                              │"
echo "│  NOTE: In-memory DB — re-run this script after              │"
echo "│  'boundary dev' restarts (e.g., after make clean + make up) │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
log "Done."
