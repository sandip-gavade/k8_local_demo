# Phase 5: Break and fix (PLANNED, documentation only)

> **Status: not implemented yet.** This is the plan and the expected behaviour. The scripts in `scripts/drills/`
> do not exist yet, and nothing below has been run. Outputs shown are what Kubernetes normally prints; they
> will be replaced with real captured output when the phase is built and tested.

Goal: practise the debugging flow interviewers ask about by deliberately breaking the working release, diagnosing
it with `kubectl`, and fixing it. Each drill = one script that **breaks**, one that **fixes**, and a table row
of symptom, diagnosis, root cause and fix.

## The debugging flow (memorise this)
```
kubectl get pods                       # what is the STATUS?  (Pending / ImagePullBackOff / CrashLoopBackOff / Running 0/1)
kubectl describe pod <pod>             # Events at the bottom explain scheduling and pull problems
kubectl logs <pod> --previous          # why the last container instance died
kubectl exec -it <pod> -- sh           # look from the inside (env, DNS, connectivity)
kubectl top pod / get events           # resource pressure
helm history / helm rollback           # bad release: go back
```

## Planned layout
```
scripts/drills/
  common.sh                 # helpers: wait_for, show_status, restore (helm rollback to a known good revision)
  01-imagepullbackoff.sh    # break / --fix
  02-crashloopbackoff.sh
  03-oomkilled.sh
  04-readiness-fail.sh
  05-pending-pod.sh
  06-bad-release-rollback.sh
  07-hpa-load-test.sh       # bonus: watch 1 -> 3 pods
docs/phase5-break-and-fix.md   # this file, later updated with real outputs
```
Convention: every script takes `break` or `fix`, prints the diagnosing commands it runs, and ends with the
cluster back in the known-good state so drills never leave debris.

## The drills

### 1. ImagePullBackOff (bad image tag)
| | |
|---|---|
| **Break** | `helm upgrade orders ... --set image.backend.tag=does-not-exist`. Note: the pre-upgrade **migrate hook** pulls the same image, so the release fails there and `--rollback-on-failure` reverts it. For a pod-level symptom, patch one Deployment directly: `kubectl -n demo set image deploy/orders-web web=django-app:nope` |
| **Symptom** | New pod `STATUS` goes `ErrImagePull` then `ImagePullBackOff`; old pod keeps serving (rolling update with `maxUnavailable: 0`) |
| **Diagnose** | `kubectl -n demo get pods` then `kubectl -n demo describe pod <new-pod>` and read Events: `Failed to pull image "django-app:nope": ... not found` |
| **Root cause** | Tag doesn't exist, or (on kind) the image was built but never `kind load`-ed, or a registry auth problem (`imagePullSecrets`) |
| **Fix** | `kubectl -n demo rollout undo deploy/orders-web`, or `helm rollback orders <rev>`, or correct the tag |
| **Interview point** | Why users saw no downtime: the rollout never removed the healthy pod. |

### 2. CrashLoopBackOff (bad environment variable)
| | |
|---|---|
| **Break** | Remove the Secret key or set a bad value: `kubectl -n demo set env deploy/orders-web POSTGRES_HOST=does-not-exist` (readiness fails) or delete `DJANGO_SECRET_KEY` from the Secret (app exits at start: `KeyError`) |
| **Symptom** | `CrashLoopBackOff`, `RESTARTS` climbing, back-off grows 10s, 20s, 40s... up to 5 min |
| **Diagnose** | `kubectl -n demo logs <pod> --previous` (current container has no logs yet) shows the traceback; `describe pod` shows `Last State: Terminated, Exit Code: 1` |
| **Root cause** | App can't start with that configuration. The container started fine; the **process** exited |
| **Fix** | Restore the env var / Secret, then `kubectl rollout restart`, or `helm rollback` |
| **Interview point** | `--previous` is the key flag. Exit codes: 1 = app error, 137 = SIGKILL/OOM, 143 = SIGTERM. |

### 3. OOMKilled (memory limit too low)
| | |
|---|---|
| **Break** | `kubectl -n demo patch deploy orders-worker --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Mi"}]'` |
| **Symptom** | Pod restarts repeatedly; `describe` shows `Last State: Terminated  Reason: OOMKilled  Exit Code: 137` |
| **Diagnose** | `kubectl -n demo describe pod <pod> | grep -A5 "Last State"`; `kubectl top pod` before it dies; Grafana "Pod memory" panel climbing to the limit; alert `DjangoPodRestarting` fires (Phase 4) |
| **Root cause** | Container exceeded its memory **limit**, so the kernel's OOM killer ended it. CPU over the limit is only throttled, never killed |
| **Fix** | Raise `worker.resources.limits.memory` in values and `helm upgrade`. Size from observed usage plus headroom, don't guess |
| **Interview point** | requests vs limits: requests drive scheduling, limits are enforced ceilings; memory limit = kill, CPU limit = throttle. |

