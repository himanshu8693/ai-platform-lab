# Dual-Role Portfolio & GitHub Strategy
## Appendix G Extension: Platform Engineer + FDE Track

**Purpose:** Two completely different hiring personas read your GitHub README.
This document gives you the exact text for each track and the Loom video script
that demonstrates both in a single 5-minute recording.

---

## The Fundamental Positioning Rule

> Lead with **reliability + security + operational scars**, then AI.
> Never reverse this order.
>
> Platform Engineer track: "I make AI run reliably at scale."
> FDE track: "I make AI deployable in any client environment in under 5 minutes."
>
> Both are the same GitHub repo. The README has two sections — one for each reader.
> The first 6 lines of the README determine which reader continues.

---

## Track A — Platform Engineer README Pitch

**Target readers:** Engineering managers at CoreWeave, Uber, Atlassian, IBM RHOAI, Lambda Labs.
**What they scan for:** Kueue/KEDA for cost, GitOps for velocity, security posture, operator authorship.

```markdown
# AI Platform Lab — Production-Grade LLM Inference Platform

> Senior Infrastructure Engineer building a zero-trust, GitOps-managed AI inference
> platform on Kubernetes. 12 years of enterprise Sev-1 RCA depth applied to
> GPU fleet operations, multi-tenant workload isolation, and AI agent security.

## What This Platform Does

- **Serves** LLM inference via vLLM/Ollama with KEDA autoscaling on queue depth
  AND KV-cache saturation (dual-trigger pattern) — reduces GPU idle cost by ~40%
  versus single-trigger scaling.
- **Isolates** multi-tenant workloads via Kueue ClusterQueue floor guarantees —
  team-a's burst load cannot starve team-b's guaranteed allocation.
- **Secures** the entire stack via a 5-layer zero-trust model: Consul mTLS →
  Vault dynamic credentials → Kyverno admission → Falco runtime rules →
  HashiCorp Boundary session recording.
- **Delivers** AI-assisted RCA: an LLM agent queries live Prometheus and Kubernetes
  metrics via MCP + IBM Context Forge, with every tool call traceable in Grafana Tempo.
- **Boots from scratch** in under 10 minutes: `make up` from a fresh clone.

## Developer Velocity Proof Points

| Metric | Before | After |
|--------|--------|-------|
| Time to reproduce a Sev-1 topology | 4–6 hours (manual) | 8 minutes (`make topology`) |
| GPU idle time during off-peak | ~60% | ~15% (KEDA dual-trigger) |
| Mean time to AI-assisted RCA | N/A | <3 minutes via MCP agent |
| Supply-chain policy violations at admission | Manual review | 0 (Kyverno blocks on PR) |

## Key Technical Components

- **GitOps engine:** ArgoCD App-of-Apps + ApplicationSet Git generator
  → topologies are declarative YAML, not imperative scripts
- **Autoscaling:** KEDA dual trigger (queue depth + KV-cache saturation)
  → cost-optimised horizontal scaling without GPU over-provisioning
- **Multi-tenancy:** Kueue ClusterQueue + LocalQueues + WorkloadPriorityClass
  → hard resource floor per team, burst borrowing when headroom available
- **Zero-trust:** Vault Agent sidecar injection → no secrets in manifests ever
- **Operator:** Custom ModelDeployment CRD (kubebuilder) → Go reconciler
  creates Deployment + Service from a single 15-line CR
- **AI governance:** IBM Context Forge Virtual Server tool whitelist →
  blast-radius containment identical to IBM watsonx.governance AI Factsheets

## IDP Capability Map

This platform is an Internal Developer Platform (IDP) for AI teams:

| Developer task | Self-service mechanism |
|---|---|
| Spawn a Consul Admin Partition topology | `make topology TOPOLOGY=consul-admin-partition TTL=2h` |
| Inject a Raft leader failure fault | `make scenario TOPOLOGY=vault-ha-raft SCENARIO=raft-leader-kill` |
| Run inference load test | `make benchmark CONCURRENCY=10 REQUESTS=100` |
| Check MCP agent RCA | `kubectl exec -n inference deploy/ai-assistant -- python3 -m mcp.client.run "What is TTFT p99?"` |

## Certifications

CKA · CKS · Vault Operations Professional · NCA-AIIO · Red Hat EX267 · NCP-AIO
```

