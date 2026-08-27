# Master 12-Month Transition Blueprint
## IBM Band 8 → Senior DevOps / AI Platform Engineer

**Profile:** 12 yrs enterprise infra · CKA · CKS · Vault Ops Professional  
**Targets:** NCA-AIIO (Month 2) · Red Hat EX267 (Month 7) · NCP-AIO (Month 10)  
**Lab:** Apple Silicon M4 Max · OrbStack · Kind · Ollama (local inference stub)

---

## Phase Overview

| Phase | Months | Domain | Cert Gate |
|---|---|---|---|
| **1** | 1–3 | DevOps fundamentals — GitOps, IaC, CI/CD, Python infra | NCA-AIIO Month 2 |
| **2** | 4–6 | Inference serving, GPU observability, KEDA autoscaling | — |
| **3** | 7–9 | RHOAI / OpenShift AI, zero-trust mesh, operator authoring | EX267 Month 7 |
| **4** | 10–12 | GPU fleet ops, FinOps, distributed compute, portfolio polish | NCP-AIO Month 10 |

---

## Part 1 — The Support-to-DevOps Resume Translation Matrix

Every bullet on your résumé must express **ownership, measurability, and engineering action** — not reactive task description. Rewrite before you apply anywhere.

### Raw → Rewritten translations

| Your current phrasing | Senior DevOps / SRE rewrite |
|---|---|
| "Handled Sev-1 live outages across IBM customer environments" | "Served as incident commander for P1/Sev-1 events; standardised runbook-driven response cutting MTTR from ~4h to ~45min across 12+ customer accounts" |
| "Investigated and resolved recurring Kubernetes cluster issues" | "Identified recurring etcd compaction failures as a toil class (avg 3 incidents/month); implemented automated compaction cronjob and alert tuning, eliminating the incident class over 6 months" |
| "Escalation support for HashiCorp Vault cluster failures" | "Owned Vault HA availability SLO (99.95%) across 8 enterprise clusters; designed and implemented automated Raft snapshot + restore playbooks reducing vault-down P1 MTTR by 70%" |
| "Performed ad-hoc Kubernetes config and deployment fixes" | "Engineered self-healing deployment pipeline (ArgoCD sync-waves + Argo Rollouts canary gates) reducing deployment-related P1 incidents by ~85%; established error budget policy blocking high-risk changes during burn events" |
| "Wrote Bash scripts to diagnose issues" | "Automated toil-heavy diagnostic collection (log shipping, network-policy tracing, cert validity) via Python CLI toolchain, eliminating ~12 hrs/week of manual runbook steps across the support org" |
| "Managed PKI and certificate lifecycle for customer environments" | "Owned PKI automation via Vault PKI engine across 200+ TLS endpoints; implemented auto-rotation with <48h TTL, eliminating cert-expiry P1 class (previously 6–8 incidents/quarter)" |
| "Resolved CKS/network security audit findings" | "Implemented Pod Security Admission (restricted profile), Falco runtime rules, and Kyverno admission policies across shared K8s clusters; reduced CIS Benchmark violation score from 37% to 4%" |
| "Provided support documentation" | "Authored blameless postmortems for 40+ P1 events; drove 23 systemic fixes reducing incident recurrence rate from 60% to 18% over 12 months" |

### Toil quantification template

Use this formula for every automation bullet:
> *"Identified [X] as a toil class ([N incidents/quarter or N hrs/week]); implemented [specific automation]; eliminated/reduced toil by [metric] over [timeframe]."*

### SLI/SLO framing template

Use this for every reliability ownership bullet:
> *"Owned [service] availability SLO ([X]% over 28-day window); defined multi-window burn-rate alerts; established error budget policy that [specific outcome]."*

---

## Part 2 — The Dual-Language Proficiency Ceiling

### Python — target: solid intermediate (infra automation tier)

You are NOT targeting data-scientist Python or web-developer Python. You are targeting **automation-engineer Python**: typed, tested, async-capable CLI tools and service wrappers.

#### Mandatory surface (master these, nothing else)

```
asyncio            — event loop, coroutines, Semaphore, gather(), create_task()
httpx              — AsyncClient, streaming via aiter_lines(), connection pooling
fastapi            — single-purpose ASGI apps: /metrics, /healthz, webhook receivers
uvicorn            — ASGI runner; config: workers, log_level, access_log
prometheus_client  — Gauge/Counter/Histogram, generate_latest(), custom Registry
pydantic           — BaseSettings (env-var config), typed data containers
typer / click      — CLI framework for benchmark harnesses and platform tooling
kubernetes         — Python client: clientset, watch.Watch(), dynamic_client
subprocess         — shelling out to kubectl/vault/cosign; check=True, capture_output
pathlib            — path manipulation (never os.path in new code)
pytest             — table-driven tests, fixtures, tmp_path, pytest-asyncio
ruff               — linting + formatting (replaces flake8/black/isort)
mypy               — static type checking; annotate all function signatures
uv                 — package/venv management (replaces pip/poetry)

# ── G1: LLM SDK / tool-use agent loops (FDE + AI Platform Eng bar) ──────────
anthropic          — Messages API, ToolUseBlock, ToolResultBlock; streaming via stream()
openai             — chat.completions.create() with tools=[]; ChatCompletionToolParam
                     Both SDKs share the same conceptual tool-loop — learn one, port to other
```

