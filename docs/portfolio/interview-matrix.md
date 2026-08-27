# Target Company Interview Matrix
## Staff-Level AI Platform & FDE Interview Preparation

**Profile:** 12 years enterprise infra · Sev-1 incident command · CKA · CKS · Vault Ops Professional
**Target level:** Staff Engineer / Principal Engineer / Senior FDE
**Preparation start:** Month 14. Active interviewing: Month 16–18.

---

## Company Track Map

### Track 1 — AI Product Vendors (FDE & Integration Focus)

| Company | Role Title | Technical Focus | Your Differentiated Angle |
|---------|-----------|-----------------|--------------------------|
| **Anthropic** | Forward Deployed Engineer | Claude API integration into enterprise infra; security constraints; regulated industries | Zero-trust AI execution flow (ADR-008); air-gapped deployment (FDE-001); 12 years of enterprise regulated-client experience |
| **Databricks** | Staff Solutions Engineer / FDE | Lakehouse architecture; Unity Catalog; ML runtime deployment; customer VPC BYOC | vLLM + Vault + Boundary in isolated namespace; Terraform automation; zero static credentials; Session recording compliance |
| **OpenAI** | Customer Solutions Engineer | GPT-4/o1 API deployment; enterprise SSO; data residency; rate limit architecture | MCP + Context Forge governance layer; IBM watsonx alignment; FDE air-gap bootstrap; 5-minute VPC story |
| **Scale AI** | Forward Deployed Engineer | RLHF pipeline deployment; data annotation tooling; customer data security | Boundary session recording = annotation session audit; Vault dynamic creds = no standing access to customer data |
| **Palantir** | Deployment Strategist / FDE | Gotham/Foundry/AIP deployment in air-gapped DoD/intel environments; STIG compliance | FDE-001 air-gap scenario; LDAP IdP integration; Transit seal for offline Vault; immutable Boundary recording |

### Track 2 — Infrastructure & GCC Leaders (Platform & Scale Focus)

| Company | Role Title | Technical Focus | Your Differentiated Angle |
|---------|-----------|-----------------|--------------------------|
| **CoreWeave** | Staff Platform Engineer | GPU cloud K8s; bare-metal provisioning; multi-tenant isolation; DCGM monitoring | KEDA dual-trigger GPU autoscaling; Kueue multi-tenant guarantees; XID cordon automation; DCGM exporter |
| **Uber** | Senior/Staff Platform Engineer | Internal platform; developer velocity; ML platform; cost optimization | IDP architecture (App-of-Apps + Topology Launcher); GPU cost attribution dashboard; KEDA idle reduction |
| **Atlassian** | Staff SRE / Platform Engineer | Reliability engineering; multi-region Kubernetes; incident management | 12 years Sev-1 MTTR reduction; postmortem authorship; automated runbook execution; KEDA self-healing |
| **Lambda Labs** | Senior Platform Engineer | GPU cloud; ML serving infrastructure; customer isolation | vLLM serving architecture; Kueue multi-tenant; dynamic credential injection; ADR decision process |

---

## System Design Questions: 5 Deep Dives

### SD-1: "Design a multi-tenant GPU inference platform that guarantees SLO isolation between teams while minimizing idle GPU cost."

**What they are testing:** Kueue/KEDA depth, cost engineering, SLO definitions, failure isolation.

**Your answer structure (target: 12 minutes):**

