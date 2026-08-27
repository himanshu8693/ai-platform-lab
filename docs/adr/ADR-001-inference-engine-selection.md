# ADR-001: Inference Engine Selection

**Status**: Accepted  
**Date**: 2025-01-15  
**Deciders**: Himanshu Sharma

---

## Context

The platform needs to serve large language models in a Kubernetes environment. Three inference engines were evaluated: vLLM, Ollama, and NVIDIA Triton Inference Server.

The lab runs on Apple M4 Max (ARM64) without NVIDIA GPUs. The production target is multi-GPU x86-64 with A100/H100 cards.

---

## Decision Drivers

1. **Local dev viability**: Must run on M4 Max without a GPU device plugin
2. **Production fidelity**: API surface and metrics must match what runs in production
3. **Kubernetes integration**: Must expose Prometheus metrics for KEDA autoscaling
4. **ARM64 support**: Docker images must run natively or via Rosetta 2 with known overhead

---

## Options Considered

### Option A: vLLM (primary production runtime)

**Pros**:
- Industry-standard OpenAI-compatible API (`/v1/completions`, `/v1/chat/completions`)
- Native Prometheus metrics: `vllm_num_waiting_requests` (KEDA driver), TTFT/TPOT histograms
- Continuous batching and PagedAttention — best GPU utilization in class
- Active development; used at Anthropic, Meta, Mistral production deployments

**Cons**:
- No official ARM64 Docker image — requires `--platform linux/amd64` on M4 Max → Rosetta 2 (~20% overhead)
- Heavy image (~15 GB with CUDA); slow to pull in lab

**Lab workaround**: Use Ollama locally for actual inference; use `mock-dcgm-exporter.py` to simulate vLLM metrics. The CRD and operator treat both as equivalent via `servingRuntime: vllm|ollama`.

### Option B: Ollama (local dev runtime)

**Pros**:
- Native ARM64 image with Apple MPS (Metal Performance Shaders) support
- ~30 tokens/s on M4 Max with `llama3.2:3b` — real inference, not simulation
- Simple HTTP API; small footprint

**Cons**:
- Does not expose production-equivalent Prometheus metrics
- No PagedAttention or continuous batching — not representative of production behavior
- Used for local dev only; not deployed in production AI infrastructure teams

**Decision**: Use Ollama as the actual inference backend in the lab cluster; configure `mock-dcgm-exporter.py` to emit vLLM metric names for dashboard/alert validation.

### Option C: NVIDIA Triton Inference Server

**Pros**:
- Supports multi-framework backends (TensorRT, PyTorch, ONNX)
- Used by enterprises with heterogeneous model formats
- Ensemble pipelines for pre/post-processing

**Cons**:
- `nvcr.io/nvidia/tritonserver` has **no official ARM64 image** (as of 2025-01)
- Running via Rosetta 2 emulation gives ~15–30% overhead; benchmarks not portable
- Requires model repository structure (not just a model ID string) — higher ops burden
- Less common in LLM-focused shops vs. Triton for traditional DL inference

**Decision**: Triton is included as a `ServingRuntimeType` enum value in the operator (`ServingRuntimeTriton`) and the image is defined in `imageForRuntime()`, but not deployed in the lab. The ARM64 caveat is documented in `main.go`.

---

## Decision

**Use vLLM as the production `ServingRuntimeType`; Ollama as the local dev runtime; Triton as a future-facing enum value with ARM64 caveats documented.**

The operator's `imageForRuntime()` function handles all three. Switching runtimes requires only changing `spec.servingRuntime` in the ModelDeployment CR — no operator changes needed.

---

## Consequences

- `mock-dcgm-exporter.py` emits vLLM metric names so Grafana dashboards and Prometheus alert rules are exercisable locally
- KEDA ScaledObject targets `vllm_num_waiting_requests` — valid whether the actual pod is vLLM or Ollama with mock exporter
- Triton benchmarking requires an x86-64 host or a cloud VM; M4 Max results should be labelled "Rosetta 2 emulation — not representative"
- CI images in `.github/workflows/ci-cd-platform-gate.yaml` do not pull Triton image (avoids 15 GB pull in CI)
