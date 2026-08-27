#!/usr/bin/env bash
# =============================================================================
# scripts/remediate/oom-recovery.sh
#
# Automated OOM recovery for the llama3 inference deployment.
# Called by on-call when Tier-1 liveness probe recovery is insufficient.
#
# Usage:
#   ./oom-recovery.sh case-a   # KV-cache overflow — scale out replicas
#   ./oom-recovery.sh case-b   # Memory limit too low — patch limits
#   ./oom-recovery.sh case-c   # Traffic shedding — drain proxy, wait, restore
#
# See: docs/runbooks/RB-001-ollama-oom-recovery.md for decision matrix
# =============================================================================
set -euo pipefail

NAMESPACE="inference"
DEPLOYMENT="llama3"
PROXY_DEPLOYMENT="inference-proxy"
CONTEXT="${KUBECTL_CONTEXT:-kind-ai-platform-lab}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

case "${1:-}" in

  # ── Case A: KV-cache overflow ─────────────────────────────────────────────
  case-a)
    log "Case A: Scaling out replicas to spread KV-cache load..."

    CURRENT=$(kubectl --context "$CONTEXT" get deployment "$DEPLOYMENT" \
      -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
    NEW_REPLICAS=$(( CURRENT + 1 ))

    kubectl --context "$CONTEXT" patch deployment "$DEPLOYMENT" \
      -n "$NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{\"replicas\":${NEW_REPLICAS}}}"

    log "Scaled $DEPLOYMENT to $NEW_REPLICAS replicas. Waiting for rollout..."

    for i in $(seq 1 24); do
      READY=$(kubectl --context "$CONTEXT" get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      log "  [${i}/24] Ready replicas: ${READY}/${NEW_REPLICAS}"
      [[ "${READY:-0}" -ge 1 ]] && { log "✓ At least one replica ready — traffic restored."; break; }
      sleep 10
    done
    ;;

  # ── Case B: Memory limit too low ─────────────────────────────────────────
  case-b)
    log "Case B: Patching memory limit from 8Gi to 12Gi..."

    kubectl --context "$CONTEXT" patch deployment "$DEPLOYMENT" \
      -n "$NAMESPACE" \
      --type=json \
      -p '[
        {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"12Gi"},
        {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"10Gi"}
      ]'

    log "Memory patch applied. Waiting for rollout..."
    kubectl --context "$CONTEXT" rollout status "deployment/${DEPLOYMENT}" \
      -n "$NAMESPACE" --timeout=120s

    log "✓ Deployment rolled out with new memory limits."
    ;;

  # ── Case C: Traffic shedding loop ─────────────────────────────────────────
  case-c)
    log "Case C: Traffic shedding — draining proxy, waiting for queue to clear..."

    kubectl --context "$CONTEXT" scale deployment "$PROXY_DEPLOYMENT" \
      -n "$NAMESPACE" --replicas=0

    log "Proxy scaled to 0. Polling queue depth until clear (timeout: 120s)..."

    TIMEOUT=120
    ELAPSED=0
    while [[ $ELAPSED -lt $TIMEOUT ]]; do
      QUEUE=$(curl -sf \
        "${PROMETHEUS_URL}/api/v1/query?query=sum(vllm_num_waiting_requests)" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); \
          print(d['data']['result'][0]['value'][1] if d['data']['result'] else '0')" \
        2>/dev/null || echo "unknown")
      log "  Queue depth: ${QUEUE} (${ELAPSED}s elapsed)"
      [[ "$QUEUE" == "0" || "$QUEUE" == "unknown" ]] && break
      sleep 10
      ELAPSED=$(( ELAPSED + 10 ))
    done

    log "Queue cleared. Restoring proxy..."
    kubectl --context "$CONTEXT" scale deployment "$PROXY_DEPLOYMENT" \
      -n "$NAMESPACE" --replicas=1
    kubectl --context "$CONTEXT" wait \
      --for=condition=Ready pod -l "app=${PROXY_DEPLOYMENT}" \
      -n "$NAMESPACE" --timeout=60s

    log "✓ Proxy restored. Traffic resuming."
    ;;

  *)
    echo "Usage: $0 [case-a|case-b|case-c]"
    echo ""
    echo "  case-a  KV-cache overflow — scale out replicas by 1"
    echo "  case-b  Memory limit too low — patch pod memory limits to 12Gi"
    echo "  case-c  Traffic shedding — drain proxy, wait for queue to clear, restore"
    echo ""
    echo "See docs/runbooks/RB-001-ollama-oom-recovery.md for decision matrix."
    exit 1
    ;;
esac

# ── Verification (runs after all cases) ──────────────────────────────────────
log "Running post-remediation verification..."
sleep 5

ERROR_RATE=$(curl -sf \
  "${PROMETHEUS_URL}/api/v1/query?query=rate(inference_requests_total{status=~'5..'}[2m])" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    r=d['data']['result']; print(r[0]['value'][1] if r else '0')" \
  2>/dev/null || echo "unknown")

log "5xx error rate (last 2m): ${ERROR_RATE}"
log "Verify in Grafana: http://localhost:3000 → LLM Golden Signals dashboard"
log "Remediation complete. File post-mortem if user impact > 5 minutes."
