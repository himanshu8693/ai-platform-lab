#!/usr/bin/env bash
# =============================================================================
# scripts/remediate/keda-prometheus-reconnect.sh
#
# Detects KEDA ScaledObject Fallback condition (Prometheus unreachable) and
# automatically restarts the Prometheus deployment if it is not responding.
# Then polls until KEDA exits Fallback or times out.
#
# Safe to run as a CronJob or triggered by a Prometheus AlertManager webhook.
#
# Usage:
#   ./keda-prometheus-reconnect.sh
#
# Exits 0: KEDA exited Fallback (autoscaling restored)
# Exits 1: KEDA still in Fallback after recovery attempt (escalate)
#
# See: docs/runbooks/RB-002-keda-undershoot-recovery.md Case B
# =============================================================================
set -euo pipefail

NAMESPACE_KEDA="${NAMESPACE_KEDA:-keda}"
NAMESPACE_MONITORING="${NAMESPACE_MONITORING:-monitoring}"
PROMETHEUS_SVC="prometheus-server"
PROMETHEUS_URL="http://${PROMETHEUS_SVC}.${NAMESPACE_MONITORING}.svc.cluster.local"
SCALEDOBJECT="${SCALEDOBJECT:-llama3-scaler}"
SCALEDOBJECT_NS="${SCALEDOBJECT_NS:-inference}"
CONTEXT="${KUBECTL_CONTEXT:-kind-ai-platform-lab}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

# ── Step 1: Is KEDA ScaledObject in Fallback? ────────────────────────────────
FALLBACK=$(kubectl --context "$CONTEXT" get scaledobject "$SCALEDOBJECT" \
  -n "$SCALEDOBJECT_NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null || echo "Unknown")

log "KEDA Fallback condition: ${FALLBACK}"

if [[ "$FALLBACK" != "True" ]]; then
  log "KEDA is not in Fallback. No action required."
  exit 0
fi

# ── Step 2: Is Prometheus responding? ────────────────────────────────────────
log "KEDA is in Fallback. Checking Prometheus health from KEDA operator pod..."

PROM_HEALTH=$(kubectl --context "$CONTEXT" exec \
  -n "$NAMESPACE_KEDA" deployment/keda-operator -- \
  wget -qO- --timeout=5 "${PROMETHEUS_URL}/-/healthy" 2>/dev/null || echo "FAIL")

if [[ "$PROM_HEALTH" == "Prometheus Server is Ready." ]]; then
  log "Prometheus is healthy — KEDA fallback may clear on next poll (30s). Waiting..."
  sleep 35
  FALLBACK2=$(kubectl --context "$CONTEXT" get scaledobject "$SCALEDOBJECT" \
    -n "$SCALEDOBJECT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null || echo "Unknown")
  log "KEDA Fallback after wait: ${FALLBACK2}"
  [[ "$FALLBACK2" != "True" ]] && { log "✓ KEDA exited Fallback."; exit 0; }
  log "⚠ Still in Fallback. Check NetworkPolicy (workloads/inference/networkpolicy.yaml Policy 7)."
  exit 1
fi

# ── Step 3: Prometheus not responding — restart it ───────────────────────────
log "Prometheus not responding (got: '${PROM_HEALTH}'). Restarting ${PROMETHEUS_SVC}..."

kubectl --context "$CONTEXT" rollout restart "deployment/${PROMETHEUS_SVC}" \
  -n "$NAMESPACE_MONITORING"

log "Waiting for ${PROMETHEUS_SVC} rollout..."
kubectl --context "$CONTEXT" rollout status "deployment/${PROMETHEUS_SVC}" \
  -n "$NAMESPACE_MONITORING" --timeout=120s

log "${PROMETHEUS_SVC} rollout complete. Waiting up to 90s for KEDA to exit Fallback..."

# ── Step 4: Poll for KEDA fallback exit ──────────────────────────────────────
for i in $(seq 1 9); do
  sleep 10
  FALLBACK3=$(kubectl --context "$CONTEXT" get scaledobject "$SCALEDOBJECT" \
    -n "$SCALEDOBJECT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null || echo "Unknown")
  log "  [${i}/9] KEDA Fallback: ${FALLBACK3}"
  [[ "$FALLBACK3" != "True" ]] && { log "✓ KEDA exited Fallback. Autoscaling restored."; exit 0; }
done

log "⚠ KEDA still in Fallback after Prometheus restart. Escalate to Platform Engineering on-call."
exit 1
