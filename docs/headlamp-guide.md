# Seeing the whole cluster: Headlamp (and k9s)

## The problem
Docker Desktop's Containers page lists **one** container, `demo-control-plane`. That is correct, and it is not where
your pods are shown:

```
Docker Desktop
 └─ container: demo-control-plane          <- the only thing Docker knows about
      └─ containerd (a second runtime, inside the node)
           ├─ pod orders-web      ┐
           ├─ pod postgres-0      │ ~30 containers Docker Desktop can't see
           ├─ pod prometheus-0    │
           └─ ...                 ┘
```
Docker's "Kubernetes" tab is a different, built-in cluster; it knows nothing about kind. So use a Kubernetes-aware
tool. They all read the same file, `~/.kube/config`, where kind added the context **`kind-demo`**.

```bash
kubectl config get-contexts        # kind-demo should be marked with *
kubectl cluster-info --context kind-demo
```

## Option 1: Headlamp (GUI)

### Open it
Headlamp is installed as a desktop app (`/Applications/Headlamp.app`).
1. Open Headlamp. It lists contexts found in `~/.kube/config`.
2. Click **kind-demo** (shown under *Clusters*). No login is needed because it uses your kubeconfig credentials.
3. If the cluster doesn't appear: check `kubectl config get-contexts`; if kind lost the context, run
   `kind export kubeconfig --name demo` and restart Headlamp.
4. Not installed? `brew install --cask headlamp`.

### Where to find what (left menu)
| Menu | Shows | Try this |
|---|---|---|
| **Home** | Cluster overview, warnings | First look: any red items? |
| **Map** | Live diagram of objects grouped by namespace (your screenshot) | Top bar: *Group By* Namespace / Instance / Node; *Namespaces* filter, choose `demo`; *Status: Error or Warning* hides the healthy ones. Click a box to open it. |
| **Workloads** | Pods, Deployments, StatefulSets, ReplicaSets, DaemonSets, Jobs | Open **Pods** and filter by `demo`. Click `orders-web-...` for status, restarts, node and IP. Tabs on top: **Logs**, **Terminal** (a shell inside the container), **Events**. |
| **Storage** | PersistentVolumeClaims, PersistentVolumes, StorageClasses | See `data-postgres-0` and `data-redis-0` (1Gi, Bound). Click one to see which pod mounts it. |
| **Network** | Services, Ingresses, Endpoints, IngressClasses | Open **Ingresses > orders**: the `/api` and `/` rules. Open **Services > postgres**: Cluster IP `None` = headless. Endpoints show pod IPs behind each Service. |
| **Gateway (beta)** | Gateway API objects | Empty here; we use classic Ingress. |
| **Security** | ServiceAccounts, Roles, RoleBindings | `orders` ServiceAccount (token not mounted). |
| **Configuration** | ConfigMaps, Secrets, HPAs, ResourceQuotas | `orders-config` (our env vars), `orders-secrets` (values hidden until you click the eye), HPA `orders-web`. |
| **Custom Resources** | CRDs from operators | `ServiceMonitor orders-web` and `PrometheusRule orders` (only while monitoring is attached). |
| **Apps** | Helm releases (if the Headlamp Helm plugin is on) | Release `orders` and the monitoring releases, with revisions. If missing, use `helm list -A`. |
| **Nodes** (Cluster section / under Home) | Node `demo-control-plane`: capacity, conditions, pods on it | CPU/memory use comes from metrics-server (installed in Phase 3). |

### Useful moves
| I want to... | In Headlamp |
|---|---|
| Watch logs of a pod | Workloads > Pods > pod > **Logs** tab (pick the container, tick *Follow*) |
| Get a shell | Pod > **Terminal** tab (`id` shows uid 10001; `touch /app/x` fails: read-only filesystem) |
| See why a pod isn't starting | Pod > **Events** (same as `kubectl describe pod`), or Map > *Status: Error or Warning* |
| See rollout history | Deployment > open it; the ReplicaSets list shows old versions at 0 pods |
| Scale temporarily | Deployment > **Scale**. Note Helm/HPA will reset it on the next upgrade/scale decision. |
| See live YAML | Any object > **Edit** (view). Avoid editing: Helm owns these objects, and changes get overwritten. |
| Find anything | Press `/` and search by name |

### Reading the Map
Each box is an object; the small circled number is how many *related* objects hang off it (pods, ReplicaSets,
ConfigMaps...). It is **not** the replica count. Real replica counts are on the Workloads pages.

## Option 2: k9s (terminal UI), already installed
```bash
k9s -n demo                     # start in namespace demo (use :ns to switch)
```
| Key | Action |
|---|---|
| `:pods`, `:deploy`, `:svc`, `:ing`, `:pvc`, `:sts`, `:hpa`, `:ns`, `:node` | jump to a resource type (type `:` then the name, Enter) |
| `Enter` | drill into the selected item |
| `l` | logs (`p` previous container, `0` all time range, `w` wrap) |
| `s` | shell into the container |
| `d` | describe (events at the bottom) |
| `y` | YAML |
| `Ctrl+d` | delete (asks first) |
| `/` | filter, `Esc` back, `?` help, `:q` quit |
| `:xray deploy` | tree view Deployment > ReplicaSet > Pod |
| `:helm` | list Helm releases |

## Option 3: look *inside* the node (proves the nesting)
```bash
docker ps                                          # 1 container: demo-control-plane
docker exec demo-control-plane crictl ps           # the ~30 real containers (pods' containers)
docker exec demo-control-plane crictl images       # images in the node's own store (kind load puts ours here)
kubectl get pods -A -o wide                        # same pods with their node and IP
```

## Option 4: plain kubectl cheat sheet
```bash
kubectl get all -A                                 # almost everything
kubectl -n demo get deploy,sts,svc,ingress,hpa,pvc,cm,secret
kubectl top nodes ; kubectl top pods -A            # needs metrics-server
kubectl get events -A --sort-by=.lastTimestamp | tail -20
helm list -A ; helm history orders -n demo
```

## Which tool for what
| Need | Best tool |
|---|---|
| Visual overview, explain the architecture, click through objects | **Headlamp** (Map) |
| Fast terminal work: logs, shell, restart, watch changes | **k9s** |
| Scripting, CI, exact output | **kubectl** |
| Metrics graphs and alerts | **Grafana / Prometheus** (`./scripts/monitoring-open.sh`) |
| See the containers behind pods | `docker exec demo-control-plane crictl ps` |

## Troubleshooting
| Symptom | Fix |
|---|---|
| Headlamp shows no cluster | `kubectl config get-contexts`; `kind export kubeconfig --name demo`; restart Headlamp |
| "Unable to connect" / timeouts | Docker Desktop isn't running, or the cluster was deleted: `kind get clusters` |
| Cluster worked yesterday, fails today | The API server port (e.g. `52579`) changes if the node container is recreated. Re-run `kind export kubeconfig --name demo`. |
| Metrics/CPU empty on nodes or pods | metrics-server not ready: `kubectl -n kube-system get pods | grep metrics` |
| Map is cluttered | Use the *Namespaces* filter and the *Workloads, Storage* filter chip; Group By Instance for per-release view |
| Secret values show as hidden | Intentional; click the eye icon. Remember Secrets are base64, not encrypted. |

## Interview angle
"On kind, the cluster is a Docker container, so Docker tooling only sees the node. I inspect the cluster through
the API server instead: Headlamp for the visual map, k9s for fast terminal work, kubectl for scripts, and `crictl`
inside the node when I need to see the real container runtime. On EKS it's the same: you never SSH to nodes first,
you start from `kubectl get / describe / logs`."
