#!/usr/bin/env bash
# Passes (exit 0) when the fault is resolved: every replica is ready after a
# completed rollout, every Secret key the container reads exists, and the
# variable the fault broke still comes from a Secret.
#
# Either real fix passes: the key put back in the Secret, or the reference
# pointed at the key the Secret has now. Marking the reference optional, or
# dropping or hardcoding the variable, starts the pod without its credential
# and fails.
set -euo pipefail
NS="${TARGET_NAMESPACE:-go-api}"
DEPLOY="${TARGET_WORKLOAD:-go-api}"

LIB="$(cd "$(dirname "$0")/../../_lib" && pwd)"
# shellcheck source=/dev/null
. "$LIB/assert.sh"
# shellcheck source=/dev/null
. "$LIB/state.sh"

# Health first: while the fault is live this says what `kubectl get pods`
# says. The Secret checks below catch the fixes that start pods without the key.
assert_workload_healthy "$NS" "$DEPLOY"

if ! REFS="$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o 'jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}|{.valueFrom.secretKeyRef.name}|{.valueFrom.secretKeyRef.key}{"\n"}{end}' 2>/dev/null)"; then
  echo "FAIL: could not read the environment of $NS/$DEPLOY. Is the cluster reachable?" >&2
  exit 1
fi

# The variable the fault broke, from its record, must still read a Secret key.
ENV_NAME="$(fault_state_get missing-secret-key env)"
if [ -n "$ENV_NAME" ] && ! printf '%s\n' "$REFS" | awk -F'|' -v e="$ENV_NAME" '$1 == e && $3 != "" { f = 1 } END { exit !f }'; then
  echo "FAIL: $ENV_NAME no longer comes from a Secret: it is gone, or its value is written into the pod template." >&2
  echo "  Read it from the Secret again, from a key that exists." >&2
  exit 1
fi

missing=""
for ref in $(printf '%s\n' "$REFS" | awk -F'|' '$2 != "" && $3 != "" { print $1 "|" $2 "|" $3 }'); do
  env_name="${ref%%|*}"
  secret="$(printf '%s' "$ref" | cut -d'|' -f2)"
  key="$(printf '%s' "$ref" | cut -d'|' -f3)"
  if ! kubectl -n "$NS" get secret "$secret" \
    -o 'go-template={{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | grep -qx "$key"; then
    missing="$missing
    $env_name reads key \"$key\" of Secret $secret, which does not have it"
  fi
done
if [ -n "$missing" ]; then
  echo "FAIL: $NS/$DEPLOY reads a Secret key that does not exist:$missing" >&2
  echo "  Stuck? 'labctl incident hint' walks you in." >&2
  exit 1
fi

echo "OK: every Secret key $NS/$DEPLOY reads exists, and every replica is ready."
