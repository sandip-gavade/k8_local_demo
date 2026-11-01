#!/usr/bin/env bash
# Phase 4 tests: metrics scraped, rules loaded, dashboard + datasources in Grafana, logs in Loki,
# and a real alert fired end-to-end (Postgres down -> 5xx -> Prometheus -> Alertmanager).
# Add --skip-alert to skip the ~4 minute alert drill.
set -uo pipefail
cd "$(dirname "$0")/.."
NS=demo; REL=orders; MON=monitoring
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; kubectl -n $NS scale statefulset/postgres --replicas=1 >/dev/null 2>&1; }
trap cleanup EXIT

# Query Prometheus / Alertmanager / Loki through the API-server service proxy (no port-forward needed).
proxy() { kubectl get --raw "/api/v1/namespaces/$MON/services/$1/proxy/$2" 2>/dev/null; }
prom()  { proxy "mon-kube-prometheus-stack-prometheus:9090" "api/v1/$1"; }
promq() { prom "query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
val()   { python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null; }
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 5; done; return 1; }

echo "== 1. Stack is up (separate namespace)"
NOTREADY=$(kubectl -n $MON get pods --no-headers | grep -vE "Running|Completed" | wc -l | tr -d ' ')
[ "$NOTREADY" = 0 ] && pass "all pods in '$MON' Running" || fail "$NOTREADY pods not running in $MON"
for r in mon loki alloy; do
  helm status $r -n $MON >/dev/null 2>&1 && pass "helm release '$r' deployed" || fail "release $r"
done

echo "== 2. App side objects (rendered by the app chart's observability flag)"
for o in servicemonitor/$REL-web prometheusrule/$REL configmap/$REL-dashboard; do
  kubectl -n $NS get $o >/dev/null 2>&1 && pass "$o exists" || fail "$o missing"
done
kubectl -n $NS get servicemonitor $REL-web -o jsonpath='{.metadata.labels.release}' | grep -qx mon && pass "ServiceMonitor labelled release=mon" || fail "release label"

echo "== 3. Metrics"
t() { [ "$(promq "up{namespace=\"$NS\",service=\"$REL-web\"}" | val)" = 1 ]; }
retry 24 t && pass "Prometheus scrapes $REL-web (up == 1)" || fail "target not up"
for i in $(seq 1 30); do curl -s -o /dev/null localhost:8080/api/orders/; done
m() { v=$(promq "sum(django_http_requests_total_by_method_total{namespace=\"$NS\"})" | val); [ -n "$v" ] && [ "${v%.*}" -gt 0 ]; }
retry 12 m && pass "django_http_requests_total_by_method_total > 0" || fail "no django metrics"
l() { v=$(promq "histogram_quantile(0.95, sum by (le)(rate(django_http_requests_latency_seconds_by_view_method_bucket{namespace=\"$NS\"}[5m])))" | val); [ -n "$v" ] && [ "$v" != NaN ]; }
retry 12 l && pass "latency p95 query returns a value" || fail "p95 empty"
c() { [ -n "$(promq "container_cpu_usage_seconds_total{namespace=\"$NS\",pod=~\"$REL-web.*\"}" | val)" ]; }
retry 6 c && pass "pod CPU (cAdvisor) metrics present" || fail "cAdvisor metrics"
prom rules | grep -q DjangoHighErrorRate && pass "alert rule DjangoHighErrorRate loaded in Prometheus" || fail "rule not loaded"
curl -s localhost:8080/metrics | head -c 100 | grep -qi "<!doctype html" && pass "/metrics NOT exposed through Ingress (served React index instead)" || fail "/metrics reachable via Ingress?"

echo "== 4. Grafana"
GPASS=$(kubectl -n $MON get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n $MON port-forward svc/mon-grafana 3001:80 >/dev/null 2>&1 & PIDS+=($!)
sleep 4
G() { curl -s -u "admin:$GPASS" "localhost:3001$1"; }
g() { G "/api/search?query=Django" | grep -q "Django Orders"; }
retry 12 g && pass "dashboard 'Django Orders - RED/USE' auto-loaded from ConfigMap" || fail "dashboard missing"
G /api/datasources | grep -q '"uid":"prometheus"' && pass "Prometheus datasource (uid prometheus)" || fail "prom datasource"
G /api/datasources | grep -q '"uid":"loki"' && pass "Loki datasource (uid loki)" || fail "loki datasource"
G /api/datasources/uid/loki/health | grep -qi '"status":"OK"' && pass "Grafana -> Loki health OK" || fail "loki health"

echo "== 5. Logs"
kubectl -n $NS logs deploy/$REL-web --tail=20 | grep '^{' | tail -1 | python3 -c 'import sys,json;json.loads(sys.stdin.read())' 2>/dev/null \
  && pass "web emits JSON log lines" || fail "web logs not JSON"
lk() { proxy "loki:3100" "loki/api/v1/query_range?query=%7Bnamespace%3D%22demo%22%2Ccontainer%3D%22web%22%7D%20%7C%20json%20%7C%20status%3D%22200%22&limit=5" | grep -q '"status":"200"\|"values":\[\['; }
retry 18 lk && pass "Loki has web logs, parsed with '| json' (status field queryable)" || fail "no logs in Loki"

if [ "${1:-}" = "--skip-alert" ]; then echo "(alert drill skipped)"; else
echo "== 6. Alert drill: Postgres down -> 5xx -> DjangoHighErrorRate firing -> Alertmanager"
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/component=web -o name | head -1)
kubectl -n $NS port-forward "$POD" 18000:8000 >/dev/null 2>&1 & PIDS+=($!)
sleep 3
kubectl -n $NS scale statefulset/postgres --replicas=0 >/dev/null
# Hit the pod directly (port-forward) because readiness fails once the DB is gone and Ingress would stop routing.
FIRED=0
for i in $(seq 1 60); do
  for _ in 1 2 3 4 5; do curl -s -o /dev/null localhost:18000/api/orders/; done
  S=$(prom alerts | python3 -c 'import sys,json;a=[x["state"] for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"]=="DjangoHighErrorRate"];print(a[0] if a else "none")' 2>/dev/null)
  [ "$S" = firing ] && { FIRED=1; break; }
  sleep 5
done
[ $FIRED = 1 ] && pass "DjangoHighErrorRate reached state=firing in Prometheus" || fail "alert never fired (last state: ${S:-none})"
am() { proxy "mon-kube-prometheus-stack-alertmanager:9093" "api/v2/alerts" | grep -q DjangoHighErrorRate; }
retry 12 am && pass "Alertmanager received DjangoHighErrorRate" || fail "not in Alertmanager"
kubectl -n $NS scale statefulset/postgres --replicas=1 >/dev/null
kubectl -n $NS wait --for=condition=ready pod/postgres-0 --timeout=120s >/dev/null 2>&1 && pass "Postgres restored" || fail "postgres not restored"
kubectl -n $NS rollout status deploy/$REL-web --timeout=120s >/dev/null 2>&1
fi

echo
if [ $FAILS = 0 ]; then echo "ALL PHASE 4 CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
