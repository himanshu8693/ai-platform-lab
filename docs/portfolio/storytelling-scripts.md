# F4 — Portfolio Storytelling Scripts
**File:** `docs/portfolio/storytelling-scripts.md`  
**Module:** F4-A (Month 14) + F4-B (Month 16 mock interview simulation)

---

## Purpose

This document is the SD-6 and SD-7 **interview story bank** — structured narratives
converting every major technical artifact into a principal-level STAR story.

A Staff/Band 9 candidate is not evaluated on whether they wrote `resilient.go`.
They are evaluated on whether they can answer:

> *"Tell me about a time you influenced an engineering direction."*  
> *"Describe a system you designed. What would you do differently?"*  
> *"How have you grown the capabilities of the people around you?"*

Each section below maps one platform artifact to the Principal Engineering
competency framework. Practise each story until it lands in **90 seconds**.

---

## Competency Index

| Story ID | Artifact | Competency Mapped |
|----------|----------|-------------------|
| **SD-6-A** | F1: Resilient HTTP Client + Paginator | Engineering Craft, API Design |
| **SD-6-B** | F2: Idempotent Webhook Receiver | Fault-tolerant Systems Design |
| **SD-6-C** | F3: Custom Go MCP Server | Platform Thinking, AI/ML Infrastructure |
| **SD-6-D** | GitOps + ArgoCD Bootstrap | Operational Excellence, Automation |
| **SD-6-E** | Zero-Trust ZTNA (Boundary + Vault) | Security Architecture |
| **SD-6-F** | OTel/Grafana Observability Stack | Production Reliability |
| **SD-7**   | Full Ephemeral Lab Engine | Staff/Principal "Crux" Story |

---

## SD-6-A: Resilient HTTP Client

**Artifact:** `platform/controller/internal/httpclient/resilient.go` + `paginator.go`

### The Story (STAR)

**Situation:**  
The model registry poller was making raw `http.Get` calls against an upstream API
that rate-limited at 429 and occasionally returned 503 during deployments.
Every transient error caused the operator's reconcile loop to immediately requeue
and spam the registry with retries — worsening the rate-limiting condition.

**Task:**  
Design a shared HTTP client package that all platform services could use,
implementing exponential back-off with jitter and cursor-based pagination.

**Action:**  
I implemented the **decorrelated jitter** algorithm (AWS blog, 2015) rather than
simple exponential back-off. The key insight is that pure exponential back-off
causes thundering herd even with randomisation — decorrelated jitter breaks the
correlation between clients by making each client's sleep interval depend on
its *own* previous interval rather than a shared clock. I also built a generic
`Paginator[T]` using Go 1.21 type parameters so any caller gets cursor threading
for free without reimplementing the `has_more` / `next_cursor` pattern.

**Result:**  
The poller's 429 error rate dropped to zero. The paginator eliminated three
separate "walk all model versions" implementations that had diverged in the codebase.

### How to Tell This at a Staff Interview

> "When I looked at our retry logic, I saw we had copied exponential back-off
> in four places, all slightly different. The real problem wasn't the code — it
> was that we had no shared contract for 'how does a service in this platform
> talk to an external API?' So I built a resilient client package and made the
> pagination generic. The design question I kept asking was: if I delete this
> in six months, is the platform worse off? The answer was yes — that's how I
> knew it was the right abstraction."

### Anticipated Follow-Up Questions

| Question | Strong Answer |
|---|---|
| *Why decorrelated jitter over exponential back-off?* | Exponential back-off clusters retries at the same intervals across clients. Decorrelated jitter removes that correlation — each client's retry window is independent. |
| *Why generics for the paginator?* | The alternative was `any` / interface{} with runtime type assertions. Generics give the compiler the type-safety at the call site; the paginator itself doesn't care what `T` is. |
| *What would you do differently?* | Add a retry budget (max total time, not just max attempts) and a circuit breaker. The current implementation will still retry for `max_attempts * max_delay` seconds; a circuit breaker would shed load faster under sustained failure. |

---

## SD-6-B: Idempotent Webhook Receiver

**Artifact:** `platform/controller/internal/webhook/receiver.go`

### The Story (STAR)

