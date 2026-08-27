# Architecture — AI Platform Lab (Ephemeral Lab Engine)

C4 model (Context → Container → Component → Code) for the AI inference platform.

---

## Level 1 — System Context

```
┌─────────────────────────────────────────────────────────────┐
│                       External Actors                       │
│                                                             │
│   Developer ──▶ GitHub (push/PR) ──▶ CI/CD Gate            │
│                                          │                  │
│   Data Scientist ──▶ kubectl / UI        │                  │
│                                          ▼                  │
│                               [AI Platform Lab]             │
│                                                             │
│   End User ──▶ HTTPS ──▶ ingress-nginx ──▶ Inference Proxy  │
└─────────────────────────────────────────────────────────────┘
```

**Key relationships**:
- GitHub Actions CI gate blocks merges with failing security or quality checks
- Developers interact via kubectl, ArgoCD UI, or Grafana dashboards
- End users reach inference endpoints via TLS-terminated ingress

---

## Level 2 — Container Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (Kind, 3 nodes)                                 │
│                                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────────┐  │
│  │  ArgoCD     │  │  ModelDeploy │  │  Inference Namespace        │  │
│  │  Namespace  │  │  Operator    │  │  ┌──────────────────────┐  │  │
│  │             │  │  (Go)        │  │  │  vLLM / Ollama Pod   │  │  │
│  │  app-of-apps│─▶│              │─▶│  │  + Vault sidecar     │  │  │
│  │  sync loop  │  │  Reconciles  │  │  └──────────────────────┘  │  │
│  └─────────────┘  │  ModelDeploy │  │  ┌──────────────────────┐  │  │
│                   │  CRD         │  │  │  inference-proxy      │  │  │
│                   └──────────────┘  │  │  (OpenAI-compat)      │  │  │
│  ┌─────────────┐                    │  └──────────────────────┘  │  │
│  │  Vault      │                    └────────────────────────────┘  │
│  │  Namespace  │  ┌──────────────┐  ┌────────────────────────────┐  │
│  │             │  │  KEDA        │  │  Monitoring Namespace       │  │
│  │  KV-v2      │  │  ScaledObject│  │  ┌──────────────────────┐  │  │
│  │  HF tokens  │  │  waiting_req │  │  │  Prometheus          │  │  │
│  └─────────────┘  └──────────────┘  │  │  + mock-dcgm         │  │  │
│                                     │  └──────────────────────┘  │  │
│  ┌─────────────┐                    │  ┌──────────────────────┐  │  │
│  │  cert-mgr   │                    │  │  Grafana             │  │  │
│  │  TLS certs  │                    │  └──────────────────────┘  │  │
│  └─────────────┘                    └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Level 3 — Component: ModelDeployment Operator

```
platform/controller/main.go

  ┌─────────────────────────────────────────────────────────────┐
  │  main()                                                     │
  │    ├── Register scheme (ModelDeployment CRD types)         │
  │    ├── Create controller-runtime Manager                   │
  │    │     ├── LeaderElection (modeldeployment.platform.ai)  │
  │    │     ├── HealthProbe :8081                             │
  │    │     └── MetricsAddr :8080                             │
  │    └── SetupWithManager(mgr)                               │
  │          ├── For(&ModelDeployment{})                       │
  │          ├── Owns(&appsv1.Deployment{})                    │
  │          ├── Owns(&corev1.Service{})                       │
  │          └── WithEventFilter(GenerationChangedPredicate)   │
  │                                                             │
  │  Reconcile(ctx, req)                                        │
  │    ├── Get ModelDeployment                                  │
  │    ├── Deletion gate (finalizer lifecycle)                  │
  │    │     └── cleanup owned resources → remove finalizer    │
  │    ├── ensureFinalizer()                                    │
  │    ├── reconcileDeployment()                                │
  │    │     ├── imageForRuntime() → vllm/ollama/triton image  │
  │    │     ├── constructDeployment()                          │
  │    │     └── CreateOrPatch (server-side apply)             │
  │    ├── reconcileService()                                   │
  │    │     └── CreateOrPatch ClusterIP service               │
  │    ├── syncStatus()                                         │
  │    │     ├── Phase: Pending/Running/Failed/Scaling         │
  │    │     ├── ReadyReplicas from Deployment status          │
  │    │     └── UpdateStatus subresource                      │
  │    └── RequeueAfter(30s)                                    │
  └─────────────────────────────────────────────────────────────┘
```

