#!/usr/bin/env python3
"""
Mock DCGM Prometheus Exporter
==============================
Simulates NVIDIA Data Center GPU Manager (DCGM) metrics for local
development on Apple Silicon (M4 Max) where no NVIDIA GPU is present.

Lets your local Prometheus + Grafana stack scrape *real DCGM field names*
so you can build and validate dashboards, Prometheus alert rules, and KEDA
ScaledObjects against production-identical metric shapes — before you ever
touch real GPU hardware.

Scrape endpoints:
  GET /metrics   port 9400 — Prometheus text exposition format
  GET /healthz   port 9400 — JSON health/readiness

Simulation model: 2× NVIDIA H100 80GB HBM3 (configurable)
  GPU utilisation  : 45–92%  (sine-wave inference workload pattern)
  Framebuffer used : 65–97%  (model weights baseline + KV-cache fill)
  Power draw       : 420–650W (H100 TDP 700W; inference at 60–93%)
  Temperature      : 55–78°C die, 60–82°C HBM
  Clocks           : SM 1750–1980 MHz; HBM3 fixed at 3200 MHz
  ECC / XID errors : probabilistic rare spikes (for alert testing)

Also exposes vLLM-native metrics so your Grafana inference dashboard
works end-to-end:
  vllm_gpu_cache_usage_perc
  vllm_num_running_requests
  vllm_num_waiting_requests
  vllm_num_preempted_requests
  vllm_avg_generation_throughput_toks_per_s
  vllm_time_to_first_token_seconds        (Histogram — TTFT p99 SLO alert)
  vllm_time_per_output_token_seconds      (Histogram — TPOT p99 SLO alert)
  vllm_e2e_request_latency_seconds        (Histogram — end-to-end latency)

Docker usage:
  docker build -t mock-dcgm-exporter .
  docker run -p 9400:9400 mock-dcgm-exporter

Prometheus scrape_config:
  - job_name: mock-dcgm
    scrape_interval: 15s
    static_configs:
      - targets: ['host.docker.internal:9400']
        labels:
          cluster: 'ai-platform-lab'
          node: 'mock-gpu-node-0'

Dependencies:
  uv add fastapi "uvicorn[standard]" prometheus-client
"""

from __future__ import annotations

import math
import os
import random
import threading
import time
from dataclasses import dataclass, field

import uvicorn
from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# ---------------------------------------------------------------------------
# Runtime configuration (override via environment variables)
# ---------------------------------------------------------------------------

NUM_GPUS: int = int(os.getenv("NUM_GPUS", "2"))
GPU_MEMORY_TOTAL_MIB: int = int(os.getenv("GPU_MEM_MIB", "81920"))  # H100 80 GB HBM3
UPDATE_INTERVAL_S: float = float(os.getenv("UPDATE_INTERVAL_S", "5"))
EXPORTER_PORT: int = int(os.getenv("EXPORTER_PORT", "9400"))
HOSTNAME: str = os.getenv("HOSTNAME", "mock-dcgm-node-0")
MODEL_NAME_LABEL: str = os.getenv("MODEL_NAME", "llama3.2:3b")

# ---------------------------------------------------------------------------
# Isolated Prometheus registry
# Keeps these metrics separate from any other prometheus_client usage
# in the same process and avoids double-registration on reload.
# ---------------------------------------------------------------------------

REGISTRY = CollectorRegistry(auto_describe=True)

# ---------------------------------------------------------------------------
# Label schema (mirrors real DCGM-exporter output exactly)
# ---------------------------------------------------------------------------

_GPU_LABELS = ["gpu", "UUID", "device", "modelName", "Hostname"]
_MODEL_LABELS = ["model_name", "version"]

# ---------------------------------------------------------------------------
# DCGM Gauge definitions
# Field IDs match the real dcgm-exporter field list verbatim.
# ---------------------------------------------------------------------------


def _gpu_gauge(name: str, doc: str) -> Gauge:
    return Gauge(name, doc, _GPU_LABELS, registry=REGISTRY)


