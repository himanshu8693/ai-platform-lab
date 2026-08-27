# FDE-001 — Forward Deployed Engineering: Air-Gap & Restricted VPC Deployment Scenario

| Field      | Value                                                      |
|------------|------------------------------------------------------------|
| **Status** | Active — Phase 2/3 Overlay (Months 5–9)                   |
| **Date**   | 2025-01-01                                                 |
| **Author** | Platform Engineering                                       |
| **Refs**   | ADR-002, ADR-005, terraform/main.tf, scripts/bootstrap-vault.sh |

---

## Context: Why FDE Constraints Belong in This Lab

Forward Deployed Engineers at Tier-1 AI product companies (Databricks, Anthropic, Scale AI,
Palantir) face a repeating class of deployment challenge that standard cloud-native tutorials
never cover:

> "The client's security team approved your Kubernetes cluster — but it has no internet
> access, their IdP is an on-premise LDAP server from 2014, the container registry is
> behind a corporate proxy that breaks TLS, and you have 72 hours to get vLLM serving
> with full audit logging before the pilot review."

This scenario overlay teaches you to solve exactly that class of problem by layering
air-gapped deployment constraints onto the existing `ai-platform-lab` topology.

**When to run this module:** After completing AI Weeks 10–12 (Argo Rollouts + Vault sidecar
working). You need a stable local kind cluster as the foundation before adding FDE constraints.

---

## The Simulated Client Environment

```
┌─────────────────────────────────────────────────────────────────┐
│  "Acme Corp" Restricted VPC — simulated by kind network policy  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  fde-airgap namespace (egress: BLOCKED by default)      │   │
│  │                                                         │   │
│  │  vLLM serving pod      ── model weights (pre-loaded)   │   │
│  │  Vault (air-gapped)    ── no internet unseal            │   │
│  │  Boundary Worker       ── localhost-only target         │   │
│  │  Context Forge         ── no outbound MCP calls         │   │
│  │  OTel Collector        ── internal sink only            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Simulated restrictions:                                        │
│  • No docker.io / ghcr.io pull (images pre-loaded into kind)   │
│  • No outbound HTTPS except to internal-registry:5000          │
│  • LDAP IdP: static ldap-mock pod (not Okta / OIDC SaaS)       │
│  • Corporate proxy: Squid pod injecting X-Corp-Proxy header    │
│  • Vault auto-unseal: AWS KMS DISABLED → Transit key seal       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Lab Task 1: Terraform 5-Minute VPC Bootstrap

**Objective:** Automate a complete `vLLM + Vault + Boundary` deployment into an isolated
namespace using only images pre-loaded into the local kind registry. Zero outbound internet
calls during bootstrap.

### Step 1 — Pre-load images into the kind internal registry

```bash
# Run this BEFORE applying the air-gap NetworkPolicy.
# These images must be in kind's local containerd cache before egress is blocked.

IMAGES=(
  "hashicorp/vault:1.17.2"
  "hashicorp/boundary:0.17.1"
  "ghcr.io/ibm/mcp-context-forge:latest"
  "vllm/vllm-openai:v0.6.3"   # or ollama/ollama:latest for Apple Silicon
  "postgres:16-alpine"
)

for img in "${IMAGES[@]}"; do
  docker pull "${img}"
  kind load docker-image "${img}" --name ai-platform-lab
done

echo "All images pre-loaded. Air-gap NetworkPolicy safe to apply."
```

### Step 2 — Apply the air-gap NetworkPolicy

```yaml
# topologies/fde-airgap/network-policy-airgap.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: airgap-default-deny-egress
  namespace: fde-airgap
  annotations:
    fde.scenario/purpose: "Simulate client VPC with no internet egress"
    fde.scenario/lab: "FDE-001"
