#!/bin/sh
# The hand fix from solution.md, for the cluster suite: give the container a CPU
# limit well above what it uses under load, and wait for the rollout.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" set resources "deploy/$WORKLOAD_NAME" \
  --requests=cpu=50m --limits=cpu=200m
kubectl -n "$WORKLOAD_NAMESPACE" rollout status "deploy/$WORKLOAD_NAME" --timeout=180s
