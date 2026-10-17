# Hints: cpu-throttling

## Hint 1
Nothing is broken, it is slow, so look at time rather than errors. In Grafana,
*Application Request Metrics* → *Latency percentiles*: compare p99 with p50.
A healthy app that is slow for 1% of requests is waiting for something. Then
rule out the obvious: `kubectl get pods -n {{.WorkloadNamespace}}` (restarts?)
and `kubectl top nodes` (a busy node?).

## Hint 2
`kubectl top pod -n {{.WorkloadNamespace}}` shows how much CPU each pod uses.
Compare it with the container's CPU limit
(`kubectl describe pod -n {{.WorkloadNamespace}} <pod>` → Limits). A pod
using exactly its limit is not idle and not overloaded: it is capped, and the
number you see is the ceiling, not what it wants.

## Hint 3
A CPU limit is enforced as a quota per 100ms period; a container that spends
its quota early waits for the next period, and the requests it was serving
wait with it. *Pod Resources* → *CPU throttled* shows the share of periods
that ran out. The limit in the Deployment
(`kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml`) is
below what the app needs under this load. You cannot measure that while it is
capped, so lift the limit first, then size it.
