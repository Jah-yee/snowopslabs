#!/usr/bin/env bash
# Passes (exit 0) when the fault is resolved: no replica of the workload is
# waiting for a node, the rollout has completed, and every replica is ready.
#
# It grades the outcome, not a request value, so any request the nodes can
# hold passes, and a rollback or a chart re-apply passes with it. Deleting the
# Pending pods changes nothing: the ReplicaSet recreates them, still Pending.
set -euo pipefail
NS="${TARGET_NAMESPACE:-go-api}"
DEPLOY="${TARGET_WORKLOAD:-go-api}"

LIB="$(cd "$(dirname "$0")/../../_lib" && pwd)"
# shellcheck source=/dev/null
. "$LIB/assert.sh"
# shellcheck source=/dev/null
. "$LIB/workload.sh"

assert_scaled_up "$NS" "$DEPLOY"

SELECTOR="$(workload_selector "$NS" "$DEPLOY")"
if [ -z "$SELECTOR" ]; then
  echo "FAIL: cannot read the pod selector of $NS/$DEPLOY, so its pods cannot be checked." >&2
  exit 1
fi

if ! PENDING="$(kubectl -n "$NS" get pods -l "$SELECTOR" --field-selector=status.phase=Pending,spec.nodeName= -o name 2>/dev/null)"; then
  echo "FAIL: could not list the pods of $NS/$DEPLOY. Is the cluster reachable?" >&2
  exit 1
fi
if [ -n "$PENDING" ]; then
  count="$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')"
  echo "FAIL: $count pod(s) of $NS/$DEPLOY are Pending: no node has taken them." >&2
  echo "  Stuck? 'labctl incident hint' walks you in." >&2
  exit 1
fi

assert_workload_healthy "$NS" "$DEPLOY"
echo "OK: every replica of $NS/$DEPLOY is scheduled and ready."
