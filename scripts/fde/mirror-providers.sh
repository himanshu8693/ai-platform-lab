#!/usr/bin/env bash
# =============================================================================
# scripts/fde/mirror-providers.sh
# Terraform Provider Mirror — Air-Gapped VPC Pre-Flight
#
# Gap F fix: mirrors all Terraform providers used by this repo into the
# vendor/terraform-providers/ directory. Air-gapped deployments use a
# .terraformrc that points to this directory as a filesystem_mirror,
# eliminating all outbound connections to registry.terraform.io.
#
# Usage:
#   ./scripts/fde/mirror-providers.sh           # mirror all providers
#   ./scripts/fde/mirror-providers.sh --verify  # verify mirrors are complete
#
# Prerequisites:
#   - terraform CLI installed (internet-connected machine for pre-flight)
#   - All .tf files present in terraform/ directory
#   - Run BEFORE deploying to air-gap VPC
#
# After running:
#   1. Commit vendor/terraform-providers/ to Git (or package to a USB drive)
#   2. Copy to the air-gapped VPC along with the repo
#   3. terraform init uses the filesystem mirror — no internet connection needed
#
# References: ADR-F01, docs/scenarios/FDE-001-airgap-vpc-deployment.md
# =============================================================================

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MIRROR_DIR="${REPO_ROOT}/vendor/terraform-providers"
TERRAFORMRC_OUT="${REPO_ROOT}/.terraformrc.airgap"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
VERIFY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --verify) VERIFY_ONLY=true ;;
        *) error "Unknown argument: $arg. Usage: $0 [--verify]" ;;
    esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v terraform >/dev/null 2>&1 || error "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v git >/dev/null 2>&1 || error "git not found."

TERRAFORM_VERSION=$(terraform version -json | jq -r '.terraform_version')
info "Terraform version: ${TERRAFORM_VERSION}"

# ── Verify mode ───────────────────────────────────────────────────────────────
if [[ "${VERIFY_ONLY}" == "true" ]]; then
    info "Verifying provider mirror completeness..."
    if [[ ! -d "${MIRROR_DIR}" ]]; then
        error "Mirror directory not found: ${MIRROR_DIR}. Run without --verify first."
    fi

    # List all providers declared in .tf files
    REQUIRED_PROVIDERS=$(grep -rh '"source"' "${REPO_ROOT}/terraform/"*.tf \
        "${REPO_ROOT}/terraform/backends/"**/*.tf 2>/dev/null | \
        grep -oP '"registry\.terraform\.io/[^"]*"' | \
        sort -u | tr -d '"')

    MISSING=0
    for provider in ${REQUIRED_PROVIDERS}; do
        SHORT=$(echo "$provider" | sed 's|registry.terraform.io/||')
        PROVIDER_DIR="${MIRROR_DIR}/registry.terraform.io/${SHORT}"
        if [[ -d "${PROVIDER_DIR}" ]]; then
            BINARY_COUNT=$(find "${PROVIDER_DIR}" -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
            success "${SHORT}: ${BINARY_COUNT} platform binaries mirrored"
        else
            warn "MISSING: ${SHORT} (directory not found: ${PROVIDER_DIR})"
            MISSING=$((MISSING + 1))
        fi
    done

    if [[ "${MISSING}" -gt 0 ]]; then
        error "${MISSING} provider(s) missing from mirror. Run without --verify to re-mirror."
    fi

    success "Provider mirror is complete. Safe to proceed with air-gapped deployment."
    exit 0
fi

# ── Create mirror directory ───────────────────────────────────────────────────
mkdir -p "${MIRROR_DIR}"
info "Mirror directory: ${MIRROR_DIR}"

# ── Mirror providers from each Terraform directory ───────────────────────────
# Run terraform providers mirror from each directory that has .tf files
# to ensure all providers are captured (including backend-specific ones).

TF_DIRS=(
    "${REPO_ROOT}/terraform"
    "${REPO_ROOT}/terraform/backends/airgap"
    "${REPO_ROOT}/terraform/backends/k3d"
    "${REPO_ROOT}/terraform/pam-federation"
)

for tf_dir in "${TF_DIRS[@]}"; do
    if [[ ! -d "${tf_dir}" ]]; then
        warn "Directory not found, skipping: ${tf_dir}"
        continue
    fi

    info "Mirroring providers from: ${tf_dir}"

    # Run terraform providers mirror
    # -platform flags capture binaries for all target platforms
    (cd "${tf_dir}" && \
        terraform providers mirror \
        -platform=linux_amd64 \
        -platform=linux_arm64 \
        -platform=darwin_arm64 \
        "${MIRROR_DIR}" \
    ) && success "Mirrored providers from ${tf_dir}" || \
        warn "Some providers in ${tf_dir} failed to mirror (check network connectivity)"
done

# ── Generate air-gap .terraformrc ─────────────────────────────────────────────
cat > "${TERRAFORMRC_OUT}" << EOF
# =============================================================================
# .terraformrc.airgap — Air-Gapped Terraform Provider Configuration
#
# Generated by scripts/fde/mirror-providers.sh
# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Usage in air-gapped VPC:
#   export TF_CLI_CONFIG_FILE=/path/to/.terraformrc.airgap
#   terraform init   # uses filesystem mirror, no internet required
# =============================================================================

provider_installation {
  filesystem_mirror {
    path    = "/opt/ai-platform-lab/vendor/terraform-providers"
    include = ["registry.terraform.io/*/*"]
  }
  # Explicitly block all direct downloads — no internet fallback
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF

info "Air-gap .terraformrc written to: ${TERRAFORMRC_OUT}"

# ── Generate .gitignore entry for large binary files ─────────────────────────
# Only ignore the binary zips — keep the index files (small JSON) in Git
GITIGNORE_ENTRY="# Terraform provider binaries (large) — index files are kept
vendor/terraform-providers/**/*.zip"

if ! grep -q "terraform-providers" "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    echo "" >> "${REPO_ROOT}/.gitignore"
    echo "${GITIGNORE_ENTRY}" >> "${REPO_ROOT}/.gitignore"
    info "Added terraform-providers binary exclusion to .gitignore"
    info "NOTE: Commit vendor/terraform-providers/**/*.json (index files) to Git."
    info "      Keep the .zip binaries on a USB drive or in a private artifact store."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
PROVIDER_COUNT=$(find "${MIRROR_DIR}" -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
info "Mirror summary:"
info "  Directory: ${MIRROR_DIR}"
info "  Provider binaries: ${PROVIDER_COUNT} .zip files"
info "  Platforms mirrored: linux_amd64, linux_arm64, darwin_arm64"
echo ""
success "Provider mirror complete!"
echo ""
echo "Next steps:"
echo "  1. Commit vendor/terraform-providers/**/*.json to Git (index files only)"
echo "  2. Copy ${MIRROR_DIR}/*.zip to USB / private artifact store"
echo "  3. In air-gap VPC: export TF_CLI_CONFIG_FILE=${TERRAFORMRC_OUT}"
echo "  4. Verify mirror: ./scripts/fde/mirror-providers.sh --verify"
