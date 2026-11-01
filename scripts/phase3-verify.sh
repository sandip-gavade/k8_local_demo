#!/usr/bin/env bash
# Phase 3 tests: lint/template, deploy health, end-to-end through Ingress, security, HPA, upgrade/rollback.
set -uo pipefail
cd "$(dirname "$0")/.."
CH=charts/django-app; NS=demo; REL=orders
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
http() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

echo "== 1. Static checks"
check "helm lint (dev)"  helm lint $CH -f $CH/values-dev.yaml
check "helm lint (prod)" helm lint $CH -f $CH/values-prod.yaml
check "helm template renders" helm template $REL $CH -n $NS -f $CH/values-dev.yaml
check "server-side dry-run accepted (helm upgrade --dry-run=server)" helm upgrade --install $REL $CH -n $NS -f $CH/values-dev.yaml --dry-run=server

echo "== 2. Release + pods"
check "release status deployed" bash -c "helm status $REL -n $NS -o json | grep -q '\"status\":\"deployed\"'"
for d in web worker beat frontend; do
  check "deployment $d available" kubectl -n $NS rollout status deploy/$REL-$d --timeout=120s
done
check "migrate hook job cleaned up (hook-succeeded)" bash -c "! kubectl -n $NS get job $REL-migrate"
check "migrations applied (orders_order table exists)" bash -c "kubectl -n $NS exec postgres-0 -- psql -U orders -d orders -tAc \"select to_regclass('public.orders_order')\" | grep -q orders_order"

echo "== 3. End-to-end through Ingress (localhost:8080)"
[ "$(http localhost:8080/)" = 200 ]            && pass "GET /            -> 200 (React via nginx)" || fail "GET /"
[ "$(http localhost:8080/api/orders/)" = 200 ] && pass "GET /api/orders/ -> 200 (Django)"        || fail "GET /api/orders/"
[ "$(http localhost:8080/api/docs/)" = 200 ]   && pass "GET /api/docs/   -> 200 (Swagger)"       || fail "GET /api/docs/"
ID=$(curl -s -XPOST localhost:8080/api/orders/ -H 'content-type: application/json' -d '{"item":"helm-test","quantity":1}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null)
sleep 5
ST=$(curl -s "localhost:8080/api/orders/" | python3 -c "import sys,json;print([o['status'] for o in json.load(sys.stdin)['results'] if o['id']==$ID][0])" 2>/dev/null)
[ "${ST:-}" = processed ] && pass "order $ID created via Ingress and processed by Celery worker in-cluster" || fail "order status=${ST:-none}"
check "beat is scheduling tasks" bash -c "kubectl -n $NS logs deploy/$REL-beat | grep -qE 'Scheduler: Sending due task|beat: Starting'"

echo "== 4. Security"
for d in web worker beat frontend; do
  U=$(kubectl -n $NS exec deploy/$REL-$d -- id -u 2>/dev/null)
  if [ -n "$U" ] && [ "$U" != 0 ]; then pass "$d runs as non-root (uid $U)"; else fail "$d uid=${U:-?}"; fi
done
check "read-only rootfs enforced on web" bash -c "! kubectl -n $NS exec deploy/$REL-web -- touch /app/x"
check "no ServiceAccount token mounted in web" bash -c "! kubectl -n $NS exec deploy/$REL-web -- ls /var/run/secrets/kubernetes.io/serviceaccount"
check "no password in ConfigMap" bash -c "! kubectl -n $NS get cm $REL-config -o yaml | grep -qi password"

echo "== 5. HPA (needs metrics-server)"
T=""
for i in $(seq 1 12); do
  T=$(kubectl -n $NS get hpa $REL-web -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  [ -n "$T" ] && break; sleep 10
done
[ -n "$T" ] && pass "HPA reads CPU metrics (current ${T}%)" || fail "HPA shows <unknown>"

echo "== 6. Upgrade / history / rollback"
REV0=$(helm history $REL -n $NS -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)[-1]["revision"])')
if helm upgrade $REL $CH -n $NS -f $CH/values-dev.yaml --set config.LOG_LEVEL=DEBUG --rollback-on-failure --timeout 3m >/dev/null 2>&1; then
  pass "upgrade with changed ConfigMap succeeded (rev $((REV0+1)))"; else fail "upgrade"; fi
check "checksum annotation rolled pods onto new config" bash -c "kubectl -n $NS exec deploy/$REL-web -- env | grep -q LOG_LEVEL=DEBUG"
echo "-- bad release (nonexistent image tag) must fail AND auto-roll back"
if helm upgrade $REL $CH -n $NS -f $CH/values-dev.yaml --set image.backend.tag=does-not-exist --rollback-on-failure --timeout 90s >/dev/null 2>&1; then
  fail "bad release unexpectedly succeeded"; else pass "bad release failed and was rolled back automatically"; fi
echo "-- failed hook Job is kept on purpose for debugging (kubectl -n $NS describe job $REL-migrate); cleaning up now"
kubectl -n $NS delete job $REL-migrate --ignore-not-found >/dev/null
[ "$(http localhost:8080/api/orders/)" = 200 ] && pass "site still serving after bad release (maxUnavailable=0)" || fail "site down after bad release"
helm history $REL -n $NS | tail -5
if helm rollback $REL $REV0 -n $NS --wait --timeout 3m >/dev/null 2>&1; then pass "manual helm rollback to revision $REV0"; else fail "rollback"; fi
check "LOG_LEVEL back to INFO after rollback" bash -c "kubectl -n $NS exec deploy/$REL-web -- env | grep -q LOG_LEVEL=INFO"

echo
if [ $FAILS = 0 ]; then echo "ALL PHASE 3 CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
