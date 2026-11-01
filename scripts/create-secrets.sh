#!/usr/bin/env bash
# Creates the K8s Secret from .env (never from a manifest in git). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
kubectl -n demo create secret generic orders-secrets \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=DJANGO_SECRET_KEY="$DJANGO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
