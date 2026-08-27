# =============================================================================
# mock-dcgm-exporter — Multi-arch container image
# =============================================================================
#
# Builds a minimal image for the mock DCGM + vLLM Prometheus exporter.
# Used in CI job 7 (cosign-sign) for supply-chain signing demonstration.
#
# Platforms built in CI: linux/amd64, linux/arm64 (Apple Silicon M4 Max)
#
# Local build (Apple Silicon):
#   docker build -t mock-dcgm-exporter:dev .
#   docker run --rm -p 9400:9400 mock-dcgm-exporter:dev
#
# Build with platform flag for CI parity:
#   docker buildx build --platform linux/amd64 -t mock-dcgm-exporter:ci .
#
# Environment variables (all optional — see mock-dcgm-exporter.py for defaults):
#   NUM_GPUS=2
#   GPU_MEM_MIB=24576
#   UPDATE_INTERVAL_S=5
#   EXPORTER_PORT=9400
#   MODEL_NAME_LABEL=llama3.2:3b
# =============================================================================

# --- Build stage: install uv and resolve dependencies into a venv ------------
FROM python:3.12-slim AS builder

# Install uv for fast, reproducible dependency installation
RUN pip install --no-cache-dir uv==0.5.20

WORKDIR /app

# Copy only the dependency specification first to maximise layer cache hits.
# If mock-dcgm-exporter.py changes but dependencies don't, this layer is reused.
COPY requirements.txt ./

RUN uv pip install --system --no-cache \
    -r requirements.txt

# --- Runtime stage: minimal image with non-root user -------------------------
FROM python:3.12-slim AS runtime

# CKS: Run as non-root. UID 10001 avoids conflicts with common system UIDs.
RUN groupadd --gid 10001 exporter && \
    useradd  --uid 10001 --gid exporter --no-create-home --shell /sbin/nologin exporter

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application source
COPY mock-dcgm-exporter.py .

# CKS: Drop all capabilities, read-only filesystem for the application files.
# The exporter writes nothing to disk — all state is in-memory.
USER exporter

# Prometheus metrics endpoint
EXPOSE 9400

# Metadata labels (OCI image spec)
LABEL org.opencontainers.image.title="mock-dcgm-exporter" \
      org.opencontainers.image.description="Mock DCGM + vLLM Prometheus exporter for GPU-less AI platform lab" \
      org.opencontainers.image.source="https://github.com/himanshusharma/ai-platform-lab" \
      org.opencontainers.image.licenses="Apache-2.0"

# Healthcheck — used by Docker and Kubernetes liveness probes
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9400/healthz')"

ENTRYPOINT ["python", "mock-dcgm-exporter.py"]
