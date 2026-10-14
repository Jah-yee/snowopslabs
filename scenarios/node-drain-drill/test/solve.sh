#!/bin/sh
# The drill a learner walks, for the cluster suite: apply the
# PodDisruptionBudget, start load, then cordon and drain a worker that runs the
# workload, and put it back in service.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

render node-drain-drill manifests/baseline.yaml | kubectl apply -f -
"${LABCTL:-labctl}" traffic start --app "$app" --profile steady --rps 20

# Prometheus records the availability the drill is graded on, and its volume
# is node-local: a drain of its node stops the measurement. Pick a worker that
# runs the workload and not Prometheus.
prometheus_nodes=$(kubectl get pods -A -l app.kubernetes.io/name=prometheus -o 'jsonpath={.items[*].spec.nodeName}')
node=""
for candidate in $(kubectl -n "$ns" get pods -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u); do
  if kubectl get node "$candidate" -o 'jsonpath={.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane'; then
    continue
  fi
  case " $prometheus_nodes " in *" $candidate "*) continue ;; esac
  node=$candidate
  break
done
[ -n "$node" ] || {
  echo "every worker that runs $app also runs Prometheus, so a drain would stop the measurement" >&2
  exit 1
}

kubectl cordon "$node"
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl -n "$ns" rollout status "deploy/$app" --timeout=180s
kubectl uncordon "$node"
