# Solution: dns-egress-blocked

## What happened

The security hardening added a default-deny egress policy to the go-api
namespace, `default-deny-egress`. It allows one thing out: TCP 8080 to the
echo-server namespace, the dependency go-api calls on every request to `/`.
It forgot DNS. go-api reaches echo-server by name,
`echo-server.echo-server.svc.cluster.local`, so every new connection starts
with a lookup to the cluster DNS Service on port 53, and the policy blocks it.
The connection never happens, and `/` answers 502 with the error.

Nothing else breaks. The policy restricts egress only, so inbound traffic
arrives as before, `/health` needs nothing outside the pod, and `/ready`
reports the dependency's error without failing, so every pod stays Ready. The
outage began when the pods were replaced: a policy governs new connections
only, and the old pods kept the connection they already had.

## How this differs from the other incidents

`network-blackhole` denies **ingress**: no request reaches the app, its logs
are quiet, and the ingress returns 5xx on its own. Here requests do arrive,
the app answers, and its error says what failed. The pods are healthy, so none
of the workload faults' signals (restarts, exit codes, Pending, waiting
reasons) apply, and the dependency itself is fine.

## Diagnosis path

```bash
curl -s http://go-api.{{.IngressURLSuffix}}/
# {"error":"upstream: Get \"http://echo-server.echo-server.svc.cluster.local:8080/\":
#   dial tcp: lookup echo-server.echo-server.svc.cluster.local on 10.43.0.10:53:
#   read udp 10.42.2.247:41387->10.43.0.10:53: read: connection refused"}
curl -s http://go-api.{{.IngressURLSuffix}}/health            # {"status":"ok"}

# The same lookup, from a throwaway pod in the namespace and from one outside it
kubectl -n go-api run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'sleep 5; nslookup echo-server.echo-server.svc.cluster.local'   # fails
kubectl -n default run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'sleep 5; nslookup echo-server.echo-server.svc.cluster.local'   # resolves

kubectl get networkpolicy -n go-api -o yaml                  # Egress, and no rule for port 53
```

The `sleep 5` matters: the network policy controller starts enforcing on a
new pod a moment after it starts, so a lookup in its first second gets
through and makes the policy look innocent.

On k3s the policy rejects the DNS packet, so the error ends in `connection
refused`. A CNI that drops it instead, such as Calico or Cilium, gives
`lookup ... i/o timeout` after several seconds. Both are the same fault.

In Grafana, *Application Request Metrics* shows the 5xx rate climb on `/` and
k6's failed requests, while *Pod Resources* shows nothing wrong. The page is
`LabFaultErrorRate`.

## Fix

Allow DNS beside the baseline, and keep the baseline:

```bash
kubectl -n go-api patch networkpolicy default-deny-egress --type=json -p \
  '[{"op":"add","path":"/spec/egress/-","value":{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}}]'
```

A separate `allow-dns` policy (the snippet in `labctl incident info
dns-egress-blocked`) works the same way: egress rules from every policy that
selects a pod add up. The next lookup succeeds, so requests recover with no
restart, once the policy controller has applied the change: allow 10 to 20
seconds before `labctl incident status` sees it.

Verify: `labctl incident status`. The check requires a request to `/` to
succeed on a running pod, the app to still call echo-server by name, and some
policy to still restrict egress. Its tidy-up removes the policy the fault
added and the snippet's `allow-dns`, so the next scenario starts with open
egress again.

## The tempting wrong fix

Deleting the policy, or adding a rule that allows all egress. Requests work
again at once, and the hardening the change was for is gone: the check fails
it. Pointing `UPSTREAM_URL` at the dependency's IP is the other shortcut, and
it breaks the next time the Service is recreated. Restarting the pods changes
nothing: the policy applies to the new ones too.

## Do this on your own cluster

The fault is one policy, then a rollout so existing connections turn over:

```bash
kubectl -n go-api apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: echo-server
      ports:
        - protocol: TCP
          port: 8080
EOF
kubectl -n go-api set env deploy/go-api UPSTREAM_URL=http://echo-server.echo-server.svc.cluster.local:8080/
```

## Real-world parallel

A default-deny egress baseline is good practice, and forgetting DNS is the
mistake almost everyone makes with it the first time. It hides until pods are
replaced, so it often looks like the next release broke something. The
lesson: with egress denied, **DNS is a dependency like any other** and needs
its own rule, and a lookup error is a network symptom, not an application bug.

Failed lookups have other common causes, and the throwaway pod tells them
apart: CoreDNS down or overloaded (lookups fail from every namespace), a typo
in the Service name (`no such host`, from everywhere), or a Service in another
namespace addressed by its short name.