spec:
  podSelector: {}  # applies to ALL pods in namespace
  policyTypes:
    - Egress
    - Ingress
  ingress:
    # Allow intra-namespace only
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: fde-airgap
  egress:
    # Allow DNS resolution (CoreDNS inside cluster)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Allow intra-namespace pod-to-pod (Vault ↔ Boundary ↔ MCP)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: fde-airgap
    # Allow access to internal-registry:5000 only (no public registries)
    - to:
        - podSelector:
            matchLabels:
              app: internal-registry
      ports:
        - protocol: TCP
          port: 5000
```

### Step 3 — Terraform module: `terraform/backends/airgap/main.tf`

```hcl
# terraform/backends/airgap/main.tf
# Air-gapped VPC bootstrap — no internet providers, no remote state.
# All chart repositories point to the in-cluster registry.
# Target: 5-minute wall-clock from `terraform apply` to serving endpoint healthy.

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
  # INTENTIONALLY no remote backend — air-gapped means no S3/GCS access.
  # State is local. Document this trade-off in the client's deployment runbook.
  backend "local" {
    path = "/tmp/fde-airgap-terraform.tfstate"
  }
}

variable "namespace" {
  type    = string
  default = "fde-airgap"
}

variable "internal_registry" {
  type        = string
  default     = "internal-registry.fde-airgap.svc.cluster.local:5000"
  description = "Internal OCI registry hostname:port. No internet access during deploy."
}

variable "vault_transit_seal_key" {
  type        = string
  sensitive   = true
  description = "Vault Transit auto-unseal key name. Used when AWS KMS is unavailable."
}

# ── Namespace with air-gap labels ──────────────────────────────────────────────
resource "kubernetes_namespace" "airgap" {
  metadata {
    name = var.namespace
    labels = {
      "kubernetes.io/metadata.name"        = var.namespace
      "pod-security.kubernetes.io/enforce" = "restricted"
      "fde.scenario/type"                  = "airgap"
      "fde.scenario/id"                    = "FDE-001"
    }
    annotations = {
      "fde.scenario/bootstrap-time-target" = "300s"  # 5-minute SLA
    }
  }
}

# ── Vault (air-gapped, Transit seal instead of AWS KMS) ────────────────────────
resource "helm_release" "vault_airgap" {
  name       = "vault"
  # Point to pre-loaded chart from internal registry, not helm.releases.hashicorp.com
  repository = "oci://${var.internal_registry}/charts"
  chart      = "vault"
  namespace  = kubernetes_namespace.airgap.metadata[0].name
  wait       = true
  timeout    = 180   # 3 min budget

  set {
    name  = "server.image.repository"
    value = "${var.internal_registry}/hashicorp/vault"
  }
  set {
    name  = "server.image.tag"
    value = "1.17.2"
  }
  set {
    name  = "server.dev.enabled"
    value = "false"
  }
  # Transit seal: when AWS KMS is unavailable, use a Vault Transit key
  # from a "parent" Vault instance (e.g., the main ai-platform-lab Vault).
  # This avoids plaintext unseal keys while remaining internet-free.
  set {
    name  = "server.ha.config"
    value = <<-EOT
      seal "transit" {
        address     = "http://vault.vault.svc.cluster.local:8200"
        token       = "${var.vault_transit_seal_key}"
        disable_renewal = "false"
        key_name    = "fde-airgap-unseal"
        mount_path  = "transit/"
      }
    EOT
  }

  depends_on = [kubernetes_namespace.airgap]
}

