# ADR-004 — GPU Partitioning Strategy: MIG vs MPS vs Time-Slicing

| Field       | Value                                      |
|-------------|--------------------------------------------|
| **Status**  | Accepted                                   |
| **Date**    | 2025-01-01                                 |
| **Author**  | Platform Engineering                       |
| **Refs**    | ADR-001, ADR-003, PM-001, RB-001           |

---

## Context

The AI Platform Lab simulates a 2× NVIDIA H100 80GB SXM5 node (see ADR-003 for
the simulation approach). In production, when a single physical GPU must serve
multiple concurrent model deployments or multiple teams, the platform engineer
must choose one of three partitioning primitives provided by the NVIDIA GPU
Operator. The wrong choice has direct, measurable impact on latency SLOs and
blast-radius during a failure.

This ADR formalises the decision criteria for each primitive and documents which
mode this platform will deploy in each scenario.

---

## The Three Primitives

### 1. Multi-Instance GPU (MIG)

**What it is:** Hardware-enforced partitioning. The H100 GPU die is physically
sliced into up to 7 isolated GPC (Graphics Processing Cluster) instances. Each
MIG instance has its own dedicated memory, L2 cache, and compute engines. The
hypervisor cannot see across instance boundaries.

**How NVIDIA delivers it:**
- Enabled per-GPU: `nvidia-smi -i 0 -mig 1`
- Profiles: `1g.10gb`, `2g.20gb`, `3g.40gb`, `4g.40gb`, `7g.80gb`
- Kubernetes surface: `nvidia.com/mig-1g.10gb: 1` in Pod resource requests
- GPU Operator handles MIG profile configuration via `MIGStrategy: single` or
  `MIGStrategy: mixed` on the NvidiaDriver CRD.

**Blast radius:** Zero. A fault in one MIG instance (ECC double-bit error,
XID 48, process hang) is hardware-contained. It cannot corrupt another instance's
memory space. The GPU Operator will report only the affected instance as
`Not Ready`.

**When to use:**
- Multi-tenant clusters where different teams or external customers share one
  physical GPU node
- Compliance boundaries: each tenant's model weights must not be readable by
  another tenant's process
- When you need hard memory guarantees: team-a's 20GB is never swapped to
  team-b, even under OOM pressure
- NVIDIA Triton Server in isolation mode (each instance runs one model)

**Drawbacks:**
- Inflexible: the MIG profile must be set at node bootstrap time. Changing it
  requires a GPU reset, which evicts all running workloads.
- Cannot combine `1g.10gb` slices for a larger job at runtime — a `4g.40gb`
  job requires a `4g.40gb` pre-allocated instance.
- Minimum slice on H100: 10GB. Unsuitable for tiny models under 10GB that
  would benefit from packing more instances.
- Not available on all GPUs: A10, A30, A100 (40GB), H100, H200 support MIG.
  The A10G (AWS g5) does not.

---

### 2. Multi-Process Service (MPS)

**What it is:** CUDA-level software multiplexing. NVIDIA MPS runs a single
CUDA context on the GPU and exposes a shared memory address space to multiple
client processes. The GPU Operator MPS Device Plugin (alpha in 2024) advertises
virtual GPU slots.

**How NVIDIA delivers it:**
- The MPS control daemon (`nvidia-cuda-mps-control`) must run on the host.
- GPU Operator MPS mode: annotate the node with
  `nvidia.com/mps.capable: "true"`
- Pod resource request: `nvidia.com/gpu: 1` (same as full GPU) but scheduler
  is instructed to time-share across up to N clients.
- ADR-003: this lab simulates MPS via a stub Device Plugin that schedules
  multiple pods to the same simulated GPU node.

**Blast radius:** Partial. MPS shares a single CUDA context. A process fault
that corrupts GPU context state can terminate ALL MPS clients simultaneously.
This is the primary production risk of MPS.

**When to use:**
- Single-tenant clusters where you own all the workloads and trust them equally
- Latency-sensitive inference: MPS eliminates CUDA context-switch overhead
  between co-scheduled processes, reducing TTFT variance by 5–15%
- When model size fits comfortably in one partition and you want to run
  multiple replicas of the same model on one GPU without idle VRAM waste
- Batch embedding workloads with multiple small concurrently-running jobs

**Drawbacks:**
- No memory isolation between clients — a misbehaving or compromised process
  can read another process's VRAM
- Context-fault blast radius: one process crash can kill all co-tenants
- Pinned memory must be managed carefully; fragmentation under mixed-size
  workloads is a known operational pain point
- Not suitable for multi-tenant (external customers) or regulated environments

---

### 3. Time-Slicing

**What it is:** GPU time-division multiplexing at the CUDA scheduler level.
Processes share the GPU by taking turns in time slices. No memory isolation.
No VRAM partitioning.

