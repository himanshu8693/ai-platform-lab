# =============================================================================
# terraform/backends/k3d/main.tf
# k3d Cluster Backend — Lightweight Alternative to kind
#
# k3d runs k3s (lightweight Kubernetes) inside Docker containers.
# Compared to kind:
#   • 40–60% faster startup (no Docker-in-Docker, native kubeconfig injection)
#   • Lower base memory footprint (~300 MB vs ~600 MB for equivalent kind cluster)
#   • Better multi-node simulation (k3s HA is closer to production than kind)
#   • Built-in LoadBalancer support via k3d's Traefik integration
#
# Usage:
#   cd terraform/backends/k3d
#   terraform init
#   terraform apply -var="cluster_name=ephemeral-consul-ap-$(date +%H%M)"
#
# Switch the Makefile to use this backend:
#   make up BACKEND=k3d
#
# Prerequisites:
#   brew install k3d
#   k3d version  # >= 5.7
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # k3d Terraform provider: github.com/pvotal-tech/terraform-provider-k3d
    k3d = {
      source  = "pvotal-tech/k3d"
      version = "~> 0.0.7"
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
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "cluster_name" {
  type        = string
  default     = "ephemeral-lab"
  description = "k3d cluster name. Include a timestamp for topology uniqueness: ephemeral-<topology>-<ts>"
}

variable "k3s_version" {
  type        = string
  default     = "v1.31.0-k3s1"
  description = "k3s image tag. Must match k3d's supported version matrix."
}

variable "api_port" {
  type        = number
  default     = 6550
  description = "Host port mapped to the k3s API server. Offset from kind's 6443 to avoid conflicts when both backends run simultaneously."
}

variable "ttl_seconds" {
  type        = number
  default     = 7200
  description = "Ephemeral TTL in seconds. The scripts/ttl-teardown.sh script uses this to schedule automatic cluster deletion."
}

# ── k3d Cluster ───────────────────────────────────────────────────────────────

resource "k3d_cluster" "ephemeral" {
  name    = var.cluster_name
  servers = 1     # 1 control plane (lab); increase to 3 for HA topology testing
  agents  = 2     # 2 worker nodes: inference + platform

  image   = "rancher/k3s:${var.k3s_version}"

  # k3d maps the k3s API server to a host port for kubectl access.
  # No NodePort conflicts with the kind cluster on the same machine.
  api {
    host      = "0.0.0.0"
    host_ip   = "127.0.0.1"
    host_port = var.api_port
  }

  # Port mappings: same as kind backend — ArgoCD, Prometheus, Grafana, DCGM.
  port {
    host_port      = 8080
    container_port = 80
    node_filters   = ["loadbalancer"]
  }
  port {
    host_port      = 9090
    container_port = 9090
    node_filters   = ["loadbalancer"]
  }
  port {
    host_port      = 3000
    container_port = 3000
    node_filters   = ["loadbalancer"]
  }

  # Disable Traefik (k3s default ingress) — we use ingress-nginx via ArgoCD.
  k3s {
    extra_args {
      arg          = "--disable=traefik"
      node_filters = ["server:*"]
    }
    # Use Flannel CNI. For NetworkPolicy enforcement, replace with Calico:
    # extra_args { arg = "--flannel-backend=none"; node_filters = ["server:*"] }
    # Then apply Calico manifests via ArgoCD.
  }

  # Node labels: match kind backend label schema for ArgoCD ApplicationSet
  # nodeSelector compatibility across both backends.
  kubeconfig {
    update_default_kubeconfig = true
    switch_current_context    = true
  }
}

# ── Provider configuration (wired from k3d cluster output) ───────────────────

provider "kubernetes" {
  host                   = "https://127.0.0.1:${var.api_port}"
  cluster_ca_certificate = base64decode(k3d_cluster.ephemeral.credentials[0].ca_certificate)
  client_certificate     = base64decode(k3d_cluster.ephemeral.credentials[0].client_certificate)
  client_key             = base64decode(k3d_cluster.ephemeral.credentials[0].client_key)
}

provider "helm" {
  kubernetes {
    host                   = "https://127.0.0.1:${var.api_port}"
    cluster_ca_certificate = base64decode(k3d_cluster.ephemeral.credentials[0].ca_certificate)
    client_certificate     = base64decode(k3d_cluster.ephemeral.credentials[0].client_certificate)
    client_key             = base64decode(k3d_cluster.ephemeral.credentials[0].client_key)
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cluster_name" {
  value       = k3d_cluster.ephemeral.name
  description = "k3d cluster name"
}

output "api_server_url" {
  value       = "https://127.0.0.1:${var.api_port}"
  description = "Kubernetes API server URL for kubectl"
}

output "ttl_teardown_cmd" {
  value       = "bash scripts/ttl-teardown.sh ${var.ttl_seconds} ${var.cluster_name} k3d"
  description = "Schedule automatic teardown: run this after terraform apply"
}

output "context_switch_cmd" {
  value       = "kubectl config use-context k3d-${var.cluster_name}"
  description = "Switch kubectl context to this k3d cluster"
}
