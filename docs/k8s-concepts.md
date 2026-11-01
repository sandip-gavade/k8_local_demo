# Kubernetes concepts used so far (plain-English guide)

Read this first, then `phase2-cluster-basics.md`. Each concept has: what it is, an everyday
analogy, and where we used it in this repo.

---

## 1. The big picture: what we have built so far

```
 Your Mac
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Browser / curl  ──►  localhost:8080                                       │
 │                          │  (kind extraPortMappings: 8080 -> node:80)     │
 │  Docker Desktop          ▼                                                │
 │ ┌──────────────────────────────────────────────────────────────────────┐ │
 │ │ Container "demo-control-plane"  = the ONE Kubernetes node (kind)     │ │
 │ │                                                                      │ │
 │ │  CONTROL PLANE (the brain)         WORKER PART (runs our pods)       │ │
 │ │  kube-apiserver, etcd,             kubelet, container runtime        │ │
 │ │  scheduler, controller-manager                                       │ │
 │ │                                                                      │ │
 │ │  ┌─ namespace: ingress-nginx ──────────────┐                         │ │
 │ │  │  Pod: ingress-nginx-controller  :80/:443 │◄── receives traffic    │ │
 │ │  └──────────────────────────────────────────┘                         │ │
 │ │                                                                      │ │
 │ │  ┌─ namespace: demo ────────────────────────────────────────────────┐│ │
 │ │  │                                                                  ││ │
 │ │  │  Secret: orders-secrets (DB password, Django key)                ││ │
 │ │  │                                                                  ││ │
 │ │  │  Service "postgres" (headless) ──► StatefulSet postgres          ││ │
 │ │  │                                     └ Pod postgres-0 ─► PVC data-postgres-0 (1Gi)│
 │ │  │  Service "redis"               ──► StatefulSet redis             ││ │
 │ │  │                                     └ Pod redis-0 ───► PVC data-redis-0 (1Gi)   │
 │ │  │                                                                  ││ │
 │ │  │  (Phase 3 adds: web, worker, beat, frontend Deployments,         ││ │
 │ │  │   Services, Ingress rules, ConfigMap, HPA, migrate Job)          ││ │
 │ │  └──────────────────────────────────────────────────────────────────┘│ │
 │ │  Images django-app:dev, orders-frontend:dev already loaded here      │ │
 │ └──────────────────────────────────────────────────────────────────────┘ │
 └──────────────────────────────────────────────────────────────────────────┘
```

Today nothing routes to our app yet: the ingress controller is running and answers 404 because no
Ingress rules exist. Phase 3 deploys the app and adds those rules.

---

## 2. Cluster, node, control plane

**Cluster** = the whole Kubernetes system: one or more machines (nodes) managed as one.
**Node** = a machine that runs containers. **Control plane** = the components that decide what should run where.

Analogy: a restaurant. The control plane is the manager and order system; nodes are the kitchens.
You tell the manager "I want 3 burgers"; the manager makes sure 3 burgers exist, always.

Control plane parts (interview staples):
| Component | Job |
|---|---|
| kube-apiserver | The front door. `kubectl` talks only to this. |
| etcd | The database holding all cluster state. |
| scheduler | Chooses which node a new pod runs on (looks at requests, labels, taints). |
| controller-manager | Loops that compare desired vs actual state and fix differences (e.g. recreate a dead pod). |
| kubelet (on each node) | Starts/stops containers on its node, runs probes. |

**In our setup:** kind makes the node a single Docker container (`demo-control-plane`), and it plays
both control plane and worker. On EKS the control plane is managed by AWS and you only manage worker nodes.

**Core idea: declarative desired state.** You apply YAML saying what you want. Controllers keep
reconciling reality to match. You don't say "start a container"; you say "I want 1 Postgres".

---

## 3. Namespace

A namespace is a named folder inside the cluster that groups and isolates resources.
Names only need to be unique inside a namespace, and you can attach quotas and access rules per namespace.

Analogy: folders on your laptop. Two files can both be called `config.yaml` if they are in different folders.

**We use:** `demo` (our app, Postgres, Redis, the Secret) and `ingress-nginx` (the controller).
System components live in `kube-system`. Always pass `-n demo`, or run `kubectl get pods -A` for all.

Note: namespaces are NOT a security boundary by themselves (that needs RBAC and NetworkPolicy).

---

## 4. Pod

The smallest thing Kubernetes runs: one or more containers that share a network (same IP) and storage.
Usually one main container per pod.

Pods are disposable: when one dies it is replaced by a NEW pod with a new name and IP. So never
depend on a pod's IP or name (except StatefulSets, see below).

