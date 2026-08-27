#!/usr/bin/env bash
# =============================================================================
# scripts/remediate/keda-force-scalein.sh
#
# Forces immediate KEDA scale-in by temporarily pinning minReplicas = maxReplicas
# to the target count, then restoring the original maxReplicaCount after 20s.
#
# Use ONLY when:
#   - Queue depth is confirmed at 0 (no in-flight requests)
#   - Cost impact from elevated replicas requires immediate action
#   - Undershoot has persisted beyond cooldownPeriod
#
# Usage:
#   ./keda-force-scalein.sh [TARGET_REPLICAS]
#   Default TARGET_REPLICAS = 1
#
# Example:
#   ./keda-force-scalein.sh 2    # scale in to 2 replicas (not min)
#
# See: docs/runbooks/RB-002-keda-undershoot-recovery.md Case C
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-inference}"
SCALEDOBJECT="${SCALEDOBJECT:-llama3-scaler}"
MAX_REPLICAS_RESTORE="${MAX_REPLICAS_RESTORE:-5}"
TARGET_REPLICAS="${1:-1}"
CONTEXT="${KUBECTL_CONTEXT:-kind-ai-platform-lab}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

# ── Preflight: verify queue is actually zero ──────────────────────────────────
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
QUEUE=$(curl -sf \
  "${PROMETHEUS_URL}/api/v1/query?query=sum(vllm_num_waiting_requests)" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    print(d['data']['result'][0]['value'][1] if d['data']['result'] else '0')" \
  2>/dev/null || echo "unknown")

log "Current queue depth: ${QUEUE}"

if [[ "$QUEUE" != "0" && "$QUEUE" != "unknown" ]]; then
  echo ""
  echo "⚠  Queue is not empty (depth=${QUEUE})."
  echo "   Forcing scale-in with active requests causes request drops."
  echo "   Confirm you want to proceed (y/N):"
  read -r CONFIRM
  [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# ── Force scale-in ────────────────────────────────────────────────────────────
log "Forcing scale-in to ${TARGET_REPLICAS} replica(s) via ScaledObject pin..."

kubectl --context "$CONTEXT" patch scaledobject "$SCALEDOBJECT" \
  -n "$NAMESPACE" \
  --type=merge \
  -p "{\"spec\":{\"minReplicaCount\":${TARGET_REPLICAS},\"maxReplicaCount\":${TARGET_REPLICAS}}}"

log "Pinned min=${TARGET_REPLICAS} max=${TARGET_REPLICAS}. Waiting 20s for KEDA reconcile..."
sleep 20

CURRENT=$(kubectl --context "$CONTEXT" get deployment \
  -n "$NAMESPACE" -l "app=llama3" \
  -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "unknown")
log "Current ready replicas: ${CURRENT}"

# ── Restore max ───────────────────────────────────────────────────────────────
log "Restoring ScaledObject: min=${TARGET_REPLICAS} max=${MAX_REPLICAS_RESTORE}..."

kubectl --context "$CONTEXT" patch scaledobject "$SCALEDOBJECT" \
  -n "$NAMESPACE" \
  --type=merge \
  -p "{\"spec\":{\"minReplicaCount\":1,\"maxReplicaCount\":${MAX_REPLICAS_RESTORE}}}"

log "✓ Scale-in forced. ScaledObject restored to min=1 max=${MAX_REPLICAS_RESTORE}."
log "Verify in Grafana: http://localhost:3000 → LLM Golden Signals dashboard"
