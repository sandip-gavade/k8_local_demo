#!/usr/bin/env bash
# Phase 2: cluster + ingress-nginx + infra + images. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
INGRESS_VER=controller-v1.12.1

kind get clusters | grep -qx demo || kind create cluster --config kind/kind-config.yaml
kubectl config use-context kind-demo

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VER}/deploy/static/provider/kind/deploy.yaml"
kubectl apply -f k8s/infra/00-namespace.yaml
./scripts/create-secrets.sh
kubectl apply -f k8s/infra/

docker build -t django-app:dev app
docker build -t orders-frontend:dev frontend
kind load docker-image django-app:dev orders-frontend:dev --name demo

kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
kubectl -n demo rollout status statefulset/postgres statefulset/redis --timeout=180s
