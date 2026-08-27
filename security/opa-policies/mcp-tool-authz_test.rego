# =============================================================================
# security/opa-policies/mcp-tool-authz_test.rego
# OPA Unit Tests for MCP Semantic Authorization Policy
#
# Run with:  opa test security/opa-policies/ -v
#
# Test coverage:
#   - All whitelisted tools: verify allow
#   - PII namespace patterns in PromQL: verify deny
#   - DDL tokens in PromQL: verify deny
#   - Blocked namespace: verify deny
#   - kube-system restriction: verify deny for non-whitelisted tools
#   - Range query time window: verify deny > 24h, allow <= 24h
#   - Unknown tool: verify deny
#
# References: ADR-010, mcp-tool-authz.rego
# =============================================================================

package mcp.authz_test

import data.mcp.authz

# ── Fixtures ──────────────────────────────────────────────────────────────────
spiffe_identity := "spiffe://ai-platform.internal/ns/inference/sa/mcp-server-sa"

# ── ALLOW: whitelisted tools with valid namespaces ────────────────────────────

test_allow_list_pods_inference if {
    authz.allow with input as {
        "tool": "list_pods",
        "args": {"namespace": "inference"},
        "identity": spiffe_identity,
    }
}

test_allow_get_pod if {
    authz.allow with input as {
        "tool": "get_pod",
        "args": {"namespace": "monitoring", "name": "prometheus-0"},
        "identity": spiffe_identity,
    }
}

test_allow_list_deployments_argocd if {
    authz.allow with input as {
        "tool": "list_deployments",
        "args": {"namespace": "argocd"},
        "identity": spiffe_identity,
    }
}

test_allow_execute_query_valid_promql if {
    authz.allow with input as {
        "tool": "execute_query",
        "args": {"query": "histogram_quantile(0.99, rate(vllm_time_to_first_token_seconds_bucket[5m]))"},
        "identity": spiffe_identity,
    }
}

test_allow_execute_range_query_under_24h if {
    authz.allow with input as {
        "tool": "execute_range_query",
        "args": {
            "query": "sum(rate(inference_requests_total[5m]))",
            "start": 1700000000,
            "end":   1700000000 + (23 * 3600),   # 23h window — allowed
        },
        "identity": spiffe_identity,
    }
}

test_allow_list_metrics if {
    authz.allow with input as {
        "tool": "list_metrics",
        "args": {},
        "identity": spiffe_identity,
    }
}

test_allow_get_metric_metadata if {
    authz.allow with input as {
        "tool": "get_metric_metadata",
        "args": {"metric": "vllm_num_requests_waiting"},
        "identity": spiffe_identity,
    }
}

test_allow_query_database_bounded_select if {
    authz.allow with input as {
        "tool": "query_database",
        "args": {"query": "SELECT id, name FROM users LIMIT 25"},
        "identity": spiffe_identity,
    }
}

test_allow_get_events_kube_system if {
    # get_events IS in namespace_restricted_tools — allowed for kube-system
    authz.allow with input as {
        "tool": "get_events",
        "args": {"namespace": "kube-system"},
        "identity": spiffe_identity,
    }
}

# ── DENY: PII patterns in PromQL ─────────────────────────────────────────────

test_deny_promql_payments_namespace if {
    not authz.allow with input as {
        "tool": "execute_query",
        "args": {"query": "sum(payments_transactions_total)"},
        "identity": spiffe_identity,
    }
}

test_deny_promql_pci_label if {
    not authz.allow with input as {
        "tool": "execute_query",
        "args": {"query": "sum by (pci_zone) (requests_total)"},
        "identity": spiffe_identity,
    }
}

test_deny_promql_phi_in_query if {
    not authz.allow with input as {
        "tool": "execute_range_query",
        "args": {
            "query": "phi_records_accessed_total",
            "start": 1700000000,
            "end":   1700000000 + 3600,
        },
        "identity": spiffe_identity,
    }
}

# ── DENY: DDL tokens in PromQL ───────────────────────────────────────────────

