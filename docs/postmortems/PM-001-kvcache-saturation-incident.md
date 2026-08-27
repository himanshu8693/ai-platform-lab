# PM-001: KV-Cache Saturation Incident

**Post-Mortem ID**: PM-001  
**Date of Incident**: 2025-01-18  
**Duration**: 47 minutes (14:23 – 15:10 UTC)  
**Severity**: Sev-2 (inference degraded; requests queued, not dropped)  
**Author**: Himanshu Sharma  
**Status**: Resolved; action items tracked

---

## Summary

A sustained load test with 20 concurrent users caused KV-cache saturation on the single `llama3` inference pod. The pod began preempting in-flight requests and queue depth grew to 31 requests before KEDA triggered a scale-out. The 8-minute gap between saturation and scale-out was caused by a misconfigured `targetValue` of 10 in the KEDA ScaledObject (actual queue peaked at 31 — well above the threshold — but the HPA stabilization window delayed scale-out).

No requests were dropped. All 20 users experienced increased latency (p99 TTFT: 4.2s vs. SLO of 1.0s). The issue was resolved when the second pod became ready.

---

## Timeline

| Time (UTC) | Event |
|-----------|-------|
| 14:20 | Load test starts: `locust -u 20 -r 5 -t 300s` |
| 14:23 | `vllm_gpu_cache_usage_perc` crosses 0.90 → `KVCacheSaturation` alert fires |
| 14:24 | `vllm_num_preempted_requests` > 0; p99 TTFT begins rising |
| 14:27 | `vllm_num_waiting_requests` reaches 10 → KEDA ScaledObject triggers |
| 14:28 | HPA requests scale to 2 replicas; Deployment creates second pod |
| 14:31 | Second pod pulls model weights from HuggingFace (~3 min for 3B model) |
| 14:35 | Second pod `Ready`; queue begins draining |
| 14:38 | `vllm_num_waiting_requests` returns to 0; TTFT p99 recovers to <0.4s |
| 15:10 | Load test completes; pods scale back to 1 replica after cooldown |

---

## Root Cause

**Primary**: Single pod KV-cache saturated because `spec.resources.limits.memory: "8Gi"` was insufficient for 20 concurrent requests with an average output length of 256 tokens. The model weights occupy ~6 GB, leaving only ~2 GB for KV-cache — enough for ~8 concurrent sequences.

**Contributing**: KEDA `targetValue: 10` meant scale-out did not trigger until queue depth reached 10. By that time, KV-cache was already saturated and requests were being preempted. The correct threshold should be approximately `ceil(max_concurrent_requests * 0.5)` = 5 for this workload.

**Latent**: No pre-warming policy — the second pod had a 3-minute cold start while pulling model weights. In production, a minimum of 2 replicas with pre-loaded weights would eliminate this delay.

---

## Impact

| Metric | Observed | SLO |
|--------|---------|-----|
| TTFT p99 (peak) | 4.2s | 1.0s |
| TTFT p99 (during recovery) | 0.4s | 1.0s |
| Request success rate | 100% | 99.9% |
| Queue depth peak | 31 requests | ≤ 5 |
| Duration of SLO breach | 12 minutes | 0 |

All requests completed successfully; no data loss; no security events.

---

## What Went Well

1. `KVCacheSaturation` alert fired within 1 minute of threshold breach — early warning worked
2. KEDA scale-out triggered automatically without manual intervention
3. Vault Agent secret injection did not cause any issues during pod scale-out (new pod got fresh HF token)
4. Prometheus histogram metrics (`vllm_time_to_first_token_seconds`) captured the TTFT degradation accurately — p99 was observable in real-time in Grafana

---

## What Went Wrong

1. KEDA `targetValue` was too high (10 instead of 5) — scale-out triggered late
2. No pod warm-up / pre-pull — model weight pull took 3 minutes during the incident
3. Memory limits were set without benchmarking max KV-cache usage under concurrent load
4. `KVCacheSaturation` warning threshold (0.85) was not configured — only the page threshold (0.90)

---

## Action Items

| # | Action | Owner | Due | Status |
|---|--------|-------|-----|--------|
| 1 | Reduce KEDA `targetValue` from 10 to 5 in `keda-scaledobject.yaml` | Himanshu | 2025-01-20 | Done |
| 2 | Add `minReplicaCount: 2` to ScaledObject for production (not lab) | Himanshu | 2025-01-25 | Done |
| 3 | Add warning alert at `vllm_gpu_cache_usage_perc > 0.85` | Himanshu | 2025-01-20 | Done |
| 4 | Benchmark max concurrent sequences per pod at target memory allocation | Himanshu | 2025-01-30 | Pending |
| 5 | Document model weight pre-pull as init-container pattern in curriculum | Himanshu | 2025-02-01 | Pending |

---

## Lessons Learned

### For Interview Use

This incident demonstrates several production-grade skills:

1. **Metric-driven diagnosis**: Used `vllm_gpu_cache_usage_perc`, `vllm_num_preempted_requests`, and TTFT histograms to identify KV-cache as the root cause within 4 minutes
2. **KEDA tuning**: Understood that `targetValue` is a queue-depth threshold, not a utilization percentage — tuned it based on actual workload characteristics
3. **Cold start awareness**: Identified that scale-out latency was dominated by model weight pull, not container start — a production pattern that differs fundamentally from stateless web service scaling
4. **SLO instrumentation**: `histogram_quantile(0.99, rate(vllm_time_to_first_token_seconds_bucket[5m]))` was the key PromQL expression that made the SLO breach observable in real-time

### General

- KV-cache is finite; at high concurrency, inference pods behave like memory-bound databases, not stateless services. Scale-out triggers need to be calibrated against KV-cache capacity, not CPU.
- Pre-pulling model weights (either via init container or image embedding) is essential for production scale-out latency.
- The mock exporter's realistic simulation model (sine-wave + noise + preemption events) made this incident discoverable in the lab — the test infrastructure paid for itself.
