#!/bin/sh
# The hand fix from solution.md, for the cluster suite: point the liveness
# probe back at the app's health endpoint, and wait for the rollout.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" patch deploy "$WORKLOAD_NAME" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health"}]'
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