```
1. Define the tenancy model (2 min)
   → Three tiers: guaranteed-tier (floor QPS, dedicated GPU quota via Kueue ClusterQueue),
     burst-tier (can borrow from guaranteed if headroom exists), best-effort (preemptible)
   → Each team gets a LocalQueue bound to a ClusterQueue with resourceFlavorRef
   → WorkloadPriorityClass: platform-critical > production > development

2. Autoscaling architecture (3 min)
   → KEDA ScaledObject: TWO triggers, not one
     Trigger 1: vllm_num_requests_waiting > 5 (queue depth)
     Trigger 2: vllm_gpu_cache_usage_perc > 0.75 (KV-cache saturation)
   → Why two triggers: queue depth alone misses KV-cache pressure from long-context requests
     that don't queue but still saturate memory. This is the key insight from PM-001.
   → cooldownPeriod: 60s (prevent thrashing); minReplicaCount: 1 (keep one warm)

3. SLO definition and enforcement (3 min)
   → TTFT p99 < 3s for guaranteed tier, < 10s for burst tier
   → Multi-window burn-rate alert: 14× error budget for 1h window, 6× for 6h window
   → AnalysisTemplate: if TTFT p99 > 3s for 3 consecutive minutes → Argo Rollouts auto-rollback
   → Error budget policy: no deployments during burn events (ArgoCD sync gate)

4. Cost optimization mechanics (2 min)
   → Scale-to-zero for dev workloads overnight (KEDA minReplicaCount: 0 with 30s cold-start SLO)
   → GPU cost attribution: DCGM per-pod metrics → Grafana dashboard → OpenCost GPU allocation
   → Spot instance strategy: guaranteed-tier on on-demand; burst-tier on spot with checkpoint/resume

5. Failure isolation proof (2 min)
   → Kueue: team-a burst cannot consume team-b's guaranteed quota floor
   → NetworkPolicy: per-team namespace default-deny; explicit ingress/egress only
   → Demonstrate: inject CPU pressure into team-a namespace → team-b SLO unaffected
```

**Key numbers to have memorized:**
- Kueue nominal quota floor: 2 CPUs, 8Gi per team minimum
- KEDA dual-trigger thresholds: queue > 5, KV-cache > 75%
- TTFT p99 SLO: <3s guaranteed, <10s burst
- Cost reduction claim: ~40% GPU idle reduction vs single-trigger scaling

---

### SD-2: "Design the security architecture for an AI agent that can query production Kubernetes and Prometheus without creating a security incident."

**What they are testing:** MCP depth, zero-trust understanding, blast-radius thinking, ADR-006/007 knowledge.

**Your answer structure (target: 10 minutes):**

```
1. The wrong answer — and why it's wrong (1 min)
   → "Give the LLM pod a ServiceAccount with get/list/watch"
   → Wrong because: SA permissions travel with the pod; if compromised (prompt injection
     or container escape), attacker has direct K8s API access with no revocation path.
   → The MCP server is the structural isolation layer — the LLM never holds API credentials.

2. The MCP architecture (4 min)
   → ai-assistant pod: NO K8s RBAC. Zero.
   → mcp-kubernetes pod: read-only ClusterRole (get/list/watch only — no exec, no portforward)
   → mcp-prometheus pod: read-only Prometheus bearer token via Vault Agent sidecar
   → Separation: the LLM calls tools; the MCP server calls APIs. If LLM is compromised,
     attacker can only call tools that are registered — no raw API access.

3. Context Forge as governance layer (3 min)
   → Virtual Server tool whitelist: only 6 tools visible to LLM
     (get_pod, list_pods, get_deployment, get_events, execute_query, execute_range_query)
   → Any upstream MCP server update adding a new write tool = invisible to LLM until
     explicitly added to Virtual Server. This is the blast-radius containment mechanism.
   → JWT auth: Vault-issued 55-min bearer token, auto-rotated by Vault Agent template watch
   → OTel trace per tool call: full audit trail in Grafana Tempo

4. Defence in depth summary (2 min)
   → Layer 1: MCP server doesn't register write tools (tool registry)
   → Layer 2: RBAC blocks write operations even if somehow called (K8s API)
   → Layer 3: Context Forge Virtual Server blocks undeclared tools (L7 whitelist)
   → Layer 4: NetworkPolicy blocks ai-assistant from reaching mcp-* directly (network layer)
   → Layer 5: Consul intention blocks non-Context-Forge traffic (mesh layer)
   → "Five independent layers. Breaking one doesn't break the others."
```

**The interviewer will ask:** "What if Context Forge itself is compromised?"
**Your answer:** "Context Forge is the governance boundary, not the auth boundary.
Even if Context Forge is compromised, the MCP servers still enforce their own RBAC.
The mcp-kubernetes ServiceAccount can only get/list/watch — no matter what Context
Forge tells the K8s API server."

---

