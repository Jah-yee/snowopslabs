# Solution: missing-secret-key

## What happened

{{.WorkloadName}} reads `API_TOKEN` from key `api-token` of its own Secret,
`{{.WorkloadName}}-secret`. The overnight credential rotation wrote the new value
under `API_TOKEN` instead and removed `api-token`. Nothing broke yet: a running
container keeps the environment it started with. Then the node rotation
replaced every pod. The kubelet builds each new container's environment
before starting it, cannot find `api-token`, and refuses to start the
container. Every pod waits in `CreateContainerConfigError`, nothing serves,
and the outage is total.

## How this differs from the other incidents

The container never starts, so there are no logs, no restarts and no exit
code. In `crashloop-bad-config` the app starts and exits with an error in its
logs; in `oom-kill` and `liveness-probe-kill` it runs until something kills
it; in `bad-deploy-rollout` the image cannot be pulled. And nothing was
deployed: the Deployment's pod template is exactly what it was yesterday, so
there is no revision to roll back to. The change is in an object the
Deployment only refers to.

## Diagnosis path

```bash
kubectl get pods -n {{.WorkloadNamespace}}            # every pod 0/1 CreateContainerConfigError
kubectl describe pod -n {{.WorkloadNamespace}} <pod>
# State:   Waiting
#   Reason: CreateContainerConfigError
# Events:
#   Warning  Failed  kubelet  Error: couldn't find key api-token in Secret {{.WorkloadNamespace}}/{{.WorkloadName}}-secret
kubectl describe secret -n {{.WorkloadNamespace}} {{.WorkloadName}}-secret
# Data
# ====
# API_TOKEN:  18 bytes                                <- the key is there, under another name
```

In Grafana, *Pod Resources* → *Containers not running, by reason* shows
`CreateContainerConfigError` from the moment the pods were replaced, and the
page is `LabFaultNoReplicasAvailable`.

## Fix

There are two honest fixes, and the question is which side owns the name.

Point the Deployment at the key the Secret has now:

```bash
kubectl -n {{.WorkloadNamespace}} patch deploy {{.WorkloadName}} -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"{{.WorkloadName}}","env":[{"name":"API_TOKEN","valueFrom":{"secretKeyRef":{"name":"{{.WorkloadName}}-secret","key":"API_TOKEN"}}}]}]}}}}'
kubectl -n {{.WorkloadNamespace}} rollout status deploy/{{.WorkloadName}}
```

Or put the key the app expects back in the Secret. The waiting pods retry on
their own and start within a minute, with no restart needed:

```bash
kubectl -n {{.WorkloadNamespace}} get secret {{.WorkloadName}}-secret -o jsonpath='{.data.API_TOKEN}'   # copy the value
kubectl -n {{.WorkloadNamespace}} patch secret {{.WorkloadName}}-secret --type=json \
  -p '[{"op":"add","path":"/data/api-token","value":"<the value you copied>"}]'
```

Re-applying the app's chart (`labctl app deploy {{.WorkloadName}}`) also puts
the key back, since the chart owns the Secret.

Verify: `labctl incident status`. The check passes once every replica is ready
and every Secret key the container reads exists.

## The tempting wrong fix

`kubectl rollout restart`. It is the reflex for "pods are stuck", and here it
does nothing useful: the new pods are built from the same template, look up
the same missing key and stop in the same state. Marking the reference
`optional: true` is the other trap: the pods start, the dashboard goes green,
and the app runs with `API_TOKEN` unset. The check fails both.

## Do this on your own cluster

The fault is a key rename in the Secret, then the pods replaced:

```bash
V=$(kubectl -n {{.WorkloadNamespace}} get secret {{.WorkloadName}}-secret -o jsonpath='{.data.api-token}')
kubectl -n {{.WorkloadNamespace}} patch secret {{.WorkloadName}}-secret --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/data/API_TOKEN\",\"value\":\"$V\"},{\"op\":\"remove\",\"path\":\"/data/api-token\"}]"
kubectl -n {{.WorkloadNamespace}} delete pod -l app.kubernetes.io/name={{.WorkloadName}}
```

## Real-world parallel

A secrets manager or External Secrets template that changes the key names it
writes, a rotation script that recreates a Secret from a new template, or a
key renamed in one repository and not the other. It hides until the pods are
replaced, which is why it so often surfaces during a node upgrade or a
scale-up hours after the change that caused it. The lesson: a Secret is an
interface, and its key names are part of the contract. Change them the way
you would change an API: add the new key, move the consumers, then remove the
old one.

`CreateContainerConfigError` has other common causes, and the event names each
one: a Secret or ConfigMap that does not exist at all (`secret "x" not found`),
a missing ConfigMap key (`couldn't find key ... in ConfigMap`), or a volume
mount of a Secret that is missing.