---

## Track B — Forward Deployed Engineer README Pitch

**Target readers:** FDE hiring managers at Databricks, Anthropic, OpenAI, Scale AI, Palantir.
**What they scan for:** Deployment speed, client adaptability, air-gap capability, zero-trust on messy infra.

```markdown
# AI Platform Lab — Forward Deployed Engineering Toolkit

> Staff Infrastructure Engineer specialising in rapid, secure AI deployment into
> enterprise client environments. I build platforms that work when the internet
> is blocked, the IdP is LDAP from 2014, and the CISO wants an audit trail
> before you leave the building.

## Core FDE Capability: 5-Minute Air-Gapped Bootstrap

Given a Kubernetes cluster with no internet access, I can deploy a complete
vLLM + Vault + Boundary stack in **under 5 minutes** using:
- Pre-loaded container images (no registry pull during deployment)
- Vault Transit seal (no AWS KMS dependency)
- Terraform automation with local state (no remote backend required)
- Boundary session recording from minute 1 (compliance artifact on first connection)

```bash
# Full air-gapped deployment (no internet access required after image pre-load):
git clone https://github.com/YOUR_ORG/ai-platform-lab
cd ai-platform-lab
make fde-bootstrap BACKEND=airgap TTL=4h
# ↑ Provisions vLLM + Vault + Boundary. All green in <5 min.
```

## Client Environment Adaptability

| Client constraint | My solution |
|---|---|
| No internet egress (air-gapped VPC) | Images pre-loaded into internal registry; `HF_OFFLINE=1` |
| Legacy LDAP IdP (no Okta/OIDC) | Vault LDAP auth method → group mapping → policy binding |
| Corporate HTTPS proxy (TLS intercept) | `HTTPS_PROXY` configured at Vault + all components; internal CA injected |
| No AWS KMS (can't do Vault cloud autoseal) | Vault Transit seal using parent Vault instance |
| CISO requires session audit before pilot approval | Boundary session recording to MinIO (S3-compatible) from Day 1 |
| "No standing credentials" policy | Vault dynamic DB credentials: zero static passwords anywhere |

## Zero-Trust Proof (the 30-second CISO demo)

```bash
# Prove to a CISO that the AI agent NEVER held a static credential:
vault read database/creds/mcp-server-role   # Creates credential
# Run the MCP tool call...
vault lease revoke <lease-id>               # Credential destroyed
psql -U v-mcp-a1b2c3d4 ...                 # Returns: "role does not exist"
# Boundary recording: every byte of the session archived in S3
```

## Supported Client Topologies (Ephemeral Lab Engine)

| Topology | Purpose | Bootstrap time |
|---|---|---|
| `consul-admin-partition` | Multi-tenant service mesh isolation | 8 min |
| `vault-ha-raft` | 3-node Vault HA with leader failover | 6 min |
| `fde-airgap` | Air-gapped VPC simulation | 5 min |
| `fde-ldap-corp` | Legacy IdP + corporate proxy | 7 min |

Each topology auto-destroys after TTL expires. No orphaned cloud resources.

## Rapid Onboarding Philosophy

> "A Forward Deployed Engineer is measured in hours-to-first-value, not weeks.
> My toolkit reduces client onboarding from a 2-week professional services engagement
> to a 1-hour live demonstration with full audit logging."
```

---

## Loom Video Script: 5-Minute Ephemeral Lab Engine Demo

**Runtime target:** 4:45–5:00 exactly. Practice to 5:10, edit to 5:00.
**Record at:** 1920×1080, 60fps. No cursor acceleration. Clean desktop (only Terminal + browser).
**Opening:** No intro. Start talking over terminal immediately.

### [00:00–00:20] Hook — the problem statement

*Narrate while showing a blank terminal:*
> "This is what a support engineer faces when a Sev-1 comes in from a multi-tenant
> inference cluster at 2am. No reproducible environment. No idea which tenant's workload
> caused the KV-cache saturation. Let me show you how I solved that."

### [00:20–01:00] Environment bootstrap

