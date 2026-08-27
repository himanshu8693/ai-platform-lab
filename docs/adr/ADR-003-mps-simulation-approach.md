# ADR-003: MPS Simulation Approach on Apple Silicon

**Status**: Accepted  
**Date**: 2025-01-22  
**Deciders**: Himanshu Sharma

---

## Context

The lab runs on an Apple M4 Max (ARM64, 128 GB unified memory). There is no NVIDIA GPU. The curriculum requires demonstrating GPU observability, autoscaling on GPU metrics, and resource quota enforcement — all of which depend on GPU-related Kubernetes resources.

Two specific questions need resolution:

1. **Can `apple.com/mps` be used as a Kubernetes extended resource for MPS (Metal Performance Shaders)?**
2. **How do we simulate DCGM/vLLM Prometheus metrics on a machine with no NVIDIA hardware?**

---

## Question 1: `apple.com/mps` as a Kubernetes Extended Resource

### Investigation

Kubernetes extended resources (`nvidia.com/gpu`, `amd.com/gpu`) are advertised by device plugins — DaemonSets that call the kubelet `DevicePlugin` API to register resource capacity on each node.

For NVIDIA GPUs, `k8s-device-plugin` (github.com/NVIDIA/k8s-device-plugin) registers `nvidia.com/gpu` capacity. For AMD, the ROCm device plugin does the same.

**Apple MPS has no equivalent device plugin.** As of 2025-01:
- Apple has not published a Kubernetes device plugin for MPS
- No third-party MPS device plugin exists in the CNCF ecosystem
- Kind/OrbStack worker nodes report zero `apple.com/mps` capacity

**Consequence**: A ResourceQuota with `requests.apple.com/mps: "1"` will be silently accepted by the API server (extended resources are schema-free), but:
- No node will ever advertise this resource
- Pods requesting it will remain `Pending` indefinitely with `Insufficient apple.com/mps`
- The quota is never consumed — functionally useless

This is documented in `workloads/multi-tenant/resource-quotas.yaml` with explanatory comments.

### Decision

**Do NOT use `apple.com/mps` in ResourceQuotas or pod resource requests.**  
Resource quotas use CPU and memory only. Ollama's MPS usage is gated by CPU/memory allocation, not by a device plugin resource.

For the curriculum exercise on "resource isolation between tenants", quota enforcement is demonstrated via CPU/memory limits — which are functionally equivalent and actually enforced.

---

## Question 2: DCGM/vLLM Metrics Simulation

### Requirement

Grafana dashboards, Prometheus alert rules, and KEDA ScaledObjects all need real metric data at Prometheus scrape time. Without NVIDIA hardware, `dcgm-exporter` cannot run.

### Decision

**Use `platform/observability/mock-dcgm-exporter.py` — a FastAPI service that emits production-identical metric names on port 9400.**

Design principles:
- **Production-identical label schema**: `gpu`, `UUID`, `device`, `modelName`, `Hostname` — same as real `dcgm-exporter`
- **Realistic simulation model**: Sine-wave load pattern with Gaussian noise; thermal lag; ECC/XID probabilistic spikes for alert testing
- **All DCGM field IDs verbatim**: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, etc.
- **vLLM Gauge metrics**: `vllm_num_waiting_requests` (KEDA driver), `vllm_gpu_cache_usage_perc`, queue depth
- **vLLM Histogram metrics**: `vllm_time_to_first_token_seconds`, `vllm_time_per_output_token_seconds`, `vllm_e2e_request_latency_seconds` with production-tuned buckets for `histogram_quantile(0.99, ...)` PromQL

The mock exporter is deployed as a Kubernetes Deployment in the `monitoring` namespace, not on the node as a DaemonSet. This is intentional: it simulates the _metrics_ of a GPU node, not a real device plugin.

---

## Honesty in Portfolio Presentation

This simulation approach is **explicitly disclosed** in all interview materials and portfolio artifacts:

> "The lab runs on Apple M4 Max. GPU metrics are simulated via a mock exporter that emits production-identical DCGM field names; dashboards and SLO alerts are validated against realistic synthetic data. Production vLLM inference has been demonstrated on an NVIDIA A100 via NVIDIA LaunchPad (cloud access)."

This is the honest framing. Claiming the mock exporter as "GPU cluster experience" without qualification is a rebranding error — documented and corrected in `docs/curriculum/master_transition_blueprint.md`.

---

## Consequences

- ResourceQuotas in `workloads/multi-tenant/resource-quotas.yaml` use CPU/memory only
- `appendix-d-capstone2-multi-tenant-inference-platform.html` updated to remove `requests.apple.com/mps` from ResourceQuota examples
- Mock exporter `Dockerfile` is multi-stage, non-root, read-only root FS — production quality
- Prometheus scrape target for mock exporter uses the same job name (`mock-dcgm`) as a real `dcgm-exporter` job — dashboards require no modification when switching to real hardware
- Phase 3 path: NVIDIA LaunchPad / DGX Cloud trial for A100 validation; replace mock exporter with real `dcgm-exporter` DaemonSet
