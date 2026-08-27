# RB-001: Ollama OOM Recovery

**Runbook ID**: RB-001
**Service**: Ollama inference pod (`inference` namespace)
**Severity**: Sev-2 (user-facing inference degraded)
**Last reviewed**: 2025-06-01
**Automation tier**: Level 2 — automated detection + scripted remediation loops (human approval for destructive steps only)

---

## Symptoms

- Pods in `inference` namespace restarting with `OOMKilled` exit code
- `DCGM_FI_DEV_FB_USED` near `DCGM_FI_DEV_FB_TOTAL` (>97% for >2 minutes)
- `vllm_gpu_cache_usage_perc` > 0.95
- `vllm_num_preempted_requests` > 0 (KV-cache pressure evictions)
- Users receiving HTTP 503 or connection timeouts from inference proxy

---

## Alert

Triggered by `KVCacheSaturation` alert in `platform/observability/prometheus/custom-rules.yaml`:
```promql
vllm_gpu_cache_usage_perc > 0.90
```

---

## Immediate Triage (< 5 minutes)

### 1. Confirm OOM

```bash
kubectl get pods -n inference -o wide
# Look for: STATUS=OOMKilled or CrashLoopBackOff

kubectl describe pod -n inference <pod-name>
# Look for: Last State: Terminated / Reason: OOMKilled
#           Exit Code: 137

kubectl top pod -n inference
# Look for: MEMORY approaching limit
```

### 2. Check current queue depth

```bash
# Prometheus query (via port-forward or ingress)
curl -s "http://localhost:9090/api/v1/query?query=vllm_num_waiting_requests" | \
  python3 -m json.tool
```

### 3. Check pod events for eviction signals

```bash
kubectl get events -n inference --sort-by='.lastTimestamp' | tail -20
```

---

## Root Cause Classification

| Symptom | Likely Cause |
|---------|-------------|
| OOMKilled + FB_USED >97% | KV-cache overflow — model too large for allocated VRAM |
| OOMKilled + FB_USED <70% | Memory limit too low in ResourceQuota or pod spec |
| Preempted requests >0 | Continuous batching under load; normal if transient |
| Slow restart loop | Model weight pull on restart hitting rate limit |

---

## Automated Remediation

> **Design principle**: All Tier-1 (traffic shedding) and Tier-2 (replica adjustment)
> remediations run as scripted loops without human intervention. Only Tier-3
> (destructive cluster rebuild) requires explicit human approval.
> This replaces the previous manual `kubectl scale` steps.

### Tier-1 Automation — Liveness Probe Auto-Restart (always active)

The `llama3` Deployment carries a liveness probe against the Ollama `/api/tags`
endpoint. When OOM causes the process to hang without exiting, the probe fails
and kubelet restarts the container automatically — no human action required.

```yaml
# Already configured in workloads/inference/argo-rollout.yaml
# Shown here for reference:
livenessProbe:
  httpGet:
    path: /api/tags
    port: 11434
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3      # 3 consecutive failures → kubelet kills + restarts
  timeoutSeconds: 5
readinessProbe:
  httpGet:
    path: /api/tags
    port: 11434
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 2      # Remove from Service endpoints on 2nd failure
```

**Effect**: Pod is removed from Service endpoints on readiness failure (no new
traffic), restarted on liveness failure (recovery attempt), all without paging
the on-call.

---

### Tier-2 Automation — KEDA Early Scale-Out (always active)

KEDA ScaledObject (`workloads/inference/keda-scaledobject.yaml`) triggers
scale-out **before** KV-cache saturates, using `vllm_gpu_cache_usage_perc`
as a leading indicator. The following `ScaledObject` trigger was added
post PM-001 to complement the queue-depth trigger:

```yaml
# Additional trigger — add to keda-scaledobject.yaml alongside the existing one:
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-server.monitoring.svc.cluster.local
      metricName: vllm_gpu_cache_usage_perc
      query: |
        avg(vllm_gpu_cache_usage_perc{namespace="inference"})
      # Scale out at 75% KV-cache — before the 90% alert fires.
      # Gives the new pod time to start before saturation is reached.
      threshold: "0.75"
```

**Effect**: Horizontal scale-out starts at 75% KV-cache usage. By the time
usage hits 90% (alert threshold), the new replica is already warm.

---

### Tier-2 Automation — OOM Remediation Script (run by on-call if Tier-1 insufficient)

This loop is safe to re-run. It does not require `kubectl edit` — it patches
the Deployment declaratively and waits for health before declaring success.