**Reconcile invariants**:
- Level-triggered: every reconcile is idempotent; no event-sourcing
- Owner references: Deployment and Service owned by ModelDeployment → GC cascade
- Status subresource: Spec and Status updated independently (no race)
- Finalizer: ensures cleanup runs even on forced deletion

---

## Level 3 — Component: Observability Stack

```
platform/observability/

  mock-dcgm-exporter.py
    ├── 24 DCGM Gauges  (GPU util, VRAM, temp, power, PCIe, NVLink, ECC/XID)
    ├── 8 vLLM Gauges   (cache util, queue depth, throughput)
    └── 3 vLLM Histograms (TTFT, TPOT, E2E latency)
          └── Buckets tuned for histogram_quantile(0.99) SLO PromQL

  prometheus/custom-rules.yaml
    ├── Alert: HighGPUTemperature    (>80°C for 5m)
    ├── Alert: KVCacheSaturation     (>90% for 2m)
    ├── Alert: InferenceQueueDepth   (waiting_requests>10 for 3m)
    ├── Alert: TTFTp99SLOBreach      (p99 TTFT >1s for 5m)
    └── Alert: XIDErrorDetected      (xid_errors > 0)
```

---

## Level 3 — Component: Zero-Trust Network

```
workloads/inference/networkpolicy.yaml  (7 policies)

  Policy 1: default-deny-ingress        deny all ingress to inference ns
  Policy 2: default-deny-egress         deny all egress from inference ns
  Policy 3: allow-dns-egress            UDP/TCP 53 to kube-dns only
  Policy 4: allow-model-server-ingress  8000/8080 from inference-proxy only
  Policy 5: allow-proxy-egress          proxy → model-server 8000/8080
  Policy 6: allow-nginx-to-proxy        ingress-nginx ns → proxy 8080
  Policy 7: allow-prometheus-scrape     monitoring ns → 9400/8080/2112
```

---

## Level 4 — Data Flow: Inference Request

```
Client
  │  HTTPS (TLS terminated by cert-manager cert)
  ▼
ingress-nginx (ingress-nginx namespace)
  │  NetworkPolicy 6: nginx → proxy allowed
  ▼
inference-proxy (inference namespace)
  │  OpenAI-compatible /v1/completions
  │  NetworkPolicy 5: proxy → model-server allowed
  ▼
vLLM / Ollama pod (inference namespace)
  │  HuggingFace token read from /vault/secrets/hf-token
  │  (injected by Vault Agent init container at pod start)
  ▼
Model weights (pulled from HuggingFace Hub on first start)
```

---

## Security Posture

| Layer | Control | Implementation |
|-------|---------|----------------|
| Supply chain | Image signing | Cosign sign on every main merge |
| Admission | Signed-image enforcement | Kyverno ClusterPolicy |
| Runtime | Syscall monitoring | Falco eBPF rules (inference-specific) |
| Network | Zero-trust | 7-policy NetworkPolicy suite |
| Secrets | No env-var injection | Vault Agent sidecar + tmpfs volume |
| Workload | Non-root, read-only FS | securityContext in all pod specs |
| RBAC | Least-privilege | Operator SA: get/list/watch/patch deployments only |

---

---

## Level 1 — Ephemeral Lab Engine: Topology Lifecycle

```
Developer / Support Engineer
  │
  │  git push  topologies/consul-ap-incident-42/
  │             (copies consul-admin-partition template,
  │              sets ttl-seconds annotation: 7200)
  ▼
GitHub → ArgoCD (topology-launcher ApplicationSet, Git generator)
  │
  │  ArgoCD detects new directory → creates Application
  │  "topology-consul-ap-incident-42"
  │  prune: true / selfHeal: true
  ▼
Kubernetes cluster
  │  Namespace: topology-consul-ap-incident-42 created
  │  Consul + test services deployed via Helm
  │  TTL annotation: 7200s
  ▼
Engineer injects fault:
  bash scripts/scenario-inject.sh consul-ap-incident-42 ap-network-split
  │
  ▼
AI RCA Agent (via MCP → Context Forge → mcp-kubernetes + mcp-prometheus)
  Queries: pod events, NetworkPolicies, Consul member health, Prometheus metrics
  Returns: structured root-cause summary with remediation steps
  ▼
Engineer remediates or tears down:
  make remediate TOPOLOGY=consul-ap-incident-42 SCENARIO=ap-network-split
  OR
  git rm -r topologies/consul-ap-incident-42 && git push
  → ArgoCD prune deletes all resources + namespace
  → Zero manual cleanup
  ▼
TTL auto-teardown fires after 7200s regardless:
  scripts/ttl-teardown.sh → kind/k3d delete cluster
```

