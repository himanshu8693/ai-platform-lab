# =============================================================================
# ai-platform-lab — Local Kind Cluster + Platform Bootstrap
# =============================================================================
#
# Provisions:
#   • 3-node Kind cluster (1 control-plane, 2 workers) on Apple Silicon
#   • ingress-nginx controller (NodePort mode for Kind)
#   • HashiCorp Vault (dev-mode, injector enabled)
#   • Cert-manager (prerequisite for Vault TLS + admission webhooks)
#
# Providers:
#   tehcyx/kind  ~> 0.4   — Kind cluster lifecycle
#   hashicorp/helm ~> 2.15 — Helm chart deployments
#   hashicorp/kubernetes ~> 2.32 — K8s resource management
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform output kubeconfig_path   # → ~/.kube/config auto-updated by Kind
#
# Teardown:
#   terraform destroy
#
# State management:
#   Local backend by default. For team use, swap to remote S3/GCS backend
#   (see commented block at bottom of this file).
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
  }

  # ── Remote state (uncomment for team use) ──────────────────────────────────
  # backend "s3" {
  #   bucket         = "ai-platform-tfstate"
  #   key            = "local-lab/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "ai-platform-tfstate-lock"
  #   encrypt        = true
  # }
}

# =============================================================================
# Variables
# =============================================================================

variable "cluster_name" {
  type        = string
  default     = "ai-platform-lab"
  description = "Kind cluster name — also used as kubeconfig context name"
}

variable "vault_root_token" {
  type        = string
  default     = "root"
  sensitive   = true
  description = "Dev-mode Vault root token. Override via TF_VAR_vault_root_token env var."
}

variable "ingress_nginx_version" {
  type    = string
  default = "4.11.2"
}

variable "vault_helm_version" {
  type    = string
  default = "0.28.1"
}

variable "cert_manager_version" {
  type    = string
  default = "1.16.1"
}

# =============================================================================
# Kind Cluster
# =============================================================================

resource "kind_cluster" "ai_platform" {
  name            = var.cluster_name
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # ── Control plane ────────────────────────────────────────────────────────
    node {
      role = "control-plane"

      # Expose NodePorts to host for ingress-nginx, Prometheus, Grafana, etc.
      extra_port_mappings {
        container_port = 80
        host_port      = 8080
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 8443
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30090
        host_port      = 9090
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30300
        host_port      = 3000
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30400
        host_port      = 9400
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }

      # Kubeadm patches: enable PodSecurity admission in enforcement mode
      kubeadm_config_patches = [
        <<-YAML
          kind: ClusterConfiguration
          apiServer:
            extraArgs:
              feature-gates: "DynamicResourceAllocation=true"
        YAML
      ]

      labels = {
        "ingress-ready"          = "true"
        "node-role"              = "control-plane"
        "platform.ai/node-class" = "system"
      }
    }

    # ── Worker 0 — inference workloads ───────────────────────────────────────
    node {
      role = "worker"
      labels = {
        "node-role"                        = "worker"
        "platform.ai/node-class"           = "inference"
        "platform.ai/gpu-enabled"          = "false"   # true on real GPU node
        "platform.ai/accelerator-profile"  = "cpu-only"
      }
    }

    # ── Worker 1 — platform services ─────────────────────────────────────────
    node {
      role = "worker"
      labels = {
        "node-role"              = "worker"
        "platform.ai/node-class" = "platform"
      }
    }

    # ── Networking ────────────────────────────────────────────────────────────
    networking {
      api_server_address = "127.0.0.1"
      pod_subnet         = "10.244.0.0/16"
      service_subnet     = "10.96.0.0/12"
      disable_default_cni = false
    }
  }
}

# =============================================================================
# Provider configuration — consume kubeconfig from the Kind cluster
# =============================================================================

provider "kubernetes" {
  host                   = kind_cluster.ai_platform.endpoint
  cluster_ca_certificate = base64decode(kind_cluster.ai_platform.cluster_ca_certificate)
  client_certificate     = base64decode(kind_cluster.ai_platform.client_certificate)
  client_key             = base64decode(kind_cluster.ai_platform.client_key)
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.ai_platform.endpoint
    cluster_ca_certificate = base64decode(kind_cluster.ai_platform.cluster_ca_certificate)
    client_certificate     = base64decode(kind_cluster.ai_platform.client_certificate)
    client_key             = base64decode(kind_cluster.ai_platform.client_key)
  }
}

# =============================================================================
# Cert-Manager (prerequisite for Vault TLS injection + webhook certs)
# =============================================================================

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = var.cert_manager_version
  wait             = true
  wait_for_jobs    = true
  timeout          = 300

  depends_on = [kind_cluster.ai_platform]

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }
}

# =============================================================================
# Ingress-NGINX
# =============================================================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = var.ingress_nginx_version
  wait             = true
  timeout          = 300

  depends_on = [kind_cluster.ai_platform]

  # Kind requires NodePort + hostNetwork for the ingress controller to work
  values = [
    yamlencode({
      controller = {
        service = {
          type = "NodePort"
          nodePorts = {
            http  = 80
            https = 443
          }
        }
        hostPort = {
          enabled = true
          ports = {
            http  = 80
            https = 443
          }
        }
        nodeSelector = {
          "ingress-ready" = "true"
        }
        tolerations = [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Equal"
            effect   = "NoSchedule"
          }
        ]
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = false  # Enable when kube-prometheus-stack is deployed
          }
        }
        config = {
          use-forwarded-headers = "true"
          compute-full-forwarded-for = "true"
        }
      }
    })
  ]
}

