#!/bin/sh
# The drill a learner walks, for the cluster suite: apply the ScaledObject,
# drive the spike, and wait until KEDA has scaled the workload above its floor.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

render autoscaling-under-load manifests/scaledobject.yaml | kubectl apply -f -
wait_until 120 "KEDA creating hpa/keda-hpa-$app" \
  kubectl -n "$ns" get "hpa/keda-hpa-$app"
"${LABCTL:-labctl}" traffic start --app "$app" --profile spike --rps 10

scaled_up() {
  [ "$(kubectl -n "$ns" get "hpa/keda-hpa-$app" -o 'jsonpath={.status.currentReplicas}')" -gt 1 ] 2>/dev/null
}
# The spike starts after a minute of baseline and a 30s ramp.
wait_until 300 "$app scaling above one replica" scaled_up