---

## Level 2 — Full Stack: Topology + Platform Services

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (kind/k3d, 3 nodes)                                  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Platform Services (persistent, not ephemeral)                     │  │
│  │                                                                     │  │
│  │  argocd/     vault/     consul/     monitoring/     keda/           │  │
│  │  ArgoCD       Vault      Consul     Prometheus       KEDA           │  │
│  │  GitOps mgr   dev-mode   service    Grafana          autoscaler     │  │
│  │               + Boundary mesh       OTel Collector                  │  │
│  │               Boundary  + PKI       (Context Forge                  │  │
│  │               dev server                traces)                     │  │
│  └─────────────────────────┬──────────────────────────────────────────┘  │
│                             │ ArgoCD topology-launcher ApplicationSet     │
│                             │ Git generator: topologies/*                 │
│                             ▼                                             │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Ephemeral Topologies (created and pruned by ArgoCD)               │  │
│  │                                                                     │  │
│  │  topology-consul-admin-partition/   topology-vault-ha-raft/        │  │
│  │  ┌────────────────────────┐         ┌────────────────────────┐     │  │
│  │  │ consul-server          │         │ vault-0 (active)       │     │  │
│  │  │ service-a (part-a)     │         │ vault-1 (standby)      │     │  │
│  │  │ service-b (part-b)     │         │ vault-2 (standby)      │     │  │
│  │  │ [active fault label]   │         │ vault-test-client      │     │  │
│  │  └────────────────────────┘         └────────────────────────┘     │  │
│  │                                                                     │  │
│  │  TTL: 7200s per topology  •  Namespaced isolation                  │  │
│  │  Fault scenarios injected via scripts/scenario-inject.sh           │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  inference/ — AI RCA Stack                                         │  │
│  │  ai-assistant → context-forge → mcp-kubernetes + mcp-prometheus    │  │
│  │  (JWT auth via Vault Agent • OTel traces → monitoring/otel-stack)  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Level 3 — Zero-Trust Credential Flow (Boundary + Vault)

```
AI Agent CLI / MCP Server
  │
  │  1. boundary authenticate password → session token
  ▼
Boundary Controller (dev mode, localhost:9200)
  │
  │  2. boundary authorize-session mcp-postgres-target
  │     Boundary calls: GET vault:8200/v1/database/creds/mcp-server-role
  │     Vault issues: { username: "v-mcp-a1b2c3d4", password: "Xy9...", lease_id: "..." }
  ▼
Boundary Worker (TCP proxy)
  │  3. Credential injected into session — client never sees raw password
  │  4. Proxy: AI Agent:random-port → postgres.inference.svc:5432
  ▼
PostgreSQL pod
  │  5. Dynamic user "v-mcp-a1b2c3d4" authenticates
  ▼
Session ends:
  6. Boundary signals Vault: revoke lease
  7. Vault executes: DROP ROLE "v-mcp-a1b2c3d4"
  8. Dynamic user ceases to exist in PostgreSQL
```

---

## M4 Max Simulation Notes

This lab runs on Apple Silicon without NVIDIA GPUs. Key adaptations:

1. **GPU metrics**: `mock-dcgm-exporter.py` emits production-identical DCGM field names so dashboards and alerts are fully exercisable
2. **Inference runtime**: Ollama with `llama3.2:3b` via Apple MPS (Metal Performance Shaders) — legitimate single-node inference, ~30 tokens/s
3. **MPS as Kubernetes resource**: `apple.com/mps` is NOT a Kubernetes extended resource. Resource quotas use CPU/memory only. See [ADR-003](docs/adr/ADR-003-mps-simulation-approach.md)
4. **Triton ARM64**: `nvcr.io/nvidia/tritonserver` has no ARM64 image — requires `--platform linux/amd64` for Rosetta 2 emulation (~15–30% overhead); benchmarks not portable to production
5. **Falco driver**: OrbStack's Linux VM kernel requires matching headers for `driver-loader` init container — see `security/falco-rules/inference-workload-rules.yaml` header comment
