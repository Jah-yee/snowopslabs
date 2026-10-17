#!/bin/sh
# The hand fix from solution.md, for the cluster suite: point the variable at
# the key the rotated Secret has now, and wait for the rollout.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" patch deploy "$WORKLOAD_NAME" --type=strategic -p \
  "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$WORKLOAD_NAME\",\"env\":[{\"name\":\"API_TOKEN\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"$WORKLOAD_NAME-secret\",\"key\":\"API_TOKEN\"}}}]}]}}}}"
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
