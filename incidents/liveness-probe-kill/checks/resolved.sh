#!/usr/bin/env bash
# Passes (exit 0) when the fault is resolved: the container still has a
# liveness probe, an HTTP probe's path answers 2xx on a running pod, and every
# replica is ready after a completed rollout.
#
# It asks the probe's own path, so any path the app really serves passes and a
# rollback or a chart re-apply passes with it. Deleting the probe, or raising its
# delay or threshold while the path still 404s, does not.
set -euo pipefail
NS="${TARGET_NAMESPACE:-go-api}"
DEPLOY="${TARGET_WORKLOAD:-go-api}"

LIB="$(cd "$(dirname "$0")/../../_lib" && pwd)"
# shellcheck source=/dev/null
. "$LIB/assert.sh"
# shellcheck source=/dev/null
. "$LIB/workload.sh"

assert_scaled_up "$NS" "$DEPLOY"

probe_get() {
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o "jsonpath={.spec.template.spec.containers[0].livenessProbe$1}" 2>/dev/null || true
}

if [ -z "$(probe_get "")" ]; then
  echo "FAIL: $NS/$DEPLOY has no liveness probe, so a hung process would never be restarted." >&2
  echo "  The restarts stopped because nothing checks the app any more. Put a probe back that the app passes." >&2
  exit 1
fi

PROBE_PATH="$(probe_get .httpGet.path)"
if [ -n "$PROBE_PATH" ]; then
  PORT="$(container_port "$NS" "$DEPLOY" "$(probe_get .httpGet.port)")"
  SCHEME="$(probe_get .httpGet.scheme)"
  POD="$(running_pod "$NS" "$(workload_selector "$NS" "$DEPLOY")")"
  if [ -z "$PORT" ]; then
    echo "FAIL: the liveness probe of $NS/$DEPLOY names a port the container does not declare." >&2
    exit 1
  fi
  if [ -z "$POD" ]; then
    echo "FAIL: no pod of $NS/$DEPLOY is running, so its liveness probe cannot be tried." >&2
    exit 1
  fi
  if ! pod_get_ok "$NS" "$POD" "$PORT" "$PROBE_PATH" "$SCHEME"; then
    echo "FAIL: the liveness probe of $NS/$DEPLOY (GET $PROBE_PATH on port $PORT) does not succeed on $POD." >&2
    echo "  Stuck? 'labctl incident hint' walks you in." >&2
    exit 1
  fi
fi

assert_workload_healthy "$NS" "$DEPLOY"
echo "OK: the liveness probe of $NS/$DEPLOY passes and every replica is ready."
