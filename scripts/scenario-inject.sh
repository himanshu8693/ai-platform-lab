#!/usr/bin/env bash
# =============================================================================
# scripts/scenario-inject.sh
# Fault Scenario Injector for the Ephemeral Lab Engine
#
# Applies a named fault scenario YAML to an active topology namespace.
# The scenario YAML creates Kubernetes resources (NetworkPolicy, ConfigMap,
# patched StatefulSet, etc.) that simulate the targeted Sev-1 failure state.
#
# After injection, the AI RCA agent (MCP-based) can query the cluster and
# identify the fault — exactly replicating the first-responder experience.
#
# Usage:
#   bash scripts/scenario-inject.sh <topology> <scenario> [--dry-run]
#
# Examples:
#   bash scripts/scenario-inject.sh consul-admin-partition ap-network-split
#   bash scripts/scenario-inject.sh consul-admin-partition ap-token-revoke
#   bash scripts/scenario-inject.sh vault-ha-raft raft-leader-kill
#   bash scripts/scenario-inject.sh vault-ha-raft seal-auto
#   bash scripts/scenario-inject.sh vault-ha-raft raft-leader-kill --dry-run
#
# To list available topologies and scenarios:
#   bash scripts/scenario-inject.sh --list
#
# To remove an active scenario (remediate the fault):
#   bash scripts/scenario-inject.sh <topology> <scenario> --remove
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGIES_DIR="${SCRIPT_DIR}/../topologies"

log()  { echo "[scenario-inject] $(date -u +%H:%M:%S) $*"; }
err()  { echo "[scenario-inject] ERROR: $*" >&2; exit 1; }

# ── List mode ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
  echo ""
  echo "Available topologies and scenarios:"
  echo ""
  for topology_dir in "${TOPOLOGIES_DIR}"/*/; do
    topology=$(basename "$topology_dir")
    [[ "$topology" == "_base" ]] && continue
    echo "  Topology: ${topology}"
    if [[ -d "${topology_dir}/scenarios" ]]; then
      for scenario_file in "${topology_dir}/scenarios/"*.yaml; do
        scenario=$(basename "$scenario_file" .yaml)
        echo "    └─ ${scenario}"
      done
    else
      echo "    └─ (no scenarios defined)"
    fi
    echo ""
  done
  exit 0
fi

# ── Arguments ─────────────────────────────────────────────────────────────────
TOPOLOGY="${1:-}"
SCENARIO="${2:-}"
MODE="${3:-}"    # --dry-run | --remove | (empty = apply)

[[ -z "$TOPOLOGY" ]] && err "topology argument required. Run with --list to see options."
[[ -z "$SCENARIO" ]] && err "scenario argument required. Run with --list to see options."

TOPOLOGY_DIR="${TOPOLOGIES_DIR}/${TOPOLOGY}"
SCENARIO_FILE="${TOPOLOGY_DIR}/scenarios/${SCENARIO}.yaml"
NAMESPACE="topology-${TOPOLOGY}"

[[ -d "$TOPOLOGY_DIR" ]]    || err "Topology not found: ${TOPOLOGY}. Check ${TOPOLOGIES_DIR}/"
[[ -f "$SCENARIO_FILE" ]]   || err "Scenario not found: ${SCENARIO_FILE}"

# ── Verify namespace exists ───────────────────────────────────────────────────
if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
  err "Namespace '${NAMESPACE}' does not exist. Is the topology deployed? Run: git push topologies/${TOPOLOGY}"
fi

# ── Dry-run mode ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "--dry-run" ]]; then
  log "DRY RUN — showing what would be applied to namespace '${NAMESPACE}':"
  echo ""
  kubectl apply --dry-run=client -n "$NAMESPACE" -f "$SCENARIO_FILE"
  echo ""
  log "No changes made (--dry-run)."
  exit 0
fi

# ── Remove mode (remediation) ─────────────────────────────────────────────────
if [[ "$MODE" == "--remove" ]]; then
  log "Removing scenario '${SCENARIO}' from topology '${TOPOLOGY}'..."
  kubectl delete -n "$NAMESPACE" -f "$SCENARIO_FILE" --ignore-not-found=true
  # Clear the active scenario annotation on the namespace.
  kubectl annotate namespace "$NAMESPACE" \
    ephemeral-lab/active-scenario="none" --overwrite
  log "Scenario removed. Topology is back to baseline state."
  exit 0
fi

# ── Apply mode ────────────────────────────────────────────────────────────────
INJECTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Injecting scenario '${SCENARIO}' into topology '${TOPOLOGY}'..."
log "Namespace: ${NAMESPACE}"
log "Scenario file: ${SCENARIO_FILE}"

# Patch the injected-at timestamp into any ConfigMaps with that field before applying.
# This lets the AI agent know when the fault was injected.
TMP_SCENARIO=$(mktemp /tmp/scenario-XXXXXX.yaml)
sed "s/ephemeral-lab\/injected-at:   \"\"/ephemeral-lab\/injected-at:   \"${INJECTED_AT}\"/" \
  "$SCENARIO_FILE" > "$TMP_SCENARIO"

kubectl apply -n "$NAMESPACE" -f "$TMP_SCENARIO"
rm -f "$TMP_SCENARIO"

# Annotate the namespace so MCP tools can read the active scenario.
kubectl annotate namespace "$NAMESPACE" \
  ephemeral-lab/active-scenario="${SCENARIO}" \
  ephemeral-lab/scenario-injected-at="${INJECTED_AT}" \
  --overwrite

log "Scenario injected at ${INJECTED_AT}."

# ── Post-injection guidance ───────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Scenario Active                                             │"
printf "│  Topology   : %-47s │\n" "${TOPOLOGY}"
printf "│  Scenario   : %-47s │\n" "${SCENARIO}"
printf "│  Namespace  : %-47s │\n" "${NAMESPACE}"
printf "│  Injected at: %-47s │\n" "${INJECTED_AT}"
echo "│                                                              │"
echo "│  AI RCA — send this query to the ai-assistant:             │"
echo "│    kubectl exec -n inference deploy/ai-assistant --         │"
echo "│    curl -s -X POST http://localhost:8082/query              │"
printf "│    -d '{\"query\":\"Investigate the active fault in %s\"}\'\n" "${NAMESPACE}" | fold -w 62 | head -1
echo "│                                                              │"
echo "│  Remediate with:                                            │"
printf "│    bash scripts/scenario-inject.sh %s %s --remove\n" "${TOPOLOGY}" "${SCENARIO}" | fold -w 62 | head -1
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