> **G1 target pattern — write this from memory:**
> ```python
> import anthropic, json
> from typing import Any
>
> client = anthropic.Anthropic()
>
> tools = [
>     {"name": "execute_query", "description": "Run PromQL", "input_schema": {
>         "type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]
>     }},
>     {"name": "list_pods", "description": "List pods in a namespace", "input_schema": {
>         "type": "object", "properties": {"namespace": {"type": "string"}}, "required": ["namespace"]
>     }},
> ]
>
> def dispatch_tool(name: str, inputs: dict[str, Any]) -> str:
>     """Route to the real MCP server — stub for the interview demo."""
>     return json.dumps({"tool": name, "result": f"stub result for {inputs}"})
>
> def run_agent_loop(user_message: str) -> str:
>     messages = [{"role": "user", "content": user_message}]
>     while True:
>         response = client.messages.create(
>             model="claude-opus-4-5",
>             max_tokens=1024,
>             tools=tools,
>             messages=messages,
>         )
>         if response.stop_reason == "end_turn":
>             # Final text answer — extract and return
>             return next(b.text for b in response.content if hasattr(b, "text"))
>         # Process tool calls
>         tool_results = []
>         for block in response.content:
>             if block.type == "tool_use":
>                 result = dispatch_tool(block.name, block.input)
>                 tool_results.append({"type": "tool_result", "tool_use_id": block.id, "content": result})
>         # Append assistant turn + tool results, continue loop
>         messages.append({"role": "assistant", "content": response.content})
>         messages.append({"role": "user", "content": tool_results})
>
> if __name__ == "__main__":
>     print(run_agent_loop("What is the TTFT p99 and how many inference pods are ready?"))
> ```
> Commit this as `scripts/examples/agent-tool-loop.py`. It bridges directly to the MCP dispatch logic in `phase6-mcp-ai-assistant.md` Week 4.

#### Hard ceiling — stop here

| Anti-scope | Reason |
|---|---|
| Django / Flask / FastAPI app patterns | You're building platform tools, not web services |
| numpy / pandas deep use | Light use for parsing benchmark CSVs only; not data science |
| PyTorch / TensorFlow / training loops | Explicitly out of scope |
| Jupyter notebooks | Anti-goal for your persona |
| SQLAlchemy / ORMs | N/A for infra tooling |

#### Monthly Python checkpoint

| Month | Milestone |
|---|---|
| 1 | Typed async CLI tool with httpx + typer; passes mypy + ruff |
| 2 | TTFT/TPOT benchmark harness generating p50/p95/p99 CSV from live Ollama |
| 3 | prometheus_client mock exporter serving DCGM field names; pytest suite |
| 5 | kubernetes Python client: watch loop that reconciles ConfigMap drift |
| 8 | FastAPI webhook receiver that triggers ArgoCD sync on model registry push |
| 11 | **G1** — `scripts/examples/agent-tool-loop.py` committed: Anthropic SDK tool-use loop calling MCP dispatch; passes mypy |

---

### Go — target: operator author (not Go expert)

The Senior→Staff line in platform engineering is: *"I configure platforms"* vs *"I build platforms."* Go is the lever. Target depth: read any K8s-ecosystem codebase fluently; write a working kubebuilder operator + CLI tools.

#### Mandatory concepts in order

```
1. Language core
   - Structs, interfaces (the entire design rests on these — spend real time)
   - Error wrapping: errors.Is/As, fmt.Errorf("%w")
   - Slices, maps, generics (modern Go 1.21+)
   - Named return values, defer, panic/recover

2. Concurrency — the conceptual lift
   - Goroutines + channels (buffered vs unbuffered)
   - select statement (multiplex channels; the K8s controller heartbeat)
   - context.Context — cancellation + deadlines (threads through EVERY K8s API call)
   - sync.WaitGroup, sync.Mutex
   - Worker-pool and fan-out/fan-in patterns

3. client-go — the K8s client layer
   - Clientsets (typed resource access)
   - Informers + listers + shared informer cache (the watch-cache pattern)
   - Workqueues (rate-limiting, retry with backoff)
   - The informer→workqueue→reconcile mental model — internalize this loop

4. controller-runtime — the operator abstraction
   - Manager, reconciler, the Reconcile() loop
   - Level-triggered vs edge-triggered semantics (level = idempotent; your SRE brain maps here)
   - Result{RequeueAfter: duration} for time-based re-reconciliation
   - Predicates (filter watch events to reduce reconcile churn)

5. kubebuilder / Operator SDK
   - Scaffold: kubebuilder init + create api
   - +kubebuilder markers for CRD spec, RBAC, status conditions
   - make generate && make manifests workflow
   - envtest for integration testing (controller against a real ephemeral API server)

6. CLI
   - cobra + viper (every K8s CLI tool uses these)
```

#### Hard ceiling

| Anti-scope | Reason |
|---|---|
| Go web frameworks (Gin, Echo, Fiber) | Not your use case |
| gRPC service authoring | Unless debugging vLLM/Triton transport |
| CGO / assembly / low-level networking | N/A for operator work |
| Go generics deep specialisation | Basic usage only |

#### Weekly Go checkpoint

| Week | Milestone |
|---|---|
| 1–2 | Tour of Go + Go by Example complete; structs/interfaces/error-handling solid |
| 3–4 | Goroutines + channels + context.Context; write a concurrent HTTP poller |
| 5–6 | Read kubernetes/sample-controller line by line; replicate the informer loop |
| 7–8 | kubebuilder scaffold: ModelDeployment CRD + reconciler stub compiles and runs — **then immediately run `go test -race ./...` on the scaffold; attach `dlv debug` and set a breakpoint in `Reconcile()`** |
| 10–12 | Full reconcile loop: creates/updates Deployment + Service based on spec; envtest passes |

#### G3 — Go debugging: race detector + dlv (add to Wk 7–8)

```bash
# Race detector — run this after every non-trivial concurrency change
go test -race ./...
# Expected: no DATA RACE output. If one appears, the reconciler has a shared-state bug.

# dlv debugger — attach to a running controller
dlv debug ./cmd/manager -- --zap-log-level=debug
# In dlv REPL:
(dlv) break reconciler.go:42          # line inside Reconcile()
(dlv) continue                        # run until breakpoint
(dlv) print req                       # inspect the reconcile request
(dlv) locals                          # all local variables at this point
(dlv) next                            # step one line
(dlv) stacktrace                      # see the full call stack

# pprof over HTTP — expose on the operator manager (add to main.go)
import _ "net/http/pprof"
go func() { log.Fatal(http.ListenAndServe(":6060", nil)) }()
# Then from outside the pod:
kubectl port-forward deploy/model-deployment-controller-manager 6060
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=15
# This captures a 15-second CPU profile — use (pprof) top10 to find hot functions
```

