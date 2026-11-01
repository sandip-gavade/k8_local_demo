# Phase 2: Cluster basics, step by step

Goal: a local Kubernetes cluster (kind, on Docker Desktop) with an ingress controller,
Postgres and Redis running as StatefulSets with persistent storage, and our app image
available inside the cluster. Nothing of our own app is deployed yet (that is Phase 3).

Run everything from the repo root. `./scripts/phase2-up.sh` does steps 1-7 in one go;
this document is the manual version so you can explain each step.

## Step 1: Create the kind cluster
```bash
kind create cluster --config kind/kind-config.yaml
kubectl config use-context kind-demo
kubectl get nodes        # demo-control-plane   Ready
```
What it does: kind runs a whole Kubernetes node as ONE Docker container (`demo-control-plane`).
`kind/kind-config.yaml` sets three things:
- `image: kindest/node:v1.34.0`: pins the Kubernetes version.
- `node-labels: ingress-ready=true`: the ingress-nginx kind manifest only schedules onto nodes with this label.
- `extraPortMappings`: Mac `localhost:8080` -> node port 80, and `8443` -> 443. This is how a browser on your Mac reaches the cluster (a cluster in a container has no other way in). 8080 is used instead of 80 so no root is needed.

## Step 2: Install the ingress controller
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
```
What it does: an `Ingress` resource is just rules ("host/path -> Service"). Something must read those
rules and route traffic; that is the controller (nginx here). The `provider/kind` variant listens on the
node's ports 80/443 (hostPort), which step 1 mapped to your Mac. Version is pinned (no `main`/`latest`).

## Step 3: Create the namespace
```bash
kubectl apply -f k8s/infra/00-namespace.yaml     # namespace "demo"
```
Namespaces group and isolate our resources from `kube-system` / `ingress-nginx`.

## Step 4: Create the Secret (not from a file in git)
```bash
./scripts/create-secrets.sh
kubectl -n demo get secret orders-secrets
```
What it does: reads `.env` and runs `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`
(the dry-run + apply pattern makes it re-runnable). Postgres and the app read `POSTGRES_PASSWORD` /
`DJANGO_SECRET_KEY` from this Secret via `secretKeyRef`. Remember: a Secret is only base64, not encrypted;
on EKS you add KMS envelope encryption or External Secrets.

## Step 5: Deploy Postgres and Redis
```bash
kubectl apply -f k8s/infra/
kubectl -n demo rollout status statefulset/postgres statefulset/redis
kubectl -n demo get pods,pvc,svc
```
`k8s/infra/postgres.yaml` has two objects:
- **Headless Service** (`clusterIP: None`): gives stable DNS (`postgres-0.postgres.demo.svc`); clients also use `postgres`.
- **StatefulSet** (`replicas: 1`) with:
  - `volumeClaimTemplates`: creates PVC `data-postgres-0` (1Gi) from kind's default `standard` StorageClass. The PVC outlives the pod.
  - `PGDATA=/var/lib/postgresql/data/pgdata`: subdirectory, because a fresh volume root contains `lost+found` and `initdb` rejects non-empty dirs.
  - Probes: `pg_isready` for readiness (stop routing) and liveness (restart).
  - Security: `runAsNonRoot`, `runAsUser: 70` (postgres user in the alpine image), `fsGroup: 70` (so the mounted volume is writable), `drop: [ALL]` capabilities, `seccompProfile: RuntimeDefault`.
  - Resources: requests (scheduling) and a memory limit.
  - An `emptyDir` at `/var/run/postgresql` because the unix socket needs a writable path.

`k8s/infra/redis.yaml` is the same idea: `--appendonly yes` (AOF, so queued Celery tasks survive a restart),
UID 999, and `readOnlyRootFilesystem: true` (only `/data` is writable).

First run is slow (about 8 min for us) because the kind node pulls images over the network.
`kubectl -n demo describe pod postgres-0` shows `Pulling` events while it waits.

## Step 6: Build the app images and load them into kind
```bash
docker build -t django-app:dev app
docker build -t orders-frontend:dev frontend
kind load docker-image django-app:dev orders-frontend:dev --name demo
docker exec demo-control-plane crictl images | grep -E "django-app|orders-frontend"
```
Why: the kind node has its own container runtime, separate from Docker Desktop's image store.
A locally built image does not exist inside the node until you `kind load` it. Use a non-`latest` tag
(`dev`), otherwise the default `imagePullPolicy: Always` would try (and fail) to pull it from a registry.

## Step 7: Verify
```bash
./scripts/phase2-verify.sh
```
| Check | How | Proves |
|---|---|---|
| Node Ready, 2 PVCs Bound | `kubectl get nodes`, `get pvc` | cluster + storage work |
| `curl localhost:8080` returns 404 | the controller answers and has no routes yet | Mac -> kind port mapping -> ingress-nginx works |
| Throwaway pod `app-smoke` using `django-app:dev` | runs `migrate`, writes an Order row, pings Redis | image loaded, runs non-root with read-only rootfs, Service DNS (`postgres`, `redis`) and Secret work |
| Delete `postgres-0`, query the row | `kubectl exec postgres-0 -- psql ...` | PVC keeps data across pod restarts |

## Teardown / reset
```bash
kubectl -n demo delete pvc --all     # only if you want to wipe data
kind delete cluster --name demo      # remove everything
```

## Debug flow (use it whenever something is stuck)
```bash
kubectl get pods -A
kubectl -n <ns> describe pod <pod>          # Events at the bottom
kubectl -n <ns> logs <pod> --previous
kubectl -n <ns> exec -it <pod> -- sh
```