# ── vLLM / Ollama (air-gapped, model weights pre-loaded into PVC) ─────────────
resource "kubernetes_persistent_volume_claim" "model_weights" {
  metadata {
    name      = "model-weights-pvc"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    annotations = {
      "fde.scenario/note" = "Model weights pre-staged into this PVC before air-gap policy applied. No HuggingFace pull during serving."
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    resources {
      requests = { storage = "20Gi" }
    }
  }
}

resource "kubernetes_deployment" "vllm_airgap" {
  metadata {
    name      = "vllm-server"
    namespace = kubernetes_namespace.airgap.metadata[0].name
    labels    = { app = "vllm-server", "fde.scenario/id" = "FDE-001" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "vllm-server" } }
    template {
      metadata { labels = { app = "vllm-server" } }
      spec {
        container {
          name  = "vllm"
          image = "${var.internal_registry}/vllm/vllm-openai:v0.6.3"
          # Model loaded from PVC — no HuggingFace download at runtime
          args  = ["--model", "/models/llama3.2-3b", "--host", "0.0.0.0", "--port", "8000"]
          port { container_port = 8000 }
          volume_mount {
            name       = "model-weights"
            mount_path = "/models"
            read_only  = true
          }
          # No HF_TOKEN env var — no internet access available
          env {
            name  = "HF_OFFLINE"
            value = "1"   # Tells HuggingFace to use local cache only
          }
          resources {
            requests = { cpu = "2", memory = "8Gi" }
            limits   = { cpu = "4", memory = "16Gi" }
          }
        }
        volume {
          name = "model-weights"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim.model_weights.metadata[0].name }
        }
      }
    }
  }
  depends_on = [helm_release.vault_airgap]
}

output "bootstrap_time_note" {
  value = "Apply completed. Verify: kubectl get pods -n ${var.namespace} -w. Target: all pods Running within 300s."
}

output "vllm_endpoint" {
  value = "http://vllm-server.${var.namespace}.svc.cluster.local:8000/v1/chat/completions"
}
```

### Step 4 — Verification script

```bash
#!/usr/bin/env bash
# scripts/fde/verify-airgap-bootstrap.sh
# Verify the air-gapped VPC bootstrap within the 5-minute SLA.

set -euo pipefail
NS="fde-airgap"
START=$(date +%s)

log() { echo "[fde-verify] $(date -u +%H:%M:%S) $*"; }

log "Waiting for Vault pod to be Running..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault \
  -n "${NS}" --timeout=180s

log "Waiting for vLLM pod to be Running..."
kubectl wait --for=condition=ready pod -l app=vllm-server \
  -n "${NS}" --timeout=180s

log "Verifying zero outbound internet traffic (egress NetworkPolicy check)..."
kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s --max-time 5 https://huggingface.co 2>&1 | grep -q "Could not resolve\|Connection refused\|timed out" \
  && log "PASS: No internet egress (HuggingFace unreachable as expected)" \
  || { log "FAIL: Internet egress NOT blocked — check NetworkPolicy"; exit 1; }

log "Verifying vLLM serving endpoint responds..."
kubectl exec -n "${NS}" deploy/vllm-server -- \
  curl -s http://localhost:8000/health | grep -q "ok\|healthy" \
  && log "PASS: vLLM serving endpoint healthy"

END=$(date +%s)
ELAPSED=$((END - START))
log "Bootstrap verification complete in ${ELAPSED}s (target: ≤300s)"
[[ "${ELAPSED}" -le 300 ]] && log "SLA: PASS" || log "SLA: MISS — review timing"
```

---

## Lab Task 2: Legacy IdP Integration (LDAP Mock)

Enterprise clients rarely have Okta. Deploy a mock LDAP server and wire Vault's auth
method to it — the same workflow you will face at 70% of regulated enterprise clients.

```yaml
# topologies/fde-airgap/ldap-mock.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ldap-mock
  namespace: fde-airgap
  annotations:
    fde.scenario/purpose: "Simulate on-premise LDAP IdP — no SaaS OIDC available"
spec:
  replicas: 1
  selector:
    matchLabels: {app: ldap-mock}
  template:
    metadata:
      labels: {app: ldap-mock}
    spec:
      containers:
        - name: openldap
          image: internal-registry.fde-airgap.svc.cluster.local:5000/osixia/openldap:1.5.0
          env:
            - name: LDAP_ORGANISATION
              value: "Acme Corp"
            - name: LDAP_DOMAIN
              value: "acme.corp"
            - name: LDAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ldap-admin-secret
                  key: password
          ports:
            - containerPort: 389
              name: ldap
            - containerPort: 636
              name: ldaps
