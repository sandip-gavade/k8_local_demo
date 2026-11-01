# syntax=docker/dockerfile:1
# ---- builder: uv resolves from uv.lock (reproducible), venv is the only artifact we keep ----
FROM python:3.13.1-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.25 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/opt/venv
WORKDIR /build
COPY pyproject.toml uv.lock ./
# --frozen: fail if lock is stale; --no-dev: no test/lint deps in the image
RUN uv sync --frozen --no-dev

# ---- runtime: no uv, no compilers, non-root ----
FROM python:3.13.1-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PATH="/opt/venv/bin:$PATH"
# Fixed numeric UID so K8s runAsNonRoot can be verified.
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY --chown=app:app . .
USER 10001:10001
EXPOSE 8000
# 1 process + threads (not N workers): /metrics counters live in-process, so one process keeps them
# consistent; scale with pods/HPA instead.
# Only /tmp and /dev/shm are written to -> compatible with readOnlyRootFilesystem in the Helm chart.
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "4", "--worker-class", "gthread", "--timeout", "30", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "--access-logformat", "{\"time\":\"%(t)s\",\"method\":\"%(m)s\",\"path\":\"%(U)s\",\"status\":%(s)s,\"duration_us\":%(D)s}"]