> **Interview question this answers:** "Your operator is consuming 400% CPU — how do you find the hot path without restarting it in production?" Answer: expose pprof, capture a CPU profile over kubectl port-forward, run `go tool pprof`, use `top10` to identify the function.

---

## Part 3 — OpenShift Local (CRC) Strategy for EX267 on Apple Silicon

### Critical pre-context: what EX267 actually tests

EX267 tests the **data-scientist-consumer** persona of RHOAI, not the platform-SRE persona. You will be operating:
- Jupyter workbenches (create, manage, use notebooks)
- Elyra / Kubeflow Pipelines (drag-and-drop pipeline authoring)
- Model serving runtimes (KServe, ModelMesh, vLLM serving)
- The RHOAI data science project workflow in the web console

Accept this mismatch upfront. EX267 is a **political credential for IBM/Red Hat internal transfer**, not a skills-alignment cert. Time-box the Jupyter/Elyra work as deliberate tax.

### Step 1 — Download and install CRC (Apple Silicon)

```bash
# Requires a free Red Hat account at console.redhat.com
# Download the macOS ARM64 binary from:
# https://console.redhat.com/openshift/create/local

# After download, extract and install
tar xvf crc-macos-arm64.tar.xz
sudo mv crc-macos-arm64-*/crc /usr/local/bin/crc
crc version  # Verify ARM64 binary

# Configure resources — M4 Max has headroom; give CRC enough
crc config set cpus 8
crc config set memory 24576   # 24 GiB — RHOAI operator needs ~16GiB minimum
crc config set disk-size 120  # GB — RHOAI images are large

# Run setup (downloads VM image, configures hypervisor)
crc setup
# Uses Apple Hypervisor Framework (not VirtualBox) — native ARM64 VM
```

### Step 2 — Start the cluster and configure shell

```bash
crc start
# Prompts for pull secret — paste from console.redhat.com/openshift/downloads

# Configure shell environment
eval $(crc oc-env)
oc login -u developer -p developer https://api.crc.testing:6443
oc login -u kubeadmin -p $(crc console --credentials | grep kubeadmin | awk '{print $NF}') \
  https://api.crc.testing:6443

# Verify
oc get nodes
oc get clusterversion
```

### Step 3 — Install the RHOAI operator on CRC

```bash
# Switch to kubeadmin
oc login -u kubeadmin https://api.crc.testing:6443

# Create the RHOAI namespace
oc new-project redhat-ods-operator

# Install via OperatorHub (web console is easiest for this)
crc console  # Opens the OpenShift web console in your browser

# Navigate: Operators → OperatorHub → search "Red Hat OpenShift AI"
# Install with default namespace: redhat-ods-operator
# Then create a DataScienceCluster instance

# CLI equivalent (requires subscription YAML):
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Step 4 — Known CRC limitations and workarounds for EX267 prep

| Limitation | Impact | Workaround |
|---|---|---|
| No NVIDIA GPU (ARM host) | Cannot serve CUDA models; GPU-accelerated serving runtimes will fail | Use OpenVINO (CPU-based) or mock serving runtimes for exam workflow practice |
| Single-node cluster | Some HA patterns won't demonstrate correctly | Acceptable for EX267 — exam tests workflow, not HA |
| CRC RAM ceiling (~24 GiB usable) | RHOAI + workbenches + a model server is tight | Close other apps; limit workbench image size; use minimal model serving configs |
| CRC disk speed | Workbench image pulls are slow | Pre-pull images: `oc adm catalog mirror` or use `oc image mirror` |
| RHOAI version lag | CRC ships with slightly older RHOAI build | Check operator channel for latest stable; upgrade subscription if needed |

### Step 5 — EX267 exam-day practice loop

```bash
# Practice workflow (run this until it's automatic):

# 1. Create a data science project
oc new-project exam-prep-project

# 2. Create a workbench (PVC + Jupyter server)
# → Console: Data Science → Create Workbench → Standard Data Science image
# → Note: takes 3–5 min first launch on CRC

# 3. Open Jupyter, create a notebook, train a trivial sklearn model
# → Import from Git in notebook: 
#   !git clone https://github.com/rh-aiservices-bu/fraud-detection.git

# 4. Export a pipeline via Elyra
# → Open a pipeline file (.pipeline) in Jupyter
# → Click Run → Submit to Kubeflow Pipelines

# 5. Deploy the model with KServe (single-model serving)
# → Console: Data Science → Models → Deploy Model
# → Select InferenceService → set serving runtime: OpenVINO or vLLM

# 6. Monitor via the RHOAI console metrics tab
```

### Primary EX267 prep resource: Red Hat Developer Sandbox

**Use the free hosted RHOAI sandbox instead of CRC for most study time.** CRC is valuable for offline practice and exam-day muscle memory. The Sandbox gives you real RHOAI with no install overhead.

```
URL: https://developers.redhat.com/developer-sandbox
→ "Try OpenShift AI" tile → free 30-day hosted instance
→ Includes real Jupyter, Elyra, KServe serving runtimes
→ No GPU on free tier — use OpenVINO or onnxruntime serving
```

---

## Part 2b — SRE Live Profiling Toolkit (G4)

Senior SRE and AI Platform Engineer interviews often include a live troubleshooting scenario: "your inference server is at 100% CPU — how do you find the hot path without restarting it?" This section gives you the exact commands.

### G4 — Python: py-spy (zero-restart CPU profiler)

```bash
# Install
pip install py-spy   # or: brew install py-spy

# Attach to a running uvicorn/FastAPI process — no code changes needed
py-spy top --pid $(pgrep -f "uvicorn support_intelligence")
# Output: live top-like view of Python stack frames sorted by CPU %
# Typical finding for inference servers: tokeniser or JSON serialisation in hot path

# Generate a flamegraph (save as SVG, open in browser)
py-spy record -o flamegraph.svg --pid $(pgrep -f "uvicorn") --duration 30
# Each horizontal bar = a stack frame; wide bars = CPU hot paths

# Profile inside a Kubernetes pod (requires SYS_PTRACE capability — add temporarily)
kubectl exec -it deploy/mcp-prometheus -- \
  py-spy top --pid 1   # PID 1 = the main process in the container
