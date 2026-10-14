#!/bin/sh
# The drill a learner walks, for the cluster suite: start load, apply the
# PodDisruptionBudget, then roll every worker one at a time (cordon, drain,
# replace on the control plane's version), reclaim storage the old nodes took
# with them, and restart the load the roll evicted.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
dir="$PROJECT_ROOT/scenarios/cluster-upgrade-drill/scripts"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

"${LABCTL:-labctl}" traffic start --app "$app" --profile steady --rps 20
render cluster-upgrade-drill manifests/baseline.yaml | kubectl apply -f -

# Rolling onto the control plane's own version is node rotation: the same
# cordon, drain and replace, with no version skew to refuse.
server=$(kubectl get node -l node-role.kubernetes.io/control-plane \
  -o 'jsonpath={.items[0].status.nodeInfo.kubeletVersion}')
target=$(echo "$server" | tr '+' '-')

workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o 'jsonpath={.items[*].metadata.name}')
[ -n "$workers" ] || {
  echo "the cluster has no worker nodes to roll" >&2
  exit 1
}
for node in $workers; do
  kubectl cordon "$node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s
  TARGET_K3S_VERSION="$target" bash "$dir/roll-node.sh" "$node"
  kubectl -n "$ns" rollout status "deploy/$app" --timeout=180s
done

bash "$dir/reclaim-stranded-pvcs.sh"
"${LABCTL:-labctl}" traffic start --app "$app" --profile steady --rps 20
