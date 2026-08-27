#!/usr/bin/env python3
"""
TTFT / TPOT Inference Benchmark Harness
========================================
Asynchronous, streaming, OpenAI-compatible. Works against Ollama, vLLM,
Triton (OpenAI-shim), NIM, or any server exposing POST /v1/chat/completions
with SSE streaming.

Metrics captured per request:
  TTFT  — Time To First Token       (t_first_chunk - t_send)           [ms]
  TPOT  — Time Per Output Token     (mean inter-token gap)              [ms]
  ITL   — Inter-Token Latency       (all gaps, for percentile analysis) [ms]
  E2E   — End-to-end request wall   (t_last_chunk - t_send)            [ms]
  Tokens — Total output tokens counted from stream chunks

Outputs:
  stdout  — Summary table: p50 / p95 / p99 per metric + throughput stats
  CSV     — Per-request raw timings (request_id, ttft_ms, tpot_ms, e2e_ms, ...)

Usage:
  # Basic
  python ttft_benchmark.py --endpoint http://localhost:11434/v1 --model llama3.2

  # Load test: 10 concurrent workers, 100 total requests
  python ttft_benchmark.py -e http://localhost:11434/v1 -m llama3.2 -c 10 -n 100

  # Custom output
  python ttft_benchmark.py -e http://localhost:11434/v1 -m llama3.2 \\
      --output docs/benchmarks/ollama-3b-baseline.csv \\
      --prompt "Explain the difference between TCP and UDP in 3 paragraphs."

Dependencies:
  uv add httpx typer pydantic
"""

from __future__ import annotations

import asyncio
import csv
import json
import statistics
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import httpx
import typer

app = typer.Typer(add_completion=False, help="LLM inference TTFT/TPOT benchmark harness.")


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------


@dataclass
class RequestResult:
    request_id: int
    ttft_ms: Optional[float] = None
    tpot_ms: Optional[float] = None
    e2e_ms: float = 0.0
    total_tokens: int = 0
    # All inter-token gaps — enables per-request ITL distribution
    itl_samples: list[float] = field(default_factory=list)
    success: bool = False
    error: Optional[str] = None
    status_code: Optional[int] = None


@dataclass
class BenchmarkConfig:
    endpoint: str
    model: str
    prompt: str
    concurrency: int
    total_requests: int
    max_tokens: int
    output_csv: Path
    timeout_s: float
    temperature: float


# ---------------------------------------------------------------------------
# Single streaming request
# ---------------------------------------------------------------------------