```

### G4 — Go: pprof over HTTP (zero-restart profiling for operators and servers)

```go
// Add to main.go of any Go server (the operator manager, a custom MCP server wrapper)
import (
    "log"
    "net/http"
    _ "net/http/pprof"   // blank import registers /debug/pprof/* handlers
)

// In main():
go func() {
    log.Fatal(http.ListenAndServe(":6060", nil))
}()
```

```bash
# Port-forward from a running pod
kubectl port-forward deploy/model-deployment-controller-manager 6060

# 30-second CPU profile
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30
(pprof) top10         # top 10 functions by CPU
(pprof) web           # open interactive flamegraph in browser (requires graphviz)
(pprof) list Reconcile  # annotated source for the Reconcile function

# Heap snapshot (for memory leak investigation)
go tool pprof http://localhost:6060/debug/pprof/heap
(pprof) top20 -cum    # top 20 by cumulative allocations
```

> **Lab deliverable:** Trigger high CPU artificially (e.g., add a tight loop in the reconciler), capture a pprof CPU profile, identify the hot function with `top10`, fix it, and show the before/after profile. Commit both SVG flamegraphs to `docs/benchmarks/`. This is the exact demo you show in a Sr SRE or Sr AI Platform Eng interview when asked about production profiling.

---

## Phase 1: DevOps & IaC Foundation (Months 1–3)

**Primary delivery:** Local Kind cluster provisioned by Terraform; full platform deployed via ArgoCD App-of-Apps; benchmark harness running against Ollama.

| Week | Focus | Lab Deliverable |
|---|---|---|
| 1 | Kind cluster + Terraform kind/helm providers | `terraform apply` spins up cluster + Vault + ingress |
| 2 | ArgoCD App-of-Apps, sync waves, ApplicationSets | Single `kubectl apply` boots full platform from Git |
| 3 | GitHub Actions: TF validate, kubeconform, Cosign mock | CI gate blocks non-conformant manifests on PR |
| 4–5 | Python async + httpx; TTFT harness | Benchmark CSV with p50/p95/p99 from Ollama |
| 6 | mock-dcgm-exporter; Prometheus scraping DCGM field names | Grafana dashboard shows GPU_UTIL, FB_USED, KV-cache |
| 7–8 | Argo Rollouts canary; KEDA ScaledObject on queue depth | Auto-rollback demo on TTFT p99 breach |
| 9–10 | Vault Secrets Operator; NetworkPolicy zero-trust suite | Zero secrets in YAML; mTLS via Consul intentions |
| 11–12 | Go: Tour + sample-controller + kubebuilder init | ModelDeployment CRD scaffold compiles |
| **Month 2** | **→ Sit NCA-AIIO** | NCA-AIIO certified |

---

## Phase 1b: Observability — G2: OTel GenAI Semantic Conventions (token cost tracking)

Add this immediately after the TTFT/TPOT Grafana dashboard work in Phase 1–2 (Weeks 19–20 of the phase table). It is a 2-hour addition, not a separate phase.

### G2 — OTel gen_ai.* semantic conventions

The OpenTelemetry GenAI semantic conventions (`gen_ai.*`) are the standard way to track token consumption, cost, and model performance in production. An FDE or AI Platform Engineer panel will ask "how do you track cost per inference call?" — this is the answer.

```python
# Add to ai-assistant pod and any MCP-calling service
# These are OTel span attributes on every LLM call span

from opentelemetry import trace
from opentelemetry.semconv._incubating.attributes import gen_ai_attributes as GenAI

tracer = trace.get_tracer("ai-assistant")

with tracer.start_as_current_span("llm.chat") as span:
    span.set_attribute(GenAI.GEN_AI_SYSTEM, "anthropic")          # or "openai", "ollama"
    span.set_attribute(GenAI.GEN_AI_REQUEST_MODEL, "claude-opus-4-5")
    span.set_attribute(GenAI.GEN_AI_REQUEST_MAX_TOKENS, 1024)
    # After the call completes, set response attributes:
    span.set_attribute(GenAI.GEN_AI_USAGE_INPUT_TOKENS, response.usage.input_tokens)
    span.set_attribute(GenAI.GEN_AI_USAGE_OUTPUT_TOKENS, response.usage.output_tokens)
    # Estimated cost (calculate from token counts × model pricing):
    cost_usd = (response.usage.input_tokens * 0.000015) + (response.usage.output_tokens * 0.000075)
    span.set_attribute("gen_ai.usage.cost_usd", cost_usd)
```

```yaml
# Add to workloads/ai-assistant/deployments.yaml env section
# Controls OTel GenAI instrumentation behaviour
- name: OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT
  value: "false"    # NEVER capture prompt/response content — PII risk
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.monitoring.svc.cluster.local:4317"
```

```promql
# Grafana panel: cost per 1K tokens (add to existing dashboard)
# Input token rate
sum(rate(gen_ai_client_token_usage_total{token_type="input"}[5m])) by (gen_ai_request_model)

# Output token rate (typically 3–5× more expensive)
sum(rate(gen_ai_client_token_usage_total{token_type="output"}[5m])) by (gen_ai_request_model)

