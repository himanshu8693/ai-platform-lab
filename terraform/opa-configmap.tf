# =============================================================================
# terraform/opa-configmap.tf
# OPA Policy Bundle — Managed via Terraform/GitOps
#
# Gap A fix: manages the OPA Rego policy bundle as a Kubernetes ConfigMap
# so that policy changes follow the same GitOps CI/CD pipeline as all other
# platform manifests (PR → CI test → ArgoCD sync).
#
# The ConfigMap is referenced by the OPA sidecar in context-forge-deployment.yaml
# as a projected volume. OPA hot-reloads the policy when the ConfigMap is updated
# (via ArgoCD sync → rolling restart of context-forge pod).
#
# Change governance:
#   1. Edit security/opa-policies/mcp-tool-authz.rego
#   2. Run: opa test security/opa-policies/ -v  (must pass 100%)
#   3. terraform apply → updates the ConfigMap with new policy content
#   4. ArgoCD detects the ConfigMap change → triggers context-forge pod restart
#   5. OPA sidecar loads the new policy bundle on startup
#
# References: ADR-010, security/opa-policies/mcp-tool-authz.rego
# =============================================================================

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
  }
}

# ── Read the Rego policy files from disk ────────────────────────────────────
# terraform's file() function reads the policy at plan/apply time.
# Any change to the .rego file produces a ConfigMap update on next apply.

locals {
  opa_policy_dir    = "${path.root}/../security/opa-policies"
  authz_policy      = file("${local.opa_policy_dir}/mcp-tool-authz.rego")
  # OPA data document: provides runtime-configurable constants without editing policy code
  opa_data_document = jsonencode({
    mcp = {
      config = {
        # Increase this list via PR + policy review — not by editing the .rego directly
        additional_allowed_namespaces = []
        # Override PII patterns for specific environments (e.g., staging with test data)
        pii_pattern_overrides = []
        # Max range query window in seconds (default: 86400 = 24h)
        max_range_query_seconds = 86400
      }
    }
  })
}

# ── ConfigMap: opa-mcp-policy-bundle ────────────────────────────────────────
resource "kubernetes_config_map" "opa_mcp_policy_bundle" {
  metadata {
    name      = "opa-mcp-policy-bundle"
    namespace = "inference"
    labels = {
      "app.kubernetes.io/name"      = "opa"
      "app.kubernetes.io/component" = "policy-bundle"
      "platform.ai/managed-by"      = "terraform"
      "platform.ai/gap"             = "A"
      "platform.ai/adr"             = "ADR-010"
    }
    annotations = {
      "platform.ai/policy-version"     = sha256(local.authz_policy)
      "platform.ai/last-reviewed-by"   = "platform-security"
      "argocd.argoproj.io/sync-wave"   = "1"
    }
  }

  data = {
    # The main policy file — loaded by OPA sidecar as the entrypoint
    "mcp-tool-authz.rego" = local.authz_policy
    # Runtime-configurable data document
    "data.json" = local.opa_data_document
  }
}

# ── Output: policy checksum ────────────────────────────────────────────────
output "opa_policy_checksum" {
  value       = sha256(local.authz_policy)
  description = "SHA-256 of the deployed OPA policy. Matches the ConfigMap annotation. Use to verify the correct policy version is deployed."
}

output "verify_opa_policy_cmd" {
  value       = "kubectl get configmap opa-mcp-policy-bundle -n inference -o jsonpath='{.metadata.annotations.platform\\.ai/policy-version}'"
  description = "Verify the deployed policy version matches this Terraform output."
}

output "run_opa_tests_cmd" {
  value       = "opa test security/opa-policies/ -v --format=pretty"
  description = "Run OPA unit tests before applying policy changes. All tests must pass."
}
