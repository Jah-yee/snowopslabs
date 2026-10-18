# Solution: cpu-throttling

## What happened

The cost review lowered {{.WorkloadName}}'s CPU limit to a third of what one pod
uses under the steady load this fault runs (inject measured it with `kubectl
top` first, so the cut fits your machine). The kernel enforces a CPU limit as
a CFS quota: in every 100ms period the container may use its limit's share of
a core, and once it has, it waits for the next period. Nothing is killed and
nothing fails. Requests that arrive while the container is waiting queue up,
so most requests are fast and the unlucky ones wait a whole period or several:
p50 stays flat, p99 goes to seconds.

## How this differs from the other incidents

No restarts, no OOM kills, no errors, every pod Ready: none of the signals
`crashloop-bad-config`, `oom-kill` or `liveness-probe-kill` give you. It is
closest to `noisy-neighbor`, which is also slow, but there the node is out of
CPU and a neighbour is taking it. Here the node is nearly idle (`kubectl top
nodes`) and the pod is held back by its own limit.

## Diagnosis path

```bash
kubectl get pods -n {{.WorkloadNamespace}}                 # Running, Ready, 0 restarts
kubectl top nodes                                          # the node is nearly idle
kubectl top pod -n {{.WorkloadNamespace}}
# NAME        CPU(cores)   MEMORY(bytes)
# {{.WorkloadName}}-…  13m          8Mi        <- pinned at the limit, every sample
kubectl describe pod -n {{.WorkloadNamespace}} <pod> | grep -A 6 Limits
# Limits:
#   cpu:  12m                         <- the same number
```

In Grafana: *Application Request Metrics* → *Latency percentiles* shows p99 in
seconds and p50 in milliseconds, and *Pod Resources* → *CPU throttled* shows
the pod throttled in most of its periods. The page is `LabFaultLatencySLO`.

## Fix

Measure first, then set the limit. While the pod is capped, `kubectl top`
reads the cap, not the demand, so lift the limit, let the load run a minute,
and read what the pod really uses:

```bash
kubectl -n {{.WorkloadNamespace}} set resources deploy/{{.WorkloadName}} --limits=cpu=500m
kubectl -n {{.WorkloadNamespace}} rollout status deploy/{{.WorkloadName}}
kubectl top pod -n {{.WorkloadNamespace}}            # repeat for a minute: the real demand under this load
```

Then set a limit with headroom over that peak, and a request near the steady
use, so the scheduler is told the truth:

```bash
kubectl -n {{.WorkloadNamespace}} set resources deploy/{{.WorkloadName}} \
  --requests=cpu=50m --limits=cpu=200m
```

Removing the CPU limit altogether is a fix too, and a common production choice
for latency-sensitive services: the request still reserves CPU for the pod.
`kubectl rollout undo` and re-applying the app's chart (`labctl app deploy
{{.WorkloadName}}`) put back the original limit.

Verify: `labctl incident status`. The check passes when there is no limit, or
the limit is at least twice the demand measured before the change. At 1.5
times, the app is still throttled in about a sixth of its periods and p99 sits
near 150ms; at twice, throttling is near zero and p99 is back to a few
milliseconds. The fault keeps the k6 load running; a hand fix closes the incident and
its tidy-up stops it.

## The tempting wrong fixes

Scaling out. More replicas share the load, so each one needs less CPU and the
latency improves, but every pod still sits at a ceiling below what it needs,
and the cost review that set the limit to save money now pays for four pods
instead of one. Stopping the load makes the dashboard green for the same
non-reason. The check grades the limit, not the moment's latency, so both
fail.

## Do this on your own cluster

Run steady load, read the pod's CPU, then set the limit to about a third of it:

```bash
labctl traffic start --app {{.WorkloadName}} --profile steady --rps 60
kubectl top pod -n {{.WorkloadNamespace}}                  # say 39m
kubectl -n {{.WorkloadNamespace}} set resources deploy/{{.WorkloadName}} --limits=cpu=13m --requests=cpu=13m
```

## Real-world parallel

A cost review that sets CPU limits from average use, a namespace LimitRange
that gives every container a default limit nobody chose, or limits copied
from an idle staging environment. The lesson: **a CPU limit does not fail
loudly, it adds latency.** Size limits from usage measured under real load,
with headroom for bursts, and watch throttling
(`container_cpu_cfs_throttled_periods_total`) next to latency. `kubectl top`
cannot tell you a pod wants more than its limit, because it never gets more.

Latency with healthy pods has other common causes: a node out of CPU
(`noisy-neighbor`), too few replicas for the traffic (an autoscaling problem),
a slow dependency, or garbage-collection pauses when the memory limit is
tight. Throttling is the one where the pod's own CPU reads flat at a round
number.
