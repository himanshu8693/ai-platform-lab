# RB-002: KEDA Undershoot Recovery

**Runbook ID**: RB-002
**Service**: KEDA autoscaling for inference workloads
**Severity**: Sev-3 (resource waste / cost overrun, no user impact)
**Last reviewed**: 2025-06-01
**Automation tier**: Level 2 — automated watchdog loop + scripted force-drain; no human step required for Cases A/B

---

## Symptoms

- Inference pods not scaling down after load drops
- `kubectl get hpa -n inference` shows current replicas > desired replicas for >15 minutes
- KEDA `ScaledObject` shows `AbleToScale: True` but pods remain
- `vllm_num_waiting_requests` metric at 0 for >10 minutes but replica count remains elevated

---

## KEDA Architecture Recap

```
Prometheus metric: vllm_num_waiting_requests{model_name="llama3.2:3b"}
    │
    ▼
KEDA ScaledObject (workloads/inference/keda-scaledobject.yaml)
    │  targetValue: 5   (scale out when queue > 5)
    │  cooldownPeriod: 300s (5 min before scale-in)
    ▼
HPA (managed by KEDA)
    │
    ▼
Deployment: llama3 (inference namespace)
```

---

## Immediate Triage

### 1. Check ScaledObject state

```bash
kubectl get scaledobject -n inference -o yaml
# Key fields:
#   status.conditions[*]  — Active, Ready, Fallback
#   status.lastActiveTime — when KEDA last saw metrics above threshold
```

### 2. Check HPA managed by KEDA

```bash
kubectl get hpa -n inference
# Look for: MINPODS / MAXPODS / REPLICAS / AGE
# If REPLICAS stuck > MINPODS with zero load: KEDA cooldown in progress

kubectl describe hpa keda-hpa-llama3 -n inference
# Look for: "SuccessfulRescale" events and timestamps
```

### 3. Check KEDA operator logs

```bash
kubectl logs -n keda deployment/keda-operator --tail=50
# Look for: "Successfully scaled" or "Failed to get metric"
```

### 4. Verify metric is actually zero

```bash
# Direct Prometheus query
curl -s "http://localhost:9090/api/v1/query?\
query=vllm_num_waiting_requests%7Bmodel_name%3D%22llama3.2%3A3b%22%7D" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
    print(d['data']['result'])"
```

---

## Root Cause Classification

| Symptom | Likely Cause |
|---------|-------------|
| ScaledObject shows `Fallback: True` | Prometheus unreachable; KEDA using fallback replica count |
| `lastActiveTime` recent, cooldown active | Normal — wait `cooldownPeriod` (300s default) |
| HPA REPLICAS stuck at max | HPA `scaleDown.stabilizationWindowSeconds` too long |
| Metric shows 0 but pods won't scale in | `minReplicaCount` in ScaledObject set to current replica count |

---

## Automated Remediation

> **Design principle**: KEDA undershoot (stuck high replicas after load drop) is
> a cost issue, not a safety issue. The automated watchdog runs continuously as a
> CronJob, checks replica:metric ratio on a 5-minute loop, and forces scale-in
> if the undershoot condition persists beyond `UNDERSHOOT_TIMEOUT_SECONDS`.
> Cases A and B require zero human intervention.

---

### Tier-1 Automation — KEDA Watchdog CronJob (always active)

Deploy this CronJob to the `keda` namespace. It polls every 5 minutes and
forces scale-in if replicas are elevated with zero queue depth for longer
than the cooldown window.

