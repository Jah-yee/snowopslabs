#!/usr/bin/env bash
# Passes (exit 0) when the fault is resolved: every replica is ready, and the
# container's CPU limit is gone or at least twice what one pod used under the
# steady load, measured before the limit was lowered. Below that the pod is
# still throttled enough to show in p99.
#
# The bar is capped at the limit the workload shipped with, so a rollback or a
# chart re-apply always passes. It grades the limit rather than live latency,
# so stopping the traffic or scaling out under the same low limit does not.
set -euo pipefail
NS="${TARGET_NAMESPACE:-go-api}"
DEPLOY="${TARGET_WORKLOAD:-go-api}"

LIB="$(cd "$(dirname "$0")/../../_lib" && pwd)"
# shellcheck source=/dev/null
. "$LIB/assert.sh"
# shellcheck source=/dev/null
. "$LIB/state.sh"
# shellcheck source=/dev/null
. "$LIB/workload.sh"

assert_workload_healthy "$NS" "$DEPLOY"

DEMAND="$(fault_state_get cpu-throttling demand-millicores)"
ORIG_LIMIT="$(fault_state_get cpu-throttling original-limit)"
LIMIT="$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o 'jsonpath={.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)"

if [ -n "$DEMAND" ] && [ -n "$LIMIT" ]; then
  NEED=$((DEMAND * 2))
  orig="$(cpu_millicores "$ORIG_LIMIT")"
  if [ -n "$orig" ] && [ "$orig" -lt "$NEED" ]; then NEED="$orig"; fi
  if [ "$(cpu_millicores "$LIMIT")" -lt "$NEED" ]; then
    echo "FAIL: $NS/$DEPLOY is still not sized for the load it serves." >&2
    echo "  Stuck? 'labctl incident hint' walks you in." >&2
    exit 1
  fi
fi
echo "OK: $NS/$DEPLOY has the CPU it needs for its load, and every replica is ready."
