#!/usr/bin/env bash
# Install the OPTIONAL observability stack, then switch on the app's monitoring objects. Re-runnable.
# Everything lives in namespace "monitoring" as 3 separate Helm releases (mon, loki, alloy).
set -euo pipefail
cd "$(dirname "$0")/.."
KPS_VER=92.17.0; LOKI_VER=7.5.0; ALLOY_VER=1.15.0

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring
# Grafana admin password: random, kept only in the cluster (not in git, not in values).
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18 | tr -d '/+=')"
fi

# Order matters: kube-prometheus-stack installs the CRDs (ServiceMonitor, PrometheusRule) the app chart needs.
helm upgrade --install mon  prometheus-community/kube-prometheus-stack --version $KPS_VER -n monitoring -f observability/kps-values.yaml --wait --timeout 10m
helm upgrade --install loki grafana/loki  --version $LOKI_VER  -n monitoring -f observability/loki-values.yaml  --wait --timeout 10m
helm upgrade --install alloy grafana/alloy --version $ALLOY_VER -n monitoring -f observability/alloy-values.yaml --wait --timeout 10m

# App side: re-deploy so the app chart renders ServiceMonitor + PrometheusRule + dashboard and JSON logs are on.
./scripts/create-secrets.sh
docker build -q -t django-app:dev app >/dev/null
kind load docker-image django-app:dev --name demo
helm upgrade --install orders charts/django-app -n demo -f charts/django-app/values-dev.yaml --rollback-on-failure --timeout 6m

echo "Grafana password: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo "Grafana:    kubectl -n monitoring port-forward svc/mon-grafana 3001:80          -> http://localhost:3001  (admin)"
echo "Prometheus: kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090 -> http://localhost:9090"