```yaml
# deploy with: kubectl apply -f scripts/remediate/keda-watchdog.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keda-undershoot-watchdog
  namespace: keda
spec:
  schedule: "*/5 * * * *"     # every 5 minutes
  concurrencyPolicy: Forbid   # don't stack runs
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: keda-watchdog-sa  # needs get/patch on scaledobject + deployment
          restartPolicy: OnFailure
          containers:
            - name: watchdog
              image: bitnami/kubectl:latest
              env:
                - name: PROMETHEUS_URL
                  value: "http://prometheus-server.monitoring.svc.cluster.local"
                - name: NAMESPACE
                  value: "inference"
                - name: SCALEDOBJECT
                  value: "llama3-scaler"
                - name: DEPLOYMENT
                  value: "llama3"
                - name: MIN_REPLICAS
                  value: "1"
                - name: UNDERSHOOT_TIMEOUT_SECONDS
                  value: "600"   # 10 minutes — longer than cooldownPeriod
              command:
                - /bin/sh
                - -c
                - |
                  set -eu

                  # ── Check queue depth ──────────────────────────────────────
                  QUEUE=$(wget -qO- \
                    "${PROMETHEUS_URL}/api/v1/query?query=sum(vllm_num_waiting_requests)" \
                    | python3 -c "
                  import sys,json
                  d=json.load(sys.stdin)
                  r=d['data']['result']
                  print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo "unknown")

                  # ── Check current replicas ─────────────────────────────────
                  CURRENT=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
                    -o jsonpath='{.spec.replicas}')

                  echo "[watchdog] queue=${QUEUE} replicas=${CURRENT} min=${MIN_REPLICAS}"

                  # ── If queue is 0 and replicas > min: check lastActiveTime ──
                  if [ "$QUEUE" = "0" ] && [ "$CURRENT" -gt "$MIN_REPLICAS" ]; then
                    LAST_ACTIVE=$(kubectl get scaledobject "$SCALEDOBJECT" \
                      -n "$NAMESPACE" \
                      -o jsonpath='{.status.lastActiveTime}' 2>/dev/null || echo "")

                    if [ -z "$LAST_ACTIVE" ]; then
                      echo "[watchdog] No lastActiveTime — ScaledObject may be in fallback. Skipping."
                      exit 0
                    fi

                    # Convert to epoch and compare
                    LAST_EPOCH=$(date -d "$LAST_ACTIVE" +%s 2>/dev/null || \
                                 python3 -c "from datetime import datetime; \
                                   print(int(datetime.fromisoformat('${LAST_ACTIVE}'.replace('Z','+00:00')).timestamp()))")
                    NOW_EPOCH=$(date +%s)
                    ELAPSED=$(( NOW_EPOCH - LAST_EPOCH ))

                    echo "[watchdog] Seconds since last active: ${ELAPSED} / timeout: ${UNDERSHOOT_TIMEOUT_SECONDS}"

                    if [ "$ELAPSED" -gt "$UNDERSHOOT_TIMEOUT_SECONDS" ]; then
                      echo "[watchdog] UNDERSHOOT DETECTED — forcing scale-in to ${MIN_REPLICAS} replica(s)"

                      # Pin min=max=MIN_REPLICAS to force immediate scale-in
                      kubectl patch scaledobject "$SCALEDOBJECT" -n "$NAMESPACE" \
                        --type=merge \
                        -p "{\"spec\":{\"minReplicaCount\":${MIN_REPLICAS},\"maxReplicaCount\":${MIN_REPLICAS}}}"

                      sleep 15

                      # Restore original maxReplicaCount
                      kubectl patch scaledobject "$SCALEDOBJECT" -n "$NAMESPACE" \
                        --type=merge \
                        -p "{\"spec\":{\"minReplicaCount\":${MIN_REPLICAS},\"maxReplicaCount\":5}}"

                      echo "[watchdog] ✓ Scale-in forced. ScaledObject restored to min=${MIN_REPLICAS} max=5."
                    else
                      echo "[watchdog] Within timeout window — cooldown still in progress. No action."
                    fi
                  else
                    echo "[watchdog] No undershoot condition detected."
                  fi
```

---

### Tier-2 Automation — Prometheus Self-Healing Script (Case B: KEDA in Fallback)

When KEDA cannot reach Prometheus, it enters `Fallback` mode and holds replicas
at `fallbackReplicas`. This script detects the fallback condition and restarts
the Prometheus pod if it is not responding, then waits for KEDA to recover.

