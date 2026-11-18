# AI Platform Lab

A portfolio reference implementation exploring secure AI inference infrastructure on Kubernetes, including GitOps delivery, an operator pattern, secrets integration, policy controls, and observability.

> **Portfolio lab** — Himanshu Sharma  
> Intended for technical discussion across Platform Engineering, DevOps, SRE, Solutions Architecture, Solutions Engineering, and FDE roles.

## Scope and validation

This repository combines local-lab components with simulations and design documentation. GPU/DCGM telemetry is mocked and the Apple Silicon MPS approach is a simulation; this is not evidence of a production GPU deployment. Cloud and production topologies are architectural examples unless explicitly identified as implemented and validated. Check the individual runbooks and test results before relying on a component.

**Recruiter portfolio:** [Himanshu Sharma — Cloud & Platform Engineering](https://himanshu8693.github.io/ai-platform-lab/)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Developer Laptop (Apple M4 Max)                                    │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Kind Cluster (3 nodes)                                      │   │
│  │                                                              │   │
│  │  ┌─────────────┐   ┌──────────────┐   ┌─────────────────┐   │   │
│  │  │  ArgoCD     │──▶│  ModelDeploy │──▶│  vLLM / Ollama  │   │   │
│  │  │  (GitOps)   │   │  Operator    │   │  (inference pod)│   │   │
│  │  └─────────────┘   └──────┬───────┘   └────────┬────────┘   │   │
│  │                           │                    │            │   │
│  │  ┌─────────────┐   ┌──────▼───────┐   ┌────────▼────────┐   │   │
│  │  │  Vault      │   │  KEDA        │   │  Prometheus     │   │   │
│  │  │  (secrets)  │   │  (autoscale) │   │  + Grafana      │   │   │
│  │  └─────────────┘   └──────────────┘   └─────────────────┘   │   │
│  │                                                              │   │
│  │  ┌─────────────┐   ┌──────────────┐   ┌─────────────────┐   │   │
│  │  │  cert-mgr   │   │  ingress-    │   │  mock-dcgm      │   │   │
│  │  │             │   │  nginx       │   │  exporter       │   │   │
│  │  └─────────────┘   └──────────────┘   └─────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  OrbStack Linux VM  ──  Falco  ──  eBPF syscall enforcement         │
└─────────────────────────────────────────────────────────────────────┘
```

**Data plane**: ModelDeployment CRD → operator reconciles → Deployment + Service  
**Secret plane**: Vault Agent sidecar injects HuggingFace tokens at pod start  
**Scale plane**: KEDA ScaledObject watches `vllm_num_waiting_requests` metric  
**Security plane**: NetworkPolicy zero-trust suite + Kyverno image signing enforcement  
**Delivery plane**: ArgoCD app-of-apps → Helm + raw manifests; CI gate on every PR  

---

## Skill Matrix

| Domain | Technology | Evidence |
|--------|-----------|---------|
| Kubernetes Operators | Go / controller-runtime | `platform/controller/main.go` |
| GitOps | ArgoCD app-of-apps | `clusters/local-kind/` |
| Autoscaling | KEDA custom metrics | `workloads/inference/keda-scaledobject.yaml` |
| Progressive Delivery | Argo Rollouts canary | `workloads/inference/argo-rollout.yaml` |
| Zero-Trust Networking | NetworkPolicy 7-suite | `workloads/inference/networkpolicy.yaml` |
| Secret Management | Vault Agent injection | Vault sidecar annotations in workloads |
| Supply Chain Security | Cosign + Kyverno | `security/kyverno-policies/` |
| Runtime Security | Falco eBPF rules | `security/falco-rules/` |
| Observability | DCGM + vLLM metrics | `platform/observability/` |
| Infrastructure-as-Code | Terraform + Kind | `terraform/main.tf` |
| Service Mesh | Consul Connect intentions | `workloads/multi-tenant/consul-intentions.yaml` |
| CI/CD | GitHub Actions 7-job gate | `.github/workflows/ci-cd-platform-gate.yaml` |

---

## Clone to Demo in 10 Minutes

### Prerequisites

```bash
# macOS / M4 Max
brew install go terraform kubectl helm kind argocd cosign kube-linter
brew install --cask orbstack

# Python toolchain
brew install uv
```

### 1 — Provision the cluster

```bash
cd terraform
terraform init
terraform apply -auto-approve
# Creates 3-node Kind cluster + Vault (dev) + cert-manager + ingress-nginx
```

### 2 — Bootstrap ArgoCD

```bash
kubectl apply -n argocd -f clusters/local-kind/app-of-apps.yaml
argocd login localhost:8080 --username admin --insecure
argocd app sync ai-platform-lab
```

### 3 — Deploy a model

```bash
# Apply ModelDeployment custom resource
kubectl apply -f workloads/inference/modeldeployment.yaml
# Operator reconciles: creates Deployment + Service within ~10 s
kubectl wait --for=condition=Ready pod -l app=llama3 --timeout=120s
```

### 4 — Generate load and watch metrics

```bash
make demo
# Opens: Grafana (http://localhost:3000)  admin/admin
#        ArgoCD  (http://localhost:8080)
#        Prometheus (http://localhost:9090)
```

### 5 — Tear down

```bash
make clean
# terraform destroy + kind cluster delete
```

---

## Make Targets

```
make up          provision cluster + bootstrap ArgoCD + deploy stack
make test        run Go unit tests + python lint + kube-linter + trivy scan
make demo        port-forward Grafana + Prometheus + ArgoCD, then open browsers
make load        run 60-second locust load test against inference proxy
make clean       destroy cluster + remove docker images
make help        print this summary
```

---

## Key Design Decisions

See `docs/adr/` for full Architecture Decision Records:

- [ADR-001](docs/adr/ADR-001-inference-engine-selection.md) — Why vLLM/Ollama over Triton for this lab
- [ADR-002](docs/adr/ADR-002-secret-injection-strategy.md) — Vault Agent sidecar vs. External Secrets Operator
- [ADR-003](docs/adr/ADR-003-mps-simulation-approach.md) — How M4 Max MPS is simulated without a GPU device plugin

---

## Certifications

| Cert | Status | Lab Evidence |
|------|--------|-------------|
| CKA | Passed | Operator pattern, RBAC, NetworkPolicy |
| CKS | Passed | Kyverno, Falco, image signing, NetworkPolicy |
| HashiCorp Vault Associate | Passed | Vault Agent injection, KV-v2 secrets |
| RHCSA | Passed | Container security, non-root UIDs, SELinux context |
| CKAD | Target Month 3 | Workload manifests, resource management |

---

## Repository Layout

```
ai-platform-lab/
├── clusters/local-kind/         ArgoCD app-of-apps + per-app manifests
├── docs/
│   ├── adr/                     Architecture Decision Records
│   ├── curriculum/              12-month learning curriculum
│   ├── runbooks/                Operational runbooks (RB-001, RB-002)
│   └── postmortems/             Incident post-mortems (PM-001)
├── platform/
│   ├── controller/              Go operator (ModelDeployment CRD)
│   └── observability/           Mock DCGM exporter + Prometheus rules
├── security/
│   ├── falco-rules/             eBPF runtime security rules
│   └── kyverno-policies/        Admission control policies
├── terraform/                   Kind cluster + dependencies (IaC)
└── workloads/
    ├── inference/               ModelDeployment, KEDA, Argo Rollout, NetworkPolicy
    └── multi-tenant/            ResourceQuota, Consul intentions
```

---

## Role-relevant evidence

- **Platform / DevOps:** Kubernetes manifests, Terraform, Argo CD and CI workflows.
- **SRE:** observability configuration, operational runbooks, and postmortem examples.
- **Solutions Architect / Solutions Engineer:** architecture decision records and deployment tradeoffs.
- **FDE:** customer scenario documents and constrained-environment design examples.

Use the linked implementation and validation artifacts to distinguish completed work from simulations and design proposals.
