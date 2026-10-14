#!/bin/sh
# The drill a learner walks, for the cluster suite: make the workload run as
# non-root, promote the Pod Security policies to Enforce, exempt the legacy
# workload, issue the workload's certificate and serve it from its Ingress.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

kubectl -n "$ns" patch deployment "$app" --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/securityContext/runAsNonRoot","value":true}]'
kubectl -n "$ns" rollout status "deployment/$app" --timeout=180s

for policy in deny-privilege-escalation require-non-root-user; do
  kubectl patch clusterpolicy "$policy" --type=json \
    -p '[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
done

render security-compliance manifests/policy-exception.yaml | kubectl apply -f -
kubectl -n "$ns" rollout restart deployment/legacy-reporter
kubectl -n "$ns" rollout status deployment/legacy-reporter --timeout=180s

render security-compliance manifests/workload-tls-certificate.yaml | kubectl apply -f -
kubectl -n "$ns" wait "certificate/$app-tls" --for=condition=Ready --timeout=180s

host=$(kubectl -n "$ns" get ingress "$app" -o 'jsonpath={.spec.rules[0].host}')
entrypoints='"metadata":{"annotations":{"traefik.ingress.kubernetes.io/router.entrypoints":"web,websecure"}}'
tls="\"spec\":{\"tls\":[{\"hosts\":[\"$host\"],\"secretName\":\"$app-tls-secret\"}]}"
kubectl -n "$ns" patch ingress "$app" --type=merge -p "{$entrypoints,$tls}"