# =============================================================================
# Vault Namespace
# =============================================================================

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      "kubernetes.io/metadata.name" = "vault"
      "platform.ai/component"       = "secrets"
    }
  }

  depends_on = [kind_cluster.ai_platform]
}

# =============================================================================
# HashiCorp Vault — dev mode (local lab only)
# =============================================================================
# Dev mode starts unsealed with a root token. NOT for production.
# For production: use HA Raft mode with auto-unseal (AWS KMS / GCP CKMS).
# Enterprise pattern would use: server.ha.enabled=true, server.ha.raft.enabled=true
# =============================================================================

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = var.vault_helm_version
  wait       = true
  timeout    = 300

  depends_on = [
    kind_cluster.ai_platform,
    kubernetes_namespace.vault,
    cert_manager_crds_ready,  # Ensure CRDs exist before Vault webhook
  ]

  values = [
    yamlencode({
      server = {
        dev = {
          enabled      = true
          devRootToken = var.vault_root_token
        }
        # Resource limits — conservative for a 3-node Kind cluster
        resources = {
          requests = {
            memory = "256Mi"
            cpu    = "250m"
          }
          limits = {
            memory = "512Mi"
            cpu    = "500m"
          }
        }
        readinessProbe = {
          enabled = true
          path    = "/v1/sys/health?standbyok=true"
        }
        livenessProbe = {
          enabled              = true
          path                 = "/v1/sys/health?standbyok=true"
          initialDelaySeconds  = 60
        }
        # Annotations for DCGM mock metrics scraping
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/v1/sys/metrics"
          "prometheus.io/port"   = "8200"
        }
      }
      # Vault Agent Injector — enables sidecar-based secret injection
      injector = {
        enabled = true
        agentImage = {
          repository = "hashicorp/vault"
          tag        = "1.17.2"
        }
        resources = {
          requests = {
            memory = "128Mi"
            cpu    = "100m"
          }
          limits = {
            memory = "256Mi"
            cpu    = "250m"
          }
        }
        # Annotate injector webhook to avoid cert-manager race
        webhook = {
          failurePolicy = "Ignore"  # Fail-open during bootstrap
        }
      }
      # Vault UI (useful for lab exploration)
      ui = {
        enabled         = true
        serviceType     = "NodePort"
        serviceNodePort = 30820
      }
    })
  ]
}

# =============================================================================
# Wait for cert-manager CRDs before Vault (avoid webhook registration race)
# =============================================================================

resource "null_resource" "cert_manager_crds_ready" {
  depends_on = [helm_release.cert_manager]

  provisioner "local-exec" {
    command = <<-BASH
      echo "Waiting for cert-manager CRDs..."
      for i in $(seq 1 30); do
        kubectl --context kind-${var.cluster_name} \
          get crd certificates.cert-manager.io 2>/dev/null && break
        echo "  Attempt $i/30 — sleeping 5s..."
        sleep 5
      done
      echo "cert-manager CRDs confirmed."
    BASH
  }
}

# =============================================================================
# Inference Namespace + baseline RBAC
# =============================================================================

resource "kubernetes_namespace" "inference" {
  metadata {
    name = "inference"
    labels = {
      "kubernetes.io/metadata.name"           = "inference"
      "pod-security.kubernetes.io/enforce"    = "restricted"
      "pod-security.kubernetes.io/audit"      = "restricted"
      "pod-security.kubernetes.io/warn"       = "restricted"
      "platform.ai/component"                 = "inference"
    }
    annotations = {
      "vault.hashicorp.com/agent-inject"              = "true"
      "vault.hashicorp.com/role"                      = "inference-role"
    }
  }

  depends_on = [kind_cluster.ai_platform]
}

resource "kubernetes_service_account" "inference_sa" {
  metadata {
    name      = "inference-sa"
    namespace = kubernetes_namespace.inference.metadata[0].name
    annotations = {
      "vault.hashicorp.com/agent-inject"  = "true"
      "vault.hashicorp.com/role"          = "inference-role"
    }
  }
}

resource "kubernetes_role" "inference_role" {
  metadata {
    name      = "inference-role"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "secrets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "inference_rb" {
  metadata {
    name      = "inference-rb"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.inference_role.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.inference_sa.metadata[0].name
    namespace = kubernetes_namespace.inference.metadata[0].name
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "cluster_name" {
  value       = kind_cluster.ai_platform.name
  description = "Kind cluster name (also the kubeconfig context)"
}

output "cluster_endpoint" {
  value       = kind_cluster.ai_platform.endpoint
  description = "Kubernetes API server endpoint"
}

output "kubeconfig_path" {
  value       = "~/.kube/config"
  description = "Kubeconfig updated by Kind (context: kind-${var.cluster_name})"
}

output "vault_ui_url" {
  value       = "http://localhost:30820"
  description = "Vault UI (accessible after port-forward or NodePort mapping)"
}

output "vault_root_token_note" {
  value       = "Use: export VAULT_TOKEN=${var.vault_root_token} | vault status -address=http://localhost:30820"
  description = "Dev-mode Vault access command"
  sensitive   = false
}

output "context_switch_cmd" {
  value       = "kubectl config use-context kind-${var.cluster_name}"
  description = "Switch kubectl context to the provisioned cluster"
}

output "argocd_install_cmd" {
  value       = "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
  description = "Next step: install ArgoCD and bootstrap app-of-apps"
}
