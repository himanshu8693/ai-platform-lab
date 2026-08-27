#!/usr/bin/env bash
# =============================================================================
# scripts/ttl-teardown.sh
# Ephemeral Cluster TTL Auto-Teardown
#
# Schedules automatic destruction of an ephemeral cluster after a TTL.
# The "ephemeral" guarantee: every topology has a hard upper time limit.
# Without this, developers forget to clean up and costs/resource usage accumulate.
#
# Usage:
#   bash scripts/ttl-teardown.sh [TTL_SECONDS] [CLUSTER_NAME] [BACKEND]
#
# Arguments:
#   TTL_SECONDS   How long until teardown fires (default: 7200 = 2 hours)
#   CLUSTER_NAME  Cluster name (default: current kubectl context, strip prefix)
#   BACKEND       "kind" or "k3d" (default: auto-detect from cluster name)
#
# Examples:
#   bash scripts/ttl-teardown.sh                        # 2-hour TTL, current context
#   bash scripts/ttl-teardown.sh 3600                   # 1-hour TTL
#   bash scripts/ttl-teardown.sh 1800 ephemeral-lab k3d # 30-min TTL, named k3d cluster
#
# To cancel a scheduled teardown:
#   kill $(cat /tmp/ttl-teardown-<cluster>.pid)
#   rm /tmp/ttl-teardown-<cluster>.pid
#
# Integration with make:
#   make up TTL=3600    # Provisions cluster then schedules 1-hour teardown
# =============================================================================

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
TTL_SECONDS="${1:-7200}"
CLUSTER_NAME="${2:-}"
BACKEND="${3:-}"

# Auto-detect cluster name from current kubectl context if not provided.
if [[ -z "$CLUSTER_NAME" ]]; then
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
  if [[ -z "$CURRENT_CTX" ]]; then
    echo "ERROR: No CLUSTER_NAME provided and kubectl has no current context." >&2
    exit 1
  fi
  # Strip known prefixes: kind- or k3d-
  CLUSTER_NAME="${CURRENT_CTX#kind-}"
  CLUSTER_NAME="${CLUSTER_NAME#k3d-}"
fi

# Auto-detect backend from cluster name or kubectl context.
if [[ -z "$BACKEND" ]]; then
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
  if [[ "$CURRENT_CTX" == k3d-* ]]; then
    BACKEND="k3d"
  else
    BACKEND="kind"
  fi
fi

PID_FILE="/tmp/ttl-teardown-${CLUSTER_NAME}.pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Validation ────────────────────────────────────────────────────────────────
if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TTL_SECONDS" -lt 60 ]]; then
  echo "ERROR: TTL_SECONDS must be a positive integer >= 60. Got: $TTL_SECONDS" >&2
  exit 1
fi

if [[ -f "$PID_FILE" ]]; then
  EXISTING_PID=$(cat "$PID_FILE")
  if kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "WARNING: A teardown for cluster '${CLUSTER_NAME}' is already scheduled (PID ${EXISTING_PID})."
    echo "         Cancel it first: kill ${EXISTING_PID} && rm ${PID_FILE}"
    echo "         Then re-run this script to reschedule."
    exit 1
  else
    # Stale PID file — old process is gone.
    rm -f "$PID_FILE"
  fi
fi

# ── Teardown function (runs after TTL sleep) ──────────────────────────────────
teardown() {
  local cluster="$1"
  local backend="$2"
  local repo_root="$3"

  echo "[TTL-TEARDOWN] $(date -u +%Y-%m-%dT%H:%M:%SZ) Tearing down cluster: ${cluster} (backend: ${backend})"

  # Step 1: Destroy Terraform resources (Boundary scopes, hosts, targets).
  if [[ -d "${repo_root}/terraform" ]]; then
    echo "[TTL-TEARDOWN] Running terraform destroy..."
    cd "${repo_root}/terraform"
    terraform destroy -auto-approve -input=false \
      -var="cluster_name=${cluster}" 2>&1 || true
    cd -
  fi

  # Step 2: Delete the cluster.
  if [[ "$backend" == "k3d" ]]; then
    echo "[TTL-TEARDOWN] Deleting k3d cluster: ${cluster}"
    k3d cluster delete "${cluster}" 2>/dev/null || true
  else
    echo "[TTL-TEARDOWN] Deleting kind cluster: ${cluster}"
    kind delete cluster --name "${cluster}" 2>/dev/null || true
  fi

  # Step 3: Kill any dangling port-forwards.
  pkill -f "kubectl port-forward" 2>/dev/null || true

  # Step 4: Clean up the boundary dev server if running.
  pkill -f "boundary dev" 2>/dev/null || true

  # Step 5: Remove the PID file.
  rm -f "/tmp/ttl-teardown-${cluster}.pid"

  echo "[TTL-TEARDOWN] $(date -u +%Y-%m-%dT%H:%M:%SZ) Cluster '${cluster}' destroyed."
}

export -f teardown

# ── Schedule teardown in background ──────────────────────────────────────────
TEARDOWN_AT=$(date -u -v "+${TTL_SECONDS}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "+${TTL_SECONDS} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || echo "unknown")

(
  sleep "$TTL_SECONDS"
  teardown "$CLUSTER_NAME" "$BACKEND" "$REPO_ROOT"
) &

TEARDOWN_PID=$!
echo "$TEARDOWN_PID" > "$PID_FILE"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  TTL Teardown Scheduled                                  │"
echo "│                                                          │"
printf "│  Cluster  : %-44s │\n" "${CLUSTER_NAME}"
printf "│  Backend  : %-44s │\n" "${BACKEND}"
printf "│  TTL      : %-44s │\n" "${TTL_SECONDS}s ($(( TTL_SECONDS / 60 )) min)"
printf "│  Fires at : %-44s │\n" "${TEARDOWN_AT}"
printf "│  PID      : %-44s │\n" "${TEARDOWN_PID}"
printf "│  PID file : %-44s │\n" "${PID_FILE}"
echo "│                                                          │"
echo "│  To cancel:                                              │"
printf "│    kill %s && rm %s\n" "${TEARDOWN_PID}" "${PID_FILE}" | fold -w 58 | head -1
echo "└─────────────────────────────────────────────────────────┘"
echo ""
