# ADR-016: Cloud vs On-Premises Deployment Strategy for the Ephemeral Lab Engine

**Status:** Accepted  
**Date:** 2025-01-15  
**Deciders:** Platform Engineering  
**References:** FDE-001 (air-gapped VPC), ADR-008 (zero-trust execution flow), `terraform/backends/`

---

## Context

The Ephemeral Lab Engine can be deployed in three configurations:

1. **Local kind/k3d** — developer workstation using OrbStack (current primary mode)
2. **Ephemeral cloud sandboxes** — EKS/GKE/AKS with TTL-bound auto-teardown
3. **On-premises bare-metal Kubernetes** — existing IBM or customer DC

A Forward Deployed Engineer (FDE) or Senior Solution Architect must be able to make and justify this deployment decision on a client engagement within the first hour of discovery. This ADR captures the decision framework.

---

## Decision Matrix

| Criterion | Local kind/k3d | Cloud (EKS/GKE/AKS) | On-Prem K8s |
|---|---|---|---|
| **Cost** | Near-zero (laptop power) | $15–80/day per sandbox (control plane + GPU node) | Capital (already paid) |
| **Startup latency** | 3–5 min | 8–15 min (control plane + node provisioning) | 10–30 min (bare-metal PXE or VM provisioning) |
| **Network isolation** | `kind` bridge — shared host network | VPC + Security Groups — true L3 isolation | DC VLAN — true L3 isolation |
| **Air-gap support** | Requires Harbor + ChartMuseum (see FDE-001) | Requires VPC endpoint config + ECR | Native (no internet egress required) |
| **Audit compliance** | Limited (local logs only; no CloudTrail) | CloudTrail / GCP Audit Log / Azure Monitor | SIEM integration required; customer-controlled |
| **CRD collision risk** | High if reusing clusters across scenarios | Low — ephemeral cluster per scenario | Low if isolated namespaces with ArgoCD AppProject |
| **GPU availability** | M4 Max Unified Memory (no CUDA) | p3/p4/g4 instances on demand (real NVIDIA GPU) | DGX/H100 if provisioned (rare) |
| **Multi-tenancy demo** | Limited (single-node kind) | Full (multi-node, real node isolation) | Full |
| **Sev-1 reproduction** | Best — fastest TTL, no cloud account needed | Good — but 8-15 min setup is too slow for live Sev-1 | Poor — provisioning overhead |
| **Customer demo (FDE)** | Poor — "runs on your laptop" is not compelling | Best — real cloud topology the customer recognises | Best for air-gap/regulated customers |

---

## Decision

### Primary mode: local kind/k3d

Use for:
- Developer iteration on Sev-1 scenario reproduction (TTL < 10 min, zero cost)
- All local lab work in the 19.5-month learning plan
- ADR and runbook authoring (no cloud account required)

### FDE demo mode: ephemeral cloud EKS

Use when:
- The client demo requires true VPC network isolation (most enterprise FDE engagements)
- The scenario requires real GPU hardware (CUDA operators, MIG partitioning)
- The client needs to see multi-node HA topology
- Terraform stub: `terraform/backends/cloud/eks-ephemeral.tf`
- Auto-teardown after `${ttl_hours}` hours via CloudWatch EventBridge → Lambda

### Customer on-prem mode: existing K8s / OpenShift

Use when:
- Customer has air-gap requirements (no outbound internet) — see FDE-001 scenario
- Customer has change-control processes that prohibit ephemeral cloud resources
- Customer already runs OpenShift — use RHOAI operator path (EX267 credential applies)

---

## Cost Controls (cloud mode)

All ephemeral cloud deployments MUST:

1. Use the TTL teardown mechanism (`aws_cloudwatch_event_rule.auto_teardown` in the stub)
2. Tag every resource with `teardown_by = timeadd(timestamp(), "${var.ttl_hours}h")`
3. Use a dedicated AWS account (not the same account as production infra)
4. Never provision instances larger than `g4dn.xlarge` (1× T4) without explicit approval
5. Set a billing alert at $25/month on the sandbox account

---

## Consequences

- The `terraform/backends/` directory now has three backend stubs: `k3d/`, `airgap/`, and `cloud/`
- FDE engagements that require GPU hardware will need a cloud account pre-provisioned
- The `kind` and `cloud` backends must use separate Terraform state files to prevent state corruption
- The air-gap backend (FDE-001) requires Harbor and ChartMuseum to be pre-loaded before isolation

---

## Rejected Alternatives

| Alternative | Reason rejected |
|---|---|
| Single always-on cloud cluster | Violates the "no centralized clusters" constraint (cost, CRD collisions, noisy neighbours) |
| Vagrant + libvirt on bare metal | Poor Apple Silicon support; slower than kind; higher setup friction |
| Docker Compose only | Cannot demonstrate K8s-native patterns (RBAC, NetworkPolicy, operator CRDs) |
| Google Cloud Run / AWS Fargate | No Kubernetes API — incompatible with the ArgoCD/Kyverno/Boundary stack |
