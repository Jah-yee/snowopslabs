# Solution: network-blackhole

## What happened

A NetworkPolicy named `default-deny-ingress` was applied to the
`{{.WorkloadNamespace}}` namespace with an empty `podSelector` (matches all pods),
`policyTypes: [Ingress]`, and no ingress rules - the canonical
deny-all-ingress policy, under the name the Kubernetes documentation gives it.
Nothing about the name looks out of place, which is how it reads in a real
cluster: a hardening change that arrived without the allow rules that go with
it. k3s enforces NetworkPolicies out of the box (via
kube-router), so all traffic *to* the pods is dropped, including from the
ingress controller. The pods themselves never notice: nothing arrives, so
there is nothing to log.

## Diagnosis path

```bash
curl -v http://{{.WorkloadName}}.{{.IngressURLSuffix}}/health            # times out / 5xx from traefik
kubectl get pods -n {{.WorkloadNamespace}}                        # all Running, Ready
kubectl get endpoints {{.WorkloadName}} -n {{.WorkloadNamespace}}            # endpoints populated - Service is fine
kubectl port-forward -n {{.WorkloadNamespace}} deploy/{{.WorkloadName}} 8080:8080 &
curl localhost:8080/health                        # works! pod is healthy
kubectl get networkpolicy -n {{.WorkloadNamespace}}               # ← one is minutes old
kubectl describe networkpolicy default-deny-ingress -n {{.WorkloadNamespace}}   # selects every pod, allows nobody
```

## Fix

```bash
kubectl delete networkpolicy default-deny-ingress -n {{.WorkloadNamespace}}
```

Giving the policy an ingress rule that admits the ingress controller is also a
fix. Adding a second, permissive policy beside it is not: the traffic returns,
but the deny-all stays behind for whoever removes that second policy next.

Recovery is immediate, no restart needed, because the policy only ever
governed new connections and new connections are now allowed.

## Why a NetworkPolicy outage often starts hours after the policy lands

This is the part that catches people, and it is the reason this fault restarts
the workload's pods when it injects.

**A NetworkPolicy applies to new connections, not to established ones.** The
enforcement point is conntrack: once a connection is in the table it keeps
flowing regardless of what policy arrives afterwards. Ingress controllers hold a
keep-alive pool to each backend, so applying a deny-all to a namespace that is
actively serving changes *nothing* that anyone can see. Measured on this lab:
with the deny-all applied, requests through the ingress kept returning 200
indefinitely, while a fresh pod-to-pod connection to the same Service, and to
the same pod IP, was refused within milliseconds.

The outage begins at the next turnover: a pod restart, a rollout, a controller
restart, or simply the pool idling out. Restarting the ingress controller took
the same cluster from 200 to 502 instantly.

Two things follow for a real cluster:

- **A policy change that "worked fine" is not proof of anything** until
  connections have turned over. Test it against a fresh connection, not against
  the traffic that is already flowing.
- **The blast radius is delayed and disconnected from the change.** The person
  who restarts the deployment three hours later gets the page, and their change
  had nothing to do with it.

`kubectl port-forward` still works throughout, because it originates from the
kubelet on the node rather than from a pod, which is exactly why it is the
right probe for "is the pod itself healthy" and the wrong one for "can anything
reach it".

## Real-world parallel

Deny-all policies are a security best practice - *when paired with the
allow rules that go with them*. A namespace-wide deny applied without its
companion allows (or applied to the wrong namespace by a templating bug)
produces exactly this: a total outage with every health indicator green.
When app-level signals look perfect but traffic dies, check the network
*policy* layer before the network itself.
