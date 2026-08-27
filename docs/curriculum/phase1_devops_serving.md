# Phase 1 Curriculum: Deep DevOps & Core Inference Serving
**Months 1–3 | IBM Band 8 → Senior AI Platform / DevOps Engineer**

Target Environment: Apple Silicon M4 Max · OrbStack · Kind · Ollama (local inference stub)  
No CUDA required. All GPU metrics via mock-dcgm-exporter.

---

## Curriculum Map

| Month | Focus | Primary Artifact |
|---|---|---|
| **1** | DevOps upskilling — GitOps deep patterns, Terraform state, GitHub Actions | ArgoCD App-of-Apps deploying Ollama + observability stack |
| **2** | Inference serving — vLLM patterns (CPU/simulated), TTFT/TPOT benchmarking, Prometheus | Benchmark harness + DCGM mock + Grafana dashboard |
| **3** | SRE translation + Python/Go foundations for infra | Postmortem doc + first kubebuilder CRD scaffold |

---

## Part 1 — The DevOps Upskilling Blueprint

### 1.1 GitOps Deep Patterns (Weeks 1–3)

You already use ArgoCD. This section targets the three patterns that separate "I deployed a Helm chart" from "I run a platform."

#### Pattern A: App-of-Apps

The App-of-Apps pattern makes ArgoCD manage ArgoCD Applications as code. One root `Application` points to a directory of child `Application` manifests. When you add a new app manifest to Git, ArgoCD auto-discovers and syncs it — no manual intervention.

```
clusters/
└── local-kind/
    ├── app-of-apps.yaml         # Root Application — points at apps/
    └── apps/
        ├── argocd.yaml          # ArgoCD itself (self-managed)
        ├── gpu-operator.yaml    # (stub on M4 — real on cloud GPU node)
        ├── vault.yaml
        ├── consul.yaml
        ├── ollama.yaml
        └── observability.yaml
```

