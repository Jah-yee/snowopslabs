#!/usr/bin/env bash
# Where a fault keeps what resolve.sh needs to undo it.
#
# Sourced, not executed:
#   . "$(cd "$(dirname "$0")/../_lib" && pwd)/state.sh"
#
# The record is a ConfigMap of its own, never an annotation or label on the
# object the fault breaks: there it would put the original value on screen in
# the first `kubectl describe` a learner runs.

FAULT_STATE_NAMESPACE="${FAULT_STATE_NAMESPACE:-kube-system}"

# fault_state_save <fault> <key=value>... — record values, replacing any
# earlier record for the fault.
fault_state_save() {
  fault="$1"
  shift
  n=$#
  for kv in "$@"; do
    set -- "$@" "--from-literal=$kv"
  done
  shift "$n"
  kubectl -n "$FAULT_STATE_NAMESPACE" create configmap "labfault-$fault" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# fault_state_get <fault> <key> — print a recorded value, or nothing.
fault_state_get() {
  kubectl -n "$FAULT_STATE_NAMESPACE" get configmap "labfault-$1" \
    -o "jsonpath={.data.$2}" 2>/dev/null || true
}

# fault_state_clear <fault> — forget the record.
fault_state_clear() {
  kubectl -n "$FAULT_STATE_NAMESPACE" delete configmap "labfault-$1" \
    --ignore-not-found >/dev/null 2>&1 || true
}
