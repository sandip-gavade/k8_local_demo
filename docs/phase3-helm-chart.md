# Phase 3: Helm chart, step by step

Goal: package the whole app (web, worker, beat, frontend) as ONE Helm chart that installs, upgrades
and rolls back as a unit, with one chart and a values file per environment.

## What Helm is
Helm = templating + release management. A **chart** is a folder of templates plus `values.yaml`.
`helm install` renders templates with values into plain YAML, applies it, and records a numbered
**revision** (a *release*) so you can `helm history` and `helm rollback`.

## Chart layout (`charts/django-app/`)
| File | Purpose |
|---|---|
| `Chart.yaml` | name, chart `version`, `appVersion` |
| `values.yaml` | defaults for everything (image tags, resources, config, ingress, hpa) |
| `values-dev.yaml` / `values-prod.yaml` | per-environment overrides (`-f` stacks on top of defaults) |
| `templates/_helpers.tpl` | reusable snippets: names, labels, selector labels, image strings, secret env |
| `templates/deployment-{web,worker,beat,frontend}.yaml` | the 4 workloads |
| `templates/service.yaml` | ClusterIP Services for web and frontend (one `range` loop) |
| `templates/ingress.yaml` | `/api` -> web, `/` -> frontend |
| `templates/configmap.yaml`, `secret.yaml` | config; Secret only if `secret.create=true` (tests) |
| `templates/hpa.yaml` | autoscaling/v2 on web CPU |
| `templates/migrate-job.yaml` | `pre-install,pre-upgrade` hook running `manage.py migrate` |
| `templates/serviceaccount.yaml` | SA with token automount disabled |

## Steps
```bash
# 1. Static checks (no cluster changes)
helm lint charts/django-app -f charts/django-app/values-dev.yaml
helm template orders charts/django-app -n demo -f charts/django-app/values-dev.yaml | less
helm upgrade --install orders charts/django-app -n demo -f charts/django-app/values-dev.yaml --dry-run=server

# 2. Install (also installs metrics-server for the HPA and creates the Secret)
./scripts/phase3-up.sh
#    = helm upgrade --install orders charts/django-app -n demo -f values-dev.yaml --rollback-on-failure --timeout 6m
#    (--rollback-on-failure is the new name of --atomic)

# 3. Look around
helm list -n demo ; helm history orders -n demo ; helm get values orders -n demo
kubectl -n demo get deploy,svc,ingress,hpa,pods
open http://localhost:8080/  http://localhost:8080/api/docs/

# 4. Change something and roll it back
helm upgrade orders charts/django-app -n demo -f charts/django-app/values-dev.yaml --set config.LOG_LEVEL=DEBUG
helm history orders -n demo
helm rollback orders 1 -n demo          # creates a NEW revision with revision 1's content

# 5. Test everything
./scripts/phase3-verify.sh
```

## Design choices (and the "why")
| Choice | Why |
|---|---|
| Secret is NOT created by the chart (`secret.name: orders-secrets` must exist) | Secrets must not live in git/values. On EKS: External Secrets + AWS Secrets Manager |
| `checksum/config` annotation on pod templates | Pods don't restart when a ConfigMap changes; a changed hash forces a rolling restart |
| web `maxSurge: 1, maxUnavailable: 0` | Zero-downtime rolling update: new pod must be Ready before an old one is removed |
| 3 probes on web: startup `/healthz`, liveness `/healthz`, readiness `/readyz` | Liveness never checks DB/Redis (a DB blip must not restart healthy pods); readiness does |
| beat: `replicas: 1` + `strategy: Recreate` | Two beats = every periodic task fires twice; Recreate avoids old+new overlap |
| worker `terminationGracePeriodSeconds: 60` | Celery warm shutdown lets running tasks finish |
| worker liveness = `celery inspect ping` | No HTTP port; asks the worker via the broker |
| `readOnlyRootFilesystem` + `emptyDir` on `/tmp` (nginx also `/var/cache/nginx`, `/etc/nginx/conf.d`) | Immutable containers; only declared paths are writable |
| HPA with `replicas` omitted from the Deployment when HPA is on | Otherwise every `helm upgrade` would reset the replica count the HPA chose |
| Memory limit but no CPU limit | CPU limits throttle; HPA scales on % of the CPU *request* |
| prod values: RDS + ElastiCache hosts, ECR images, TLS, 2+ replicas | Same chart, different environment; image tag injected by CI (`--set image.backend.tag=$SHA`) |

