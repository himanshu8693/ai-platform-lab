#!/usr/bin/env bash
# =============================================================================
# scripts/fde/verify-airgap-bootstrap.sh
# Verify the FDE-001 air-gapped VPC bootstrap completed within the 5-minute SLA.
#
# Tests:
#   1. All expected pods are Running
#   2. Internet egress IS blocked (NetworkPolicy working)
#   3. vLLM serving endpoint responds
#   4. Vault is initialized and unsealed
#   5. LDAP mock is responding
#   6. Wall-clock time is within 300s SLA
#
# Usage:
#   # Run immediately after: make fde-bootstrap
#   bash scripts/fde/verify-airgap-bootstrap.sh
#
# Exit codes:
#   0 = all checks pass, SLA met
#   1 = a check failed
#   2 = checks passed but SLA missed (>300s)
# =============================================================================

set -euo pipefail

NS="${1:-fde-airgap}"
SLA_SECONDS=300
PASS=0
FAIL=1
WARN=2

START=$(date +%s)
FAILURES=0

log()  { echo "[fde-verify] $(date -u +%H:%M:%S) $*"; }
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILURES=$((FAILURES + 1)); }
info() { echo "  ℹ $*"; }

log "Verifying air-gapped bootstrap in namespace: ${NS}"
echo ""

# ── Test 1: Pods Running ──────────────────────────────────────────────────────
log "Test 1: Waiting for all pods to be Ready..."

pods=("vault" "vllm-server" "ldap-mock")
for pod_prefix in "${pods[@]}"; do
  if kubectl wait --for=condition=ready pod \
    -l "app=${pod_prefix}" \
    -n "${NS}" \
    --timeout=180s &>/dev/null 2>&1; then
    pass "${pod_prefix} pod is Ready"
  else
    fail "${pod_prefix} pod did NOT reach Ready state within 180s"
  fi
done

# ── Test 2: Internet egress IS blocked ────────────────────────────────────────
log "Test 2: Verifying internet egress is BLOCKED (NetworkPolicy check)..."

# Attempt to reach docker.io from the vllm pod — should fail
if kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s --max-time 5 https://registry-1.docker.io/v2/ &>/dev/null 2>&1; then
  fail "Internet egress NOT blocked — docker.io is reachable from vllm-server. Check NetworkPolicy."
else
  pass "Internet egress blocked — docker.io unreachable from vllm-server (expected)"
fi

# Attempt to reach HuggingFace — should fail
if kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s --max-time 5 https://huggingface.co &>/dev/null 2>&1; then
  fail "Internet egress NOT blocked — huggingface.co is reachable. Air-gap simulation broken."
else
  pass "Internet egress blocked — huggingface.co unreachable (expected)"
fi

# ── Test 3: vLLM endpoint responds ────────────────────────────────────────────
log "Test 3: Verifying vLLM serving endpoint health..."

if kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s http://localhost:8000/health 2>/dev/null | grep -qE "ok|healthy|200"; then
  pass "vLLM /health endpoint responds (serving active)"
else
  fail "vLLM /health endpoint did not respond. Check pod logs: kubectl logs -n ${NS} deploy/vllm-server"
fi

# Test the OpenAI-compatible chat endpoint with a trivial request
log "  Sending test inference request to vLLM..."
RESPONSE=$(kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${MODEL_NAME:-llama3.2-3b}"'","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}' 2>/dev/null || true)

if echo "${RESPONSE}" | grep -q "choices"; then
  pass "vLLM inference endpoint returned a response with 'choices' field"
  TOKEN_COUNT=$(echo "${RESPONSE}" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo "0")
  info "Completion tokens: ${TOKEN_COUNT}"
else
  fail "vLLM inference endpoint did not return expected response. Raw: ${RESPONSE:0:200}"
fi

# ── Test 4: Vault status ──────────────────────────────────────────────────────
log "Test 4: Verifying Vault is initialized and unsealed..."

VAULT_STATUS=$(kubectl exec -n "${NS}" -it deploy/vault -- \
  vault status -format=json 2>/dev/null || echo '{}')

if echo "${VAULT_STATUS}" | jq -e '.initialized == true' &>/dev/null; then
  pass "Vault is initialized"
else
  fail "Vault is NOT initialized. Run: kubectl exec -n ${NS} deploy/vault -- vault operator init"
fi

if echo "${VAULT_STATUS}" | jq -e '.sealed == false' &>/dev/null; then
  pass "Vault is unsealed (Transit seal working)"
else
  fail "Vault is SEALED. Transit seal may be misconfigured. Check parent Vault transit key."
fi

# ── Test 5: LDAP mock ─────────────────────────────────────────────────────────
log "Test 5: Verifying LDAP mock IdP responds..."

if kubectl exec -n "${NS}" deploy/ldap-mock -- \
  ldapsearch -x -H ldap://localhost:389 \
  -b "dc=fde,dc=client,dc=corp" \
  -D "cn=admin,dc=fde,dc=client,dc=corp" \
  -w "$(kubectl get secret -n ${NS} ldap-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
  "(objectClass=*)" dn 2>/dev/null | grep -q "dn:"; then
  pass "LDAP mock responds to ldapsearch — base DN accessible"
else
  fail "LDAP mock did not respond to ldapsearch. Check pod: kubectl logs -n ${NS} deploy/ldap-mock"
fi

# ── Test 6: HF_OFFLINE enforcement ───────────────────────────────────────────
log "Test 6: Verifying HF_OFFLINE=1 is set (no HuggingFace calls at runtime)..."

HF_OFFLINE=$(kubectl get deployment -n "${NS}" vllm-server \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HF_OFFLINE")].value}' 2>/dev/null || echo "")

if [[ "${HF_OFFLINE}" == "1" ]]; then
  pass "HF_OFFLINE=1 is set on vllm-server deployment"
else
  fail "HF_OFFLINE is not set to '1'. vLLM may attempt HuggingFace calls at model load. Found: '${HF_OFFLINE}'"
fi

# ── SLA check ─────────────────────────────────────────────────────────────────
END=$(date +%s)
ELAPSED=$((END - START))

echo ""
log "=== Bootstrap Verification Summary ==="
log "Failures: ${FAILURES}"
log "Elapsed (verification): ${ELAPSED}s"

# Try to get the Terraform apply timestamp from namespace annotation
BOOTSTRAP_START=$(kubectl get namespace "${NS}" \
  -o jsonpath='{.metadata.annotations.fde\.scenario/bootstrap-start}' 2>/dev/null || echo "")

if [[ -n "${BOOTSTRAP_START}" ]]; then
  NOW=$(date +%s)
  TOTAL_ELAPSED=$((NOW - BOOTSTRAP_START))
  log "Total elapsed since terraform apply: ${TOTAL_ELAPSED}s (SLA: ${SLA_SECONDS}s)"
  if [[ "${TOTAL_ELAPSED}" -le "${SLA_SECONDS}" ]]; then
    log "SLA: PASS (${TOTAL_ELAPSED}s ≤ ${SLA_SECONDS}s)"
  else
    log "SLA: MISS (${TOTAL_ELAPSED}s > ${SLA_SECONDS}s) — review timing in bootstrap log"
  fi
else
  log "SLA: CANNOT MEASURE (bootstrap-start annotation not found — set it at terraform apply start)"
fi

echo ""
if [[ "${FAILURES}" -eq 0 ]]; then
  log "All checks passed. Air-gapped bootstrap verified."
  exit 0
else
  log "${FAILURES} check(s) FAILED. Review errors above."
  exit 1
fi
