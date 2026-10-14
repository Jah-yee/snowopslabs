#!/bin/sh
# The hand fix from solution.md, for the cluster suite: give the workload
# memory above its peak again, and wait for the rollout. The limit it shipped
# with, from the fault's record, is known to be enough; 256Mi when it had none.
set -eu
. "$PROJECT_ROOT/incidents/_lib/state.sh"
limit=$(fault_state_get oom-kill original-limit)
request=$(fault_state_get oom-kill original-request)
case "$limit" in "" | none) limit=256Mi ;; esac
case "$request" in "" | none) request=64Mi ;; esac
kubectl -n "$WORKLOAD_NAMESPACE" set resources "deploy/$WORKLOAD_NAME" \
  "--limits=memory=$limit" "--requests=memory=$request"
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
