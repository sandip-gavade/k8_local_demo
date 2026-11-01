# Project: Django on Kubernetes with Helm + Observability (SiFive interview prep)

Remote: git@github.com:sandip-gavade/k8_local_demo.git (branch `main`)

## Context
- Sandip: full-stack dev, 10+ yrs Python/Django, Java/Spring Boot.
- Interview: SiFive "Staff DevOps / Backend Engineer", Mon 2 Nov 2026, 10 AM IST.
  JD: Django APIs, AWS EKS, Terraform, Docker, Helm, K8s (Pods, Services, Ingress, ConfigMaps),
  CI/CD (GitHub Actions, Jenkins, Concourse), observability, K8s secrets and IAM.
- Budget ~10 h hands-on. A setup problem blocking > 30 min gets skipped.
- Machine: Mac M1 Pro (arm64). **Container runtime: Docker Desktop only (no Podman)**,
  plus kind, kubectl, helm. Local only: never create real AWS resources; Terraform is `plan`/`validate` only.

## How to help
- Runnable code and commands; comments are the main documentation.
- One phase at a time. Each phase ends with a "verify" command list + expected output.
- arm64-compatible images, pinned versions (no `latest`).
- Security defaults: non-root containers, resource requests/limits, no secrets in images or committed values files.
- After each phase give: (1) a 2-3 sentence interview talking point, (2) 3-5 likely interview Qs with short model answers.
- Short, concrete explanations. Don't over-engineer. Ask only if blocked; otherwise choose defaults and say so.
- Commit per phase (small focused commits); push to origin only when asked.

## Stack
- Django 5 + DRF (`orders` API list/create), PostgreSQL 16, Redis 7, Celery worker + beat (1 periodic, 1 async task)
- gunicorn, multi-stage Dockerfile
- kind + ingress-nginx (kind uses Docker Desktop; load images with `kind load docker-image`)
- Own Helm chart `charts/django-app`
- kube-prometheus-stack + django-prometheus + Loki
- Terraform (AWS VPC + EKS modules, plan only) + GitHub Actions workflow

## Repo layout
```
app/                 # Django project, Dockerfile, .dockerignore, requirements.txt
charts/django-app/   # values.yaml values-dev.yaml values-prod.yaml
  templates/  deployment-web|worker|beat.yaml service.yaml ingress.yaml configmap.yaml
              secret.yaml hpa.yaml migrate-job.yaml servicemonitor.yaml prometheusrule.yaml _helpers.tpl
k8s/infra/           # postgres + redis (StatefulSet + PVC + Service)
terraform/eks/       # main.tf variables.tf outputs.tf backend.tf (plan only)
.github/workflows/ci.yaml
scripts/             # break-and-fix drills
README.md            # commands + interview notes
```

## Phases
1. **App and image (1 h)**: Django+DRF orders API, Celery tasks, `/healthz` `/readyz`, secure multi-stage Dockerfile, `docker compose` smoke test.
2. **Cluster basics (1 h)**: kind cluster w/ ingress port mappings, ingress-nginx, Postgres+Redis StatefulSets/PVCs, load app image into kind.
3. **Helm chart (2.5 h)**: web/worker/beat Deployments, Service, Ingress, ConfigMap, Secret, HPA, migration Job (`pre-install,pre-upgrade` hook), probes, securityContext, `_helpers.tpl`, dev/prod values. Verify: `helm lint`, `helm template`, `helm upgrade --install --atomic`, `helm history`, `helm rollback`.
4. **Observability (1.5 h)**: kube-prometheus-stack, django-prometheus `/metrics`, ServiceMonitor (label `release: mon`), Grafana dashboard (rate, errors, p95, pod CPU/mem), PrometheusRule alert, Loki + JSON logging.
5. **Break and fix (1 h)**: ImagePullBackOff, CrashLoopBackOff, OOMKilled, failing readiness, Pending pod, bad release -> `helm rollback`. For each: symptom, diagnosing `kubectl`, root cause, fix.
6. **AWS and CI on paper (1 h)**: Terraform vpc+eks modules (3 AZs, private node subnets, managed node group, IRSA, S3 backend w/ locking), `init`+`validate`. GitHub Actions: lint+test, build+Trivy, push to ECR via OIDC, `helm upgrade` to EKS. Short Jenkinsfile for comparison.

## Interview points to cover
- Pod/Deployment/ReplicaSet/StatefulSet; Service types; Ingress + controller
- ConfigMap vs Secret; KMS encryption or External Secrets + AWS Secrets Manager
- Probes; requests/limits; HPA; rolling update settings
- Helm: structure, templating, helpers, hooks, per-env values, upgrade/rollback, library charts
- Secure Dockerfile, image scanning
- Observability: RED/USE, logs, traces (OpenTelemetry), symptom-based alerting
- Debug flow: `get` -> `describe` -> `logs --previous` -> `exec` -> `top`
- EKS: managed control plane, node groups, VPC CNI, IRSA, ALB controller, Karpenter
- Terraform: state, locking, modules, plan in PR / apply on merge, drift, import
- CI/CD: pre/post-merge checks, OIDC, canary, auto rollback
- Map to real work: RefundStacker (Django, Celery, Redis, Postgres), GCP migration design, Infosys AWS CloudFormation + CI/CD
