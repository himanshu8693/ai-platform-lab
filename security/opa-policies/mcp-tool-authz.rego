# =============================================================================
# security/opa-policies/mcp-tool-authz.rego
# OPA Rego Policy — Semantic Authorization for MCP Tool Calls
#
# Gap A fix: evaluates BOTH tool name AND argument payload before Context Forge
# proxies a tools/call to an upstream MCP server.
#
# Enforcement point: OPA sidecar on the context-forge pod.
# Context Forge calls POST http://localhost:8181/v1/data/mcp/authz
# with the full JSON body: { tool: "...", args: {...}, identity: "spiffe://..." }
#
# Policy structure:
#   mcp.authz.allow     — boolean: true means proxy the call
#   mcp.authz.deny_reason — string: human-readable reason surfaced in 403 body
#   mcp.authz.audit_data — object: structured data emitted to OPA decision log
#
# References: ADR-010, context-forge-deployment.yaml, terraform/opa-configmap.tf
# =============================================================================

package mcp.authz

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ── Default: deny unless explicitly allowed ───────────────────────────────────
default allow = false
default deny_reason = "Tool call denied by default policy. No matching allow rule."

# ── Allowed namespace set ─────────────────────────────────────────────────────
# MCP tools that accept a namespace argument are restricted to these namespaces.
# Adding a namespace here is a conscious governance decision — do it via PR.
allowed_namespaces := {
    "inference",
    "monitoring",
    "argocd",
    "kube-system",   # read-only events/nodes only — see namespace_restricted_tools below
}

# Tools that operate on kube-system are additionally restricted to event/node reads only.
# All other namespace-scoped tools are blocked from kube-system to prevent SA token enumeration.
namespace_restricted_tools := {"get_events", "list_pods"}

# ── PII-sensitive namespace patterns ─────────────────────────────────────────
pii_patterns := {
    "payments", "cardholder", "pci", "phi", "hipaa",
    "ssn", "social_security", "credit_card", "dob", "date_of_birth",
}

# ── Allowed tool set (must match the Context Forge Virtual Server whitelist) ──
allowed_tools := {
    # Kubernetes MCP server tools
    "get_pod", "list_pods",
    "get_deployment", "list_deployments",
    "get_events", "get_logs",
    # Prometheus MCP server tools
    "execute_query", "execute_range_query",
    "list_metrics", "get_metric_metadata",
    # Database MCP server tools
    "query_database",
}

# ── Rule: unknown tool ────────────────────────────────────────────────────────
allow if {
    input.tool in allowed_tools
    not _blocked(input.tool, input.args)
}

# ── Rule: tool is not in the allowed set ─────────────────────────────────────
deny_reason := msg if {
    not input.tool in allowed_tools
    msg := sprintf("Tool '%v' is not in the MCP platform whitelist. Add it to allowed_tools and the Virtual Server to enable.", [input.tool])
}

# ── Rule: PromQL query contains PII-scoped namespace pattern ─────────────────
_blocked("execute_query", args) if {
    _pii_in_query(args.query)
}

_blocked("execute_range_query", args) if {
    _pii_in_query(args.query)
}

_pii_in_query(query) if {
    some pattern in pii_patterns
    contains(lower(query), pattern)
}

deny_reason := msg if {
    input.tool in {"execute_query", "execute_range_query"}
    _pii_in_query(input.args.query)
    msg := sprintf(
        "PromQL query references a PII-scoped pattern. Denied by mcp-tool-authz policy. Query: '%v'",
        [input.args.query],
    )
}

# ── Rule: PromQL query contains DDL-like destructive tokens ──────────────────
_blocked("execute_query", args) if {
    destructive := {"drop", "delete", "truncate", "alter", "create", "insert", "update"}
    some token in destructive
    contains(lower(args.query), token)
}