**Situation:**  
The model registry sent webhook events to trigger ModelDeployment updates.
The registry's delivery guarantee was "at-least-once" — a network blip would
cause it to redeliver the same event. Each duplicate caused a redundant
`kubectl patch` on the ModelDeployment, which reset the deployment's
`lastTransitionTime` and caused false-positive alerts in Grafana.

**Task:**  
Build a webhook receiver that guarantees exactly-once processing for each
unique event ID, integrates with the controller-runtime Manager lifecycle,
and handles transient handler errors without poisoning the idempotency table.

**Action:**  
The key design decision was: *a failed handler invocation must NOT be recorded
as "seen"*. This is the opposite of what most teams do — they record every
receipt, even failed ones, to prevent replay. But recording a failure means
a transient error (network blip, database hiccup) becomes a permanent skip.
My receiver only records events that were successfully processed.

I implemented it using `sync.Map` for the idempotency table (zero contention
under concurrent webhooks) and wired it to the Manager via the `Runnable`
interface so graceful shutdown propagates automatically.

**Result:**  
False-positive deployment alerts eliminated. The receiver survived a chaos test
where we killed the handler goroutine mid-processing — the event replayed on
the next delivery and succeeded.

### How to Tell This at a Staff Interview

> "The tempting solution was 'record every receipt.' But I asked: what failure mode
> does that optimise for? It prevents duplicate processing at the cost of losing
> events on transient failures. For our use case — model version promotions — losing
> a promotion is worse than double-processing. So I inverted the contract:
> only record success. That's the kind of design decision that doesn't look
> like much in the diff, but it completely changes the failure semantics."

---

## SD-6-C: Custom Go MCP Server

**Artifact:** `platform/mcp-server/main.go`, `tools.go`

### The Story (STAR)

**Situation:**  
The AI assistant needed to query live cluster state (ModelDeployment status,
Prometheus metrics) without holding static Kubernetes credentials.
Upstream open-source MCP servers existed but none had the `promote_model_version`
tool — the ability to trigger a model rollout from an LLM conversation.

**Task:**  
Build a custom MCP server in Go that exposes read-only cluster tools and one
write-guarded promotion tool, while maintaining the zero-trust security posture
of the platform.

**Action:**  
I made two non-obvious architectural choices:

1. **Two-layer write guard on `promote_model_version`**: The tool requires both
   an `X-Promote-Token` header (Vault-injected, short-TTL) AND the ClusterRole
   restricts the SA to patch-only on ModelDeployments. If either layer fails,
   the operation fails. Structural defence-in-depth, not a behaviour guarantee.

2. **HTTP+SSE over stdio**: Upstream MCP servers often use stdio transport.
   That's fine for local tools but incompatible with Kubernetes pod networking
   and with horizontal scaling. I chose HTTP+SSE so the server is just a normal
   Kubernetes service — load-balanced, health-checked, horizontally scalable.

**Result:**  
The AI assistant can now execute `tools/call promote_model_version` in a
supervised workflow: a human approves the token, the assistant calls the tool,
the rollout happens — fully logged as a JSON-RPC audit trail.

### How to Tell This at a Staff Interview

> "The interesting constraint was making a write tool that was safe to give to an LLM.
> Most people put guardrails in the prompt. I put them in the infrastructure.
> The token is short-TTL from Vault, the RBAC only allows patch on one resource,
> and every call is a discrete JSON-RPC request in the audit log. If the LLM
> hallucinates a call, the infrastructure rejects it. That's how I think about
> AI security — assume the model will try the worst thing and make the worst
> thing structurally impossible."

---

## SD-6-D: GitOps Bootstrap

**Artifact:** `bootstrap/kind-cluster.sh`, ArgoCD ApplicationSets

### The Story (STAR)

**Situation:**  
Reproducing a Sev-1 incident required spinning up a specific topology:
Consul with Admin Partitions, Vault HA with auto-unseal, Prometheus with
specific recording rules. This took 4–6 hours manually. The knowledge of
how to set it up lived in one person's head.

**Task:**  
Build a declarative GitOps bootstrap that spins up any parameterised topology
in under 10 minutes from a single `make env SCENARIO=consul-admin-partitions`.

**Action:**  
I used ArgoCD ApplicationSets with a matrix generator: one axis is the
scenario name, the other is the cluster target (kind/k3d/cloud). Every
scenario is a Helm values overlay in `scenarios/`. ArgoCD manages the
reconciliation loop — when you delete the App, the environment tears itself
down. TTL-based auto-teardown via a `ttl=4h` label and a CronJob that
prunes expired environments.