**We use:** `postgres-0`, `redis-0`, the ingress controller pod, and a short-lived `app-smoke` pod in the verify script.

---

## 5. Workload controllers: ReplicaSet, Deployment, StatefulSet, Job

You rarely create bare pods. A controller creates and keeps them alive.

| Object | What it does | Pod names | Storage | Use for |
|---|---|---|---|---|
| ReplicaSet | Keeps N identical pods running | random (`web-7d9f-x2k`) | shared/none | rarely used directly |
| Deployment | Manages ReplicaSets; gives rolling updates and rollback | random | none/shared | stateless apps (web, worker, frontend) |
| StatefulSet | Like Deployment but pods have identity | stable and ordered (`postgres-0`, `-1`) | own PVC per pod | databases, Redis, Kafka |
| Job | Runs a pod to completion once | random | none | migrations, batch work |
| DaemonSet | One pod per node | per node | none | log agents, node exporters |

### StatefulSet in depth (what we used for Postgres and Redis)
Guarantees three things a Deployment does not:
1. **Stable name:** `postgres-0` comes back as `postgres-0`, not a random name.
2. **Stable storage:** `postgres-0` always reattaches to its own volume `data-postgres-0`.
3. **Ordered start/stop:** `-0` before `-1` (matters for primary/replica setups).

If you ran Postgres as a Deployment and the pod restarted, it could start with an empty disk or two
pods could fight over one volume. That is why databases use StatefulSets.

### Deployment (coming in Phase 3)
Rolling update: start new pods, wait until ready, then stop old ones, controlled by `maxSurge` and
`maxUnavailable`. `kubectl rollout undo` goes back to the previous ReplicaSet.

---

## 6. Service

Pods come and go with changing IPs, so a **Service** gives a stable name and virtual IP in front of a
set of pods, chosen by a **label selector** (`selector: {app: postgres}`), and load-balances across them.
Inside the cluster you reach it by DNS: `postgres`, or fully `postgres.demo.svc.cluster.local`.

Analogy: a company phone number that forwards to whoever is currently on shift.

| Type | Reachable from | Use |
|---|---|---|
| ClusterIP (default) | inside cluster only | app-to-app (web -> postgres) |
| NodePort | node IP:30000-32767 | quick testing |
| LoadBalancer | cloud load balancer (AWS ELB/NLB) | exposing to internet on EKS |
| ExternalName | DNS alias to outside host | pointing at RDS |
| Headless (`clusterIP: None`) | inside cluster | see below |

### Headless Service (what we used for Postgres)
Normal Service: one virtual IP that load-balances to pods. **Headless** (`clusterIP: None`): no virtual
IP; DNS returns the pod IPs directly, and each StatefulSet pod gets its own DNS name:
`postgres-0.postgres.demo.svc.cluster.local`.

Why: with databases you often must talk to a SPECIFIC pod (the primary, not a random replica).
A StatefulSet's `serviceName: postgres` ties the pods to this headless Service.
In our case there is one replica, so the name `postgres` simply resolves to that pod's IP.
(Our `redis` Service is a normal ClusterIP one, which is fine because a single instance needs no per-pod DNS.)

### Labels and selectors
Labels are key/value tags (`app: postgres`). Selectors find objects by label. This is how a Service
finds its pods, and how a StatefulSet owns its pods. A typo in a label means "Service has no endpoints".
Check with `kubectl -n demo get endpoints`.

---

## 7. Storage: PV, PVC, StorageClass

| Object | Meaning | Analogy |
|---|---|---|
| PersistentVolume (PV) | An actual piece of storage | a hard disk |
| PersistentVolumeClaim (PVC) | A pod's request for storage ("1Gi, read-write") | a request ticket for a disk |
| StorageClass | A recipe for creating PVs on demand | the disk vendor / catalogue |