```bash
#!/usr/bin/env bash
# scripts/remediate/keda-prometheus-reconnect.sh
# Automated: safe to run via CronJob or triggered by alert webhook
set -euo pipefail

NAMESPACE_KEDA="keda"
NAMESPACE_MONITORING="monitoring"
PROMETHEUS_URL="http://prometheus-server.${NAMESPACE_MONITORING}.svc.cluster.local"
SCALEDOBJECT="llama3-scaler"
SCALEDOBJECT_NS="inference"
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
log "KEDA is in Fallback. Checking Prometheus health..."

PROM_HEALTH=$(kubectl --context "$CONTEXT" exec \
  -n "$NAMESPACE_KEDA" deployment/keda-operator -- \
  wget -qO- --timeout=5 "${PROMETHEUS_URL}/-/healthy" 2>/dev/null || echo "FAIL")

if [[ "$PROM_HEALTH" == "Prometheus Server is Ready." ]]; then
  log "Prometheus is healthy — KEDA fallback may clear on next poll (30s). Waiting..."
  sleep 35
  # Re-check fallback status
  FALLBACK2=$(kubectl --context "$CONTEXT" get scaledobject "$SCALEDOBJECT" \
    -n "$SCALEDOBJECT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null || echo "Unknown")
  log "KEDA Fallback after wait: ${FALLBACK2}"
  exit 0
fi

# ── Step 3: Prometheus not responding — restart it ───────────────────────────
log "Prometheus not responding. Restarting prometheus-server deployment..."

kubectl --context "$CONTEXT" rollout restart deployment/prometheus-server \
  -n "$NAMESPACE_MONITORING"

log "Waiting for Prometheus to become ready..."
kubectl --context "$CONTEXT" rollout status deployment/prometheus-server \
  -n "$NAMESPACE_MONITORING" --timeout=120s

# ── Step 4: Wait for KEDA to exit Fallback (up to 90s) ───────────────────────
for i in $(seq 1 9); do
  sleep 10
  FALLBACK3=$(kubectl --context "$CONTEXT" get scaledobject "$SCALEDOBJECT" \
    -n "$SCALEDOBJECT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null || echo "Unknown")
  log "  [${i}/9] KEDA Fallback: ${FALLBACK3}"
  [[ "$FALLBACK3" != "True" ]] && { log "✓ KEDA exited Fallback. Autoscaling restored."; exit 0; }
done

log "⚠ KEDA still in Fallback after Prometheus restart. Escalate to on-call."
exit 1
```

---

### Case C: Force immediate scale-in (automated — no cooldown wait)

Use the watchdog script above (`case-a` trigger) or run directly:

```bash
#!/usr/bin/env bash
# scripts/remediate/keda-force-scalein.sh
# Use only when cost impact requires immediate action and queue is confirmed zero.
set -euo pipefail

NAMESPACE="inference"
SCALEDOBJECT="llama3-scaler"
TARGET_REPLICAS="${1:-1}"
CONTEXT="${KUBECTL_CONTEXT:-kind-ai-platform-lab}"

echo "Forcing scale-in to ${TARGET_REPLICAS} replica(s)..."

# Pin min and max to target — KEDA reconciles immediately
kubectl --context "$CONTEXT" patch scaledobject "$SCALEDOBJECT" \
  -n "$NAMESPACE" \
  --type=merge \
  -p "{\"spec\":{\"minReplicaCount\":${TARGET_REPLICAS},\"maxReplicaCount\":${TARGET_REPLICAS}}}"

sleep 20

# Restore max (keep min at 1)
kubectl --context "$CONTEXT" patch scaledobject "$SCALEDOBJECT" \
  -n "$NAMESPACE" \
  --type=merge \
  -p "{\"spec\":{\"minReplicaCount\":1,\"maxReplicaCount\":5}}"

echo "✓ Scale-in forced. ScaledObject maxReplicaCount restored to 5."
```

### Case D: HPA stabilizationWindow too conservative

Patch declaratively — never `kubectl edit` in production:

```bash
kubectl patch scaledobject llama3-scaler -n inference --type=merge -p '{
  "spec": {
    "advanced": {
      "horizontalPodAutoscalerConfig": {
        "behavior": {
          "scaleDown": {
            "stabilizationWindowSeconds": 60,
            "policies": [{"type":"Pods","value":1,"periodSeconds":60}]
          }
        }
      }
    }
  }
}'
# Persist the change to workloads/inference/keda-scaledobject.yaml and commit.
```

---

## Tuning Reference

Default KEDA ScaledObject values and their effects:

| Parameter | Default | Effect if Too High | Effect if Too Low |
|-----------|---------|-------------------|------------------|
| `targetValue` | 5 | Late scale-out, queue builds | Premature scale-out, cost waste |
| `cooldownPeriod` | 300s | Slow scale-in, resource waste | Thrashing (scale in/out rapidly) |
| `pollingInterval` | 30s | Slow reaction to load spike | Prometheus query overhead |
| `minReplicaCount` | 1 | N/A | Zero-pod cold start on burst |

---

## Post-Incident Actions

1. [ ] Check Grafana `vllm_num_waiting_requests` time-series for load pattern
2. [ ] If undershoot was resource waste > 30 min: tune `cooldownPeriod` downward
3. [ ] If scale-out was too slow: reduce `targetValue` or `pollingInterval`
4. [ ] Verify KEDA prometheus-scaler metrics in KEDA operator dashboard

---

## Escalation

If KEDA operator pod is crash-looping or ScaledObject enters permanent fallback:
- Delete and re-create the ScaledObject (non-destructive — KEDA is stateless)
- Check KEDA version compatibility with current Kubernetes version
- Review KEDA operator logs for `panic` or `nil pointer` errors
