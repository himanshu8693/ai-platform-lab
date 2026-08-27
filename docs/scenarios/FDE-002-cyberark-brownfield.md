# FDE-002 — CyberArk Brownfield Deployment: Integrating AI Platform with Incumbent PAM

**Scenario ID:** FDE-002
**Complexity:** Staff-level
**Target audience:** Forward Deployed Engineers deploying at enterprises with incumbent CyberArk EPV
**Reference:** ADR-014, terraform/pam-federation/

---

## Scenario Description

You are deploying the AI Platform Lab at a financial services enterprise. Their infrastructure
security requirements:

- All privileged access must flow through CyberArk EPV — no exceptions
- Dual-control approval required for any privileged database access
- Every credential checkout must appear in CyberArk's audit trail
- The CISO has budget for HashiCorp Vault as an *additive* tool but will not approve
  removing CyberArk from the approval chain

**Your task:** Deploy the AI Platform MCP stack so that:
1. Boundary still brokers all MCP server → PostgreSQL access (zero-trust chain preserved)
2. Vault calls CyberArk CCP to check out the PostgreSQL credential (CyberArk in the chain)
3. CyberArk's audit trail shows every checkout event with the Boundary session metadata
4. The MCP server never sees the plaintext credential (credential injection unchanged)

---

## Pre-Deployment Checklist

```bash
# ── CyberArk-side configuration (CyberArk admin performs these steps) ──────
# 1. Register the Vault integration as an Application in CyberArk
#    EPV Admin → Applications → Add Application
#    Application ID: vault-ai-platform
#    Authentication: Certificate (use the Vault host certificate)
#    Allowed Safes: AI-Platform-Credentials

# 2. Create a Safe and add the PostgreSQL accounts
#    Safe: AI-Platform-Credentials
#    Members: vault-ai-platform (checkout only), CyberArk-admin (full control)
#    Account: mcp-postgres | Address: postgres.inference.svc.cluster.local | Platform: PostgreSQL

# 3. Configure dual-control policy (optional — if required by compliance)
#    Safe → Properties → Require dual control password access approval: Yes
#    Approvers: security-team
#    NOTE: Dual-control adds a human approval step that breaks automated workflows.
#          For AI platform, use the "Exclusive" access policy instead:
#          The AI platform is the only consumer; no concurrent checkout needed.
#          Dual-control for the ROOT rotation credentials only.

# ── Vault-side configuration (Platform Engineer runs terraform) ─────────────
# 4. Deploy the CyberArk bridge Terraform
export TF_VAR_cyberark_ccp_url="https://cyberark.internal/AIMWebService/api/Accounts"
export TF_VAR_cyberark_app_id="vault-ai-platform"
export TF_VAR_cyberark_safe_name="AI-Platform-Credentials"
cd terraform/pam-federation
terraform init && terraform apply
```

---

## Step-by-Step Deployment

### Step 1 — Verify CyberArk CCP Connectivity from Vault

```bash
# Run from the Vault pod (or Vault operator machine with network access to CyberArk)
curl -sf \
  --cert /opt/cyberark/certs/client.pem \
  --key /opt/cyberark/certs/client-key.pem \
  --cacert /opt/cyberark/certs/cyberark-ca.pem \
  "https://cyberark.internal/AIMWebService/api/Accounts?AppID=vault-ai-platform&Safe=AI-Platform-Credentials&Object=mcp-postgres" \
  | jq '{username: .UserName, address: .Address, last_modified: .LastModifiedTime}'

# Expected: {"username": "v-mcp-postgres-svc", "address": "postgres.inference.svc.cluster.local", ...}
# If 403: check Application ID and certificate thumbprint in CyberArk
# If 404: check Safe name and Object name spelling (case-sensitive)
```

### Step 2 — Apply the Terraform Bridge