```bash
# Show: fresh terminal, nothing running
kubectl get pods --all-namespaces | wc -l   # shows 0 or minimal

# Run:
make up BACKEND=kind TOPOLOGY=consul-admin-partition TTL=2h
```
*Narrate:* "Single make command. GitOps-driven. ArgoCD syncs Vault, Consul, KEDA, the
full observability stack. Watch this — 8 minutes to a fully isolated topology."

*Time-lapse or speed up to 2× while ArgoCD syncs. Show ArgoCD UI with apps going green.*

### [01:00–01:45] Fault injection

```bash
# Show: all pods green in ArgoCD
# Then inject the fault:
make scenario TOPOLOGY=consul-admin-partition SCENARIO=ap-network-split
```
*Narrate:* "I'm injecting a UDP 8301 gossip block — simulating a network partition between
Consul admin partitions. Watch the client services start failing health checks."

*Show: Grafana dashboard — consul_health_checks_critical climbing.*

### [01:45–02:30] AI-assisted RCA

```bash
kubectl exec -n inference deploy/ai-assistant -- \
  python3 -m mcp.client.run \
  "The Consul health check failure rate just spiked. What is the current state of the
   inference pods and what PromQL query shows the consul_health_check_critical metric?"
```
*Narrate:* "The AI agent calls two MCP servers through IBM Context Forge. It has NO
credentials, NO direct cluster access. Every call is whitelisted and traced."

*Show: Context Forge admin UI — tool call trace with latency. Grafana Tempo — span waterfall.*

### [02:30–03:30] Zero-trust credential proof

*Switch to Vault UI or terminal:*
```bash
vault read database/creds/mcp-server-role -format=json | jq '{
  username: .data.username,
  ttl_seconds: .lease_duration
}'
```
*Narrate:* "This is the credential the Boundary session just issued. Notice the username:
`v-mcp-a1b2c3d4`. This credential was created 3 seconds ago when the MCP server
requested a database connection. It will be destroyed in 3600 seconds — or immediately
when I revoke it now."

```bash
vault lease revoke $(vault read -field=lease_id database/creds/mcp-server-role)
psql -h localhost -U v-mcp-a1b2c3d4 -d mcpdb -c "SELECT 1"
# "FATAL: role v-mcp-a1b2c3d4 does not exist"
```
*Narrate:* "Gone. The CISO's audit question is answered in 30 seconds."

### [03:30–04:15] Boundary session recording

*Show MinIO or S3 bucket:*
```bash
mc ls minio/boundary-recordings/mcp/ | tail -3
# Shows: .cast file created within the last 2 minutes
```
*Narrate:* "Every session that Boundary proxied — including that MCP→PostgreSQL connection
— is recorded here. Immutable. The compliance team can replay every byte the AI agent
sent to the database. This is SOC-2 CC6.8 done automatically."

### [04:15–04:45] TTL teardown

```bash
# Show the TTL countdown:
cat /tmp/ttl-teardown-consul-admin-partition.pid
# Then show teardown firing (or manually trigger):
make teardown TOPOLOGY=consul-admin-partition
```
*Narrate:* "The topology self-destructs after 2 hours. No orphaned cloud resources. No
cleanup ticket. The GitOps state is reset. The next engineer spawns a fresh isolated
environment for their reproduction case."

### [04:45–05:00] Closing

*Show GitHub repo README:*
> "Everything you just saw is in this repo — ADRs, Terraform, ArgoCD manifests,
> the Makefile targets. `make up` from a fresh clone, under 10 minutes.
> The complete zero-trust architecture document is ADR-008."
*End recording.*

---

## GitHub Repository Checklist (Both Tracks)

Before sharing the repo link in any job application, all items must be true:

```
[ ] README.md leads with 3-sentence impact statement (not technology list)
[ ] make up from fresh clone succeeds in <10 minutes (test on a new machine)
[ ] CI badge green on main branch
[ ] ADR-001 through ADR-008 all committed and cross-referenced
[ ] 3 runbooks (RB-001, RB-002, at least one FDE scenario runbook)
[ ] 1 postmortem (PM-001 minimum)
[ ] Loom video link in README header (5-minute demo)
[ ] GitHub Actions CI shows: lint + kubeconform + trivy scan + cosign verify
[ ] No secrets in git history (run: git log --all -S 'password' --oneline)
[ ] ARCHITECTURE.md has ASCII diagram of full zero-trust flow (ADR-008 diagram)
```
