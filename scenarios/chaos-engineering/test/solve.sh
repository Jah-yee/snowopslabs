#!/bin/sh
# The drill a learner walks, for the cluster suite: put the workload under
# load, kill a pod on one replica, scale it to three, verify to record the
# hardening, and re-run the same experiment against the hardened service.
set -eu
dir="$PROJECT_ROOT/scenarios/chaos-engineering/scripts"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

"${LABCTL:-labctl}" traffic start --app "$app" --profile browse --rps 20 --duration 30m
bash "$dir/inject.sh" pod-kill --app "$app" --namespace "$ns"

kubectl -n "$ns" scale "deploy/$app" --replicas=3
kubectl -n "$ns" rollout status "deploy/$app" --timeout=180s
# The blast-radius check measures from the first verify that sees the
# hardened service, so it cannot pass yet.
if "${LABCTL:-labctl}" scenario verify chaos-engineering; then
  echo "verify passed before the experiment was re-run on the hardened service" >&2
  exit 1
fi

kubectl delete podchaos "pod-kill-$app" -n "$ns" --ignore-not-found
bash "$dir/inject.sh" pod-kill --app "$app" --namespace "$ns"