deny_reason := msg if {
    input.tool in {"execute_query", "execute_range_query"}
    destructive := {"drop", "delete", "truncate", "alter", "create", "insert", "update"}
    some token in destructive
    contains(lower(input.args.query), token)
    msg := sprintf("PromQL query contains a disallowed SQL/DDL token '%v'. This is not valid PromQL.", [token])
}

# ── Rule: query_database denies destructive SQL payloads ─────────────────────
_blocked("query_database", args) if {
    query := _sql_query(args)
    _contains_destructive_sql(query)
}

deny_reason := msg if {
    input.tool == "query_database"
    query := _sql_query(input.args)
    _contains_destructive_sql(query)
    msg := "query_database payload contains destructive SQL keywords. Only read-only SELECT/CTE queries are allowed."
}

# ── Rule: query_database denies unbounded SELECT * queries ───────────────────
_blocked("query_database", args) if {
    query := _sql_query(args)
    _contains_unbounded_select_star(query)
}

deny_reason := msg if {
    input.tool == "query_database"
    query := _sql_query(input.args)
    _contains_unbounded_select_star(query)
    msg := "query_database payload contains SELECT * without LIMIT. Provide explicit columns or add a bounded LIMIT."
}

# ── Rule: namespace-scoped tools must target an allowed namespace ─────────────
_blocked(tool, args) if {
    tool in {"get_pod", "list_pods", "get_deployment", "list_deployments",
             "get_events", "get_logs", "get_logs"}
    args.namespace
    not args.namespace in allowed_namespaces
}

deny_reason := msg if {
    input.tool in {"get_pod", "list_pods", "get_deployment", "list_deployments",
                   "get_events", "get_logs"}
    input.args.namespace
    not input.args.namespace in allowed_namespaces
    msg := sprintf(
        "Namespace '%v' is not in the allowed namespace set %v.",
        [input.args.namespace, allowed_namespaces],
    )
}

# ── Rule: kube-system restricted to specific tools only ──────────────────────
_blocked(tool, args) if {
    args.namespace == "kube-system"
    not tool in namespace_restricted_tools
}

deny_reason := msg if {
    input.args.namespace == "kube-system"
    not input.tool in namespace_restricted_tools
    msg := sprintf(
        "Tool '%v' is not permitted in kube-system namespace. Only %v are allowed there.",
        [input.tool, namespace_restricted_tools],
    )
}

# ── Rule: execute_range_query time window must not exceed 24 hours ────────────
_blocked("execute_range_query", args) if {
    args.start
    args.end
    window_hours(args.start, args.end) > 24
}

window_hours(start, end) := h if {
    h := (end - start) / 3600
}

_sql_query(args) := query if {
    query := trim(object.get(args, "query", object.get(args, "sql", "")), " \t\n\r")
}

_contains_destructive_sql(query) if {
    destructive := {"drop", "delete", "truncate", "alter", "create", "insert", "update"}
    normalized := lower(query)
    some token in destructive
    regex.match(sprintf("(^|[^a-z])%v([^a-z]|$)", [token]), normalized)
}

_contains_unbounded_select_star(query) if {
    normalized := lower(query)
    regex.match("\\bselect\\s*\\*\\s*from\\b", normalized)
    not regex.match("\\blimit\\s+[0-9]+\\b", normalized)
}

deny_reason := msg if {
    input.tool == "execute_range_query"
    input.args.start
    input.args.end
    window_hours(input.args.start, input.args.end) > 24
    msg := sprintf(
        "Range query window exceeds 24 hours (requested: %.1fh). Reduce the time range.",
        [window_hours(input.args.start, input.args.end)],
    )
}

# ── Audit data: always emitted to the OPA decision log ───────────────────────
audit_data := {
    "tool":     input.tool,
    "identity": object.get(input, "identity", "unknown"),
    "allowed":  allow,
    "reason":   deny_reason,
    "args_keys": [k | input.args[k]],   # log arg names but NOT values (avoid PII in logs)
}
