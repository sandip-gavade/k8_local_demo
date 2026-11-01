#!/usr/bin/env bash
# Proves observability is DETACHABLE: remove it completely, show the app is untouched, then re-attach.
set -uo pipefail
cd "$(dirname "$0")/.."
NS=demo; REL=orders; FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
pods() { kubectl -n $NS get pods -l app.kubernetes.io/instance=$REL -o jsonpath='{range .items[*]}{.metadata.name}:{.status.containerStatuses[0].restartCount}{"\n"}{end}' | sort; }

BEFORE=$(pods)
echo "== Detach"
./scripts/monitoring-down.sh >/dev/null 2>&1 && pass "monitoring-down.sh completed" || fail "monitoring-down.sh"

kubectl get ns monitoring >/dev/null 2>&1 && fail "namespace monitoring still exists" || pass "namespace 'monitoring' gone"
[ -z "$(kubectl get crd -o name | grep monitoring.coreos.com)" ] && pass "Prometheus Operator CRDs removed" || fail "CRDs remain"
[ "$(helm list -A --no-headers | awk '{print $1}' | grep -cE '^(mon|loki|alloy)$')" = 0 ] && pass "helm releases mon/loki/alloy gone" || fail "releases remain"
[ -z "$(kubectl -n $NS get cm $REL-dashboard -o name 2>/dev/null)" ] && pass "dashboard ConfigMap removed from app namespace" || fail "dashboard CM remains"
helm get manifest $REL -n $NS | grep -qE "ServiceMonitor|PrometheusRule" && fail "release still contains monitoring objects" || pass "app release no longer contains ServiceMonitor/PrometheusRule"

echo "== App unaffected"
AFTER=$(pods)
[ "$BEFORE" = "$AFTER" ] && pass "same app pods, no restarts, no rollout (pods identical before/after)" || { fail "app pods changed"; echo "$BEFORE"; echo ---; echo "$AFTER"; }
[ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/api/orders/)" = 200 ] && pass "API still 200 via Ingress" || fail "API down"
ID=$(curl -s -XPOST localhost:8080/api/orders/ -H 'content-type: application/json' -d '{"item":"detach-test","quantity":1}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null)
sleep 4
curl -s localhost:8080/api/orders/ | python3 -c "import sys,json;sys.exit(0 if [o for o in json.load(sys.stdin)['results'] if o['id']==$ID and o['status']=='processed'] else 1)" \
  && pass "order $ID created and processed by worker with no monitoring present" || fail "order flow"
kubectl -n $NS logs deploy/$REL-web --tail=3 | grep -q '^{' && pass "app still logs JSON to stdout (collector-agnostic)" || fail "logging"

echo "== Re-attach"
./scripts/monitoring-up.sh >/dev/null 2>&1 && pass "monitoring-up.sh completed" || fail "monitoring-up.sh"
r() { v=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/mon-kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up%7Bnamespace%3D%22demo%22%2Cservice%3D%22$REL-web%22%7D" 2>/dev/null | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null); [ "$v" = 1 ]; }
ok=1; for _ in $(seq 1 24); do r && { ok=0; break; }; sleep 5; done
[ $ok = 0 ] && pass "after re-attach Prometheus scrapes the app again" || fail "re-attach scrape"
echo
if [ $FAILS = 0 ]; then echo "ALL DETACH CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
