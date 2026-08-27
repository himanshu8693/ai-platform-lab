# ADR-014 — PAM Federation: Vault as Broker for Incumbent CyberArk / Delinea

| Field      | Value                                                                          |
|------------|--------------------------------------------------------------------------------|
| **Status** | Accepted                                                                       |
| **Date**   | 2025-01-01                                                                     |
| **Author** | Platform Engineering                                                           |
| **Refs**   | ADR-005, ADR-008, ADR-009, terraform/pam-federation/                           |

---

## Context

Every enterprise FDE target (Anthropic, Databricks, Palantir) arrives with an incumbent PAM
(Privileged Access Management) system already deployed. The current architecture assumes a
greenfield Vault deployment. Real brownfield deployments involve one of:

- **CyberArk EPV / Privilege Cloud** — most common in financial services, DoD, healthcare
- **Delinea Secret Server / Privilege Manager** — common in mid-enterprise
- **BeyondTrust / ManageEngine** — less common, same problem

The FDE interview challenge (Gap G): *"The customer already has CyberArk and a team of
12 CyberArk admins. You are proposing to add HashiCorp Vault. How do you position this
so it is additive rather than a competing threat?"*

The wrong answer: "Vault replaces CyberArk."
The right answer: "Vault sits *downstream* of CyberArk, acting as the dynamic credential
engine that honours CyberArk's approval workflows and audit chain."

---

## Decision

**Deploy Vault as a PAM aggregation and dynamic credential layer. CyberArk / Delinea
remains the authoritative credential store and identity governance system.**

### Two Integration Patterns

#### Pattern A — CyberArk CCP (credential authority stays in CyberArk)

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Pattern A: CyberArk is the credential authority                            │
│                                                                             │
│  Boundary → Vault (generic engine) → CyberArk CCP REST API                 │
│                                        │                                   │
│                                        ▼                                   │
│                               CyberArk EPV                                  │
│                               (approvals, dual-control,                     │
│                                checkout audit trail)                        │
│                                                                             │
│  Value of Vault: abstraction layer (Boundary talks to one endpoint);        │
│                  lease management; SPIFFE identity binding (Gap B)          │
│  Value of CyberArk: approval workflows; session recording; enterprise PAM  │
└────────────────────────────────────────────────────────────────────────────┘
```

Use when: customer requires CyberArk to remain the **system of record** for every
credential checkout. Compliance requirement: "all privileged access must have a
CyberArk audit trail."

#### Pattern B — Delinea as Identity Provider (Vault retains credential issuance)

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Pattern B: Delinea is the identity authority                               │
│                                                                             │
│  MCP server → Delinea OIDC token → Vault OIDC login                        │
│                                        │                                   │
│                                        ▼                                   │
│                               Vault dynamic credential engine               │
│                               (DB engine, SPIFFE binding)                   │
│                                        │                                   │
│                                        ▼                                   │
│                               Boundary → PostgreSQL                         │
│                                                                             │
│  Value of Delinea: identity governance; group membership; session approval  │
│  Value of Vault: dynamic credential issuance; lease management; short TTLs │
└────────────────────────────────────────────────────────────────────────────┘
```

Use when: customer uses Delinea for IAM/SSO but Vault for runtime credential
management. Delinea's group membership policies govern *who* can get credentials
(identity control); Vault governs *what* they get and *for how long* (credential control).

---

## Decision Matrix

| Factor | Pattern A (CyberArk) | Pattern B (Delinea) |
|---|---|---|
| Credential authority | CyberArk EPV | Vault (Delinea = identity only) |
| Checkout audit trail | CyberArk audit log | Vault audit log |
| CyberArk admin buy-in | High (they own the chain) | Medium (Vault added) |
| Latency impact | +50–100ms (CCP API call per checkout) | Negligible (OIDC token cached) |
| Approval workflow support | Full CyberArk dual-control | Requires Vault ACL policy for equivalence |
| Dynamic creds (short TTL) | Possible (CCP can return rotating creds) | Native (Vault DB engine) |
| FedRAMP alignment | Stronger (established PAM tool) | Acceptable with Vault Enterprise |

---

## The CISO Conversation (FDE Interview Script)

**CISO:** "We have CyberArk. Why would we add Vault?"

**You:** "CyberArk is excellent for human privileged access — operator checkout, dual-control,
session recording. What CyberArk doesn't do natively is *dynamic, ephemeral, machine-identity
credentials* for non-human workloads. When an AI agent needs a 5-minute database credential
that auto-revokes on session end, that's not a CyberArk checkout workflow — that's a Vault
use case. We use Vault as a dynamic credential engine that calls *back* to CyberArk CCP for
the source credential. Your CyberArk audit trail still captures every checkout event.
Your CyberArk admins still own the password policy. We're adding dynamic TTL management
on top of your existing investment, not replacing it."

---

## Files Changed

| File | Change |
|---|---|
| `terraform/pam-federation/cyberark-vault-bridge.tf` | NEW — Pattern A: Vault → CyberArk CCP |
| `terraform/pam-federation/delinea-vault-bridge.tf` | NEW — Pattern B: Delinea OIDC → Vault |
| `docs/scenarios/FDE-002-cyberark-brownfield.md` | NEW — Deployment walkthrough |