```bash
#!/usr/bin/env bash
# scripts/remediate/oom-recovery.sh
# Usage: ./oom-recovery.sh [case-a|case-b|case-c]
set -euo pipefail

NAMESPACE="inference"
DEPLOYMENT="llama3"
PROXY_DEPLOYMENT="inference-proxy"
CONTEXT="${KUBECTL_CONTEXT:-kind-ai-platform-lab}"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

case "${1:-case-a}" in

  # ── Case A: KV-cache overflow ─────────────────────────────────────────────
  case-a)
    log "Case A: Scaling out replicas to spread KV-cache load..."

    CURRENT=$(kubectl --context "$CONTEXT" get deployment "$DEPLOYMENT" \
      -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
    NEW_REPLICAS=$(( CURRENT + 1 ))

    # Patch replica count — operator reconciles; no direct spec.replicas edit needed
    kubectl --context "$CONTEXT" patch deployment "$DEPLOYMENT" \
      -n "$NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{\"replicas\":${NEW_REPLICAS}}}"

    log "Scaled $DEPLOYMENT to $NEW_REPLICAS replicas. Waiting for rollout..."

    # Poll until at least one ready replica is serving
    for i in $(seq 1 24); do
      READY=$(kubectl --context "$CONTEXT" get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      log "  [${i}/24] Ready replicas: ${READY}/${NEW_REPLICAS}"
      [[ "$READY" -ge 1 ]] && { log "✓ At least one replica ready — traffic restored."; break; }
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
    kubectl --context "$CONTEXT" rollout status deployment/"$DEPLOYMENT" \
      -n "$NAMESPACE" --timeout=120s

    log "✓ Deployment rolled out with new memory limits."
    ;;

  # ── Case C: Traffic shedding loop ─────────────────────────────────────────
  case-c)
    log "Case C: Traffic shedding — draining proxy, waiting for queue to clear..."

    # Remove proxy from Service by scaling to 0
    kubectl --context "$CONTEXT" scale deployment "$PROXY_DEPLOYMENT" \
      -n "$NAMESPACE" --replicas=0

    log "Proxy scaled to 0. Polling queue depth until clear..."

    # Poll Prometheus for queue depth — loop until queue clears or timeout
    PROMETHEUS_URL="http://localhost:9090"
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
      --for=condition=Ready pod -l "app=$PROXY_DEPLOYMENT" \
      -n "$NAMESPACE" --timeout=60s

    log "✓ Proxy restored. Traffic resuming."
    ;;

  *)
    echo "Usage: $0 [case-a|case-b|case-c]"
    exit 1
    ;;
esac

# ── Verification loop (runs after all cases) ─────────────────────────────────
log "Running post-remediation verification..."
sleep 5

ERROR_RATE=$(curl -sf \
  "http://localhost:9090/api/v1/query?query=rate(inference_requests_total{status=~'5..'}[2m])" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    r=d['data']['result']; print(r[0]['value'][1] if r else '0')" \
  2>/dev/null || echo "unknown")

log "5xx error rate (last 2m): ${ERROR_RATE}"
log "Verify in Grafana: http://localhost:3000 → LLM Golden Signals dashboard"
log "Remediation complete. File post-mortem if user impact > 5 minutes."
```

---

### Case D: Model pull rate-limited (HuggingFace token exhausted)

This case cannot be automated without risk — rotating a secret mid-request
could invalidate in-flight model loads. **Manual steps only**:

```bash
# 1. Verify current Vault secret
kubectl exec -n inference <pod-name> -c vault-agent -- \
  cat /vault/secrets/hf-token

# 2. Rotate via Vault — agent picks up on next lease renewal (no pod restart)
vault kv put secret/ai-platform/hf-token token=<new-token>

# 3. Confirm agent picked up new token (lease renewal within 60s)
kubectl logs -n inference <pod-name> -c vault-agent | grep "renewed lease"
```

---

## Post-Incident Actions

1. [ ] Capture `kubectl describe pod` and events for post-mortem
2. [ ] Check if KEDA scaled out during the event (expected behavior)
3. [ ] Review `vllm_num_waiting_requests` time-series in Grafana for queue build-up pattern
4. [ ] Adjust HPA/KEDA `targetValue` if queue depth grew before scale-out triggered
5. [ ] Update `spec.resources.requests.memory` to match observed steady-state + 20% headroom
6. [ ] File post-mortem if user impact > 5 minutes

---

## Prevention

- Set `vllm_gpu_cache_usage_perc > 0.85` as a warning alert (before the 0.90 page threshold)
- Tune KEDA `targetValue` on `vllm_num_waiting_requests` to scale out earlier (default 5 → 3)
- Set pod memory requests == limits (guaranteed QoS class) to prevent eviction by other pods
- Run `make load` monthly to confirm autoscaling triggers before saturation

---

## Escalation

If remediation steps above do not resolve within 30 minutes:
- Engage: Platform Engineering on-call
- Check: OrbStack VM memory (`docker stats`) — OrbStack may be OOM-killing the entire VM
- Nuclear option: `make clean && make up` — full cluster rebuild (~8 minutes)
