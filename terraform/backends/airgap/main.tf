# =============================================================================
# terraform/backends/airgap/main.tf
# Air-Gapped / Restricted VPC Bootstrap — FDE-001 Scenario
#
# Deploys: vLLM + Vault (Transit seal) + Boundary into an isolated namespace
# with zero internet egress. All images must be pre-loaded into the internal
# kind registry before the air-gap NetworkPolicy is applied.
#
# Design constraints:
#   • NO remote Terraform backend (no S3/GCS available in air-gap)
#   • NO public container registries (all images served from internal-registry)
#   • NO AWS KMS (Vault uses Transit seal from parent Vault instance)
#   • NO SaaS IdP (LDAP mock deployed in-namespace)
#
# Usage:
#   # Step 1: Pre-load images (requires internet — do before air-gap)
#   bash scripts/fde/preload-images.sh
#
#   # Step 2: Apply air-gap NetworkPolicy
#   kubectl apply -f topologies/fde-airgap/network-policy-airgap.yaml
#
#   # Step 3: Deploy the stack (all from internal registry)
#   export TF_VAR_vault_transit_seal_key="$(vault token create -policy=transit-unseal -field=token)"
#   terraform -chdir=terraform/backends/airgap init
#   terraform -chdir=terraform/backends/airgap apply -auto-approve
#
#   # Step 4: Verify SLA
#   bash scripts/fde/verify-airgap-bootstrap.sh
#
# 5-minute SLA: terraform apply + all pods Running ≤ 300s wall-clock
# =============================================================================

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }
  # Local backend — intentional. Air-gapped environments have no remote state storage.
  # Document this trade-off in the client deployment runbook. State lives in /tmp.
  backend "local" {
    path = "/tmp/fde-airgap-terraform.tfstate"
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "namespace" {
  type        = string
  default     = "fde-airgap"
  description = "Kubernetes namespace for the air-gapped deployment."
}

variable "internal_registry" {
  type        = string
  default     = "localhost:5001"
  description = "Internal OCI registry host:port. No internet access used during deployment. Override to match your kind registry port."
}

variable "vault_transit_seal_key_token" {
  type        = string
  sensitive   = true
  description = "Short-TTL Vault token from the parent ai-platform-lab Vault instance with transit encrypt/decrypt permissions. Used for Vault Transit auto-unseal without AWS KMS."
}

variable "model_name" {
  type        = string
  default     = "llama3.2-3b"
  description = "Model directory name under /models PVC mount. Must be pre-staged into the PVC before air-gap activation."
}

variable "bootstrap_timeout_seconds" {
  type        = number
  default     = 300
  description = "Target wall-clock budget for the full bootstrap. Referenced in namespace annotation only — not enforced by Terraform itself."
}

# ── Kubernetes + Helm providers (use existing kubeconfig context) ──────────────

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-ai-platform-lab"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-ai-platform-lab"
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "airgap" {
  metadata {
    name = var.namespace
    labels = {
      "kubernetes.io/metadata.name"        = var.namespace
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "fde.scenario/type"                  = "airgap"
      "fde.scenario/id"                    = "FDE-001"
    }
    annotations = {
      "fde.scenario/bootstrap-sla-seconds" = tostring(var.bootstrap_timeout_seconds)
      "fde.scenario/no-internet"           = "true"
      "fde.scenario/idp-type"              = "ldap"
      "fde.scenario/seal-type"             = "transit"
    }
  }
}

# ── Internal registry Service (exposes kind's local registry inside cluster) ───

resource "kubernetes_service" "internal_registry" {
  metadata {
    name      = "internal-registry"
    namespace = var.namespace
    labels    = { "fde.scenario/component" = "registry" }
  }
  spec {
    type       = "ExternalName"
    # Points to the kind cluster's local registry running on the host
    external_name = "host.docker.internal"
    port {
      port        = 5001
      target_port = "5001"
    }
  }
  depends_on = [kubernetes_namespace.airgap]
}

# ── Vault (Transit seal, no AWS KMS) ─────────────────────────────────────────

resource "helm_release" "vault_airgap" {
  name             = "vault"
  # Use OCI pull from the internal registry, not helm.releases.hashicorp.com
  repository       = "oci://${var.internal_registry}/charts"
  chart            = "vault"
  namespace        = kubernetes_namespace.airgap.metadata[0].name
  create_namespace = false
  wait             = true
  wait_for_jobs    = true
  timeout          = 180

  values = [yamlencode({
    server = {
      image = {
        repository = "${var.internal_registry}/hashicorp/vault"
        tag        = "1.17.2"
        pullPolicy = "Never"  # Must be pre-loaded — IfNotPresent would still check registry
      }
      # HA disabled for FDE-001 single-node lab
      ha = { enabled = false }
      dev = { enabled = false }
      # Transit seal: uses the parent ai-platform-lab Vault to auto-unseal.
      # This avoids plaintext unseal keys while remaining internet-free.
      # Replace with PKI cert-based seal for production regulated clients.
      extraConfig = <<-EOT
        seal "transit" {
          address            = "http://vault.vault.svc.cluster.local:8200"
          token              = "${var.vault_transit_seal_key_token}"
          disable_renewal    = "false"
          key_name           = "fde-airgap-unseal-key"
          mount_path         = "transit/"
          tls_skip_verify    = true  # lab only
        }
      EOT
      # No internet needed for storage — file backend, ephemeral by design
      dataStorage = {
        enabled      = true
        storageClass = "standard"
        size         = "2Gi"
      }
    }
    injector = { enabled = true }
    ui       = { enabled = true, serviceType = "ClusterIP" }
  })]

  depends_on = [kubernetes_namespace.airgap]
}

# ── Wait for Vault to be ready ────────────────────────────────────────────────

resource "null_resource" "vault_ready" {
  depends_on = [helm_release.vault_airgap]
  provisioner "local-exec" {
    command = <<-BASH
      echo "Waiting for Vault pod in ${var.namespace}..."
      kubectl wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=vault" \
        -n "${var.namespace}" \
        --timeout=120s
      echo "Vault ready."
    BASH
  }
}

# ── Model weights PVC (pre-staged; no HuggingFace pull at runtime) ─────────────

resource "kubernetes_persistent_volume_claim" "model_weights" {
  metadata {
    name      = "model-weights-pvc"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    annotations = {
      "fde.scenario/note"            = "Model weights must be pre-staged into this PVC before air-gap NetworkPolicy is applied. Zero HuggingFace network calls at serving time."
      "fde.scenario/pre-stage-cmd"   = "kubectl cp /local/models/${var.model_name} ${var.namespace}/model-staging-pod:/models/${var.model_name}"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    resources {
      requests = { storage = "20Gi" }
    }
  }
  depends_on = [kubernetes_namespace.airgap]
}

# ── vLLM Deployment (air-gapped, model from PVC) ───────────────────────────────

resource "kubernetes_deployment" "vllm" {
  metadata {
    name      = "vllm-server"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    labels = {
      app                      = "vllm-server"
      "fde.scenario/component" = "inference"
    }
    annotations = {
      "fde.scenario/no-internet" = "true"
    }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "vllm-server" } }
    template {
      metadata {
        labels = { app = "vllm-server", "fde.scenario/component" = "inference" }
      }
      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "vllm"
          image             = "${var.internal_registry}/vllm/vllm-openai:v0.6.3"
          image_pull_policy = "Never"  # Must be pre-loaded into kind
          args = [
            "--model", "/models/${var.model_name}",
            "--host", "0.0.0.0",
            "--port", "8000",
            "--trust-remote-code",
          ]
          env {
            # HF_OFFLINE=1 prevents any HuggingFace network calls at startup.
            # Without this, vLLM attempts to check for model updates even with a local path.
            name  = "HF_OFFLINE"
            value = "1"
          }
          env {
            name  = "TRANSFORMERS_OFFLINE"
            value = "1"
          }
          port { container_port = 8000 }
          volume_mount {
            name       = "model-weights"
            mount_path = "/models"
            read_only  = true
          }
          resources {
            requests = { cpu = "2", memory = "8Gi" }
            limits   = { cpu = "4", memory = "16Gi" }
          }
          liveness_probe {
            http_get { path = "/health"; port = 8000 }
            initial_delay_seconds = 30
            period_seconds        = 15
          }
          readiness_probe {
            http_get { path = "/health"; port = 8000 }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false  # vLLM writes model cache
            capabilities { drop = ["ALL"] }
          }
        }
        volume {
          name = "model-weights"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.model_weights.metadata[0].name
            read_only  = true
          }
        }
      }
    }
  }
  depends_on = [null_resource.vault_ready, kubernetes_persistent_volume_claim.model_weights]
}