DCGM = {
    # ── Compute utilisation ──────────────────────────────────────────────────
    "DCGM_FI_DEV_GPU_UTIL": _gpu_gauge(
        "DCGM_FI_DEV_GPU_UTIL",
        "SM (Streaming Multiprocessor) utilization % — primary GPU busy signal",
    ),
    "DCGM_FI_DEV_MEM_COPY_UTIL": _gpu_gauge(
        "DCGM_FI_DEV_MEM_COPY_UTIL",
        "Memory copy engine utilization %",
    ),
    "DCGM_FI_DEV_ENC_UTIL": _gpu_gauge(
        "DCGM_FI_DEV_ENC_UTIL",
        "Encoder utilization % (typically 0 for LLM inference)",
    ),
    "DCGM_FI_DEV_DEC_UTIL": _gpu_gauge(
        "DCGM_FI_DEV_DEC_UTIL",
        "Decoder utilization %",
    ),
    # ── Framebuffer (VRAM) ───────────────────────────────────────────────────
    "DCGM_FI_DEV_FB_TOTAL": _gpu_gauge(
        "DCGM_FI_DEV_FB_TOTAL",
        "Total framebuffer memory (MiB) — H100 80GB = 81920",
    ),
    "DCGM_FI_DEV_FB_USED": _gpu_gauge(
        "DCGM_FI_DEV_FB_USED",
        "Framebuffer memory used (MiB) — model weights + KV-cache",
    ),
    "DCGM_FI_DEV_FB_FREE": _gpu_gauge(
        "DCGM_FI_DEV_FB_FREE",
        "Framebuffer memory free (MiB)",
    ),
    "DCGM_FI_DEV_FB_RESERVED": _gpu_gauge(
        "DCGM_FI_DEV_FB_RESERVED",
        "Framebuffer reserved by driver (MiB) — typically 512",
    ),
    # ── Clocks ───────────────────────────────────────────────────────────────
    "DCGM_FI_DEV_SM_CLOCK": _gpu_gauge(
        "DCGM_FI_DEV_SM_CLOCK",
        "SM clock frequency (MHz) — H100 boost ~1980 MHz",
    ),
    "DCGM_FI_DEV_MEM_CLOCK": _gpu_gauge(
        "DCGM_FI_DEV_MEM_CLOCK",
        "HBM memory clock (MHz) — H100 HBM3 fixed at 3200",
    ),
    "DCGM_FI_DEV_APP_SM_CLOCK": _gpu_gauge(
        "DCGM_FI_DEV_APP_SM_CLOCK",
        "Application requested SM clock (MHz)",
    ),
    "DCGM_FI_DEV_CLOCKS_THROTTLE_REASONS": _gpu_gauge(
        "DCGM_FI_DEV_CLOCKS_THROTTLE_REASONS",
        "Bitmask of active clock throttle reasons (0 = unthrottled)",
    ),
    # ── Thermals & Power ─────────────────────────────────────────────────────
    "DCGM_FI_DEV_GPU_TEMP": _gpu_gauge(
        "DCGM_FI_DEV_GPU_TEMP",
        "GPU die temperature (°C) — alert threshold typically 83°C",
    ),
    "DCGM_FI_DEV_MEMORY_TEMP": _gpu_gauge(
        "DCGM_FI_DEV_MEMORY_TEMP",
        "HBM memory temperature (°C) — critical at 95°C",
    ),
    "DCGM_FI_DEV_POWER_USAGE": _gpu_gauge(
        "DCGM_FI_DEV_POWER_USAGE",
        "Instantaneous power draw (W) — H100 TDP 700W",
    ),
    "DCGM_FI_DEV_POWER_MGMT_LIMIT": _gpu_gauge(
        "DCGM_FI_DEV_POWER_MGMT_LIMIT",
        "Power management limit (W) — enforced ceiling",
    ),
    "DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION": _gpu_gauge(
        "DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION",
        "Total energy consumed since driver load (mJ) — monotonically increasing",
    ),
    # ── PCIe throughput ──────────────────────────────────────────────────────
    "DCGM_FI_DEV_PCIE_TX_THROUGHPUT": _gpu_gauge(
        "DCGM_FI_DEV_PCIE_TX_THROUGHPUT",
        "PCIe transmit throughput (KB/s)",
    ),
    "DCGM_FI_DEV_PCIE_RX_THROUGHPUT": _gpu_gauge(
        "DCGM_FI_DEV_PCIE_RX_THROUGHPUT",
        "PCIe receive throughput (KB/s)",
    ),
    "DCGM_FI_DEV_PCIE_REPLAY_COUNTER": _gpu_gauge(
        "DCGM_FI_DEV_PCIE_REPLAY_COUNTER",
        "PCIe replay counter — non-zero indicates fabric instability",
    ),
    # ── NVLink ───────────────────────────────────────────────────────────────
    "DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL": _gpu_gauge(
        "DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL",
        "NVLink total bandwidth TX+RX (KB/s) — active in tensor-parallel inference",
    ),
    # ── ECC & XID errors ─────────────────────────────────────────────────────
    "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL": _gpu_gauge(
        "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL",
        "ECC single-bit volatile errors — correctable, non-fatal",
    ),
    "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL": _gpu_gauge(
        "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL",
        "ECC double-bit volatile errors — triggers XID 48, indicates DRAM fault",
    ),
    "DCGM_FI_DEV_XID_ERRORS": _gpu_gauge(
        "DCGM_FI_DEV_XID_ERRORS",
        "XID error count — non-zero should trigger node cordon alert",
    ),
    # ── MIG (Multi-Instance GPU) ─────────────────────────────────────────────
    "DCGM_FI_DEV_MIG_MODE_ACTIVE": _gpu_gauge(
        "DCGM_FI_DEV_MIG_MODE_ACTIVE",
        "MIG mode active (1) or disabled (0)",
    ),
}