### 4. Failing readiness probe
| | |
|---|---|
| **Break** | Point the probe at a path that returns 404/503, or break a dependency: `kubectl -n demo scale sts/redis --replicas=0` (`/readyz` returns 503) |
| **Symptom** | Pods `Running` but `READY 0/1`, no restarts; Service endpoints empty; Ingress returns 503 |
| **Diagnose** | `kubectl -n demo get endpoints orders-web` (empty), `describe pod` Events: `Readiness probe failed: HTTP probe failed with statuscode: 503`, `kubectl exec ... curl localhost:8000/readyz` shows which dependency is down |
| **Root cause** | Readiness removes the pod from the Service on purpose; the pod isn't dead, it's not fit to serve |
| **Fix** | Restore the dependency; the pod rejoins by itself. No restart needed |
| **Interview point** | Contrast with liveness (restart) and why liveness here never checks Redis/Postgres: it would restart-loop every pod during a database outage. |

### 5. Pending pod (request too large)
| | |
|---|---|
| **Break** | `kubectl -n demo patch deploy orders-frontend --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"64Gi"}]'` |
| **Symptom** | New pod stays `Pending` forever; nothing in logs (the container never started) |
| **Diagnose** | `kubectl -n demo describe pod <pod>`: `FailedScheduling ... 0/1 nodes are available: 1 Insufficient memory.` Also check `kubectl describe node` (Allocatable vs Allocated) |
| **Root cause** | Scheduler found no node with that much unreserved memory. Requests (not usage) decide placement |
| **Fix** | Lower the request; on EKS the Cluster Autoscaler or Karpenter would add a node if the request fits an instance type |
| **Interview point** | Other Pending causes: unbound PVC, node selectors/taints, quota exceeded, too many pods per node (VPC CNI IP limits on EKS). |

### 6. Bad release fixed with `helm rollback`
| | |
|---|---|
| **Break** | Ship a release that passes install but misbehaves, e.g. `--set config.POSTGRES_HOST=wrong` (readiness fails, so with `--rollback-on-failure` Helm reverts automatically; run once **without** the flag to see the broken state, then recover manually) |
| **Symptom** | `helm history` shows a new revision; pods unready; `/api/orders/` returns 503 |
| **Diagnose** | `helm history orders -n demo`, `helm get values orders -n demo`, `helm diff` (plugin) or `helm get manifest` of two revisions |
| **Root cause** | A bad value in the release |
| **Fix** | `helm rollback orders <last-good-rev> -n demo --wait`: creates a **new** revision with the old content |
| **Interview point** | Rollback does not undo database migrations; keep migrations backward compatible (expand/contract). |

### 7. Bonus: HPA load test (1 → 3 pods)
Generate load on `orders-web` (for example `kubectl run load --rm -it --image=busybox:1.36 -- sh -c 'while true; do wget -q -O- http://orders-web:8000/api/orders/; done'`), then `kubectl -n demo get hpa -w` and watch CPU% pass 70 and replicas go 1, 2, 3. Stop the load and watch the slow scale-down (default stabilisation window 5 min).

## Acceptance criteria (when we build it)
- Every drill: `break` produces exactly the documented symptom; `fix` returns the release to the known-good state.
- A final script `scripts/drills/run-all.sh` runs all drills in order, asserts the symptom with `kubectl`, applies the fix, and exits non-zero on any mismatch.
- This doc is updated with the real captured output for each command.

## Interview prep (answers you should be able to give now)
| Question | Short answer |
|---|---|
| Pod stuck in Pending? | `describe pod` Events: insufficient resources, unbound PVC, taints/selectors, quota. |
| CrashLoopBackOff? | `logs --previous` for the reason; check env/config, dependencies, exit code, OOM. |
| ImagePullBackOff? | Wrong tag/name, missing `kind load`, registry auth (`imagePullSecrets`, ECR IAM). |
| Pod Running but not receiving traffic? | Readiness failing or Service selector/labels mismatch: `get endpoints`. |
| OOMKilled vs CPU throttling? | Memory limit kills; CPU limit throttles. |
| How do you roll back? | `kubectl rollout undo` (one Deployment) or `helm rollback` (whole release); DB migrations are not undone. |
