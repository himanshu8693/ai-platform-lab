# ADR-015 — CAB-Compatible GitOps: Manual Approval Gates for Regulated Environments

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-008, clusters/production/app-of-apps.yaml, workloads/platform/cab-approval-hook.yaml |

---

## Context

ArgoCD auto-sync is the default model for local-kind and staging environments.
Production deployments at regulated enterprises (financial services, healthcare, DoD)
require a Change Advisory Board (CAB) process:

1. Every production change must have a change ticket in the enterprise ITSM system
2. The ticket must be approved before the change is applied
3. The change must be applied in an approved change window (business hours only)
4. A rollback plan must be documented in the ticket
5. The entire change history must be auditable

The tension: GitOps principles (declarative, automated, self-healing) conflict directly
with CAB requirements (human approval gates, change windows, audit trails).

**Gap H from the ARB panel:** *"How does your GitOps model integrate with a CAB process
that requires a change ticket to be approved before the sync proceeds?"*

---

## Decision

**Three-stage gate for production syncs:**

### Stage 1 — Git PR Gate (source of truth)

The promotion PR from `clusters/staging` to `clusters/production` path requires
approval from the `platform-change-board` CODEOWNERS group. The PR template
auto-populates a change request template (`.github/PULL_REQUEST_TEMPLATE/change-request.md`)
that includes: impact assessment, rollback plan, CAB ticket ID, change window.

No merge = no sync. The PR IS the change record.

### Stage 2 — ArgoCD Manual Sync

The production App-of-Apps (`clusters/production/app-of-apps.yaml`) has NO
`syncPolicy.automated` block. ArgoCD shows OutOfSync after merge but does NOT apply.

An authorized operator must explicitly run:
```bash
argocd app sync production-platform --prune
```

This is the human "execute" gate. It is separate from the PR approval gate so that:
- A PR can be merged before the change window opens (planning ahead)
- The actual sync happens only when the operator is ready (within the window)

### Stage 3 — CAB Ticket Verification (PreSync Hook)

Before wave 3 workloads update, the `cab-approval-hook.yaml` PreSync Job verifies
the CAB ticket ID (stored in the `current-change-ticket` ConfigMap) is in "Approved"
state in the ITSM system. If not, ArgoCD halts the sync.

---

## Sync Wave Architecture

```
Wave 0: Namespaces, CRDs, RBAC                           (no workload impact)
Wave 1: Secrets, ConfigMaps, Vault policies               (configuration only)
Wave 2: Infrastructure + CAB approval hook                (PreSync gate fires here)
        └── cab-approval-hook Job: verify CAB ticket ──→ BLOCKS if not Approved
Wave 3: Application workloads                             (only if wave 2 passes)
        └── mcp-kubernetes, mcp-prometheus, context-forge
Wave 4: Autoscalers, KEDA ScaledObjects                   (depends on wave 3)
```

---

## ArgoCD Sync Windows

The production AppProject defines sync windows that enforce change timing:

```yaml
syncWindows:
  - kind: allow
    schedule: "0 9-17 * * 1-5"   # Monday-Friday, business hours
    duration: 8h
    manualSync: true
  - kind: deny
    schedule: "0 17-9 * * *"     # Outside business hours
    duration: 16h
    manualSync: false             # No syncs — even manual — outside hours
```

This means: even if the operator runs `argocd app sync` at 11 PM, ArgoCD will reject
the sync request. Changes must happen during business hours (when the CAB team is available).

---

## The CAB Conversation (IBM Band 9 Interview Script)

**Interviewer:** "Your platform uses GitOps with auto-sync. How does that work with our
change management process that requires manual CAB approvals?"

**You:** "Great question — this is one of the most common friction points between GitOps
and regulated enterprises. Our architecture has three distinct gates:

First, the Git PR itself. Production changes require CODEOWNERS approval from the change
board team. The PR template embeds the CAB ticket ID. The ticket must be referenced before
the PR can merge.

Second, ArgoCD manual sync. Production applications have auto-sync disabled. Merging the
PR does not apply the change — it just puts ArgoCD in OutOfSync state. A human operator
must explicitly trigger the sync during the approved change window.

Third, the PreSync hook. When the operator triggers the sync, our CAB approval Job fires
before any workloads update. It queries the ITSM system for the ticket state. If the ticket
isn't in Approved state — maybe it was submitted but not yet reviewed — the sync stops
immediately. The workloads don't update until the ticket is approved and the operator
retries.

The result: you get all the benefits of GitOps — declarative config, Git as the audit trail,
automated testing on PR — but with three human checkpoints before anything touches production."

---

## Files Changed

| File | Change |
|---|---|
| `clusters/production/app-of-apps.yaml` | NEW — Production App-of-Apps with manual sync + AppProject |
| `.github/PULL_REQUEST_TEMPLATE/change-request.md` | NEW — CAB change request template |
| `workloads/platform/cab-approval-hook.yaml` | NEW — PreSync CAB approval hook Job |
| `.github/CODEOWNERS` | PATCHED — platform-change-board as required reviewer on production paths |
