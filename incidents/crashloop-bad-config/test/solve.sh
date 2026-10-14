#!/bin/sh
# The hand fix from solution.md, for the cluster suite: set PORT back to the
# port the workload serves on, and wait for the rollout.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" set env "deploy/$WORKLOAD_NAME" "PORT=${WORKLOAD_PORT:-8080}"
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
