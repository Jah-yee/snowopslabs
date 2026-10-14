#!/usr/bin/env bash
# Shared assertions for incident detection checks.
#
# Sourced, not executed:
#   . "$(cd "$(dirname "$0")/../../_lib" && pwd)/assert.sh"

# assert_scaled_up <namespace> <deployment>
#
# Returns non-zero unless the Deployment exists and asks for at least one
# replica, and leaves the count in DESIRED_REPLICAS.
#
# Scaling to zero silences every symptom without repairing anything: nothing is
# left to crash, be killed or fail a probe, and `kubectl rollout status` reports
# success. A check that grades health has to rule it out first.
assert_scaled_up() {
  ns="$1"
  deploy="$2"

  DESIRED_REPLICAS="$(kubectl -n "$ns" get deploy "$deploy" -o 'jsonpath={.spec.replicas}' 2>/dev/null || true)"
  if [ -z "$DESIRED_REPLICAS" ]; then
    echo "FAIL: deployment $ns/$deploy not found." >&2
    return 1
  fi
  if [ "$DESIRED_REPLICAS" -lt 1 ]; then
    echo "FAIL: $ns/$deploy is scaled to $DESIRED_REPLICAS replicas, so nothing is serving." >&2
    echo "  Scaling to zero silences the symptom without fixing the fault." >&2
    echo "  Restore it: kubectl -n $ns scale deploy $deploy --replicas=1" >&2
    return 1
  fi
  return 0
}

# assert_workload_healthy <namespace> <deployment>
#
# Returns non-zero unless the workload is serving: scaled up, rolled out, and
# with every replica ready.
assert_workload_healthy() {
  ns="$1"
  deploy="$2"

  assert_scaled_up "$ns" "$deploy" || return 1
  desired="$DESIRED_REPLICAS"

  # kubectl's own failure here is "error: timed out waiting for the condition",
  # which tells a learner nothing about what it was waiting for. Say what the
  # pods are actually doing instead.
  if ! kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=15s >/dev/null 2>&1; then
    echo "FAIL: the rollout of $ns/$deploy has not completed." >&2
    kubectl -n "$ns" get pods -l "app.kubernetes.io/name=$deploy" --no-headers \
      -o 'custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,REASON:.status.containerStatuses[0].state.waiting.reason,RESTARTS:.status.containerStatuses[0].restartCount' \
      2>/dev/null | sed 's/^/  /' >&2 || true
    echo "  Stuck? 'labctl incident hint' walks you in." >&2
    return 1
  fi

  ready="$(kubectl -n "$ns" get deploy "$deploy" -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
  if [ "${ready:-0}" -lt "$desired" ]; then
    echo "FAIL: $ns/$deploy has ${ready:-0}/$desired replicas ready." >&2
    return 1
  fi
  return 0
}
