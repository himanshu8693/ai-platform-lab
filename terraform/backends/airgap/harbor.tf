# =============================================================================
# terraform/backends/airgap/harbor.tf
# Harbor OCI Registry — Air-Gapped VPC Mirror
#
# Gap F fix: deploys a Harbor registry inside the air-gapped VPC that acts as
# the sole OCI image source for all platform workloads. No image pulls from
# Docker Hub, GHCR, or public registries are permitted after the pre-flight
# mirror step (scripts/fde/preload-images.sh).
#
# Architecture:
#   Internet (pre-flight only) → scripts/fde/preload-images.sh → Harbor (in-VPC)
#   All K8s nodes → Harbor (in-VPC) — no direct internet image pulls
#   ArgoCD → Harbor Helm chart cache (chartmuseum embedded)
#   Terraform providers → filesystem mirror (vendor/terraform-providers/)
#
# References: ADR-F01 (to be written), docs/scenarios/FDE-001-airgap-vpc-deployment.md
# =============================================================================

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "harbor_namespace" {
  type    = string
  default = "harbor"
}

variable "harbor_admin_password" {
  type      = string
  sensitive = true
  description = "Harbor admin password. Set via TF_VAR_harbor_admin_password. Rotated after initial bootstrap."
}

variable "harbor_hostname" {
  type        = string
  default     = "registry.internal.airgap"
  description = "Internal DNS name for Harbor. Must be resolvable within the air-gap VPC."
}

variable "harbor_storage_size" {
  type        = string
  default     = "50Gi"
  description = "PVC size for Harbor registry storage. Size for all platform images."
}

variable "harbor_chart_version" {
  type        = string
  default     = "1.15.0"
  description = "Harbor Helm chart version. Must be mirrored to chartmuseum before applying."
}

# ── Namespace: harbor ─────────────────────────────────────────────────────────
resource "kubernetes_namespace" "harbor" {
  metadata {
    name = var.harbor_namespace
    labels = {
      "kubernetes.io/metadata.name" = var.harbor_namespace
      "platform.ai/managed-by"      = "terraform"
      "platform.ai/gap"             = "F"
    }
  }
}

# ── Harbor: deployed via Helm ──────────────────────────────────────────────────
# The Harbor chart is sourced from the in-cluster chartmuseum (not from internet).
# Chart must be pre-loaded into chartmuseum during the pre-flight step:
#   helm repo add harbor-offline oci://registry.internal.airgap/harbor
#   OR: manually upload the harbor-<version>.tgz to chartmuseum via API

resource "helm_release" "harbor" {
  name       = "harbor"
  namespace  = var.harbor_namespace
  repository = "oci://${var.harbor_hostname}/charts"   # in-cluster OCI chart repo
  chart      = "harbor"
  version    = var.harbor_chart_version

  # In air-gap mode: chart must already be present in the registry
  # Run: helm push harbor-${version}.tgz oci://${harbor_hostname}/charts
  # before terraform apply

  values = [<<-YAML
    expose:
      type: clusterIP
      tls:
        enabled: false   # mTLS via Consul mesh; plain HTTP within cluster
      clusterIP:
        name: harbor
        ports:
          httpPort: 80

    externalURL: "http://${var.harbor_hostname}"

    harborAdminPassword: "${var.harbor_admin_password}"

    # Disable external access — all registry traffic stays in-cluster
    ingress:
      enabled: false

    # Registry storage: local PVC
    persistence:
      enabled: true
      persistentVolumeClaim:
        registry:
          size: "${var.harbor_storage_size}"
        chartmuseum:
          size: "10Gi"
        jobservice:
          size: "2Gi"
        database:
          size: "5Gi"
        redis:
          size: "2Gi"
        trivy:
          size: "5Gi"

    # Trivy: vulnerability scanning (runs offline with pre-loaded DB)
    trivy:
      enabled: true
      offlineScan: true   # do not pull CVE DB from internet
      skipUpdate: true    # DB must be pre-loaded during pre-flight

    # Replication rules: pre-defined projects for platform image categories
    # These are populated by scripts/fde/preload-images.sh
    updateStrategy:
      type: Recreate

    # Resource limits appropriate for air-gap VPC VM sizes
    core:
      resources:
        requests: { cpu: "100m", memory: "256Mi" }
        limits:   { cpu: "1",    memory: "512Mi" }
    registry:
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "1",    memory: "512Mi" }
  YAML
  ]

  depends_on = [kubernetes_namespace.harbor]
}