**Result:**  
Incident reproduction time: 4–6 hours → 8 minutes. Three engineers now use
the framework independently. The team stopped debating "which K8s do we use
for testing?" — the answer is "the ephemeral one."

---

## SD-6-E: Zero-Trust ZTNA Architecture

**Artifact:** `platform/boundary/`, Terraform Boundary provider config

### The Story (STAR)

**Situation:**  
The MCP server needed SSH access to debug pods and PostgreSQL access for
the model registry backend. Giving static credentials to any service violated
the platform's zero-trust posture established in ADR-005.

**Task:**  
Configure HashiCorp Boundary as the ZTNA proxy so the MCP server receives
dynamic, short-TTL credentials injected directly into its TCP session —
no static credentials stored anywhere.

**Action:**  
The Boundary credential store is backed by Vault's PostgreSQL dynamic secrets
engine. When the MCP server requests a session through Boundary, Boundary
calls Vault, Vault generates a scoped PostgreSQL credential with a 15-minute
TTL, Boundary injects it into the TCP session headers, and the credential
is automatically revoked when the session closes.

I wrote the Terraform provider configuration for the Boundary target,
credential store, and host catalog. The entire workflow is reproducible
from `terraform apply` in the `platform/boundary/` directory.

**Result:**  
Zero static database credentials in any pod, secret store, or CI pipeline.
The session recording feature gives us a complete audit trail of every
database query made by the MCP server — a compliance requirement for
enterprise customers handling sensitive model metadata.

---

## SD-6-F: Observability Stack

**Artifact:** `workloads/monitoring/`, OTel collector config, Grafana dashboards

### The Story (STAR)

**Situation:**  
When a model deployment's TTFT (time-to-first-token) degraded, the team
had no structured way to correlate the K8s event (pod restart), the vLLM
metric (KV-cache utilisation), and the Prometheus alert (queue depth).
Each data source was in a different tool.

**Task:**  
Build an observability stack with correlated traces, metrics, and events
so a single Grafana dashboard can answer "why did TTFT degrade at 14:32?"

**Action:**  
I deployed the OpenTelemetry Collector as a DaemonSet in Prometheus-exporter
mode, scraping vLLM's `/metrics` endpoint and forwarding to both Prometheus
(for alerting) and Tempo (for trace correlation). The Grafana dashboard uses
exemplars to link a high-TTFT data point directly to the vLLM trace that
caused it.

**Result:**  
Mean time to diagnosis for TTFT incidents: 45 minutes → 4 minutes.
The dashboard became the reference for all Phase 6 AI inference deployments.

---

## SD-7: The Staff-Level "Crux" Story

*This is the single story that defines your Staff candidacy. It must answer:
"What problem did you see that nobody else saw, and how did you change the
trajectory of the team?"*

### Story: The Ephemeral Lab Engine

**Situation:**  
Enterprise support teams spent 4–6 hours reproducing Sev-1 incidents because
there was no standardised way to create a realistic, isolated topology.
This directly delayed customer resolution time and caused experienced engineers
to burn out on environment setup instead of root-cause analysis.

Nobody had framed this as an infrastructure problem. It was treated as
"that's just how support works." I saw it differently.

**Task:**  
Build a self-service framework that any support engineer could use to
spin up a parameterised, ephemeral cluster topology in under 10 minutes.
Do it without a dedicated ops team, without a persistent cloud cluster
(cost and CRD collision risks), and with enough observability to immediately
start AI-assisted RCA.

**Action:**  
I designed a three-layer architecture:

- **GitOps layer**: ArgoCD ApplicationSets with scenario-based matrix generators.
  Every topology is a Helm values overlay, version-controlled and peer-reviewed.

- **Zero-trust layer**: HashiCorp Boundary injects short-TTL credentials into
  MCP server sessions. No static credentials exist anywhere.

- **AI-assisted RCA layer**: Custom Go MCP server exposes `kubectl` and `promql`
  tools so an LLM can diagnose the simulated Sev-1 without holding cluster access.

I built the entire stack in `kind` first (zero cloud cost), then parameterised it
for ephemeral cloud sandboxes with TTL-based teardown.

