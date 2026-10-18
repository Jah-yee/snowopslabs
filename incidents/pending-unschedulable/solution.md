# Solution: pending-unschedulable

## What happened

The launch change did two things at once: it scaled {{.WorkloadName}} to 4
replicas, and it raised the container's CPU request to one whole core more than
the largest node in the cluster can allocate. The Deployment scaled the old
ReplicaSet up with the new count, and the rolling update started new pods from
the new template while keeping all but one replica (`maxUnavailable: 25%`)
serving. The scheduler cannot place a pod that asks for more CPU than any node
has, so the new pods stay Pending however idle the nodes are, and the rollout
waits on them forever: 3 old pods serve and the fourth replica never arrives.

## How this differs from the other incidents

Nothing is failing. No container crashes (`crashloop-bad-config`), is killed by
the kernel (`oom-kill`), fails to pull (`bad-deploy-rollout`) or is starved by a
neighbour (`noisy-neighbor`); the Service still has endpoints and the old pods
answer every request (`service-selector-broken`, `network-blackhole`). The new
pods never started a container at all, so they have no logs and no restarts:
the only evidence is the scheduler's event on the pod.

## Diagnosis path

```bash
kubectl get deploy,rs,pods -n {{.WorkloadNamespace}}
# deployment READY 3/4; the new ReplicaSet's 2 pods are Pending, the old ones Running
kubectl describe pod -n {{.WorkloadNamespace}} <pending-pod>
# Events:
#   Warning  FailedScheduling  default-scheduler
#   0/2 nodes are available: 2 Insufficient cpu.
#   preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
kubectl describe nodes | grep -A 6 'Allocated resources'   # the nodes are far from full
kubectl top nodes                                          # and nearly idle
kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml | grep -A 6 'resources:'
# requests: cpu: "5"   <- more than any node's allocatable CPU
```

`kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu`
prints each node's allocatable CPU; the request is larger than every one of
them.

In Grafana, *Pod Resources* → *Pods waiting for a node* shows the new pods from
the moment of the change. The page is `LabFaultReplicasUnavailable`: the
Deployment has fewer replicas available than it asked for.

## Fix

Give the container a request the nodes can hold. Size it from what the app
uses (`kubectl top pod -n {{.WorkloadNamespace}}`), with headroom:

```bash
kubectl -n {{.WorkloadNamespace}} set resources deploy/{{.WorkloadName}} \
  --requests=cpu=100m --limits=cpu=500m
kubectl -n {{.WorkloadNamespace}} rollout status deploy/{{.WorkloadName}}
```

`kubectl -n {{.WorkloadNamespace}} rollout undo deploy/{{.WorkloadName}}` works
too: it puts back the previous pod template and keeps the 4 replicas. So does
re-applying the app's chart (`labctl app deploy {{.WorkloadName}}`), which also
returns the replica count to the chart's value.

Verify: `labctl incident status`. The check passes once no replica is Pending
and every replica is ready.

## The tempting wrong fix

Deleting the Pending pods. They are not stuck, they are waiting: the ReplicaSet
recreates each one from the same template, and the scheduler rejects it for the
same reason. Scaling back down does not help either: the rollout is still
waiting on a new pod that cannot be placed.

## Do this on your own cluster

The fault is one plain `kubectl patch`. Pick a CPU request one core larger than
your largest node's allocatable CPU (here 5, for 4-core nodes), and use your
container's name from `kubectl get deploy -o yaml`:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu
kubectl -n {{.WorkloadNamespace}} patch deploy {{.WorkloadName}} -p \
  '{"spec":{"replicas":4,"template":{"spec":{"containers":[{"name":"<container>","resources":{"requests":{"cpu":"5"},"limits":{"cpu":"5"}}}]}}}}'
```

## Real-world parallel

A values file copied from production, where nodes have 32 cores, into a
cluster of 4-core nodes. A request set "to be safe" at a whole node. A
right-sizing tool that recommended from a peak. The lesson: **requests decide
scheduling, not usage.** The scheduler never looks at `kubectl top`; it adds up
requests. A pod that uses 5 millicores and requests 5 cores cannot be placed on
a node that is 99% idle.

Pending has other common causes, and `describe pod` names each one in the same
FailedScheduling event: a `nodeSelector` or affinity no node matches
(`didn't match Pod's node affinity/selector`), a taint the pod does not tolerate
(`had untolerated taint`), a PersistentVolumeClaim that never binds
(`unbound immediate PersistentVolumeClaims`), or a cluster that is genuinely
full, where the fix is more nodes. Read the event before you change anything.
