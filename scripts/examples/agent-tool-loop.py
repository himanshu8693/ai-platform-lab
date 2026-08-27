"""
scripts/examples/agent-tool-loop.py
G1 — LLM SDK tool-use agent loop (Anthropic SDK)

Purpose:
  Standalone demonstration of the full tool-use cycle using the Anthropic Messages API.
  Bridges directly to the MCP dispatch logic in phase6-mcp-ai-assistant.md Week 4.
  Run this before writing the full ai-assistant client to internalize the pattern.

Usage:
  export ANTHROPIC_API_KEY=sk-ant-...
  uv run scripts/examples/agent-tool-loop.py

Cost: ~$0.002 per run (Claude claude-opus-4-5, stub tool responses, ~500 tokens)

References: docs/curriculum/master_transition_blueprint.md §G1
            docs/curriculum/phase6-mcp-ai-assistant.md §Week 4
"""

import anthropic
import json
import sys
from typing import Any


client = anthropic.Anthropic()

# ── Tool definitions (JSON Schema — same format MCP servers advertise) ────────
TOOLS: list[dict[str, Any]] = [
    {
        "name": "execute_query",
        "description": "Execute a PromQL instant query against the Prometheus API. "
                       "Returns a list of metric results.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "A valid PromQL expression"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "list_pods",
        "description": "List Kubernetes pods in a namespace.",
        "input_schema": {
            "type": "object",
            "properties": {
                "namespace": {"type": "string", "description": "Kubernetes namespace"},
            },
            "required": ["namespace"],
        },
    },
]


def dispatch_tool(name: str, inputs: dict[str, Any]) -> str:
    """
    Route to the real MCP server in production.
    Stub returns synthetic data so this script runs without a live cluster.
    """
    if name == "execute_query":
        return json.dumps({"status": "success", "data": {"result": [{"value": [1700000000, "0.342"]}]}})
    if name == "list_pods":
        ns = inputs.get("namespace", "unknown")
        return json.dumps({"pods": [f"vllm-server-0.{ns}", f"vllm-server-1.{ns}"], "ready": 2})
    return json.dumps({"error": f"Unknown tool: {name}"})


def run_agent_loop(user_message: str) -> str:
    """Full tool-use agent loop: handles multi-turn until stop_reason == 'end_turn'."""
    messages: list[dict[str, Any]] = [{"role": "user", "content": user_message}]

    while True:
        response = client.messages.create(
            model="claude-opus-4-5",
            max_tokens=1024,
            tools=TOOLS,  # type: ignore[arg-type]
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            # Extract the final text answer
            return next(
                (b.text for b in response.content if hasattr(b, "text")),
                "(no text in response)",
            )

        # Process tool_use blocks
        tool_results: list[dict[str, Any]] = []
        for block in response.content:
            if block.type == "tool_use":
                result = dispatch_tool(block.name, block.input)  # type: ignore[arg-type]
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result,
                })

        # Append assistant turn + tool results → continue loop
        messages.append({"role": "assistant", "content": response.content})  # type: ignore[arg-type]
        messages.append({"role": "user", "content": tool_results})


if __name__ == "__main__":
    query = sys.argv[1] if len(sys.argv) > 1 else (
        "What is the current TTFT p99 for the inference cluster, "
        "and how many vLLM pods are ready in the inference namespace?"
    )
    print(f"Query: {query}\n")
    answer = run_agent_loop(query)
    print(f"Answer:\n{answer}")