**How NVIDIA delivers it:**
- GPU Operator ConfigMap: set `sharing.timeSlicing.resources[0].replicas: N`
- Advertises `nvidia.com/gpu: N` replicas from a single physical GPU
- Each Pod requests `nvidia.com/gpu: 1` and gets 1/N of the GPU's time

**Blast radius:** Highest. Identical to MPS — no CUDA context separation.
Additionally, time-slicing adds non-deterministic latency variance because
a long-running decode kernel on one process delays all other processes in
that time slice.

**When to use:**
- Development and local lab only (this is ADR-003's simulation approach)
- Running many small, non-latency-sensitive batch jobs where occasional
  stalls are acceptable
- Jupyter notebook clusters where researchers occasionally run small
  fine-tuning jobs

**Do NOT use for:**
- Production inference serving with TTFT p99 SLOs — latency variance is
  non-deterministic and will violate p99 budgets under concurrent load
- Any multi-tenant scenario where one team should not see another team's
  memory

---

## Decision Matrix

| Scenario                                    | Recommended Mode | Reason                                        |
|---------------------------------------------|------------------|-----------------------------------------------|
| Multi-tenant, external customers            | **MIG**          | Hardware memory isolation, zero blast radius  |
| Single-tenant, production inference         | **MPS**          | Lowest TTFT variance, context-switch savings  |
| Team-internal batch jobs, dev cluster       | **Time-Slicing** | Operational simplicity, no SLO requirement    |
| Mixed: live serving + batch on same node    | **MIG**          | Partition live serving; isolate from batch    |
| Compliance/regulated (HIPAA, SOC2, FedRAMP) | **MIG**          | Mandatory hardware isolation for audit        |
| Local lab (this repo, M4 Max, no NVIDIA)    | **Simulation**   | ADR-003 stub Device Plugin + mock DCGM        |

---

## Decision for This Platform

**Phase 1 (current — local lab):** Time-slicing simulation per ADR-003.
No real partitioning is possible without NVIDIA hardware. The mock DCGM
exporter emits `DCGM_FI_DEV_MIG_MODE_ACTIVE: 0` to reflect this.

**Phase 2 (cloud burst — GCP/AWS):**
- Node pool labelled `nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3` will
  use **MIG** for the multi-tenant batch queue (team-a, team-b ClusterQueues)
  with profile `3g.40gb` per team.
- The inference-platform ClusterQueue will use **MPS** for live serving
  replicas of the same model. This matches the production topology at
  Anthropic and Cohere (public references from their GPU operator blog posts).

**Phase 3 (production hardening):**
- Implement `MIGStrategy: mixed` so a single H100 can offer both MIG
  instances (for batch) and a full-GPU MPS context (for live serving)
  simultaneously. Requires NVIDIA GPU Operator ≥ v24.3 and H100 SXM5
  hardware with driver ≥ 545.

---

## GPU Operator Kubernetes Resources (Reference)

```yaml
# MIG strategy annotation on a node (set by GPU Operator DaemonSet)
# kubectl label node gpu-node-0 nvidia.com/mig.strategy=mixed

# ClusterPolicy for GPU Operator (sets MIG mode and MPS):
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  mig:
    strategy: mixed      # options: none | single | mixed
  devicePlugin:
    config:
      name: time-slicing-config   # ConfigMap with replica count per GPU
  mps:
    enabled: true        # Experimental in GPU Operator v24.x
  dcgmExporter:
    enabled: true        # Real DCGM; replaced by mock-dcgm-exporter in this lab
```

```yaml
# MIG resource request — Pod requesting a 3g.40gb instance:
resources:
  limits:
    nvidia.com/mig-3g.40gb: "1"

# MPS resource request — Pod requesting a time-shared full GPU:
resources:
  limits:
    nvidia.com/gpu: "1"   # scheduler maps this to MPS context slot
```

---

## Consequences

**Positive:**
- This ADR provides a defensible, interview-ready rationale for GPU partitioning
  choices at Staff/Principal level. Interviewers at NVIDIA, Databricks, and
  Cohere routinely probe this decision.
- The MIG → MPS split for batch vs serving mirrors what production-scale AI
  platforms actually do, and the decision matrix can be cited during system
  design rounds.

**Negative / Risks:**
- MIG profile changes require a GPU reset (pod eviction). The platform must
  have a maintenance window strategy for profile changes.
- MPS context-fault blast radius is not acceptable for external customer
  multi-tenancy. This must be documented as an explicit platform constraint
  in the tenant SLA.

**Open questions:**
- NVIDIA NIM (November 2024) provides its own MIG-aware scheduling. Evaluate
  whether NIM's scheduling model supersedes the MIG/MPS split above when
  running NIM-packaged models in Phase 3.