test_deny_promql_drop_token if {
    not authz.allow with input as {
        "tool": "execute_query",
        "args": {"query": "drop table users"},
        "identity": spiffe_identity,
    }
}

test_deny_promql_delete_token if {
    not authz.allow with input as {
        "tool": "execute_query",
        "args": {"query": "delete from secrets where 1=1"},
        "identity": spiffe_identity,
    }
}

test_deny_query_database_drop if {
    not authz.allow with input as {
        "tool": "query_database",
        "args": {"query": "DROP TABLE users"},
        "identity": spiffe_identity,
    }
}

test_deny_query_database_delete if {
    not authz.allow with input as {
        "tool": "query_database",
        "args": {"query": "DELETE FROM users WHERE id = 1"},
        "identity": spiffe_identity,
    }
}

test_deny_query_database_select_star_without_limit if {
    not authz.allow with input as {
        "tool": "query_database",
        "args": {"query": "SELECT * FROM users"},
        "identity": spiffe_identity,
    }
}

# ── DENY: blocked namespace ───────────────────────────────────────────────────

test_deny_list_pods_default_namespace if {
    not authz.allow with input as {
        "tool": "list_pods",
        "args": {"namespace": "default"},
        "identity": spiffe_identity,
    }
}

test_deny_get_deployment_vault_namespace if {
    not authz.allow with input as {
        "tool": "get_deployment",
        "args": {"namespace": "vault"},
        "identity": spiffe_identity,
    }
}

# ── DENY: kube-system restricted to get_events/list_pods only ─────────────────

test_deny_get_deployment_kube_system if {
    # get_deployment is NOT in namespace_restricted_tools → denied for kube-system
    not authz.allow with input as {
        "tool": "get_deployment",
        "args": {"namespace": "kube-system"},
        "identity": spiffe_identity,
    }
}

test_deny_get_logs_kube_system if {
    not authz.allow with input as {
        "tool": "get_logs",
        "args": {"namespace": "kube-system", "pod": "coredns-abc123"},
        "identity": spiffe_identity,
    }
}

# ── DENY: range query exceeds 24h ─────────────────────────────────────────────

test_deny_range_query_over_24h if {
    not authz.allow with input as {
        "tool": "execute_range_query",
        "args": {
            "query": "sum(rate(inference_requests_total[5m]))",
            "start": 1700000000,
            "end":   1700000000 + (25 * 3600),   # 25h — denied
        },
        "identity": spiffe_identity,
    }
}

# ── DENY: unknown / unlisted tool ────────────────────────────────────────────

test_deny_unknown_tool if {
    not authz.allow with input as {
        "tool": "create_pod",
        "args": {"namespace": "inference"},
        "identity": spiffe_identity,
    }
}

test_deny_exec_tool if {
    not authz.allow with input as {
        "tool": "exec_pod",
        "args": {"namespace": "inference", "pod": "target"},
        "identity": spiffe_identity,
    }
}

# ── DENY reason strings are populated on deny ─────────────────────────────────

test_deny_reason_unknown_tool if {
    reason := authz.deny_reason with input as {
        "tool": "exec_pod",
        "args": {},
        "identity": spiffe_identity,
    }
    contains(reason, "not in the MCP platform whitelist")
}

test_deny_reason_pii_namespace if {
    reason := authz.deny_reason with input as {
        "tool": "execute_query",
        "args": {"query": "payments_total"},
        "identity": spiffe_identity,
    }
    contains(reason, "PII-scoped pattern")
}

test_deny_reason_query_database_unbounded_select_star if {
    reason := authz.deny_reason with input as {
        "tool": "query_database",
        "args": {"query": "SELECT * FROM audit_events"},
        "identity": spiffe_identity,
    }
    contains(reason, "SELECT * without LIMIT")
}

test_deny_reason_query_database_destructive_sql if {
    reason := authz.deny_reason with input as {
        "tool": "query_database",
        "args": {"query": "TRUNCATE TABLE sessions"},
        "identity": spiffe_identity,
    }
    contains(reason, "destructive SQL keywords")
}
