#!/usr/bin/env bash
# =============================================================================
# scripts/fde/preload-images.sh
# Pre-load all required container images into the kind internal registry
# BEFORE applying the air-gap NetworkPolicy.
#
# This script must be run with internet access. After it completes, the
# air-gap NetworkPolicy can be applied and no further image pulls are needed.
#
# Usage:
#   bash scripts/fde/preload-images.sh [REGISTRY_PORT]
#   REGISTRY_PORT defaults to 5001 (kind's default local registry port)
# =============================================================================

set -euo pipefail

REGISTRY_PORT="${1:-5001}"
REGISTRY="localhost:${REGISTRY_PORT}"
CLUSTER_NAME="${CLUSTER_NAME:-ai-platform-lab}"

log() { echo "[preload-images] $(date -u +%H:%M:%S) $*"; }

# Images required for the air-gapped bootstrap
declare -A IMAGES=(
  ["hashicorp/vault:1.17.2"]="hashicorp/vault:1.17.2"
  ["hashicorp/boundary:0.17.1"]="hashicorp/boundary:0.17.1"
  ["ghcr.io/ibm/mcp-context-forge:latest"]="ibm/mcp-context-forge:latest"
  ["vllm/vllm-openai:v0.6.3"]="vllm/vllm-openai:v0.6.3"
  ["osixia/openldap:1.5.0"]="osixia/openldap:1.5.0"
  ["postgres:16-alpine"]="postgres:16-alpine"
  ["prom/prometheus:v2.54.1"]="prom/prometheus:v2.54.1"
  ["grafana/grafana:11.2.0"]="grafana/grafana:11.2.0"
)

log "Pulling and tagging images for internal registry at ${REGISTRY}..."
for src_image in "${!IMAGES[@]}"; do
  dst_tag="${IMAGES[$src_image]}"
  log "  Pulling: ${src_image}"
  docker pull "${src_image}"
  docker tag "${src_image}" "${REGISTRY}/${dst_tag}"
  log "  Pushing to internal registry: ${REGISTRY}/${dst_tag}"
  docker push "${REGISTRY}/${dst_tag}"
  log "  Loading into kind cluster: ${CLUSTER_NAME}"
  kind load docker-image "${src_image}" --name "${CLUSTER_NAME}"
done

log ""
log "All images pre-loaded. Summary:"
for src_image in "${!IMAGES[@]}"; do
  echo "  ✓ ${REGISTRY}/${IMAGES[$src_image]}"
done

log ""
log "Next step: apply the air-gap NetworkPolicy"
log "  kubectl apply -f topologies/fde-airgap/network-policy-airgap.yaml"
log ""
log "Then bootstrap:"
log "  make fde-bootstrap"
