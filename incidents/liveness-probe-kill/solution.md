# Solution: liveness-probe-kill

## What happened

A values update renamed {{.WorkloadName}}'s liveness probe path from `/health`
to `/healthz`. The app does not serve `/healthz`, so every probe gets a 404.
After `failureThreshold` failures in a row (3 probes, 10 seconds apart, after a
15-second initial delay) the kubelet decides the container is dead, sends it
SIGTERM and starts a new one. The app is healthy the whole time: it serves
requests until the moment it is stopped, shuts down cleanly and exits 0.

With one replica, every restart is a short outage: the pod leaves the Service
until its readiness probe passes again, and requests in that window fail. That
is the burst of 5xx, followed by quiet until the next kill.

## How this differs from the other incidents

| Incident | Who stops the container | Last State | Where the cause is |
|---|---|---|---|
| `crashloop-bad-config` | the app exits by itself | `Error`, exit code 1 | the previous container's logs |
| `oom-kill` | the kernel | `OOMKilled`, exit code 137 | the memory limit |
| `liveness-probe-kill` | the kubelet | `Completed`, exit code 0 | the pod's events |

The app's logs here are the misleading part: they show a clean start, normal
requests and a graceful shutdown on signal 15, with nothing wrong. The answer
is in the events, not the logs.

## Diagnosis path

```bash
kubectl get pods -n {{.WorkloadNamespace}}                  # RESTARTS climbing, pod Running most of the time
kubectl describe pod -n {{.WorkloadNamespace}} <pod>
# Last State:  Terminated
#   Reason:    Completed
#   Exit Code: 0
# Liveness:    http-get http://:http/healthz delay=15s timeout=5s period=10s #success=1 #failure=3
# Events:
#   Warning  Unhealthy  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 404
#   Normal   Killing    kubelet  Container {{.WorkloadName}} failed liveness probe, will be restarted
kubectl logs -n {{.WorkloadNamespace}} <pod> --previous | tail -4
# ..."path":"/healthz","status":404...
# ..."msg":"received signal, shutting down","signal":15
```

In Grafana, *Pod Resources* → *Container restarts* climbs steadily, and
*Application Request Metrics* shows the k6 traffic this fault starts failing
in bursts, one per restart. The page is `LabFaultPodRestarting`.

## Fix

Point the probe at the path the app serves:

```bash
kubectl -n {{.WorkloadNamespace}} patch deploy {{.WorkloadName}} --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health"}]'
kubectl -n {{.WorkloadNamespace}} rollout status deploy/{{.WorkloadName}}
```

`kubectl -n {{.WorkloadNamespace}} rollout undo deploy/{{.WorkloadName}}` works
too, and so does re-applying the app's chart (`labctl app deploy
{{.WorkloadName}}`), which puts back the probe the chart defines.

Verify: `labctl incident status`. The check asks the probe's path on a running
pod, the way the kubelet does, and passes once it answers and every replica is
ready.

The fault runs the k6 generator so the errors show up. A hand fix closes the
incident and its tidy-up stops the load; if you stopped it early, `labctl
traffic stop` does the same.

## The tempting wrong fix

Deleting the liveness probe. The restarts stop and the dashboards go green, so
it looks fixed, but nothing checks the app any more: the next time it
deadlocks, it stays up and serves errors until someone notices. Raising
`initialDelaySeconds` or `failureThreshold` is the same mistake made slower:
the path still answers 404, and the kills come back on a longer cycle. The check
fails both.

## Do this on your own cluster

The fault is one `kubectl patch`:

```bash
kubectl -n {{.WorkloadNamespace}} patch deploy {{.WorkloadName}} --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}]'
```

## Real-world parallel

`/healthz` against `/health` is the classic: one framework's convention copied
into another app's chart, or a probe path changed in a shared values file. The
lesson: a liveness probe is a kill switch you hand the kubelet, so it has to
check only that this process is alive, on a path that cannot get it wrong.

Liveness kills have other common causes, and the event names each one:

- **A slow start.** The app takes longer to start than `initialDelaySeconds`
  plus `failureThreshold × periodSeconds`, so it is killed before it is ready,
  every time. Add a `startupProbe`, which holds liveness off until the app has
  started once.
- **A timeout under load.** `timeoutSeconds: 1` and a busy app: the event says
  `context deadline exceeded`, not a status code.
- **A probe that checks a dependency.** A liveness endpoint that pings the
  database restarts every pod when the database blips, which makes the outage
  worse. Dependency checks belong in readiness, if anywhere.
