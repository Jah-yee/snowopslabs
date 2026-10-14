#!/bin/sh
# The drill a learner walks, for the cluster suite: wire the workload to the
# trace collector, drive steady load, then fail one pod's readiness until a
# scenario alert fires, and restore it.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

bash "$PROJECT_ROOT/scenarios/observability-sre/scripts/enable-tracing.sh" --app "$app" --namespace "$ns"
kubectl -n "$ns" rollout status "deploy/$app" --timeout=180s
"${LABCTL:-labctl}" traffic start --app "$app" --profile steady --rps 25 --duration 20m

pod=$(kubectl -n "$ns" get pods -l "app=$app" --field-selector=status.phase=Running \
  -o 'jsonpath={.items[0].metadata.name}')
port=$(kubectl -n "$ns" get "deploy/$app" -o 'jsonpath={.spec.template.spec.containers[0].ports[0].containerPort}')
toggle() { kubectl -n "$ns" exec "$pod" -- wget -qO- "localhost:$port/toggle-failure"; }

toggle
wait_until 420 "a scenario alert firing" at_least \
  'count(ALERTS{scenario="observability-sre",alertstate="firing"})' 1
toggle