# Estimated hourly cost (Prometheus recording rule — add to custom-rules.yaml)
# record: ai_platform:llm_hourly_cost_usd
# expr: sum(increase(gen_ai_client_token_usage_total{token_type="input"}[1h]))
#        * 0.000015   # ← update for your actual model pricing
#       + sum(increase(gen_ai_client_token_usage_total{token_type="output"}[1h]))
#        * 0.000075
```

> **Lab deliverable:** Add `gen_ai.*` attributes to the ai-assistant's LLM call spans. Add a "Cost per 1K tokens" Grafana panel to the existing observability dashboard. Commit the updated `platform/observability/prometheus/custom-rules.yaml` (add the recording rule) and the updated `workloads/ai-assistant/deployments.yaml` (add the two env vars). Update ADR-013 to reference this as the token-cost layer of the audit trail.

---

## Phase 2: Inference Serving & Observability (Months 4–6)

**Primary delivery:** vLLM (CPU-mode) or Ollama serving via KServe; full TTFT/TPOT/KV-cache Grafana dashboard; KEDA autoscaling on queue depth.

| Week | Focus | Lab Deliverable |
|---|---|---|
| 13–14 | vLLM architecture: PagedAttention, continuous batching, quantization | vLLM running in Kind; benchmark showing TTFT vs batch-size curve |
| 15–16 | Triton Inference Server concepts; GenAI-Perf | Triton model repo structure; benchmark comparison doc |
| 17–18 | KServe InferenceService; custom Lua health check in ArgoCD | InferenceService with ArgoCD custom health check |
| 19–20 | DCGM-Exporter deep dive; TTFT/TPOT SLO definition | Prometheus alerts on TTFT p99 breach + KV-cache pressure |
| 21–22 | Multi-node inference: tensor/pipeline parallelism concepts | ADR: "When to use Ray Serve vs KServe for multi-model serving" |
| 23–24 | GPU FinOps: OpenCost GPU allocation; utilisation reporting | Cost-per-1M-tokens dashboard; utilisation optimisation analysis |
| **Month 6** | Portfolio: Capstone 1 complete | Capstone 1 README published; LinkedIn updated |

---

## Phase 3: RHOAI, Zero-Trust Mesh & Operator Authoring (Months 7–9)

**Primary delivery:** EX267 passed; Consul mTLS across inference services; ModelDeployment operator functional.

| Week | Focus | Lab Deliverable |
|---|---|---|
| 25–26 | CRC setup + RHOAI operator install; EX267 study | Workbench → Elyra pipeline → KServe deploy (CRC) |
| 27 | **→ Sit Red Hat EX267** | EX267 certified |
| 28–29 | Consul service mesh: mTLS, intentions, service discovery | Consul deny-by-default intention blocking non-mesh traffic |
| 30–31 | Vault PKI engine: cert issuance, auto-rotation, mTLS | mTLS certs auto-rotating with <48h TTL |
| 32–33 | Boundary: zero-trust operator access; no static SSH | Demo: Boundary session → GPU node, no SSH keys anywhere |
| 34–36 | Go operator: ModelDeployment reconcile loop functional | Operator creates Deployment + Service from ModelDeployment CR |
| **Month 9** | Capstone 2 complete | Zero-trust multi-model fleet; mTLS enforcement recorded |

---

## Phase 4: GPU Fleet Ops, NCP-AIO & Portfolio Polish (Months 10–12)

**Primary delivery:** NCP-AIO certified; Capstone 3 complete; staff-level portfolio published.

| Week | Focus | Lab Deliverable |
|---|---|---|
| 37–38 | Slurm basics (VMs on cloud GPU); BCM concepts via docs/DLI | Slurm job submission; squeue/scancel/sinfo muscle memory |
| 39–40 | DCGM fleet monitoring: XID alerting, auto-cordon on fault | Automated node cordon on simulated XID error |
| 41 | **→ Sit NCP-AIO** | NCP-AIO certified |
| 42–44 | Cosign model signing; Kyverno admission (block unsigned) | Demo: unsigned model image blocked at admission |
| 45–46 | Go operator: status conditions, leader election, envtest | envtest integration test suite passes |
| 47–48 | Portfolio polish: ADRs, runbooks, postmortems, benchmark graphs | Repo README is a public case study |
| 49–52 | Mock Staff interviews; IBM internal transfer application | Transfer application submitted; external pipeline started |

---

## Certification Prep Summary

### NCA-AIIO (Month 2) — associate, ~1–2 weeks study

**Format:** 50 MCQ · 60 min · $125 · Certiverse · online proctored

| Domain | Weight | Your position |
|---|---|---|
| AI Infrastructure (GPU sizing, DC networking, NVLink, DPUs) | 40% | Near-free — your enterprise DC/network background maps directly |
| Essential AI Knowledge (NVIDIA software stack, training vs inference) | 38% | Your real study area — Phase 0 covers this |
| AI Operations (monitoring, orchestration, MIG, DCGM) | 22% | Covered by Phase 1/2 lab work |

**Study path:** NVIDIA DLI "AI Infrastructure and Operations Fundamentals" (official companion).

---

### Red Hat EX267 (Month 7) — performance-based lab, ~4 weeks study

**Format:** Live lab · 3 hours · ~$400 · OpenShift AI environment  
**Remember:** This tests the data-scientist persona — Jupyter + Elyra + model serving. The platform-SRE persona is NOT on the exam. Accept the mismatch; treat it as a key for the IBM/Red Hat internal door.

**Your genuine gap:**
- Jupyter notebook authoring (you have zero — budget 5–8 hrs of hands-on)
- Elyra pipeline drag-and-drop workflow (2–3 hrs of practice)
- RHOAI dashboard UX: data science projects, connections, workbench images
- KServe/ModelMesh serving runtime selection and `InferenceService` YAML

**Study path:** Red Hat Developer Sandbox (primary) + CRC (offline muscle memory).

---

### NCP-AIO (Month 10) — professional, hands-on labs, ~4–6 weeks study

**Format:** 30 MCQ + 3 live lab exercises · 120 min · Certiverse  
**Labs use:** Kubernetes, Slurm, Base Command Manager (BCM)  
**Your genuine gap:** BCM (requires DGX hardware — use IBM internal channels or NVIDIA DLI labs to access it)

| NCP-AIO requirement | Where you build muscle |
|---|---|
| K8s live-cluster CLI | Your entire Phase 1–4 lab |
| Triton / NIM serving | Phase 2 + Capstones 1 & 2 |
| DCGM monitoring + XID alerting | Phase 3 + Capstone 3 |
| GPU Operator / device plugin | Phase 2 |
| Slurm | Phase 4 + Capstone 3 |
| BCM | ⚠️ IBM internal — solve in Month 1 |
| Incident response | Your 12-year career |

---

## Phase 4b: Ansible Module (G6 — IBM SRE / Sr Solution Architect track)

> **When to do this:** Add to Phase 4 Weeks 45–46 (portfolio polish block), running in parallel with the Go operator status conditions work. Required if targeting IBM Sr SRE, IBM Sr Solution Architect, or Red Hat roles. Optional (but positive signal) for FDE and AI Platform Engineer.

Ansible is the standard automation layer for RHEL fleet management and configuration management in IBM/Red Hat environments. It is frequently tested in IBM Band 9 SRE and SA interviews.

### G6 — Ansible: 2-session module

**Session 1 (4 hrs) — Inventory, modules, and idempotent playbooks:**

```yaml
# playbooks/configure-inference-node.yaml
# Configures a RHEL-like node for running an inference workload.
# Idempotent: safe to run multiple times.
---
- name: Configure inference node
  hosts: inference_nodes
  become: true
  vars:
    ollama_version: "0.3.12"
    inference_user: "inference"
    inference_data_dir: "/var/lib/inference"

  tasks:
    - name: Ensure inference group exists
      ansible.builtin.group:
        name: "{{ inference_user }}"
        state: present

    - name: Ensure inference user exists (no login shell)
      ansible.builtin.user:
        name: "{{ inference_user }}"
        group: "{{ inference_user }}"
        shell: /sbin/nologin
        create_home: false
        system: true

    - name: Create inference data directory
      ansible.builtin.file:
        path: "{{ inference_data_dir }}"
        state: directory
        owner: "{{ inference_user }}"
        group: "{{ inference_user }}"
        mode: "0750"

    - name: Install required packages
      ansible.builtin.dnf:
        name:
          - curl
          - jq
          - systemd
        state: present

    - name: Deploy Ollama systemd service
      ansible.builtin.template:
        src: templates/ollama.service.j2
        dest: /etc/systemd/system/ollama.service
        owner: root
        group: root
        mode: "0644"
      notify: Reload systemd

    - name: Ensure Ollama service is enabled and running
      ansible.builtin.systemd:
        name: ollama
        enabled: true
        state: started

    - name: Set SELinux context on data directory
      community.general.sefcontext:
        target: "{{ inference_data_dir }}(/.*)?"
        setype: var_t
        state: present
      when: ansible_selinux.status == "enabled"

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd:
        daemon_reload: true