### SD-3: "You're deploying an LLM inference platform for a financial services client who requires zero standing credentials and a complete audit trail. Walk me through your architecture."

**What they are testing:** ADR-008 depth, compliance understanding, FDE credibility.

**Your answer structure (target: 8 minutes):**

```
1. The compliance requirements (1 min)
   → SOC-2 Type II CC6.1 (access control), CC6.6 (logical access removal), CC6.8 (monitoring)
   → No standing credentials = every DB/API credential is ephemeral, issued at request time
   → Complete audit trail = every access event recorded, immutable, reviewable

2. The credential chain (4 min)
   → Draw the ADR-008 diagram on a whiteboard: 7 steps
   → Key insight: "The MCP server never sees a password. Boundary injects it transparently
     into the proxied TCP stream. The password exists for the duration of the session only."
   → Vault database secrets engine: CREATE ROLE "v-mcp-a1b2c3d4" VALID UNTIL +TTL
   → Session end → Boundary calls Vault /sys/leases/revoke → DROP ROLE immediately

3. The audit trail (2 min)
   → Boundary session recording: byte-level stream of every client→target interaction
   → Immutable storage: S3 Object Lock (WORM) or MinIO with retention policy
   → Three correlated audit logs: Context Forge OTel spans + Boundary session metadata + Vault lease log
   → "Show a CISO any session by session_id — they can replay the exact SQL queries the AI agent ran"

4. The 30-second proof (1 min)
   → vault read database/creds/mcp-server-role → shows fresh credential, TTL
   → vault lease revoke <id> → credential destroyed
   → psql -U v-mcp-a1b2c3d4 → "role does not exist"
   → "This is the audit evidence the CISO puts in the SOC-2 package."
```

---

### SD-4: "Design a GitOps-driven Ephemeral Lab Engine that allows a support team to reproduce any Sev-1 topology in under 10 minutes."

**What they are testing:** ArgoCD depth, ApplicationSet Git generator understanding, topology-as-code thinking.

**Your answer structure (target: 10 minutes):**

```
1. Why ephemeral matters (1 min)
   → The alternative is a shared 24/7 cluster: CRD collisions between topologies,
     "noisy neighbour" state pollution, cost accumulation, no isolation guarantee.
   → Ephemeral = every engineer gets a fresh, isolated, parameterized environment.
     The environment self-destructs after TTL. No cleanup required.

2. The Git generator (3 min)
   → ArgoCD ApplicationSet with Git directory generator, not a static list
   → Every directory under topologies/ is a deployable topology
   → Adding a new topology = add a directory + topology.yaml. ArgoCD picks it up automatically.
   → topology.yaml has: helmValues (parameterization), ttl (auto-teardown), scenarios (fault list)

3. The TTL teardown loop (2 min)
   → scripts/ttl-teardown.sh: PID-tracked background process
   → Annotates namespace with fde.scenario/expires-at timestamp
   → After TTL: kubectl delete namespace <topology> + kind delete cluster (if dedicated)
   → make ttl-schedule TTL=7200 → guaranteed cost ceiling per topology invocation

4. Fault injection (2 min)
   → scenarios/ directory per topology: YAML patches applied on demand
   → raft-leader-kill.yaml: memory limit 1Mi → OOMKill → raft leader re-election
   → ap-network-split.yaml: NetworkPolicy blocking UDP 8301 gossip
   → AI-readable labels on each scenario: scenario.fde/what, scenario.fde/expected-symptom
   → These labels are what the MCP agent reads to diagnose the injected fault

5. The 8-minute demo (2 min)
   → make up BACKEND=kind TOPOLOGY=consul-admin-partition TTL=2h
   → make scenario SCENARIO=ap-network-split
   → make agent-rca   (triggers MCP tool call against the live failing topology)
   → make teardown
   → "Four commands. Zero manual kubectl. Self-documenting via GitOps state."
```

---

### SD-5: "How would you migrate a team's GPU workload from an on-premise bare-metal cluster to a cloud GPU provider without service interruption?"

**What they are testing:** Practical platform engineering, state management, Vault/secrets portability.

**Your answer structure (target: 10 minutes):**

