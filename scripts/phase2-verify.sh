#!/usr/bin/env bash
# Phase 2 tests. Exits non-zero on first failure.
set -euo pipefail
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# 1. Node + PVCs
kubectl get nodes --no-headers | grep -q " Ready" && pass "node Ready" || fail "node"
[ "$(kubectl -n demo get pvc --no-headers | grep -c Bound)" = 2 ] && pass "2 PVCs Bound" || fail "PVCs"

# 2. Ingress controller reachable from the Mac via the kind port mapping (404 = nginx up, no routes yet)
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/)
[ "$code" = 404 ] && pass "ingress-nginx answers on localhost:8080 (404, no routes yet)" || fail "ingress code=$code"

# 3. App image runs in-cluster as non-root, reaches Postgres + Redis through Service DNS
kubectl -n demo delete pod app-smoke --ignore-not-found >/dev/null
kubectl -n demo apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: app-smoke, namespace: demo}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: app
      image: django-app:dev        # loaded with `kind load`; not pulled from a registry
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "python manage.py migrate --noinput && python manage.py shell -c \"from orders.models import Order; o=Order.objects.create(item='k8s-smoke'); print('DB_WRITE_OK', o.pk)\" && python -c \"import redis,os; print('REDIS', redis.Redis.from_url(os.environ['REDIS_URL']).ping())\""]
      env:
        - {name: POSTGRES_HOST, value: postgres}
        - {name: POSTGRES_DB, value: orders}
        - {name: POSTGRES_USER, value: orders}
        - {name: REDIS_URL, value: "redis://redis:6379/0"}
        - name: POSTGRES_PASSWORD
          valueFrom: {secretKeyRef: {name: orders-secrets, key: POSTGRES_PASSWORD}}
        - name: DJANGO_SECRET_KEY
          valueFrom: {secretKeyRef: {name: orders-secrets, key: DJANGO_SECRET_KEY}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 256Mi}}
YAML
kubectl -n demo wait --for=jsonpath='{.status.phase}'=Succeeded pod/app-smoke --timeout=120s >/dev/null || { kubectl -n demo logs app-smoke; fail "app-smoke pod"; }
out=$(kubectl -n demo logs app-smoke)
echo "$out" | grep -q DB_WRITE_OK && pass "migrate + DB write from app pod" || fail "db"
echo "$out" | grep -q "REDIS True" && pass "Redis ping from app pod" || fail "redis"
kubectl -n demo delete pod app-smoke >/dev/null

# 4. Persistence: restart Postgres, the row must survive (PVC)
kubectl -n demo delete pod postgres-0 >/dev/null
kubectl -n demo wait --for=condition=ready pod/postgres-0 --timeout=120s >/dev/null
n=$(kubectl -n demo exec postgres-0 -- psql -U orders -d orders -tAc "select count(*) from orders_order where item='k8s-smoke'")
[ "$n" -ge 1 ] && pass "data survived Postgres pod restart (rows=$n)" || fail "persistence"
echo "ALL PHASE 2 CHECKS PASSED"