Flow: StatefulSet's `volumeClaimTemplates` creates PVC `data-postgres-0` -> the StorageClass
(`standard`, kind's local-path provisioner) auto-creates a PV -> the PVC becomes **Bound** -> the pod mounts it
at `/var/lib/postgresql/data`.

Key facts:
- The PVC outlives the pod, which is why our data survived `delete pod postgres-0`.
- Deleting the StatefulSet does NOT delete its PVCs (a safety feature).
- `ReadWriteOnce` = mountable read-write by one node at a time.
- On EKS the StorageClass would be EBS gp3 (via the EBS CSI driver). EBS volumes live in one AZ, so a pod can only reschedule to that AZ.

`emptyDir` (used for `/var/run/postgresql`) is different: scratch space that lives and dies with the pod.

---

## 8. Ingress and Ingress controller

Services expose things inside the cluster. To let outside traffic in on HTTP, instead of one cloud load
balancer per Service, use **one entry point** that routes by host and path.

- **Ingress** = a YAML object with rules: "`/api` -> Service `web`, `/` -> Service `frontend`".
- **Ingress controller** = the program that implements the rules (here nginx). An Ingress does nothing without one.

Analogy: the Ingress is the building's directory sign; the controller is the receptionist who actually walks you there.

Our path today: `curl localhost:8080` -> Docker port mapping -> node port 80 -> ingress-nginx pod -> (no rule) -> 404.
That 404 is proof the front door is up. On EKS the controller would sit behind an AWS load balancer
(NLB/ALB), or you'd use the AWS Load Balancer Controller.

---

## 9. ConfigMap and Secret

Both inject configuration into pods without baking it into the image.

| | ConfigMap | Secret |
|---|---|---|
| For | non-sensitive config (log level, hosts) | passwords, tokens, keys |
| Stored | plain text in etcd | base64 in etcd (NOT encryption!) |
| Used as | env vars or mounted files | same |

**We use:** Secret `orders-secrets` (created by `scripts/create-secrets.sh` from `.env`) read via
`secretKeyRef`. Hardening on EKS: enable KMS envelope encryption for etcd, restrict RBAC on secrets,
or use External Secrets / Secrets Store CSI to pull from AWS Secrets Manager. ConfigMap arrives in Phase 3.

---

## 10. Probes, resources, security context (what you saw in the YAML)

**Probes**
| Probe | Question | On failure |
|---|---|---|
| startup | Has it finished booting? | keep waiting, then restart; disables the other two until it passes |
| readiness | Can it take traffic now? | removed from Service endpoints (no restart) |
| liveness | Is it stuck/dead? | container restarted |

**Resources**
- `requests` = what the scheduler reserves (used to place the pod). `limits` = the ceiling.
- Exceed the memory limit -> **OOMKilled**. Exceed the CPU limit -> throttled (not killed).
- We set a memory limit but no CPU limit on purpose (CPU limits cause throttling; a common practice).

**securityContext**
- `runAsNonRoot` + `runAsUser`: never run as root.
- `fsGroup`: gives the pod's group ownership of mounted volumes (so Postgres can write to the PVC).
- `capabilities: drop [ALL]`: removes Linux privileges.
- `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`: shrink the attack surface.

---

## 11. kind and `kind load`

kind = "Kubernetes in Docker": nodes are Docker containers. Good for local dev and CI.
Its node has its own container runtime and image store, separate from Docker Desktop's, so
`kind load docker-image NAME:TAG` copies your locally built image into the node.
Use a non-`latest` tag so `imagePullPolicy` defaults to `IfNotPresent` and doesn't try the internet.

---

## 12. Glossary / cheat sheet

| Term | One line |
|---|---|
| Desired state | What your YAML says should exist; controllers make it true |
| Reconciliation | The loop that detects drift and fixes it |
| Label / selector | Tags / the query that finds tagged objects |
| Endpoints | The list of ready pod IPs behind a Service |
| `kubectl apply -f` | Create or update objects from YAML |
| `kubectl describe` | Details plus Events (first stop when stuck) |
| Rollout | A controlled update of pods |
| CNI | Plugin giving pods networking (kind: kindnet; EKS: VPC CNI) |
| CSI | Plugin that provides storage (EBS CSI on EKS) |

Commands to poke at what we built:
```bash
kubectl get ns
kubectl -n demo get all,pvc,secret
kubectl -n demo get endpoints                      # which pod IPs back each Service
kubectl -n demo describe statefulset postgres
kubectl -n demo exec -it postgres-0 -- psql -U orders -d orders -c '\dt'
kubectl -n demo get svc postgres -o wide           # CLUSTER-IP shows None (headless)
```

## 13. Quick interview answers

- **Pod vs Deployment vs StatefulSet?** Pod runs containers; Deployment keeps N interchangeable pods with rolling updates; StatefulSet keeps pods with stable name, DNS and own volume.
- **Why a headless Service for a StatefulSet?** To get per-pod DNS so clients (or replicas) can address a specific pod.
- **PV vs PVC vs StorageClass?** Disk vs request for a disk vs recipe for creating disks.
- **Ingress vs Service type LoadBalancer?** LoadBalancer is one cloud LB per Service at L4; Ingress is one entry point doing host/path routing at L7, needing a controller.
- **ConfigMap vs Secret?** Same mechanics; Secrets are for sensitive data but only base64 by default, so add KMS encryption or an external secret store.
- **What happens when a pod crashes?** The controller creates a replacement; StatefulSet pods return with the same name and re-attach the same PVC.