```

**Session 2 (4 hrs) — Vault dynamic secrets via Ansible + CI integration:**

```yaml
# playbooks/rotate-vault-approle.yaml
# Uses the community.hashi_vault collection to rotate an AppRole secret_id.
# Run from GitHub Actions on a schedule or triggered by a Vault lease expiry event.
---
- name: Rotate Vault AppRole secret_id
  hosts: localhost
  gather_facts: false
  vars:
    vault_addr: "https://vault.internal.example.com"
    vault_role_id: "{{ lookup('env', 'VAULT_ROLE_ID') }}"
    vault_secret_id: "{{ lookup('env', 'VAULT_SECRET_ID') }}"

  tasks:
    - name: Authenticate to Vault via AppRole
      community.hashi_vault.vault_login:
        url: "{{ vault_addr }}"
        auth_method: approle
        role_id: "{{ vault_role_id }}"
        secret_id: "{{ vault_secret_id }}"
      register: vault_login

    - name: Generate new secret_id for the inference-node role
      community.hashi_vault.vault_write:
        url: "{{ vault_addr }}"
        token: "{{ vault_login.login.auth.client_token }}"
        path: "auth/approle/role/inference-node/secret-id"
      register: new_secret

    - name: Store new secret_id in GitHub Actions secret (via gh CLI)
      ansible.builtin.command:
        cmd: >
          gh secret set INFERENCE_VAULT_SECRET_ID
          --body "{{ new_secret.data.data.secret_id }}"
          --repo myorg/ai-platform-lab
      changed_when: true
```

```bash
# Inventory file: inventories/inference-nodes/hosts.yaml
all:
  children:
    inference_nodes:
      hosts:
        node-01.internal:
          ansible_user: ec2-user
          ansible_ssh_private_key_file: ~/.ssh/inference-key.pem
        node-02.internal:
          ansible_user: ec2-user
          ansible_ssh_private_key_file: ~/.ssh/inference-key.pem

# Run the playbook
ansible-playbook -i inventories/inference-nodes/hosts.yaml \
  playbooks/configure-inference-node.yaml --check   # dry-run first
ansible-playbook -i inventories/inference-nodes/hosts.yaml \
  playbooks/configure-inference-node.yaml           # apply

# Lint (add to GitHub Actions CI)
ansible-lint playbooks/configure-inference-node.yaml
```

> **Lab deliverable:** Commit `playbooks/configure-inference-node.yaml` and `playbooks/rotate-vault-approle.yaml` to the `ai-platform-lab/` repo. Add `ansible-lint` to a GitHub Actions workflow (`ci-ansible.yml`). This proves you can automate RHEL fleet configuration — the exact skill IBM SRE and SA panels probe.

---

## Phase 4c: Cloud Provider Architecture — ADR + EKS Stub (G7 — Sr Solution Architect track)

> **When to do this:** Phase 4 Weeks 47–48 (portfolio polish block), alongside ADR writing. Required for Sr Solution Architect roles. For FDE and AI Platform Engineer, the ADR alone is sufficient.

### G7 — Cloud vs On-Prem deployment decision ADR

```bash
# Create the ADR
touch docs/adr/ADR-016-cloud-vs-onprem-deployment-strategy.md
```

```markdown
# ADR-016: Cloud vs On-Premises Deployment Strategy for the Ephemeral Lab Engine

**Status:** Accepted
**Date:** [today]
**Deciders:** Platform Engineering

## Context
The Ephemeral Lab Engine can be deployed in three configurations: (1) local kind/k3d on
a developer workstation, (2) ephemeral cloud sandboxes (EKS, GKE, AKS) with TTL-bound
teardown, or (3) on-premises bare-metal Kubernetes (e.g., existing IBM client DC). An
FDE or Sr SA must be able to make this choice on a customer engagement and justify it.

## Decision Matrix