## Gotchas we hit (good interview stories)
1. **Hook Job stuck: `serviceaccount "orders" not found`.** `pre-install` hooks run *before* the chart's
   normal resources exist, so the Job could not use the chart's ServiceAccount (nor its ConfigMap, which is
   why the Job gets config as inline env). Fix: use the namespace default SA with `automountServiceAccountToken: false`.
   `helm install` waited the whole timeout, then `--rollback-on-failure` uninstalled the release.
2. **Bad image tag fails at the migrate hook, not at the Deployment.** The pre-upgrade Job hit `ImagePullBackOff`,
   Helm marked the revision `failed` and rolled back automatically, and the old pods kept serving. Hooks are a safety gate.
3. **Failed hook Jobs are kept** (`hook-delete-policy: before-hook-creation,hook-succeeded`) so you can `describe`/`logs` them.
4. `kubectl apply --dry-run=server` of an Ingress that already exists is rejected by the ingress-nginx webhook
   (duplicate path). Use `helm upgrade --dry-run=server` for validation instead.
5. Metrics-server on kind needs `--kubelet-insecure-tls` (self-signed kubelet certs). Local only.

## Verify results (`./scripts/phase3-verify.sh`): 33 checks
lint dev+prod, template, server dry-run; release deployed, 4 deployments available, hook job cleaned,
migrations applied; `/`, `/api/orders/`, `/api/docs/` all 200 through Ingress; order created and
processed by the in-cluster worker; beat scheduling; all pods non-root; read-only rootfs; no SA token; no
password in ConfigMap; HPA reads CPU; ConfigMap upgrade rolls pods; bad release auto-rolled-back with the
site still up; `helm rollback` restores config.

## Interview prep
**Talking point:** "I packaged the Django API, Celery worker and beat, and React frontend as one Helm chart
with dev and prod values. Migrations run as a pre-upgrade hook so a bad migration or image fails the release
before any new pod takes traffic, and `--rollback-on-failure` reverts automatically. Pods are non-root with
read-only filesystems, config changes trigger rolling restarts via a checksum annotation, and secrets are
referenced from an external Secret, never from values."

| Question | Short answer |
|---|---|
| What is a Helm hook? | An annotated resource run at a lifecycle point (pre/post install/upgrade/delete). Not part of the release manifest; ordered by weight; cleaned by delete-policy. |
| `helm upgrade --install --atomic`? | Install if missing else upgrade; wait for readiness; on failure roll back (now `--rollback-on-failure`). |
| How does `helm rollback` work? | It creates a new revision with an older revision's manifest. It doesn't rewind data (DB migrations are not undone). |
| How do you handle per-env config? | Layered values files (`-f values.yaml -f values-prod.yaml`) plus `--set` for CI-provided values like the image tag. |
| How do you make pods restart on ConfigMap change? | Checksum annotation of the rendered ConfigMap on the pod template. |
| Why not Helm-manage secrets? | Values end up in git and in the release Secret. Use External Secrets Operator / Secrets Store CSI with IRSA. |
| What is `_helpers.tpl`? | Named templates (`define`/`include`) for DRY labels and names; `_` prefix = not rendered as a manifest. |
| Library chart? | A chart of only helpers (`type: library`) that other charts depend on to share templates. |
| Why is `selector` a problem on upgrade? | `spec.selector` of a Deployment is immutable; keep selector labels minimal and stable (no version labels). |
