#!/bin/sh
# The hand fix from solution.md, for the cluster suite: point the Service's
# selector back at the workload's pods.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" patch svc "$WORKLOAD_NAME" \
  -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/name\":\"$WORKLOAD_NAME\"}}}"
