#!/usr/bin/env bash
# Phase 3: metrics-server (for HPA) + install/upgrade the Helm release. Re-runnable.
set -euo pipefail
cd "$(dirname "$0")/.."

# kind's kubelet uses a self-signed cert, so metrics-server needs --kubelet-insecure-tls (local only!).
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true

./scripts/create-secrets.sh
# --rollback-on-failure (formerly --atomic): roll back automatically if the migrate hook or the rollout fails. --wait is implied.
helm upgrade --install orders charts/django-app -n demo \
  -f charts/django-app/values-dev.yaml --rollback-on-failure --timeout 6m
