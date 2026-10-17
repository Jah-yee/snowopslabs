#!/bin/sh
# The hand fix from solution.md, for the cluster suite: give the container a CPU
# request the nodes can hold, and wait for the rollout.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" set resources "deploy/$WORKLOAD_NAME" \
  --requests=cpu=100m --limits=cpu=500m
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