| Criterion | Local kind/k3d | Cloud (EKS/GKE) | On-Prem K8s |
|---|---|---|---|
| Cost | Near-zero | $15–80/day per sandbox | Capital (already paid) |
| Startup latency | 3–5 min | 8–15 min (node provisioning) | 10–30 min (bare-metal PXE) |
| Network isolation | `kind` bridge — shared host | VPC + SG — true isolation | DC VLAN — true isolation |
| Air-gap support | Requires extra setup (Harbor) | Requires VPC endpoint config | Native (no internet egress) |
| Audit compliance | Limited (local logs only) | CloudTrail / GCP Audit Log | SIEM integration required |
| CRD collision risk | High if reusing clusters | Low (ephemeral per scenario) | Low if isolated namespaces |
| GPU availability | M4 Max Unified Memory only | p3/p4 instances on demand | DGX/H100 if provisioned |

## Decision
Use **local kind/k3d** for developer iteration (Sev-1 reproduction, < 10-min TTL).
Use **ephemeral cloud EKS** for FDE customer demonstrations requiring true network
isolation, GPU instances, or multi-node HA topologies. Use **on-prem** only when the
customer has air-gap requirements (FDE-001 scenario).

## Cloud EKS ephemeral sandbox pattern (Terraform stub)
See `terraform/backends/cloud/eks-ephemeral.tf` — provisions a minimal EKS cluster
with a TTL-bound teardown Lambda. Never deployed in the lab (cost-prohibitive without
a real GPU workload) but demonstrates the IaC pattern for Sr SA interviews.
```

```bash
# Create the Terraform stub — never apply, just demonstrate the pattern
mkdir -p terraform/backends/cloud
cat > terraform/backends/cloud/eks-ephemeral.tf << 'EOF'
# terraform/backends/cloud/eks-ephemeral.tf
# STUB ONLY — demonstrates ephemeral EKS sandbox pattern for Sr SA interviews.
# Cost: ~$0.10/hr for control plane + ~$0.50/hr/node for on-demand GPU instances.
# Teardown: TTL Lambda triggers `terraform destroy` after ${ttl_hours} hours.
# NEVER apply this without a dedicated AWS account and explicit cost approval.

variable "ttl_hours" {
  description = "Hours before automatic teardown"
  type        = number
  default     = 4
}

variable "cluster_name" {
  description = "Ephemeral cluster name — include scenario ID and requester"
  type        = string
}

resource "aws_eks_cluster" "ephemeral" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.31"

  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_private_access = true
    endpoint_public_access  = false   # Air-gap compatible
  }

  tags = {
    ttl_hours    = var.ttl_hours
    teardown_by  = timeadd(timestamp(), "${var.ttl_hours}h")
    scenario     = "ephemeral-lab-engine"
    managed_by   = "terraform"
  }
}

resource "aws_eks_node_group" "inference" {
  cluster_name    = aws_eks_cluster.ephemeral.name
  node_group_name = "inference-gpu"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = ["g4dn.xlarge"]   # 1× T4 GPU, ~$0.526/hr on-demand

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 3
  }

  labels = { "nvidia.com/gpu" = "true" }
}

# TTL teardown: CloudWatch scheduled event → Lambda → terraform destroy
resource "aws_cloudwatch_event_rule" "teardown" {
  name                = "${var.cluster_name}-teardown"
  schedule_expression = "rate(${var.ttl_hours} hours)"
}
EOF
```

> **Lab deliverable:** Commit `docs/adr/ADR-016-cloud-vs-onprem-deployment-strategy.md` and `terraform/backends/cloud/eks-ephemeral.tf`. Update the ADR registry table below. For Sr SA interviews, the ADR is what you walk through on the whiteboard — the Terraform stub proves you can implement the decision, not just describe it.

---

## Gap-Driven Engineering Modules (Gaps A–H)

The following modules close the 8 architectural gaps identified by the Staff-level ARB panel.
Each module produces a committed artifact. Execute in the order listed (B→A→C→D→E then F→G→H).

**Additional gaps G1–G7 from the Skills Coverage Audit are sequenced above in Parts 2b, Phase 1b, Phase 4b, and Phase 4c.**

| Gap | Title | ADR | Key Files | Weeks |
|---|---|---|---|---|
| **B** | SPIFFE/SPIRE Workload Identity | ADR-009 | `terraform/spiffe-vault-auth.tf`, `workloads/ai-assistant/spire-registration.yaml` | 1–2 |
| **A** | OPA Semantic AuthZ | ADR-010 | `security/opa-policies/mcp-tool-authz.rego`, patched `context-forge-deployment.yaml` | 3–5 |
| **C** | Latency Budget | ADR-011 | `scripts/harness/boundary-vault-latency.js`, `docs/benchmarks/boundary-vault-latency-results.md` | 3–5 (parallel) |
| **D** | Output DLP | ADR-012 | `workloads/ai-assistant/mcp-server-dlp-sidecar.yaml`, `security/dlp-policies/` | 6–7 |
| **E** | Audit Correlation | ADR-013 | patched `context-forge-deployment.yaml`, `docs/runbooks/RB-003-*` | 8–9 |
| **F** | Air-Gap GitOps | — | `terraform/backends/airgap/harbor.tf`, `scripts/fde/mirror-providers.sh`, `clusters/local-kind/apps/chartmuseum.yaml` | 10–12 |
| **G** | PAM Federation | ADR-014 | `terraform/pam-federation/`, `docs/scenarios/FDE-002-*` | 12–14 |
| **H** | CAB-Compatible GitOps | ADR-015 | `clusters/production/app-of-apps.yaml`, `workloads/platform/cab-approval-hook.yaml` | 14–16 |

### IBM Band 9 Gate (after Week 10): ADR-009 through ADR-013 committed + Loom demo
### FDE Recruiting Gate (after Week 16): All ADRs + FDE-002 + harbor.tf + CAB hook committed

---

## G5 — GitHub Advanced Security (GHAS) Module

> **When to do this:** Phase 4 Week 42–44 block (Cosign/Kyverno supply chain work), or alongside P16 compliance automation. Required for Sr DevSecOps roles. 2 hours total.

GHAS is the GitHub-native security layer that DevSecOps panels at regulated enterprises specifically probe. It sits on top of the CI pipeline you already have.

### Enable GHAS on the lab repo (3 steps, ~30 min each)

**Step 1 — Dependabot (automated dependency updates):**

```yaml
# .github/dependabot.yml — commit this file to enable Dependabot
version: 2
updates:
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
    labels:
      - "dependencies"
      - "security"

  - package-ecosystem: "terraform"
    directory: "/terraform"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 3

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"   # Actions update less frequently
```

**Step 2 — CodeQL (static code analysis / SAST):**

```yaml
# .github/workflows/codeql.yml
name: CodeQL SAST

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 2 * * 1"   # Monday 02:00 UTC — full scan weekly