```

```bash
# Wire Vault LDAP auth method (run in bootstrap-vault.sh, airgap mode):
vault auth enable ldap

vault write auth/ldap/config \
  url="ldap://ldap-mock.fde-airgap.svc.cluster.local:389" \
  userdn="ou=users,dc=acme,dc=corp" \
  groupdn="ou=groups,dc=acme,dc=corp" \
  groupattr="cn" \
  userattr="uid" \
  binddn="cn=admin,dc=acme,dc=corp" \
  bindpass="${LDAP_ADMIN_PASSWORD}" \
  insecure_tls=true  # lab only — prod requires cert chain

# Create Vault group mapping for the "platform-engineers" LDAP group
vault write identity/group \
  name="platform-engineers" \
  type="external" \
  policies="boundary-mcp-credential-policy"

vault write identity/group-alias \
  name="platform-engineers" \
  canonical_id="$(vault read -field=id identity/group/name/platform-engineers)" \
  mount_accessor="$(vault auth list -format=json | jq -r '.["ldap/"].accessor')"
```

---

## Lab Task 3: Corporate Proxy Penetration

Many enterprise deployments route ALL outbound traffic through an authenticated HTTP proxy.
Simulate this and teach your tools to respect it.

```bash
# Deploy Squid proxy in fde-airgap namespace
kubectl apply -n fde-airgap -f topologies/fde-airgap/squid-proxy.yaml

# Configure Vault to use the corporate proxy for any outbound calls
# (e.g., reaching HCP Vault, PKI CRL distribution point)
kubectl set env deployment/vault -n fde-airgap \
  HTTPS_PROXY="http://squid-proxy.fde-airgap.svc.cluster.local:3128" \
  NO_PROXY="vault.fde-airgap.svc.cluster.local,10.96.0.0/12,10.244.0.0/16"

# Verify proxy header injection (Squid adds X-Forwarded-For)
kubectl exec -n fde-airgap deploy/vllm-server -- \
  curl -v --proxy http://squid-proxy.fde-airgap.svc.cluster.local:3128 \
  http://internal-registry.fde-airgap.svc.cluster.local:5000/v2/ 2>&1 \
  | grep "X-Forwarded-For\|X-Corp-Proxy"
```

---

## FDE Gate Checklist

Before moving to the next learning block, all gates must pass:

```
[ ] terraform apply -var-file=airgap.tfvars completes in ≤300s wall-clock
[ ] scripts/fde/verify-airgap-bootstrap.sh reports SLA: PASS
[ ] vault auth list shows "ldap/" enabled
[ ] vault login -method=ldap username=fde-engineer works
[ ] vllm-server pod is Running with HF_OFFLINE=1 (no HuggingFace pull)
[ ] NetworkPolicy airgap-default-deny-egress blocks outbound internet
[ ] boundary connect postgres -target-id=<id> works with Vault-injected creds
[ ] ADR updated: document the transit-seal trade-off for regulated clients
[ ] Blog post draft: "Deploying vLLM in 5 Minutes into an Air-Gapped VPC"
```

---

## FDE Interview Story: The "Messy Client" Narrative

When asked "Tell me about the hardest deployment you've done," answer with this structure:

> "At IBM, I supported enterprise Kubernetes clusters across 40+ accounts.
> I built a portable Ephemeral Lab Engine that replicates the exact constraints I see
> on client sites: no internet egress, legacy LDAP IdPs, corporate proxy interception,
> and Vault auto-unseal without AWS KMS.
>
> The specific FDE scenario I built is: 5-minute automated bootstrap of vLLM + Vault +
> Boundary into an isolated namespace using only pre-loaded container images and
> Terraform. Zero manual kubectl commands. The model serves requests inside 5 minutes.
>
> I use this to simulate Sev-1 reproduction in client environments — the same scenario
> a Forward Deployed Engineer faces on Day 1 of a new enterprise engagement.
> That's the same problem your FDE team solves for [Databricks/Anthropic/Scale AI] clients."
