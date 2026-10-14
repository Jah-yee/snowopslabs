#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../_lib/workload.sh"

# remove-autoscaler.sh — delete the ScaledObject the learner applied, and the
# HPA KEDA made for it, then return the workload to one replica. The engine
# only tracks what it staged, so without this a `down` leaves KEDA scaling the
# shared workload in every later scenario, and the next activation starts with
# the ScaledObject already in place.

NS="${WORKLOAD_NAMESPACE}"
WORKLOAD="${WORKLOAD_NAME}"

kubectl -n "$NS" delete scaledobject "$WORKLOAD" --ignore-not-found
kubectl -n "$NS" delete hpa "keda-hpa-${WORKLOAD}" --ignore-not-found
kubectl -n "$NS" scale deployment "$WORKLOAD" --replicas=1
echo "Removed ${WORKLOAD}'s autoscaler and scaled it back to 1 replica."