async def _stream_one(
    client: httpx.AsyncClient,
    config: BenchmarkConfig,
    request_id: int,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    """
    Issue a single streaming chat completion request.

    SSE format (OpenAI-compatible):
        data: {"choices":[{"delta":{"content":"..."}, "finish_reason":null}]}
        data: {"choices":[{"delta":{}, "finish_reason":"stop"}]}
        data: [DONE]

    We stamp time.perf_counter() on every content-bearing chunk to compute:
      - TTFT  : first chunk timestamp - send timestamp
      - ITL   : consecutive chunk delta list
      - TPOT  : mean(ITL)
      - E2E   : last response byte timestamp - send timestamp
    """
    result = RequestResult(request_id=request_id)

    payload: dict = {
        "model": config.model,
        "messages": [{"role": "user", "content": config.prompt}],
        "max_tokens": config.max_tokens,
        "temperature": config.temperature,
        "stream": True,
    }

    async with semaphore:
        t_send = time.perf_counter()
        chunk_times: list[float] = []

        try:
            async with client.stream(
                "POST",
                f"{config.endpoint}/chat/completions",
                json=payload,
                timeout=httpx.Timeout(config.timeout_s, connect=10.0),
            ) as resp:
                result.status_code = resp.status_code
                resp.raise_for_status()

                async for raw_line in resp.aiter_lines():
                    line = raw_line.strip()
                    if not line or not line.startswith("data:"):
                        continue

                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break

                    try:
                        chunk = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    choices = chunk.get("choices") or []
                    if not choices:
                        continue

                    delta_content = choices[0].get("delta", {}).get("content")
                    if delta_content is not None:
                        chunk_times.append(time.perf_counter())

            t_end = time.perf_counter()

            n = len(chunk_times)
            if n >= 1:
                result.ttft_ms = (chunk_times[0] - t_send) * 1_000
                result.e2e_ms = (t_end - t_send) * 1_000
                result.total_tokens = n

                if n >= 2:
                    itl = [
                        (chunk_times[i] - chunk_times[i - 1]) * 1_000
                        for i in range(1, n)
                    ]
                    result.itl_samples = itl
                    result.tpot_ms = statistics.mean(itl)
                else:
                    result.tpot_ms = 0.0

                result.success = True
            else:
                result.error = "Stream returned no content tokens"

        except httpx.HTTPStatusError as exc:
            result.status_code = exc.response.status_code
            result.error = f"HTTP {exc.response.status_code}: {exc.response.text[:300]}"
        except httpx.TimeoutException:
            result.error = f"Timeout ({config.timeout_s}s)"
        except httpx.ConnectError as exc:
            result.error = f"Connection refused — is {config.endpoint} running? ({exc})"
        except httpx.RequestError as exc:
            result.error = f"Request error: {type(exc).__name__}: {exc}"
        except Exception as exc:  # noqa: BLE001
            result.error = f"Unexpected: {type(exc).__name__}: {exc}"

    return result


# ---------------------------------------------------------------------------
# Async orchestrator
# ---------------------------------------------------------------------------


async def _run(config: BenchmarkConfig) -> list[RequestResult]:
    semaphore = asyncio.Semaphore(config.concurrency)
    limits = httpx.Limits(
        max_connections=config.concurrency + 10,
        max_keepalive_connections=config.concurrency,
        keepalive_expiry=60.0,
    )

    async with httpx.AsyncClient(
        limits=limits,
        headers={"Content-Type": "application/json"},
        follow_redirects=True,
    ) as client:
        tasks = [
            _stream_one(client, config, i, semaphore)
            for i in range(config.total_requests)
        ]

        typer.echo(
            f"→ {config.total_requests} requests · concurrency={config.concurrency} · "
            f"model={config.model} · endpoint={config.endpoint}"
        )

        t0 = time.perf_counter()
        results: list[RequestResult] = await asyncio.gather(*tasks)
        elapsed = time.perf_counter() - t0

        typer.echo(f"✓ Completed in {elapsed:.2f}s")

    return results


# ---------------------------------------------------------------------------
# Percentile (no numpy dependency)
# ---------------------------------------------------------------------------


def _pct(data: list[float], p: float) -> float:
    """Linear-interpolation percentile. Returns 0.0 for empty input."""
    if not data:
        return 0.0
    if len(data) == 1:
        return data[0]
    sd = sorted(data)
    idx = (p / 100.0) * (len(sd) - 1)
    lo, hi = int(idx), min(int(idx) + 1, len(sd) - 1)
    return sd[lo] + (idx - lo) * (sd[hi] - sd[lo])


# ---------------------------------------------------------------------------
# CSV output
# ---------------------------------------------------------------------------


def _write_csv(results: list[RequestResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=[
                "request_id", "success", "status_code",
                "ttft_ms", "tpot_ms", "e2e_ms",
                "total_tokens", "error",
            ],
        )
        writer.writeheader()
        for r in results:
            writer.writerow({
                "request_id":   r.request_id,
                "success":      r.success,
                "status_code":  r.status_code or "",
                "ttft_ms":      f"{r.ttft_ms:.3f}"  if r.ttft_ms  is not None else "",
                "tpot_ms":      f"{r.tpot_ms:.3f}"  if r.tpot_ms  is not None else "",
                "e2e_ms":       f"{r.e2e_ms:.3f}",
                "total_tokens": r.total_tokens,
                "error":        r.error or "",
            })


# ---------------------------------------------------------------------------
# Summary printer
# ---------------------------------------------------------------------------

_SEP = "─" * 64


def _pct_row(label: str, data: list[float]) -> str:
    if not data:
        return f"  {label:<6}  {'(no data)':>60}"
    return (
        f"  {label:<6}  "
        f"p50={_pct(data, 50):>8.1f} ms  "
        f"p95={_pct(data, 95):>8.1f} ms  "
        f"p99={_pct(data, 99):>8.1f} ms  "
        f"mean={statistics.mean(data):>8.1f} ms"
    )


def _print_summary(results: list[RequestResult], config: BenchmarkConfig) -> None:
    ok = [r for r in results if r.success]
    fail = [r for r in results if not r.success]

    ttft  = [r.ttft_ms for r in ok if r.ttft_ms  is not None]
    tpot  = [r.tpot_ms for r in ok if r.tpot_ms  is not None and r.tpot_ms > 0]
    e2e   = [r.e2e_ms  for r in ok]
    # Flatten all ITL samples for a population-level distribution
    all_itl = [gap for r in ok for gap in r.itl_samples]

    print(f"\n{_SEP}")
    print(f"  BENCHMARK — {config.model} @ {config.endpoint}")
    print(f"  concurrency={config.concurrency}  requests={config.total_requests}  "
          f"max_tokens={config.max_tokens}  temp={config.temperature}")
    print(_SEP)
    print(f"  Total: {len(results)} | Success: {len(ok)} | Failed: {len(fail)}")
    print()
    print(_pct_row("TTFT",  ttft))
    print(_pct_row("TPOT",  tpot))
    print(_pct_row("E2E",   e2e))
    print(_pct_row("ITL",   all_itl))

    if ok:
        total_tokens = sum(r.total_tokens for r in ok)
        total_e2e_s = sum(e2e) / 1_000
        print()
        print(f"  Output tokens total : {total_tokens:,}")
        if total_e2e_s > 0:
            print(f"  Throughput (approx) : {total_tokens / total_e2e_s:.1f} tok/s  "
                  f"[sum_tokens / sum_e2e, NOT wall-clock RPS]")
        successful_rps = len(ok) / (max(e2e) / 1_000) if e2e else 0
        print(f"  Req/s (approx)      : {successful_rps:.1f}")

    if fail:
        print(f"\n  ERRORS ({len(fail)}):")
        # Group errors by type
        error_groups: dict[str, int] = {}
        for r in fail:
            key = (r.error or "unknown")[:80]
            error_groups[key] = error_groups.get(key, 0) + 1
        for msg, count in sorted(error_groups.items(), key=lambda x: -x[1]):
            print(f"    [{count:>3}x] {msg}")

    print(_SEP)
    print()


# ---------------------------------------------------------------------------
# CLI entry-point
# ---------------------------------------------------------------------------


@app.command()
def benchmark(
    endpoint: str = typer.Option(
        "http://localhost:11434/v1",
        "--endpoint", "-e",
        help="OpenAI-compatible base URL (no trailing slash).",
    ),
    model: str = typer.Option(
        "llama3.2",
        "--model", "-m",
        help="Model name as registered by the server.",
    ),
    prompt: str = typer.Option(
        "Explain the difference between a TCP connection and a UDP datagram "
        "in plain language. Cover reliability, ordering, and use cases.",
        "--prompt", "-p",
        help="User message to send for each request.",
    ),
    concurrency: int = typer.Option(
        10,
        "--concurrency", "-c",
        help="Number of concurrent requests in-flight.",
        min=1, max=512,
    ),
    total_requests: int = typer.Option(
        50,
        "--requests", "-n",
        help="Total number of requests to fire.",
        min=1,
    ),
    max_tokens: int = typer.Option(
        256,
        "--max-tokens",
        help="Maximum output tokens per request.",
        min=1,
    ),
    temperature: float = typer.Option(
        0.0,
        "--temperature",
        help="Sampling temperature (0.0 = deterministic for reproducible benchmarks).",
    ),
    output: Path = typer.Option(
        Path("benchmark_results.csv"),
        "--output", "-o",
        help="CSV output path.",
    ),
    timeout: float = typer.Option(
        120.0,
        "--timeout",
        help="Per-request timeout in seconds.",
    ),
) -> None:
    """
    Fire N concurrent streaming requests against an OpenAI-compatible inference
    endpoint and report TTFT / TPOT / ITL / E2E latency percentiles.

    Designed for Ollama (local dev), vLLM, Triton OpenAI-shim, and NIM.
    """
    config = BenchmarkConfig(
        endpoint=endpoint.rstrip("/"),
        model=model,
        prompt=prompt,
        concurrency=concurrency,
        total_requests=total_requests,
        max_tokens=max_tokens,
        output_csv=output,
        timeout_s=timeout,
        temperature=temperature,
    )

    results = asyncio.run(_run(config))
    _print_summary(results, config)
    _write_csv(results, output)
    typer.echo(f"📄 Raw results → {output}")


if __name__ == "__main__":
    app()