# ── vLLM Service ──────────────────────────────────────────────────────────────

resource "kubernetes_service" "vllm" {
  metadata {
    name      = "vllm-server"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    labels    = { app = "vllm-server" }
  }
  spec {
    selector   = { app = "vllm-server" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
  depends_on = [kubernetes_deployment.vllm]
}

# ── LDAP Mock (simulates on-premise IdP) ──────────────────────────────────────

resource "kubernetes_secret" "ldap_admin" {
  metadata {
    name      = "ldap-admin-secret"
    namespace = kubernetes_namespace.airgap.metadata[0].name
  }
  type = "Opaque"
  data = {
    # Random admin password generated at bootstrap time — never static
    password = base64encode(bcrypt("ldap-admin-${var.namespace}-${timestamp()}"))
  }
  depends_on = [kubernetes_namespace.airgap]
}

resource "kubernetes_deployment" "ldap_mock" {
  metadata {
    name      = "ldap-mock"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    labels    = { app = "ldap-mock", "fde.scenario/component" = "idp" }
    annotations = {
      "fde.scenario/purpose" = "Simulate on-premise LDAP IdP — replaces SaaS OIDC in air-gapped environments"
    }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "ldap-mock" } }
    template {
      metadata { labels = { app = "ldap-mock" } }
      spec {
        container {
          name              = "openldap"
          image             = "${var.internal_registry}/osixia/openldap:1.5.0"
          image_pull_policy = "Never"
          env {
            name  = "LDAP_ORGANISATION"
            value = "FDE Client Corp"
          }
          env {
            name  = "LDAP_DOMAIN"
            value = "fde.client.corp"
          }
          env {
            name = "LDAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ldap_admin.metadata[0].name
                key  = "password"
              }
            }
          }
          port { container_port = 389; name = "ldap" }
          port { container_port = 636; name = "ldaps" }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.airgap]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "airgap_namespace" {
  value       = kubernetes_namespace.airgap.metadata[0].name
  description = "Namespace containing the air-gapped AI stack."
}

output "vllm_endpoint" {
  value       = "http://vllm-server.${var.namespace}.svc.cluster.local:8000/v1/chat/completions"
  description = "vLLM OpenAI-compatible endpoint. Use from within the cluster (e.g., from the ai-assistant pod)."
}

output "ldap_endpoint" {
  value       = "ldap://ldap-mock.${var.namespace}.svc.cluster.local:389"
  description = "LDAP endpoint for Vault auth method configuration. Base DN: dc=fde,dc=client,dc=corp"
}

output "verify_cmd" {
  value       = "bash scripts/fde/verify-airgap-bootstrap.sh"
  description = "Run this after apply to verify the 5-minute SLA."
}

output "sla_annotation" {
  value       = "kubectl get namespace ${var.namespace} -o jsonpath='{.metadata.annotations}'"
  description = "Inspect the namespace annotations to see bootstrap SLA target and scenario metadata."
}
