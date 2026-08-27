# terraform/backends/cloud/eks-ephemeral.tf
# G7 — Cloud vs On-Prem Deployment Strategy (ADR-016)
#
# STUB ONLY — demonstrates the ephemeral EKS sandbox pattern for Sr SA interviews.
# Accompanies docs/adr/ADR-016-cloud-vs-onprem-deployment-strategy.md
#
# Cost estimate (if actually applied):
#   EKS control plane:  $0.10/hr
#   g4dn.xlarge node:   $0.526/hr (1× NVIDIA T4 GPU, on-demand)
#   Total 4-hr sandbox: ~$2.50
#
# NEVER apply this without a dedicated AWS account and explicit cost approval.
# The Terraform state backend for this module must be isolated from the local kind backend.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Use a separate state key from local kind/k3d backends
  backend "s3" {
    bucket         = "tf-state-ai-platform-ephemeral"
    key            = "cloud/eks-ephemeral/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-state-locks-ephemeral"
    encrypt        = true
  }
}

variable "ttl_hours" {
  description = "Hours before automatic teardown via CloudWatch scheduled event + Lambda"
  type        = number
  default     = 4
}

variable "cluster_name" {
  description = "Ephemeral cluster name — include scenario ID and requester initials, e.g. 'consul-ap-fde001-hs'"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the ephemeral sandbox"
  type        = string
  default     = "us-east-1"
}

# VPC is created by a separate networking module (not shown here)
# In a real deployment: module.vpc.private_subnets → subnet_ids below
locals {
  common_tags = {
    ttl_hours   = var.ttl_hours
    teardown_by = timeadd(timestamp(), "${var.ttl_hours}h")
    scenario    = "ephemeral-lab-engine"
    managed_by  = "terraform"
    cluster     = var.cluster_name
  }
}

resource "aws_eks_cluster" "ephemeral" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn   # role defined in iam.tf (not shown)
  version  = "1.31"

  vpc_config {
    subnet_ids              = []            # replace with module.vpc.private_subnets
    endpoint_private_access = true
    endpoint_public_access  = false         # air-gap compatible — no public API endpoint
  }

  tags = local.common_tags
}

resource "aws_eks_node_group" "inference_gpu" {
  cluster_name    = aws_eks_cluster.ephemeral.name
  node_group_name = "inference-gpu"
  node_role_arn   = aws_iam_role.eks_node.arn   # role defined in iam.tf (not shown)
  subnet_ids      = []                           # replace with module.vpc.private_subnets
  instance_types  = ["g4dn.xlarge"]              # 1× T4 16GB GPU, ~$0.526/hr on-demand

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 3
  }

  labels = {
    "nvidia.com/gpu"          = "true"
    "node.kubernetes.io/role" = "inference"
  }

  tags = local.common_tags
}

# TTL teardown: CloudWatch EventBridge scheduled rule → Lambda → `terraform destroy`
resource "aws_cloudwatch_event_rule" "auto_teardown" {
  name                = "${var.cluster_name}-auto-teardown"
  description         = "Triggers ephemeral sandbox teardown after TTL expires"
  schedule_expression = "rate(${var.ttl_hours} hours)"
  tags                = local.common_tags
}

output "cluster_name" {
  value       = aws_eks_cluster.ephemeral.name
  description = "EKS cluster name — use with: aws eks update-kubeconfig --name <value>"
}

output "teardown_at" {
  value       = timeadd(timestamp(), "${var.ttl_hours}h")
  description = "Estimated teardown time (UTC)"
}
