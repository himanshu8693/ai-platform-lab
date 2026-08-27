---
name: Production Change Request
about: Required template for all changes to clusters/production/**
title: "chg: [COMPONENT] [BRIEF DESCRIPTION] (CAB-TICKET-ID)"
labels: ["change-request", "production", "requires-cab-approval"]
assignees: []
---

## Change Advisory Board (CAB) Request
<!-- Required by ADR-015 for all production deployments -->

### Change Ticket
- **ITSM Ticket ID:** <!-- CHG0012345 or RITM0012345 -->
- **ITSM System:** <!-- servicenow | jira-service-management | remedy -->
- **Ticket URL:** <!-- https://your-itsm.internal/ticket/CHG0012345 -->
- **Ticket State:** <!-- Must be "Approved" before syncing -->

### Change Summary
<!-- One paragraph. What is changing and why. -->

### Components Affected
<!-- Check all that apply -->
- [ ] mcp-kubernetes (Kubernetes MCP server)
- [ ] mcp-prometheus (Prometheus MCP server)
- [ ] context-forge (MCP gateway + OPA policy)
- [ ] vault (secrets engine, policy)
- [ ] boundary (targets, credential libraries)
- [ ] spire (workload identity)
- [ ] argocd (applications, projects)
- [ ] monitoring (Prometheus, Grafana, Tempo)
- [ ] network policies
- [ ] RBAC / security policies
- [ ] Other: <!-- specify -->

### Impact Assessment
<!-- Complete each section -->
**Blast radius (worst case):**
<!-- Example: "All MCP tool calls will fail for ~30s during rolling restart of context-forge." -->

**SLO impact:**
<!-- Example: "AI assistant unavailable for 1 rolling-restart cycle (~30s). Within error budget." -->

**Data at risk:**
<!-- Example: "No data at risk. config-only change." OR "Boundary session recordings will be unaffected." -->

### Rollback Plan
<!-- Exact commands to execute if the change causes a P1 incident -->
```bash
# Rollback commands (copy-paste ready):
git revert <commit-sha>
git push origin main
argocd app sync production-platform --prune
# OR for emergency rollback without PR:
argocd app rollback production-platform <revision>
```

**Rollback time estimate:** <!-- 5 minutes | 15 minutes | 30 minutes -->

### Change Window
- **Planned start:** <!-- 2025-01-15 10:00 UTC -->
- **Planned end:**   <!-- 2025-01-15 10:30 UTC -->
- **Change window compliance:** <!-- Monday-Friday 09:00-17:00 per ADR-015 AppProject sync window -->

### Pre-Change Checklist
- [ ] All CI/CD checks pass on this PR
- [ ] `opa test security/opa-policies/ -v` passes locally (if OPA policy changed)
- [ ] Staging deployment verified: same change applied to `clusters/staging` first
- [ ] CAB ticket is in "Submitted" state (will update to "Approved" after review)
- [ ] Rollback plan reviewed and tested in staging
- [ ] On-call engineer notified of planned change window

### Post-Change Verification
<!-- How will you verify the change succeeded? -->
```bash
# Verification commands (run after sync completes):
kubectl rollout status deployment/context-forge -n inference
kubectl logs deploy/context-forge -c opa | tail -20
# Add application-specific verification steps:
```

### Operator Instructions
<!-- For the operator executing the sync -->
1. Verify CAB ticket `TICKET_ID` is in **Approved** state
2. Update the `current-change-ticket` ConfigMap:
   ```bash
   kubectl patch configmap current-change-ticket -n platform \
     --patch '{"data":{"ticket_id":"TICKET_ID"}}'
   ```
3. Trigger the sync during the approved change window:
   ```bash
   argocd app sync production-platform --prune
   ```
4. Monitor the sync: `argocd app get production-platform --watch`
5. Run post-change verification commands above
6. Update CAB ticket to **Implemented** state
7. If verification fails: execute rollback plan immediately

---
<!-- DO NOT MERGE until CAB ticket is in Approved state -->
<!-- The ArgoCD PreSync hook will block the sync if ticket is not Approved -->