# ---------------------------------------------------------------------------
# vLLM-native Prometheus metrics
# (normally emitted by vllm's built-in /metrics endpoint)
# ---------------------------------------------------------------------------

VLLM = {
    "vllm_gpu_cache_usage_perc": Gauge(
        "vllm_gpu_cache_usage_perc",
        "KV-cache utilization ratio [0.0–1.0] — approaches 1.0 = OOM risk",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_cpu_cache_usage_perc": Gauge(
        "vllm_cpu_cache_usage_perc",
        "CPU KV-cache utilization ratio — used when GPU cache overflows",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_num_running_requests": Gauge(
        "vllm_num_running_requests",
        "Requests currently in prefill or decode phase",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_num_waiting_requests": Gauge(
        "vllm_num_waiting_requests",
        "Requests queued waiting for KV-cache slots — drives KEDA scaling",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_num_preempted_requests": Gauge(
        "vllm_num_preempted_requests",
        "Requests preempted due to KV-cache pressure — non-zero = memory alert",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_avg_prompt_throughput_toks_per_s": Gauge(
        "vllm_avg_prompt_throughput_toks_per_s",
        "Average prompt (prefill) throughput tokens/s",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    "vllm_avg_generation_throughput_toks_per_s": Gauge(
        "vllm_avg_generation_throughput_toks_per_s",
        "Average generation (decode) throughput tokens/s — headline throughput metric",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
    # Counter (not Gauge): vllm_request_success_total must be a Counter so that
    # rate() and increase() PromQL functions work correctly. Using a Gauge for a
    # monotonically-increasing value makes rate() return 0 whenever the scrape
    # interval crosses a reset, and the ARB panel flagged this as a P1 bug.
    "vllm_request_success_total": Counter(
        "vllm_request_success_total",
        "Cumulative successful requests — monotonically increasing (Counter, not Gauge)",
        _MODEL_LABELS,
        registry=REGISTRY,
    ),
}

# ---------------------------------------------------------------------------
# vLLM latency histograms
# Production vLLM exposes these so histogram_quantile(0.99, ...) works in
# PromQL SLO alerts. Buckets match real vLLM defaults.
# ---------------------------------------------------------------------------

_TTFT_BUCKETS = (0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.0, 5.0, 10.0)
_TPOT_BUCKETS = (0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.2, 0.5, 1.0)
_E2E_BUCKETS = (0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0)

VLLM_HIST = {
    "vllm_time_to_first_token_seconds": Histogram(
        "vllm_time_to_first_token_seconds",
        "Time to first token (TTFT) per request (seconds) — prefill latency SLO",
        _MODEL_LABELS,
        buckets=_TTFT_BUCKETS,
        registry=REGISTRY,
    ),
    "vllm_time_per_output_token_seconds": Histogram(
        "vllm_time_per_output_token_seconds",
        "Per-token decode latency (TPOT) in seconds — inter-token latency SLO",
        _MODEL_LABELS,
        buckets=_TPOT_BUCKETS,
        registry=REGISTRY,
    ),
    "vllm_e2e_request_latency_seconds": Histogram(
        "vllm_e2e_request_latency_seconds",
        "End-to-end request latency in seconds (TTFT + decode) — overall SLO",
        _MODEL_LABELS,
        buckets=_E2E_BUCKETS,
        registry=REGISTRY,
    ),
}

# ---------------------------------------------------------------------------
# Per-GPU simulation state
# ---------------------------------------------------------------------------


@dataclass
class GpuState:
    gpu_id: str
    uuid: str
    device: str
    model_name: str
    # Independent phase per GPU so they don't track in lockstep
    phase: float = field(default_factory=lambda: random.uniform(0.0, math.tau))
    energy_mj: float = 0.0
    successful_requests: float = 0.0


def _build_states() -> list[GpuState]:
    return [
        GpuState(
            gpu_id=str(i),
            uuid=f"GPU-{0xC0FFEE00 + i:08X}-mock-{i:04X}",
            device=f"nvidia{i}",
            model_name="NVIDIA H100 80GB HBM3",
        )
        for i in range(NUM_GPUS)
    ]


_STATES = _build_states()

# ---------------------------------------------------------------------------
# Wave generator — produces realistic fluctuating time-series
# ---------------------------------------------------------------------------


def _wave(phase: float, base: float, amp: float, noise_sd: float = 0.0) -> float:
    """Sine-driven value with Gaussian noise. Always ≥ 0."""
    return max(0.0, base + amp * math.sin(phase) + random.gauss(0.0, noise_sd))


# ---------------------------------------------------------------------------
# Background metric update loop
# ---------------------------------------------------------------------------


def _update_loop() -> None:
    """
    Runs in a daemon thread. Pushes new values to all Gauges every
    UPDATE_INTERVAL_S seconds.

    Load pattern:
      - Inference workload follows a sinusoidal busy/idle cycle (~2 min period)
      - KV-cache fills proportionally to GPU utilisation
      - Power correlates with SM utilisation (higher compute = higher power)
      - Temperature lags power by ~half a phase (thermal inertia)
      - ECC/XID errors are probabilistic rare events for alert testing
    """
    vllm_phase = random.uniform(0.0, math.tau)
    vllm_requests_total = 0.0

    while True:
        vllm_phase += 0.15  # ~2-min period at 5s update interval

        for s in _STATES:
            s.phase += 0.09 + random.uniform(-0.008, 0.008)
            p = s.phase

            lbl = {
                "gpu": s.gpu_id,
                "UUID": s.uuid,
                "device": s.device,
                "modelName": s.model_name,
                "Hostname": HOSTNAME,
            }

            # ── Compute ──────────────────────────────────────────────────────
            gpu_util = min(99.0, _wave(p, 68.0, 23.0, noise_sd=3.5))
            DCGM["DCGM_FI_DEV_GPU_UTIL"].labels(**lbl).set(gpu_util)
            DCGM["DCGM_FI_DEV_MEM_COPY_UTIL"].labels(**lbl).set(
                _wave(p + 0.5, 38.0, 14.0, noise_sd=2.0)
            )
            DCGM["DCGM_FI_DEV_ENC_UTIL"].labels(**lbl).set(0.0)
            DCGM["DCGM_FI_DEV_DEC_UTIL"].labels(**lbl).set(0.0)

            # ── Framebuffer ──────────────────────────────────────────────────
            # Model weights occupy ~65% baseline; KV-cache fills proportionally
            # to utilisation above that floor
            kv_fill_frac = (gpu_util / 99.0) * 0.30       # up to 30% for KV-cache
            fb_occ = min(0.97, max(0.15, 0.64 + kv_fill_frac + random.gauss(0, 0.01)))
            fb_reserved = 512
            fb_used = int(GPU_MEMORY_TOTAL_MIB * fb_occ)
            fb_free = max(0, GPU_MEMORY_TOTAL_MIB - fb_used - fb_reserved)
            DCGM["DCGM_FI_DEV_FB_TOTAL"].labels(**lbl).set(GPU_MEMORY_TOTAL_MIB)
            DCGM["DCGM_FI_DEV_FB_USED"].labels(**lbl).set(fb_used)
            DCGM["DCGM_FI_DEV_FB_FREE"].labels(**lbl).set(fb_free)
            DCGM["DCGM_FI_DEV_FB_RESERVED"].labels(**lbl).set(fb_reserved)

            # ── Clocks ───────────────────────────────────────────────────────
            sm_clock = _wave(p, 1845.0, 115.0, noise_sd=18.0)
            DCGM["DCGM_FI_DEV_SM_CLOCK"].labels(**lbl).set(sm_clock)
            DCGM["DCGM_FI_DEV_MEM_CLOCK"].labels(**lbl).set(3200.0)
            DCGM["DCGM_FI_DEV_APP_SM_CLOCK"].labels(**lbl).set(1980.0)
            DCGM["DCGM_FI_DEV_CLOCKS_THROTTLE_REASONS"].labels(**lbl).set(0)

            # ── Thermals ─────────────────────────────────────────────────────
            # Temperature lags power by ~quarter period (thermal mass)
            DCGM["DCGM_FI_DEV_GPU_TEMP"].labels(**lbl).set(
                _wave(p - 0.3, 67.0, 9.0, noise_sd=1.2)
            )
            DCGM["DCGM_FI_DEV_MEMORY_TEMP"].labels(**lbl).set(
                _wave(p - 0.2, 73.0, 7.0, noise_sd=1.0)
            )

            # ── Power ────────────────────────────────────────────────────────
            power_w = _wave(p, 528.0, 72.0, noise_sd=12.0)
            DCGM["DCGM_FI_DEV_POWER_USAGE"].labels(**lbl).set(power_w)
            DCGM["DCGM_FI_DEV_POWER_MGMT_LIMIT"].labels(**lbl).set(700.0)
            s.energy_mj += power_w * UPDATE_INTERVAL_S * 1_000  # W·s → mJ
            DCGM["DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION"].labels(**lbl).set(s.energy_mj)

            # ── PCIe ─────────────────────────────────────────────────────────
            DCGM["DCGM_FI_DEV_PCIE_TX_THROUGHPUT"].labels(**lbl).set(
                _wave(p, 11_500.0, 4_200.0, noise_sd=600.0)
            )
            DCGM["DCGM_FI_DEV_PCIE_RX_THROUGHPUT"].labels(**lbl).set(
                _wave(p + 0.35, 17_800.0, 5_100.0, noise_sd=600.0)
            )
            DCGM["DCGM_FI_DEV_PCIE_REPLAY_COUNTER"].labels(**lbl).set(
                1 if random.random() < 0.001 else 0
            )

            # ── NVLink (active in multi-GPU tensor-parallel inference) ───────
            DCGM["DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL"].labels(**lbl).set(
                _wave(p, 76_000.0, 24_000.0, noise_sd=2_500.0)
            )

            # ── ECC & XID errors — rare probabilistic spikes ─────────────────
            # Tune probabilities to test alert rule sensitivity
            sbe = 1 if random.random() < 0.003 else 0
            dbe = 1 if random.random() < 0.0004 else 0  # DBE triggers XID 48
            xid = dbe or (1 if random.random() < 0.0001 else 0)
            DCGM["DCGM_FI_DEV_ECC_SBE_VOL_TOTAL"].labels(**lbl).set(sbe)
            DCGM["DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"].labels(**lbl).set(dbe)
            DCGM["DCGM_FI_DEV_XID_ERRORS"].labels(**lbl).set(xid)

            # ── MIG ──────────────────────────────────────────────────────────
            DCGM["DCGM_FI_DEV_MIG_MODE_ACTIVE"].labels(**lbl).set(0)

        # ── vLLM model-level metrics ──────────────────────────────────────────
        ml = {"model_name": MODEL_NAME_LABEL, "version": "0"}

        kv_util = min(0.98, max(0.05, _wave(vllm_phase, 0.72, 0.18, noise_sd=0.02)))
        VLLM["vllm_gpu_cache_usage_perc"].labels(**ml).set(kv_util)
        VLLM["vllm_cpu_cache_usage_perc"].labels(**ml).set(
            max(0.0, _wave(vllm_phase + 1.2, 0.08, 0.07, noise_sd=0.01))
        )

        running = max(0, int(_wave(vllm_phase, 9.0, 6.0, noise_sd=1.2)))
        waiting = max(0, int(_wave(vllm_phase + 0.5, 3.5, 3.5, noise_sd=0.6)))
        preempted = max(0, int(_wave(vllm_phase + 0.9, 0.2, 0.4, noise_sd=0.1)))
        VLLM["vllm_num_running_requests"].labels(**ml).set(running)
        VLLM["vllm_num_waiting_requests"].labels(**ml).set(waiting)
        VLLM["vllm_num_preempted_requests"].labels(**ml).set(preempted)

        VLLM["vllm_avg_prompt_throughput_toks_per_s"].labels(**ml).set(
            _wave(vllm_phase, 1_180.0, 320.0, noise_sd=55.0)
        )
        gen_tput = _wave(vllm_phase + 0.25, 415.0, 85.0, noise_sd=22.0)
        VLLM["vllm_avg_generation_throughput_toks_per_s"].labels(**ml).set(gen_tput)

        # Counter.inc() is the correct method for prometheus_client Counter objects.
        # We increment by the estimated number of completions per tick rather than
        # calling .set() (which is only valid on Gauge).
        VLLM["vllm_request_success_total"].labels(**ml).inc(
            running * (UPDATE_INTERVAL_S / 4.0)
        )

        # ── vLLM latency histograms ───────────────────────────────────────────
        # Observe N synthetic requests per tick (proportional to running count).
        # Distributions: log-normal centred on realistic H100 inference values.
        #   TTFT:  ~200 ms mean at low load, degrades under KV pressure
        #   TPOT:  ~25 ms/token at 1750 MHz SM clock
        #   E2E:   TTFT + (avg_output_tokens * TPOT), ~128 output tokens default
        obs_count = max(1, running)
        ttft_mean = 0.18 + kv_util * 0.40          # 0.18 s → 0.58 s under pressure
        tpot_mean = 0.022 + (1.0 - kv_util) * 0.01  # slightly better when cache warm

        for _ in range(obs_count):
            ttft = max(0.005, random.lognormvariate(
                math.log(ttft_mean) - 0.18, 0.35
            ))
            tpot = max(0.002, random.lognormvariate(
                math.log(tpot_mean) - 0.08, 0.25
            ))
            output_tokens = max(16, int(random.lognormvariate(math.log(128), 0.6)))
            e2e = ttft + tpot * output_tokens

            VLLM_HIST["vllm_time_to_first_token_seconds"].labels(**ml).observe(ttft)
            VLLM_HIST["vllm_time_per_output_token_seconds"].labels(**ml).observe(tpot)
            VLLM_HIST["vllm_e2e_request_latency_seconds"].labels(**ml).observe(e2e)

        time.sleep(UPDATE_INTERVAL_S)


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Mock DCGM Exporter",
    description=(
        "Simulates NVIDIA DCGM + vLLM Prometheus metrics for local dev "
        "on Apple Silicon M4 Max. Scrape /metrics on port 9400."
    ),
    version="0.3.0",
    docs_url="/docs",
    redoc_url=None,
)


@app.on_event("startup")
def _start_updater() -> None:
    """Launch background metric-update thread as a daemon (dies with the process)."""
    t = threading.Thread(
        target=_update_loop,
        daemon=True,
        name="dcgm-updater",
    )
    t.start()


@app.get(
    "/metrics",
    include_in_schema=False,
    summary="Prometheus scrape endpoint",
    response_description="Prometheus text exposition format",
)
def metrics_endpoint() -> Response:
    """
    Standard Prometheus text format. Configure prometheus.yml to scrape this.

    Example scrape_configs entry:
      - job_name: mock-dcgm
        static_configs:
          - targets: ['localhost:9400']
    """
    return Response(
        content=generate_latest(REGISTRY),
        media_type=CONTENT_TYPE_LATEST,
    )


@app.get("/healthz", summary="Health check")
def healthz() -> dict:
    return {
        "status": "ok",
        "simulated_gpus": NUM_GPUS,
        "gpu_model": "NVIDIA H100 80GB HBM3 (mock)",
        "gpu_memory_total_mib": GPU_MEMORY_TOTAL_MIB,
        "update_interval_s": UPDATE_INTERVAL_S,
        "vllm_model": MODEL_NAME_LABEL,
        "scrape_url": f"http://localhost:{EXPORTER_PORT}/metrics",
    }


# ---------------------------------------------------------------------------
# Dockerfile hint (paste into platform/observability/Dockerfile)
# ---------------------------------------------------------------------------
# FROM python:3.12-slim
# WORKDIR /app
# COPY . .
# RUN pip install --no-cache-dir fastapi "uvicorn[standard]" prometheus-client
# EXPOSE 9400
# CMD ["python", "mock-dcgm-exporter.py"]

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(
        "mock-dcgm-exporter:app",
        host="0.0.0.0",
        port=EXPORTER_PORT,
        log_level="info",
        access_log=False,  # Suppress per-scrape noise (Prometheus scrapes every 15s)
    )
