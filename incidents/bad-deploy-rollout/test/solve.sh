#!/bin/sh
# The hand fix from solution.md, for the cluster suite: roll back to the
# revision that worked, and wait for it.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" rollout undo "deploy/$WORKLOAD_NAME"
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
