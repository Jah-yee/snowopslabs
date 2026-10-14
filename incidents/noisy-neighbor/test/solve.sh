#!/bin/sh
# The hand fix from solution.md, for the cluster suite: cap the batch job's CPU
# so the workload on the same node gets its share back.
set -eu
kubectl -n labfault-batch set resources deploy/report-batch \
  --requests=cpu=100m --limits=cpu=200m
kubectl -n labfault-batch rollout status deploy/report-batch --timeout=180s