Root Application manifest (`app-of-apps.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/ai-platform-lab
    targetRevision: HEAD
    path: clusters/local-kind/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Lab exercise:** Create the directory structure above. Add a child application for Ollama. Watch ArgoCD auto-sync it. Then add the observability app and watch it deploy without touching `kubectl apply` by hand. This is the "platform" moment — Git is the only interface.

#### Pattern B: ApplicationSets — fleet/multi-model rollouts

`ApplicationSet` generates `Application` resources dynamically from a template + a generator. The critical use case for AI platform: **one ApplicationSet that stamps out a separate inference deployment per model**, with per-model resource limits, GPU profiles, and namespace isolation.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: inference-models
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - model: llama3.2-3b
            namespace: inference-llama
            memoryLimit: "8Gi"
          - model: mistral-7b
            namespace: inference-mistral
            memoryLimit: "16Gi"
  template:
    metadata:
      name: "inference-{{model}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/YOUR_ORG/ai-platform-lab
        path: workloads/inference
        targetRevision: HEAD
        helm:
          valueFiles:
            - "values-{{model}}.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{namespace}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**Key insight:** When you add a new element to the `list` generator and push to Git, ArgoCD automatically creates a new namespaced inference deployment. This is how a Platform Engineer enables self-service — the developer edits the list, not a platform engineer's calendar.

#### Pattern C: Sync Waves — ordered dependency deployment

Sync waves solve the ordering problem: the GPU Operator must be ready before the device plugin, which must be ready before the model server, which must be ready before the autoscaler. ArgoCD sync waves let you declare this dependency chain in annotations.

```yaml
# GPU Operator — wave 1 (first)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
# Vault Secrets Operator — wave 2
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"
---
# Ollama / vLLM server — wave 3 (after secrets infra is ready)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"
---
# KEDA ScaledObject — wave 4 (last, requires server to exist)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

**Custom health checks (Senior signal):** ArgoCD doesn't know when a `vLLM` Deployment is *actually* healthy — the pod can be Running while the model is still loading into VRAM. Write a custom Lua health check that reads the `/health` or `/v1/models` endpoint:

```lua
-- argocd-cm ConfigMap: resource.customizations.health
-- Key: apps/Deployment.vllm-server
hs = {}
if obj.status ~= nil then
  if obj.status.readyReplicas ~= nil and obj.status.readyReplicas == obj.spec.replicas then
    hs.status = "Healthy"
    hs.message = "All replicas ready"
    return hs
  end
end
hs.status = "Progressing"
hs.message = "Waiting for model server replicas"
return hs
```

For KServe `InferenceService` CRDs, write a health check that reads `.status.conditions` for the `Ready` condition type.

**Lab deliverable:** Deploy your full local stack (Ollama + Prometheus + Grafana + mock-dcgm-exporter) via a single `kubectl apply -f app-of-apps.yaml`. Everything else is GitOps-driven.

---

### 1.2 Advanced Terraform State Mechanics (Week 3–4)

#### State file — what it actually is

The Terraform state file (`terraform.tfstate`) is a JSON-serialised snapshot of every managed resource's attributes. It is Terraform's source of truth about the *real world*, not your config files. Three things to know cold:

**State locking:** Remote backends (S3 + DynamoDB, GCS, Terraform Cloud) acquire a distributed lock before any write operation. Without this, two concurrent `terraform apply` runs corrupt the state. Implementing locking is table stakes for any team state.

**State drift:** Real-world state diverges from the state file when someone modifies infrastructure outside Terraform (a manual `kubectl edit`, a cloud console click). `terraform plan` detects drift. `terraform refresh` re-reads real world into state. In AI platform contexts, drift is common: ops teams apply emergency patches during incidents. Build a CI job that runs `terraform plan` on a schedule and alerts on unexpected drift.

**State isolation patterns for AI platform:**
```hcl
# workspaces — lightweight isolation, single backend
terraform workspace new prod-gpu-cluster
terraform workspace select prod-gpu-cluster

# preferred at scale: separate state files per component
# backends.tf for gpu-cluster layer
terraform {
  backend "s3" {
    bucket         = "tf-state-ai-platform"
    key            = "gpu-cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-state-locks"
    encrypt        = true
  }
}
```

**Remote state data sources** — one layer reading another layer's outputs:
```hcl
# networking layer outputs VPC ID
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "tf-state-ai-platform"
    key    = "networking/terraform.tfstate"
    region = "us-east-1"
  }
}

# gpu-cluster layer consumes it
resource "aws_eks_cluster" "gpu" {
  vpc_config {
    subnet_ids = data.terraform_remote_state.networking.outputs.private_subnet_ids
  }
}
```

**M4 Max lab:** Use a local MinIO container as an S3-compatible backend for practicing state operations. `terraform state list`, `terraform state show`, `terraform state rm`, `terraform import` — run all of these. Knowing `terraform import` cold saves you in interviews ("how would you bring an existing resource under management?").

---

### 1.3 GitHub Actions Workflow Engineering (Week 4–5)

Target: build the CI/CD pipeline that validates and ships your ArgoCD apps.

#### The three pipelines every AI platform needs

**Pipeline 1 — Terraform validate + plan on PR:**
```yaml
name: terraform-plan
on:
  pull_request:
    paths:
      - 'platform/terraform/**'

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.9"

      - name: Terraform Init
        run: terraform -chdir=platform/terraform init -backend=false

      - name: Terraform Validate
        run: terraform -chdir=platform/terraform validate

      - name: Terraform Format Check
        run: terraform -chdir=platform/terraform fmt -check -recursive

      - name: Terraform Plan (dry-run)
        run: terraform -chdir=platform/terraform plan -out=tfplan
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

**Pipeline 2 — Python lint, type-check, and test on PR:**
```yaml
name: python-ci
on: [pull_request]

jobs:
  lint-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: astral-sh/setup-uv@v3
        with:
          version: "latest"

      - name: Install dependencies
        run: uv sync --all-extras

      - name: Ruff lint
        run: uv run ruff check scripts/ platform/

      - name: Mypy type check
        run: uv run mypy scripts/ platform/ --ignore-missing-imports

      - name: Pytest
        run: uv run pytest tests/ -v --tb=short
```

**Pipeline 3 — Kubernetes manifest validation:**
```yaml
name: k8s-manifest-validate
on:
  pull_request:
    paths:
      - 'workloads/**'
      - 'platform/**/*.yaml'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate with kubeconform
        uses: docker://ghcr.io/yannh/kubeconform:latest
        with:
          args: >-
            -strict
            -schema-location default
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
            workloads/ platform/
```

**GitHub Actions security patterns (your CKS instincts applied):**
- Never store secrets in env vars in the workflow YAML — use `${{ secrets.NAME }}`.
- Pin action versions to a commit SHA, not a mutable tag: `uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (prevents supply-chain attacks via tag mutation).
- Use `permissions:` blocks to grant least-privilege to the `GITHUB_TOKEN`:
```yaml
permissions:
  contents: read
  pull-requests: write  # only if the job needs to post PR comments
```

---

## Part 2 — The SRE Translation Matrix

### 2.1 Vocabulary Translation — 12 years of support → SRE engineering

This is the reframing layer. Every statement on your résumé should be in the right column, not the left.

| Your current language (passive, reactive) | SRE engineering language (active, measurable) |
|---|---|
| "Handled Sev-1 live outages" | "Served as incident commander for P1 incidents; drove MTTR from X to Y hours through standardised runbooks and automated diagnostic collection" |
| "Escalation support engineer" | "Reliability engineer responsible for postmortem-driven root-cause elimination and toil reduction" |
| "Managed recurring tickets for [issue]" | "Identified [issue] as a toil candidate; implemented automated remediation, reducing ticket volume by N%" |
| "Troubleshot Vault/Consul cluster issues" | "Owned secret-management SLOs (availability, latency to secret fetch); implemented PKI auto-rotation to eliminate cert-expiry incidents" |
| "Fixed deployment failures" | "Engineered self-healing deployment pipeline using ArgoCD sync-waves and Argo Rollouts canary gates; reduced deployment-related incidents by X%" |
| "Provided infrastructure support" | "Operated shared platform infrastructure serving N teams; defined and monitored SLIs/SLOs on platform components" |
| "Documented issue resolutions" | "Authored blameless postmortems and institutional runbooks; drove systemic fixes reducing recurrence rate" |

### 2.2 SLI / SLO / Error Budget — exact definitions to whiteboard

**SLI (Service Level Indicator):** A quantitative measure of a service dimension. Must be a ratio: `good events / total events`.

Examples for an LLM inference service:
- `successful_requests / total_requests` (availability SLI)
- `requests_where_TTFT < 2000ms / total_requests` (latency SLI)
- `requests_where_KV_cache_util < 90% / total_requests` (saturation SLI)

**SLO (Service Level Objective):** A target percentage for an SLI over a rolling window.
- "99.5% of requests shall have TTFT < 2000ms over a 30-day rolling window."
- "99.9% of requests shall succeed (non-5xx) over a 28-day rolling window."

**Error budget:** `1 - SLO`. If your availability SLO is 99.9%, your error budget is 0.1% of request volume per window. Burn rate = how fast you're consuming it. When budget hits zero, you stop risky changes until it recovers.

**Burn rate alerts (multi-window):**
```yaml
# 2% burn rate over 1h (fast burn) OR 5% over 6h (slow burn) → page
- alert: InferenceSLOErrorBudgetBurn
  expr: |
    (
      sum(rate(inference_requests_total{status="error"}[1h]))
      / sum(rate(inference_requests_total[1h]))
    ) > 0.02 * (1 - 0.999)
    or
    (
      sum(rate(inference_requests_total{status="error"}[6h]))
      / sum(rate(inference_requests_total[6h]))
    ) > 0.05 * (1 - 0.999)
  for: 2m
  labels:
    severity: page
  annotations:
    summary: "Inference service error budget burn rate critical"
```

### 2.3 Toil — identification and automation

Toil is manual, repetitive, automatable operational work that scales with service load and provides no enduring value beyond the immediate fix. SRE practice says: keep toil below 50% of eng time; actively reduce it.

**Your toil translation exercise:** List 10 recurring tasks from your last 6 months of escalation work. For each, ask:
1. Is it triggered automatically by an event? (If yes = automatable)
2. Does it leave the system in a better long-term state? (If no = toil)
3. Can it be reduced by platform investment? (If yes = engineering opportunity)

These become résumé bullets: "Identified cert-expiry escalations as toil class (N tickets/quarter); implemented Vault PKI auto-rotation eliminating the class."

### 2.4 Automated Self-Healing — patterns and implementations

**Node auto-cordon on GPU fault:**
```bash
# DaemonSet-based XID watcher — if DCGM reports XID error on a node, cordon it
while true; do
  xid=$(curl -s http://localhost:9400/metrics | grep 'DCGM_FI_DEV_XID_ERRORS{' | awk '{print $2}')
  if [[ "$xid" -gt "0" ]]; then
    kubectl cordon "$(hostname)"
    # alert + drain after grace period
  fi
  sleep 30
done
```

**Argo Rollouts SLO-gated promotion** (the model-rollout self-healing pattern):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: inference-server
  namespace: inference
spec:
  strategy:
    canary:
      steps:
        - setWeight: 5
        - pause: {}          # Manual gate for first 5%
        - setWeight: 20
        - pause: {duration: 300s}
        - setWeight: 50
        - pause: {duration: 300s}
        - setWeight: 100
      analysis:
        templates:
          - templateName: ttft-p99-check
        args:
          - name: slo-threshold-ms
            value: "2000"
  template:
    # ... pod template
```

The `AnalysisTemplate` queries Prometheus: if p99 TTFT > threshold during canary, Argo auto-rolls back. You don't page anyone — the platform heals itself.

---

## Part 3 — Python for Infra SRE: Mastery Index

### 3.1 Core async pattern — master this, use everywhere

```python
import asyncio
import httpx
from typing import Any

async def fire_request(
    client: httpx.AsyncClient,
    sem: asyncio.Semaphore,
    url: str,
    payload: dict[str, Any],
) -> dict[str, Any]:
    async with sem:
        async with client.stream("POST", url, json=payload) as resp:
            resp.raise_for_status()
            chunks = []
            async for line in resp.aiter_lines():
                chunks.append(line)
            return {"lines": chunks}

async def main(concurrency: int = 10, total: int = 100) -> None:
    sem = asyncio.Semaphore(concurrency)
    limits = httpx.Limits(max_connections=concurrency + 5)
    
    async with httpx.AsyncClient(limits=limits) as client:
        tasks = [
            fire_request(client, sem, "http://localhost:11434/v1/chat/completions", {
                "model": "llama3.2",
                "messages": [{"role": "user", "content": "hello"}],
                "stream": True,
            })
            for _ in range(total)
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
    
    errors = [r for r in results if isinstance(r, Exception)]
    print(f"Success: {total - len(errors)}, Errors: {len(errors)}")

if __name__ == "__main__":
    asyncio.run(main())
```

Internalise: `asyncio.Semaphore` limits concurrency. `asyncio.gather(*tasks)` runs all coroutines concurrently within that limit. `httpx.AsyncClient` is reused across requests (connection pooling). `aiter_lines()` processes SSE streams token by token.

### 3.2 prometheus_client — exposing custom infra metrics

```python
from prometheus_client import CollectorRegistry, Gauge, generate_latest, CONTENT_TYPE_LATEST

REGISTRY = CollectorRegistry()

kv_cache_util = Gauge(
    "inference_kv_cache_utilization",
    "KV-cache utilisation ratio (0.0–1.0)",
    ["model", "replica"],
    registry=REGISTRY,
)

queue_depth = Gauge(
    "inference_queue_depth",
    "Number of requests in the waiting queue",
    ["model"],
    registry=REGISTRY,
)

# Set values
kv_cache_util.labels(model="llama3.2", replica="0").set(0.73)
queue_depth.labels(model="llama3.2").set(4)

# Serve
from fastapi import FastAPI, Response
app = FastAPI()

@app.get("/metrics")
def metrics() -> Response:
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)
```

### 3.3 Typed configs with pydantic (senior signal)

```python
from pydantic_settings import BaseSettings  # pydantic v2: BaseSettings moved to pydantic-settings package
from pydantic import Field
from pathlib import Path

class BenchmarkConfig(BaseSettings):
    endpoint: str = Field("http://localhost:11434/v1", validation_alias="BENCHMARK_ENDPOINT")
    model: str = Field("llama3.2", validation_alias="BENCHMARK_MODEL")
    concurrency: int = Field(10, validation_alias="BENCHMARK_CONCURRENCY")
    total_requests: int = Field(100, validation_alias="BENCHMARK_TOTAL_REQUESTS")
    output_csv: Path = Field(Path("results.csv"), validation_alias="BENCHMARK_OUTPUT")
    timeout_seconds: float = 120.0

    model_config = {"env_file": ".env"}  # pydantic v2: replaces inner class Config

cfg = BenchmarkConfig()  # reads from env vars or .env file
```

### 3.4 pytest patterns for infra tools

```python
# tests/test_benchmark.py
import pytest
from pathlib import Path
from scripts.harness.ttft_benchmark import percentile, BenchmarkConfig

def test_percentile_empty():
    assert percentile([], 99) == 0.0

def test_percentile_single():
    assert percentile([42.0], 50) == 42.0

@pytest.mark.parametrize("p,expected", [
    (50, 50.0),
    (95, 95.0),
    (99, 99.0),
])
def test_percentile_sorted(p: float, expected: float):
    data = list(range(1, 101, 1))  # 1..100
    assert abs(percentile(data, p) - expected) < 1.0

def test_config_defaults():
    cfg = BenchmarkConfig()
    assert cfg.concurrency == 10
    assert cfg.total_requests == 100
```

### 3.5 Monthly Python checkpoint

| Month | Python milestone | Target state |
|---|---|---|
| 1 | asyncio + httpx + typer | Can write a concurrent API poller with clean CLI args |
| 2 | prometheus_client + FastAPI + pytest | Can write a mock exporter + tests; can parse SSE streams for TTFT |
| 3 | pydantic configs + kubernetes client + mypy | Can write a typed K8s automation script that lists pods and updates ConfigMaps |

---

## Lab Setup: M4 Max Kind Cluster + Ollama

### Prerequisites

```bash
# Install via Homebrew
brew install orbstack kind kubectl helm argocd

# Install Ollama for local inference (Metal-accelerated)
brew install ollama
ollama pull llama3.2  # 3B model, fits in 4GB unified memory

# Start Ollama (OpenAI-compatible endpoint at :11434)
ollama serve
```

### Kind cluster with ArgoCD

```bash
# Create cluster
kind create cluster --name ai-platform --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080    # ArgoCD UI
      - containerPort: 30090
        hostPort: 9090    # Prometheus
      - containerPort: 30300
        hostPort: 3000    # Grafana
      - containerPort: 30400
        hostPort: 9400    # mock-dcgm-exporter
EOF

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Get initial password
argocd admin initial-password -n argocd

# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Install Python env

```bash
# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# Create project env in ai-platform-lab/
cd /Users/himanshusharma/Desktop/AI-Roadmap/ai-platform-lab
uv init
uv add httpx fastapi uvicorn prometheus-client pydantic-settings typer pytest pytest-asyncio mypy ruff
```

---

## Month-by-Month Milestone Checklist

### Month 1 — GitOps & IaC Foundation
- [ ] Kind cluster running with ArgoCD App-of-Apps managing all workloads
- [ ] Ollama deployed via Helm/ArgoCD, serving `llama3.2` locally
- [ ] Sync waves: Vault stub → Prometheus → mock-dcgm-exporter → Ollama (in order)
- [ ] One ApplicationSet parameterising 2 model namespaces
- [ ] Custom Lua health check for the Ollama Deployment
- [ ] Terraform backend on local MinIO; `terraform state list` / `import` exercises complete
- [ ] GitHub Actions CI: Terraform validate + K8s manifest validate on PR

### Month 2 — Inference Serving & Observability
- [ ] `ttft_benchmark.py` running against Ollama; CSV output with p50/p95/p99
- [ ] `mock-dcgm-exporter.py` running in-cluster; Prometheus scraping it
- [ ] Grafana dashboard: TTFT, TPOT, GPU util (mocked), KV-cache util, queue depth
- [ ] KEDA `ScaledObject` scaling Ollama replicas on queue depth (simulated metric)
- [ ] Argo Rollouts canary configured (mock analysis template using Prometheus query)
- [ ] Benchmark run: 10/20/50 concurrency; throughput curve documented in `docs/benchmarks/`

### Month 3 — SRE Translation & Go Foundations
- [ ] Résumé fully rewritten using SRE vocabulary from Part 2
- [ ] One blameless postmortem written from a deliberately induced failure (kill Ollama mid-run)
- [ ] One ADR written: "Why Ollama over vLLM for local M4 Max lab"
- [ ] Python: all benchmark + exporter code type-annotated and passing `mypy`
- [ ] Go: Tour of Go + Go by Example complete; `kubernetes/sample-controller` read and annotated
- [ ] Go: First `kubebuilder` project scaffolded (ModelDeployment CRD shell, reconcile loop stub)
- [ ] LinkedIn headline updated to SRE/platform framing; NVIDIA DLI NCA-AIIO study started
