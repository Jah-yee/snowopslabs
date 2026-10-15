#!/bin/sh
# Runs one lab item end to end against a real cluster, the way a reviewer
# would, and fails at the first step that does not behave.
#
#   A warm-up cycle (up and down, or inject and resolve) first installs the
#   item's prerequisites, which stay, so they are not counted as left behind.
#   scenario: up, verify must fail on the untouched lab, the item's
#             test/solve.sh, verify must pass, down, nothing left behind.
#   incident: inject, the detection check must fail, the resolve escape hatch
#             must restore the lab; inject again, the item's test/solve.sh, the
#             check must pass, resolve tidies up, nothing left behind.
#
# Usage: run.sh scenario|incident <name>
# Environment: LABCTL (default labctl), APP (default go-api), WAIT_SECONDS
# (default 600, how long a solved item may take to pass), ITEMS_ROOT (default
# this checkout: where scenarios/ and incidents/ are found), POLL_SECONDS
# (default 10), RECORD (1: write the scenario's untouched and solved check
# fixtures to its test/fixtures/ for the replay tests).
set -eu

kind="${1:?usage: run.sh scenario|incident <name>}"
name="${2:?usage: run.sh scenario|incident <name>}"
labctl="${LABCTL:-labctl}"
app="${APP:-go-api}"
wait_seconds="${WAIT_SECONDS:-600}"

root="${ITEMS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
work=$(mktemp -d "${TMPDIR:-/tmp}/cluster-suite.XXXXXX")
trap 'rm -rf "$work"' EXIT

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  exit 1
}

# What a solve script is told about the lab it solves.
export WORKLOAD_NAME="$app" WORKLOAD_NAMESPACE="$app" PROJECT_ROOT="$root" LABCTL="$labctl"

namespaces() { kubectl get namespaces -o name | sort; }

# The objects in the workload's namespace, less the kinds Kubernetes and its
# controllers create and replace on their own.
app_objects() {
  for kind in $(kubectl api-resources --verbs=list --namespaced -o name); do
    case "$kind" in
      pods | events | events.events.k8s.io | endpoints | endpointslices.discovery.k8s.io | \
        replicasets.apps | controllerrevisions.apps | leases.coordination.k8s.io | \
        pods.metrics.k8s.io | *.wgpolicyk8s.io | *reports.kyverno.io) continue ;;
    esac
    kubectl -n "$app" get "$kind" -o name 2>/dev/null
  done | grep -v '^secret/sh\.helm\.release\.' | sort
}

snapshot() {
  namespaces >"$work/before"
  app_objects >"$work/objects-before"
}

# Everything the item created must be gone again: no new namespace, no new
# object in the workload's namespace, and no fault record left in kube-system.
assert_nothing_left() {
  namespaces >"$work/after"
  left=$(comm -13 "$work/before" "$work/after")
  [ -z "$left" ] || fail "left behind after $1: $(echo "$left" | tr '\n' ' ')"
  app_objects >"$work/objects-after"
  left=$(comm -13 "$work/objects-before" "$work/objects-after")
  [ -z "$left" ] || fail "left behind in namespace $app after $1: $(echo "$left" | tr '\n' ' ')"
  if kubectl -n kube-system get configmap "labfault-$name" >/dev/null 2>&1; then
    fail "left behind after $1: the fault record configmap/labfault-$name"
  fi
  pass "nothing left behind after $1"
}

solve() {
  script="$root/${kind}s/$name/test/solve.sh"
  [ -x "$script" ] || fail "$kind $name has no executable test/solve.sh"
  "$script" || fail "test/solve.sh exited $?"
  pass "ran test/solve.sh"
}

case "$kind" in
  scenario)
    "$labctl" scenario up "$name" --app "$app" --deploy-prereqs || fail "the warm-up scenario up $name"
    "$labctl" scenario down "$name" || fail "the warm-up scenario down $name"
    pass "prerequisites in place"
    snapshot
    "$labctl" scenario up "$name" --app "$app" || fail "scenario up $name"
    pass "scenario up $name"
    fixtures="$root/scenarios/$name/test/fixtures"
    record() { [ "${RECORD:-0}" != 1 ] || echo "--record $fixtures/$1.json"; }
    # shellcheck disable=SC2046 # record prints nothing or two words
    if "$labctl" scenario verify "$name" $(record untouched) >"$work/untouched" 2>&1; then
      fail "verify passed on the untouched lab: the checks grade nothing"
    fi
    pass "verify fails on the untouched lab"
    solve
    # The solved fixture is what the lab answered on the pass that graded it.
    # shellcheck disable=SC2046
    "$labctl" scenario verify "$name" --watch --interval 10s --timeout "${wait_seconds}s" $(record solved) ||
      fail "verify does not pass on the solved lab"
    pass "verify passes on the solved lab"
    [ "${RECORD:-0}" != 1 ] || pass "recorded the untouched and solved check fixtures"
    # Traffic a solve started is the learner's to stop; down leaves it running.
    "$labctl" traffic stop >/dev/null 2>&1 || true
    "$labctl" scenario down "$name" || fail "scenario down $name"
    pass "scenario down $name"
    assert_nothing_left "scenario down"
    ;;

  incident)
    "$labctl" incident inject "$name" --app "$app" --deploy-prereqs || fail "the warm-up incident inject $name"
    "$labctl" incident resolve || fail "the warm-up incident resolve"
    pass "prerequisites in place"
    snapshot
    "$labctl" incident inject "$name" --app "$app" || fail "incident inject $name"
    pass "incident inject $name"
    "$labctl" incident status >"$work/status" 2>&1 || fail "incident status"
    grep -q "^NOT RESOLVED" "$work/status" || fail "the detection check passes on the broken lab"
    pass "the detection check fails on the broken lab"
    "$labctl" incident resolve || fail "incident resolve"
    "$labctl" incident status 2>&1 | grep -q "No incident is active" || fail "an incident is still active after resolve"
    pass "resolve restores the lab"
    assert_nothing_left "resolve"

    "$labctl" incident inject "$name" --app "$app" || fail "the second incident inject $name"
    solve
    elapsed=0
    until "$labctl" incident status 2>&1 | grep -q "^RESOLVED — detection check"; do
      [ "$elapsed" -lt "$wait_seconds" ] || fail "the detection check does not pass on the fixed lab after ${wait_seconds}s"
      sleep "${POLL_SECONDS:-10}"
      elapsed=$((elapsed + ${POLL_SECONDS:-10}))
    done
    pass "the detection check passes on the fixed lab"
    # A hand fix closes the incident but leaves the fault's record; resolve
    # tidies it and must leave the learner's fix alone.
    "$labctl" incident resolve "$name" || fail "incident resolve $name after the hand fix"
    pass "resolve after the hand fix"
    assert_nothing_left "a hand fix and resolve"
    ;;

  *)
    fail "unknown kind $kind: want scenario or incident"
    ;;
esac