# ── Harbor Projects: pre-created via Terraform ───────────────────────────────
# Projects organize images by platform component. Each project has a pull-only
# robot account that cluster nodes use (no push permissions at runtime).

resource "null_resource" "harbor_projects" {
  triggers = {
    harbor_ready = helm_release.harbor.status
  }

  provisioner "local-exec" {
    command = <<-EOT
      HARBOR_URL="http://${var.harbor_hostname}"
      ADMIN_PASS="${var.harbor_admin_password}"

      # Wait for Harbor to be ready
      until curl -sf "$${HARBOR_URL}/api/v2.0/health" -u "admin:$${ADMIN_PASS}" | grep -q '"status":"healthy"'; do
        echo "Waiting for Harbor..."
        sleep 10
      done

      for PROJECT in platform-base inference security monitoring argocd vault consul boundary; do
        curl -sf -X POST "$${HARBOR_URL}/api/v2.0/projects" \
          -u "admin:$${ADMIN_PASS}" \
          -H "Content-Type: application/json" \
          -d "{\"project_name\": \"$${PROJECT}\", \"public\": false, \"metadata\": {\"prevent_vul\": \"true\", \"severity\": \"critical\"}}" \
          && echo "Created project: $${PROJECT}" \
          || echo "Project $${PROJECT} may already exist — skipping"
      done
    EOT
  }
}

# ── Robot account: cluster-pull (read-only) ───────────────────────────────────
resource "null_resource" "harbor_pull_robot" {
  triggers = {
    harbor_ready = helm_release.harbor.status
  }

  provisioner "local-exec" {
    command = <<-EOT
      HARBOR_URL="http://${var.harbor_hostname}"
      ADMIN_PASS="${var.harbor_admin_password}"

      # Create a system-level robot account with pull permissions on all projects
      curl -sf -X POST "$${HARBOR_URL}/api/v2.0/robots" \
        -u "admin:$${ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d '{
          "name": "cluster-pull",
          "duration": -1,
          "description": "Pull-only robot account for all K8s nodes",
          "permissions": [
            {
              "kind": "System",
              "namespace": "/",
              "access": [
                {"resource": "repository", "action": "pull"},
                {"resource": "repository", "action": "list"}
              ]
            }
          ]
        }' > /tmp/harbor-robot-token.json

      echo "Robot account token saved to /tmp/harbor-robot-token.json"
      echo "Store the robot.secret as a Kubernetes imagePullSecret in every namespace."
      cat /tmp/harbor-robot-token.json | jq '{name: .name, secret: .secret}'
    EOT
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "harbor_url" {
  value       = "http://${var.harbor_hostname}"
  description = "Harbor registry URL. Nodes use this as the image pull base."
}

output "harbor_create_imagepullsecret_cmd" {
  value = "kubectl create secret docker-registry harbor-pull --docker-server=${var.harbor_hostname} --docker-username=robot\\$cluster-pull --docker-password=<token-from-robot-account> --namespace=<namespace>"
  description = "Create the imagePullSecret in each namespace after getting the robot account token."
}

output "harbor_push_image_example" {
  value       = "docker tag ghcr.io/ibm/mcp-context-forge:latest ${var.harbor_hostname}/inference/mcp-context-forge:latest && docker push ${var.harbor_hostname}/inference/mcp-context-forge:latest"
  description = "Example: mirror an image to Harbor. Run this during pre-flight (scripts/fde/preload-images.sh does this for all platform images)."
}