```
1. Assessment phase (2 min)
   → Inventory: GPU type, driver version, DCGM exporter version, model storage location
   → Dependencies: KV-cache storage, Vault secret paths, ArgoCD app source URLs
   → SLO baseline: TTFT p99 on current hardware (benchmark harness output)

2. Vault migration strategy (3 min)
   → Vault-to-Vault migration: vault operator migrate (not a dump/restore)
   → Critical: Vault KMS/seal config changes between environments
   → Secret path parity: same KV paths, same policy names, same K8s auth roles
   → Test: `vault kv get secret/ai-platform/hf-token` must work identically in new cluster
   → Boundary: re-provision targets pointing to new cluster hosts; sessions are stateless (no migration)

3. Traffic cutover (3 min)
   → GitOps-based: update ArgoCD Application source to new cluster's ingress
   → Argo Rollouts canary: 10% → 50% → 100% with TTFT p99 AnalysisTemplate gate
   → KEDA replication: copy ScaledObject + TriggerAuthentication to new cluster
   → Kueue: ClusterQueue definitions are cluster-local, not portable — re-create from Git

4. Rollback plan (2 min)
   → ArgoCD: git revert the ingress change → traffic returns to old cluster in <60s
   → Vault: old cluster Vault remains running until canary reaches 100% + 24h soak
   → "We never cut the old cluster off while any traffic is still on the canary."
```

---

## Behavioral Questions: STAR Format (Sev-1 to Staff Narrative)

### BQ-1: "Tell me about the most complex distributed systems incident you've diagnosed."

**STAR Answer:**

> **Situation:** Enterprise client running a 3-node Vault HA cluster in Kubernetes.
> At 02:30, the primary Vault node failed — PagerDuty triggered. All application pods were
> failing with `connection refused` on port 8200. The client's on-call engineer had no
> Vault HA expertise and was about to restart all three pods (which would have caused a
> full cluster reseal).
>
> **Task:** I was on the escalation call within 8 minutes. My job: diagnose root cause,
> stop the wrong remediation, restore service, and produce a postmortem that eliminated
> the recurrence.
>
> **Action:**
> 1. First question before touching anything: "What changed in the last 4 hours?"
>    → Answer: cert-manager renewed the Vault TLS cert 3 hours ago.
> 2. Checked Vault audit logs: `x509: certificate signed by unknown authority` errors
>    starting exactly at cert renewal time.
> 3. Root cause: cert-manager issued a new cert but the Vault HA cluster's peer-to-peer
>    communication was still using the old cert's fingerprint in its raft peer config.
>    Leader elected successfully, but standby nodes couldn't rejoin → quorum lost.
> 4. Fix: `vault operator raft list-peers` confirmed the standby nodes were in
>    `voter` state but disconnected. Updated the raft peer configuration with the new
>    cert fingerprint. Standby nodes rejoined quorum within 90 seconds.
> 5. Prevention: automated Raft snapshot cronjob before every cert-manager renewal +
>    Prometheus alert on `vault_raft_peers` count dropping below 3.
>
> **Result:** Service restored in 23 minutes from my joining the call. MTTR reduced from
> the org average of 4+ hours to 23 minutes. The postmortem drove a platform-wide policy:
> Vault cert renewal is now tested in staging with a simulated raft-leader-kill scenario
> before applying to production. I built exactly that simulation as a topology in my lab
> (`topologies/vault-ha-raft/scenarios/raft-leader-kill.yaml`).
>
> **Staff-level signal:** The difference between L2 support and Staff-level engineering
> was not the debugging skill. It was knowing to ask "what changed" before touching
> anything, and converting a one-off incident into a systematic prevention mechanism
> that protects every future cert renewal.

---

### BQ-2: "Describe a time you influenced a technical decision you disagreed with."

**STAR Answer:**

