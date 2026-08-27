# ADR-002: Secret Injection Strategy

**Status**: Accepted  
**Date**: 2025-01-20  
**Deciders**: Himanshu Sharma

---

## Context

Inference pods need access to a HuggingFace Hub API token (`HF_TOKEN`) to pull gated model weights. The platform also anticipates future secrets: inference API keys, object-store credentials, TLS client certs.

The question is how to inject secrets into pods without storing them in Kubernetes Secret objects (which are base64-encoded, not encrypted at rest by default) or environment variables (which appear in `kubectl describe pod` and process listings).

---

## Decision Drivers

1. **CKS alignment**: The CKS exam tests Vault integration, secret management, and principle of least privilege
2. **No secrets in environment variables**: `kubectl describe pod` exposure and `/proc/<pid>/environ` leakage
3. **Dynamic rotation**: Secrets should be rotatable without pod restart where possible
4. **Audit trail**: All secret accesses should be logged (Vault audit log)
5. **Simplicity for lab**: Dev-mode Vault is acceptable; HA Vault is a Phase 3 concern

---

## Options Considered

### Option A: Kubernetes Secrets as environment variables

```yaml
env:
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: hf-token
      key: token
```

**Rejected**: Secret value visible in `kubectl describe pod`; in process environment (`/proc/1/environ`); base64-decoded by anyone with `kubectl get secret`. Fails CKS best practices.

### Option B: Kubernetes Secrets as mounted volumes

```yaml
volumes:
- name: hf-secret
  secret:
    secretName: hf-token
volumeMounts:
- mountPath: /run/secrets
  readOnly: true
```

**Partial improvement**: Not in environment, but Kubernetes Secrets are still stored unencrypted in etcd unless etcd encryption is configured. Rotation requires pod restart. No audit log.

### Option C: External Secrets Operator (ESO) + AWS Secrets Manager / GCP Secret Manager

**Pros**: Clean Kubernetes-native API; supports rotation; audit via cloud provider  
**Cons**: Requires cloud account (AWS/GCP/Azure); more complex for a local Kind lab; adds ESO CRD dependency; overkill for dev phase

### Option D: HashiCorp Vault Agent Sidecar Injection (selected)

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/agent-inject-secret-hf-token: "secret/data/ai-platform/hf-token"
  vault.hashicorp.com/role: "inference-role"
```

**Pros**:
- Secret written to `tmpfs` volume at `/vault/secrets/` — not in environment, not persisted to disk
- Vault audit log records every read (who, when, which secret, from which pod SA)
- Kubernetes auth method: pod SA token → Vault role → policy → KV-v2 secret
- Supports dynamic rotation: Vault Agent re-fetches on lease expiry (static KV requires restart, dynamic creds do not)
- Direct CKS exam evidence: Vault Agent injection is a canonical Kubernetes secrets management pattern
- Dev-mode Vault deployed via Terraform; same code targets HA Vault in production (change Helm values only)

**Cons**:
- Adds `vault-agent-init` init container + `vault-agent` sidecar to every pod (+~50 MB memory, +~0.1 CPU)
- Vault must be running before pod starts (init container fails otherwise)
- `vault.hashicorp.com/agent-inject-secret-*` annotation pattern ties workload to Vault-specific annotations

---

## Decision

**Use HashiCorp Vault Agent sidecar injection for all secrets.**

KV-v2 path: `secret/data/ai-platform/{secret-name}`  
Kubernetes auth role: `inference-role` bound to SA `default` in namespace `inference`

Vault policy (`inference-policy`):
```hcl
path "secret/data/ai-platform/*" {
  capabilities = ["read"]
}
```

---

## Consequences

- `kube-linter.yaml` excludes `read-secret-from-env-var` check (false positive on vault-agent annotation pattern)
- NetworkPolicy must allow Vault egress from inference pods (Policy 5 in `networkpolicy.yaml`)
- `HF_TOKEN` is read from `/vault/secrets/hf-token` in entrypoint scripts, not from `$HF_TOKEN`
- Phase 3: migrate to Vault Enterprise with auto-unseal (AWS KMS) for HA
- ESO remains an option for cloud deployments where Vault is not already present