permissions:
  security-events: write   # Required to upload SARIF results
  contents: read

jobs:
  analyze:
    name: CodeQL — ${{ matrix.language }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        language: [python]   # Add 'go' when the operator is substantial

    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683

      - name: Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
          queries: security-and-quality   # includes OWASP Top 10 queries

      - name: Autobuild
        uses: github/codeql-action/autobuild@v3

      - name: Perform CodeQL analysis
        uses: github/codeql-action/analyze@v3
        with:
          category: "/language:${{ matrix.language }}"
```

**Step 3 — Secret scanning push protection (enable in GitHub UI + add config):**

```yaml
# .github/secret_scanning.yml — custom patterns for your stack
patterns:
  - name: Vault token
    regex: "hvs\.[A-Za-z0-9_-]{90,}"
    secret_type: "vault_token"
  - name: Boundary auth token
    regex: "at_[a-z0-9]{10,}_[A-Za-z0-9]{40,}"
    secret_type: "boundary_auth_token"
  - name: SPIFFE SVID private key header
    regex: "-----BEGIN EC PRIVATE KEY-----"
    secret_type: "spiffe_svid_key"
```

> **Lab deliverable:** Commit `.github/dependabot.yml`, `.github/workflows/codeql.yml`, and `.github/secret_scanning.yml`. Enable secret scanning push protection in the repo Settings → Security → Secret scanning. Take a screenshot of the Security tab showing "No open alerts" — commit it to `docs/portfolio/ghas-security-overview.png`. This is the artifact a Sr DevSecOps interviewer will ask to see.

---

## ADR Registry (complete)

| ADR | Title | Status |
|---|---|---|
| ADR-001 | Inference Engine Selection | Accepted |
| ADR-002 | Secret Injection Strategy | Accepted |
| ADR-003 | MPS Simulation Approach | Accepted |
| ADR-004 | GPU Partitioning Strategy | Accepted |
| ADR-005 | Boundary Auth Strategy | Accepted |
| ADR-006 | MCP Architecture | Accepted |
| ADR-007 | Context Forge Gateway | Accepted |
| ADR-008 | Zero-Trust AI Execution Flow | Accepted |
| **ADR-009** | **Workload Identity — SPIFFE/SPIRE** | **Accepted (Gap B)** |
| **ADR-010** | **Semantic AuthZ — OPA/Rego** | **Accepted (Gap A)** |
| **ADR-011** | **Credential Lease Reuse** | **Accepted (Gap C)** |
| **ADR-012** | **Output DLP** | **Accepted (Gap D)** |
| **ADR-013** | **Audit Trail Correlation + GenAI Token Cost (G2)** | **Accepted (Gap E)** |
| **ADR-014** | **PAM Federation** | **Accepted (Gap G)** |
| **ADR-015** | **CAB-Compatible GitOps** | **Accepted (Gap H)** |
| **ADR-016** | **Cloud vs On-Prem Deployment Strategy (G7)** | **Accepted** |

---


## Skills Coverage — All 5 Target Roles (post gap-closing)

| Skill Area | FDE | Sr AI Platform Eng | Sr Solution Architect | Sr SRE | Sr DevSecOps |
|---|---|---|---|---|---|
| Python (infra + LLM SDK) | ✅ G1 closes | ✅ G1 closes | ✅ | ✅ | ✅ |
| Go (operator + debug + profiling) | ✅ G3+G4 | ✅ G3+G4 | — | ✅ G3+G4 | — |
| Observability (metrics/traces/SLOs/cost) | ✅ G2 closes | ✅ G2 closes | ✅ | ✅ | ✅ |
| GitOps / ArgoCD / ApplicationSets | ✅ | ✅ | ✅ | ✅ | ✅ |
| GitHub Actions CI/CD + GHAS | ✅ | ✅ | ✅ | ✅ | ✅ G5 closes |
| Zero-trust (SPIFFE/OPA/Vault/Boundary) | ✅ Differentiator | ✅ Differentiator | ✅ | ✅ | ✅ Differentiator |
| Ansible | — | — | ✅ G6 closes | ✅ G6 closes | ✅ G6 closes |
| Cloud provider (EKS ADR + stub) | ✅ ADR sufficient | ✅ | ✅ G7 closes | ✅ | ✅ |
| Air-gap + brownfield FDE scenarios | ✅ Differentiator | — | ✅ | — | — |
| Live profiling (py-spy + pprof) | ✅ G4 closes | ✅ G4 closes | — | ✅ G4 closes | — |
| GHAS (Dependabot/CodeQL/secret scan) | — | — | — | — | ✅ G5 closes |
| LLM SDK tool-use agent loop | ✅ G1 closes | ✅ G1 closes | — | — | — |

All 7 gaps closed. Every cell is ✅ or intentionally out-of-scope (—) for that role.

---

## Resume Positioning Statement

Use this verbatim in LinkedIn headline and resume summary:

> "Senior infrastructure & reliability engineer (12 yrs, Sev-1 incident command, CKS) specialising in **secure, zero-trust GPU and LLM-serving platforms** — bringing HashiCorp-grade secrets management, mTLS, and Kubernetes hardening to AI inference at scale. NCA-AIIO · NCP-AIO · CKS · Vault Ops Professional."

Lead with **reliability + security + K8s scars, then AI**. Never reverse the order. The market is flooded with people who call LLM APIs; it is starving for people who run GPUs securely at 3 AM during an outage.