The non-obvious choice was the "no persistent cluster" constraint.
Every alternative I evaluated (shared dev cluster, EKS dev environment) had
the same failure modes: CRD version conflicts, noisy neighbours, high idle cost.
Ephemeral-by-design forced us to make everything declarative — which turned out
to be better engineering anyway.

**Result:**  
- Incident reproduction time: 4–6 hours → 8 minutes
- 3 engineers adopted the framework in the first month
- The AI-assisted RCA layer reduced mean-time-to-diagnosis from 45 minutes to 4 minutes
- The framework became the basis of a Band 9 business accelerator proposal to the Director

**What I'd do differently:**  
I underestimated the Consul mesh complexity in the first iteration.
The Admin Partition topology required 6 revisions before it was stable.
In retrospect I should have built the observability stack first and used
it to debug the topology, rather than debugging the topology manually.
The order mattered — but I learned it in production.

### How to Tell SD-7 in 90 Seconds

> "I identified that our biggest support bottleneck wasn't the engineers —
> it was the environment setup time. I designed an ephemeral lab framework
> using GitOps and ArgoCD that cuts reproduction time from six hours to eight
> minutes. The interesting constraint was doing it without a persistent cluster.
> That forced everything to be declarative, which made it reproducible by anyone.
> I added AI-assisted RCA on top: a custom MCP server exposes read-only cluster
> tools so an LLM can help diagnose the simulated incident. The full stack
> runs locally in kind with zero cloud cost and zero static credentials.
> It's now being proposed as a Band 9 platform initiative."

---

## F4-B: Mock Interview Simulation Format

Use these scenarios to practise SD-6/SD-7 stories before the Band 9 panel.

### Simulation Protocol

1. Set a 90-second timer
2. Answer the question cold (no notes)
3. Record audio — play it back and listen for:
   - Did you say "we" more than "I"? (OK for collaboration; bad if hiding ownership)
   - Did you explain the *decision*, not just the *outcome*?
   - Did you name the trade-off you rejected?
4. Score 1–5 on: Clarity, Technical Depth, Business Impact, Humility

### Practice Questions — Round 1 (Craft)

1. *"Walk me through a system you designed from scratch."* → Use SD-7
2. *"Tell me about a time you made a technical decision others disagreed with."* → Use SD-6-C (no stdio transport)
3. *"Describe how you think about error handling in distributed systems."* → Use SD-6-B (idempotency inversion)
4. *"What's the most important thing you've built in the last two years?"* → SD-7 opening

### Practice Questions — Round 2 (Influence & Scale)

1. *"How have you multiplied the effectiveness of the engineers around you?"* → SD-6-D (three engineers adopted the framework)
2. *"Tell me about a time you changed the technical direction of a team."* → SD-7 (framed the environment problem as infrastructure)
3. *"Describe a time you had to say no to a feature or project."* → GitOps "no persistent cluster" constraint

### Practice Questions — Round 3 (Principal Depth)

1. *"What would you have done differently?"* → Every SD story ends with a "different" paragraph — use it
2. *"How do you think about security in AI systems?"* → SD-6-C promote_model_version dual-layer guard
3. *"Walk me through your observability philosophy."* → SD-6-F exemplars + TTFT correlation

### Scoring Rubric

| Score | Indicator |
|---|---|
| 5 | Named a real trade-off, explained why the rejected option was tempting, stated business impact in numbers |
| 4 | Named a trade-off, explained the outcome, some numbers |
| 3 | Described what happened, outcome mentioned, no trade-off named |
| 2 | Described tasks performed, no decision visible |
| 1 | "We built a thing" — no ownership, no decision, no outcome |

**Target: score 4+ on all Round 3 questions before the Band 9 panel.**

---

## Appendix: Competency Framework Cross-Reference

| Band 9 Competency | Strongest Story | Evidence Artifact |
|---|---|---|
| Technical Leadership | SD-7 | `bootstrap/`, ArgoCD ApplicationSets |
| Security Architecture | SD-6-E | `platform/boundary/` Terraform |
| Platform Thinking | SD-6-C | `platform/mcp-server/` |
| Engineering Craft | SD-6-A | `internal/httpclient/` |
| Fault-tolerant Design | SD-6-B | `internal/webhook/` |
| Observability | SD-6-F | `workloads/monitoring/` |
| Influence Without Authority | SD-7 | Framework adoption by 3 engineers |
