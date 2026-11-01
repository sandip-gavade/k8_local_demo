#!/usr/bin/env bash
# DETACH observability completely. The app keeps running untouched (it only loses its ServiceMonitor/Rule/dashboard).
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. App first: stop rendering objects that need the Prometheus CRDs (--set wins over values-dev.yaml).
helm upgrade orders charts/django-app -n demo -f charts/django-app/values-dev.yaml \
  --set observability.enabled=false --rollback-on-failure --timeout 6m

# 2. Remove the stack, then its namespace (also removes PVCs/secrets such as grafana-admin).
helm uninstall alloy loki mon -n monitoring || true
kubectl delete ns monitoring --ignore-not-found

# 3. Helm never deletes CRDs; remove them so the cluster is truly clean (this also deletes any CR of those kinds).
kubectl get crd -o name | grep 'monitoring.coreos.com' | xargs -r kubectl delete
echo "Observability detached. Re-attach with ./scripts/monitoring-up.sh"
