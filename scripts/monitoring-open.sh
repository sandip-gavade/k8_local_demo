#!/usr/bin/env bash
# Open Grafana, Prometheus, Alertmanager and Loki on localhost via port-forward. Ctrl+C stops all of them.
# (The stack itself keeps running in the cluster; port-forward is only the "door" from your Mac.)
set -euo pipefail
kubectl -n monitoring get deploy mon-grafana >/dev/null 2>&1 || { echo "Monitoring not installed. Run ./scripts/monitoring-up.sh"; exit 1; }

PASS=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
trap 'kill $(jobs -p) 2>/dev/null' EXIT
kubectl -n monitoring port-forward svc/mon-grafana 3001:80 >/dev/null &
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090 >/dev/null &
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-alertmanager 9093:9093 >/dev/null &
kubectl -n monitoring port-forward svc/loki 3100:3100 >/dev/null &
sleep 2
cat <<MSG
Grafana       http://localhost:3001   user: admin   password: $PASS
Prometheus    http://localhost:9090   (Status > Targets, Alerts, Graph)
Alertmanager  http://localhost:9093
Loki API      http://localhost:3100/ready   (no UI: query logs in Grafana > Explore > Loki)
Ctrl+C to stop.
MSG
wait