> **Situation:** My team was planning to give the AI assistant pod a Kubernetes
> ServiceAccount with `get/list/watch` on all resources — the fastest path to
> making it work. I disagreed with this design on security grounds.
>
> **Task:** I needed to change the technical direction without being obstructionist,
> because the timeline pressure was real and my objection needed to come with an alternative.
>
> **Action:**
> 1. I wrote a one-page threat model: "If the ai-assistant pod is compromised via
>    prompt injection, the attacker has direct K8s API access. There is no revocation
>    mechanism short of deleting the ServiceAccount, which requires human intervention."
> 2. I presented the MCP architecture as the alternative: the LLM calls tools; the MCP
>    server (with SA permissions) calls APIs. The LLM has zero SA permissions.
> 3. I estimated the timeline delta: 2 extra weeks to wire up the MCP servers, vs the
>    SA approach which was 2 days. I acknowledged the trade-off openly.
> 4. I built a proof-of-concept overnight: mcp-kubernetes + mcp-prometheus deployed,
>    end-to-end tool call working in 18 hours.
> 5. The proof-of-concept demonstrated that the 2-week estimate was wrong — it was
>    closer to 5 days once the approach was proven.
>
> **Result:** The team adopted the MCP architecture. The decision is documented in
> ADR-006, which I wrote to ensure future team members understand not just what was
> decided but why the SA approach was considered and rejected.
>
> **Staff-level signal:** ADRs are how Staff engineers make their reasoning auditable.
> A good ADR doesn't just document the decision — it documents the alternatives
> considered and why they were rejected. That's what makes it useful 6 months later
> when someone asks "why didn't we just give it a ServiceAccount?"

---

### BQ-3: "How do you handle being the senior person on an escalation call where you don't know the answer?"

**STAR Answer:**

> **Situation:** A client's Vault cluster was exhibiting intermittent authentication
> failures on their Kubernetes auth method. I had been paged as the senior Vault SME.
> After 20 minutes of log analysis, I didn't have a root cause. The client's CISO was
> on the call watching.
>
> **Task:** Lead the incident to resolution without pretending to know something I didn't.
>
> **Action:**
> 1. At the 20-minute mark, I explicitly named the situation: "I don't have root cause
>    yet. Here is what I've ruled out, here is what I'm investigating next, and here is
>    my confidence level on the current hypothesis."
> 2. Named the hypothesis: "My working theory is clock skew between the K8s node and
>    Vault causing JWT validation failures. I want 2 minutes to check node time sync."
> 3. Checked: `kubectl exec -n vault vault-0 -- date` vs node NTP. Found: 4-second skew.
>    Vault's default JWT `nbf` tolerance is 2 seconds. 4-second skew = intermittent failures.
> 4. Fix: `chronyc tracking` on the affected node confirmed NTP sync failure. Restarted
>    chronyd on the node. Failures stopped within 3 minutes.
> 5. Wrote the postmortem the same day: root cause, timeline, NTP monitoring alert added.
>
> **Result:** Client CISO commented explicitly that the way the incident was narrated —
> "here is what I know, here is what I don't know, here is my next hypothesis" —
> was more confidence-inspiring than engineers who claim certainty they don't have.
>
> **Staff-level signal:** Calm narration under pressure is a leadership skill, not just
> a technical one. The CISO isn't evaluating your Vault knowledge — they're evaluating
> whether you will make the right call under uncertainty. Naming what you don't know
> is a trust signal, not a weakness signal.

---

## The 60-Second LinkedIn Message (Cold Outreach to FDE Hiring Managers)

Use this template when reaching out to FDE engineering managers at target companies.
Do not modify — the specificity is what makes it not get deleted.

```
Hi [Name],

I'm a Senior Infrastructure Engineer (12 yrs, IBM, HashiCorp Vault/Consul/K8s)
transitioning into Forward Deployed Engineering.

I built a portable Ephemeral Lab Engine that deploys a complete vLLM + Vault +
Boundary stack into an air-gapped Kubernetes namespace in under 5 minutes —
no internet access, no static credentials, full session recording from minute 1.

The zero-trust credential flow I implemented (AI Agent → Context Forge → MCP
Server → Boundary → Vault → dynamic PostgreSQL creds) maps directly to the
compliance constraints I hear about at enterprise AI deployments.

5-minute Loom demo: [link]
GitHub (make up from fresh clone in <10 min): [link]

Would you have 20 minutes to discuss what client deployment challenges look like
at [Company] and whether my background is relevant?

[Name]
```
