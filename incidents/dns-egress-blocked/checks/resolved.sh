#!/usr/bin/env bash
# Passes (exit 0) when the fault is resolved: every replica is ready, the app
# still calls the upstream it was given by name, a request that needs that
# upstream succeeds on a running pod, and egress is still restricted.
#
# It grades the outcome, so any policy change that lets the pods resolve names
# passes. Deleting the egress baseline, or allowing all egress, restores the
# service by giving up the control it was added for, and fails. So does
# pointing the app at an IP or at no upstream at all.
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

WANT="$(fault_state_get dns-egress-blocked upstream)"
if [ -n "$WANT" ]; then
  NOW="$(kubectl -n "$NS" get deploy "$DEPLOY" \
    -o 'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="UPSTREAM_URL")].value}' 2>/dev/null || true)"
  if [ "$NOW" != "$WANT" ]; then
    echo "FAIL: $NS/$DEPLOY no longer calls its upstream at $WANT (UPSTREAM_URL is \"$NOW\")." >&2
    echo "  The app needs that dependency, by that name. Put UPSTREAM_URL back and fix what stops the call." >&2
    exit 1
  fi
fi

POD="$(running_pod "$NS" "$(workload_selector "$NS" "$DEPLOY")")"
PORT="$(kubectl -n "$NS" get deploy "$DEPLOY" -o 'jsonpath={.spec.template.spec.containers[0].ports[0].containerPort}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "FAIL: no pod of $NS/$DEPLOY is running to try a request on." >&2
  exit 1
fi
if ! BODY="$(pod_get "$NS" "$POD" "${PORT:-8080}" "/")"; then
  echo "FAIL: a request to $NS/$DEPLOY that calls its upstream still fails on $POD." >&2
  echo "  Stuck? 'labctl incident hint' walks you in." >&2
  exit 1
fi
# A 200 counts only if the call to the upstream happened: an image older than
# UPSTREAM_URL ignores it and answers without calling anything.
case "$BODY" in
  *'"upstreamStatus"'*) ;;
  *)
    if [ -n "$WANT" ]; then
      echo "FAIL: $NS/$DEPLOY answers without calling its upstream, so the fault is not in effect at all." >&2
      echo "  Its image predates UPSTREAM_URL. Rebuild it: labctl app build $DEPLOY && labctl app deploy $DEPLOY" >&2
      exit 1
    fi
    ;;
esac

# "<name>|<policyTypes>|<egress rules>" for each policy in the namespace.
if ! POLICIES="$(kubectl -n "$NS" get networkpolicy \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.spec.policyTypes}{"|"}{.spec.egress}{"\n"}{end}' 2>/dev/null)"; then
  echo "FAIL: could not list the NetworkPolicies in $NS. Is the cluster reachable?" >&2
  exit 1
fi
if [ -n "$WANT" ]; then
  EGRESS="$(printf '%s\n' "$POLICIES" | awk -F'|' '$2 ~ /Egress/')"
  if [ -z "$EGRESS" ] || printf '%s\n' "$EGRESS" | grep -q -e '\[{}' -e ',{}'; then
    echo "FAIL: nothing restricts egress from $NS any more: the baseline was removed or opens all traffic." >&2
    echo "  Requests work again, but the hardening is gone. Keep a default-deny egress policy and allow what the app needs." >&2
    exit 1
  fi
fi
echo "OK: $NS/$DEPLOY reaches its upstream by name, with egress still restricted."
