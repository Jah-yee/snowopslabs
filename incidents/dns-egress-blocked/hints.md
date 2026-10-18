# Hints: dns-egress-blocked

## Hint 1
The app is answering, so ask it what is wrong: `curl -s
http://go-api.{{.IngressURLSuffix}}/` prints the error it returns, and
`kubectl logs -n go-api deploy/go-api` shows the same line for every failed
request. Read the whole error: which step of the call to the dependency
failed?

## Hint 2
The error is a failed **lookup**: the app never got as far as connecting,
because the dependency's name did not resolve. Try the same lookup from a
throwaway pod in the same namespace, then from one in another namespace:
`kubectl -n go-api run dnstest --rm -it --restart=Never --image=busybox:1.36 --
sh -c 'sleep 5; nslookup echo-server.echo-server.svc.cluster.local'`. Does it
work in one and not the other? (Keep the sleep: the network policy controller
needs a moment to start enforcing on a new pod, and a lookup in its first
second can get through.)

## Hint 3
Something applies to every pod in the go-api namespace and not elsewhere:
`kubectl get networkpolicy -n go-api`. A policy that lists `Egress` in its
`policyTypes` allows only the traffic its egress rules name, and every name
lookup is traffic to the cluster DNS Service on port 53. Read the rules with
`kubectl get networkpolicy -n go-api -o yaml`.