```bash
cd ai-platform-lab/terraform/pam-federation
terraform init
terraform plan -out=cyberark-bridge.tfplan
terraform apply cyberark-bridge.tfplan
```

Expected output:
```
vault_mount.cyberark_ccp: Creating...
vault_policy.boundary_cyberark_policy: Creating...
vault_kv_secret_v2.cyberark_ccp_script: Creating...
Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
```

### Step 3 — Test the Credential Chain End-to-End

```bash
# From the Vault CLI (or kubectl exec into the Vault pod):
vault read cyberark/ccp/mcp-postgres

# Expected output:
# Key         Value
# ---         -----
# username    v-mcp-postgres-svc
# password    <password-from-cyberark>
# ttl         1h0m0s
# cyberark_account  postgres.inference.svc.cluster.local

# Verify the checkout appears in CyberArk audit:
# CyberArk Admin → Monitoring → Privileged Session Manager → Activity Log
# Filter: Application = vault-ai-platform, Safe = AI-Platform-Credentials
# Expected: one checkout event matching the timestamp of the vault read above
```

### Step 4 — Update Boundary Credential Store to Use CyberArk Backend

```bash
# The boundary_credential_store_vault resource in vault-boundary-auth.tf
# already points at the Vault address. The only change needed is to update
# the credential library path from the native DB engine to the CyberArk engine:

# In terraform/vault-boundary-auth.tf, change:
#   path = "database/creds/mcp-server-role"
# To:
#   path = "cyberark/ccp/mcp-postgres"
#   http_method = "GET"

# Then apply:
cd terraform
terraform apply -target=boundary_credential_library_vault.postgres_dynamic
```

### Step 5 — Verify Full Chain via Boundary Session

```bash
# Authorize a Boundary session to the mcp-postgres target
boundary connect postgres \
  -target-id=$(terraform output -raw mcp_postgres_target_id) \
  -dbname=mcpdb \
  -- -c "SELECT current_user, NOW();"

# Expected:
# current_user              | now
# --------------------------+-------------------------------
# v-mcp-postgres-svc        | 2025-01-01 12:00:00.000000+00

# Verify in CyberArk audit: the checkout event should show
# Requester: vault-ai-platform (Vault application)
# Object: mcp-postgres
# Session: corresponds to the Boundary session ID
```

---

## CyberArk Admin Objections and Responses

| Objection | Response |
|---|---|
| "Vault is another tool to manage" | "Vault is invisible to your CyberArk admin team. Every checkout still appears in your EPV audit. We added dynamic TTL management on top of your existing investment." |
| "Why not just use CyberArk directly?" | "CyberArk EPV is designed for human checkout workflows with approval gates and session recording. We need *machine-identity, sub-minute, auto-revoking credentials* for AI agent tool calls. That's a different use case — CyberArk's checkout latency (~200–500ms + approval wait) is incompatible with real-time AI agent workflows." |
| "What if Vault is compromised?" | "Vault's only capability in this setup is to call CyberArk CCP and present a certificate. A compromised Vault instance can checkout credentials — but CyberArk logs every checkout. The incident is detectable. Additionally, the SPIFFE SVID binding (ADR-009) means only the specific MCP server workload identity can authenticate to Vault." |
| "This bypasses our approval workflow" | "For AI agent tool calls, we configure CyberArk's Exclusive Access policy rather than dual-control. This registers the AI platform as the exclusive user of these specific accounts, eliminating the human approval wait while keeping the checkout audit trail intact. The dual-control policy remains for the ROOT rotation credentials that the human DBAs use." |

---

## Rollback Procedure

If CyberArk integration causes issues, roll back to native Vault dynamic creds:

```bash
cd terraform
# Revert the credential library path to the native DB engine
terraform apply -target=boundary_credential_library_vault.postgres_dynamic \
  -var="credential_path=database/creds/mcp-server-role"

# Verify Vault DB engine still works (was never removed):
vault read database/creds/mcp-server-role
```
