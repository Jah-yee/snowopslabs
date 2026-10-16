#!/usr/bin/env bash
set -euo pipefail

# check-nodes-ready.sh - exit 0 only if every node is Ready and none is
# cordoned. After a rolling upgrade the cluster must be back to full, healthy
# capacity; a NotReady or SchedulingDisabled node means the roll did not finish.

# A failed query is not "every node is fine": without the node list nothing
# says whether one is NotReady.
READINESS=$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  2>/dev/null || true)
if [ -z "$READINESS" ]; then
  echo "FAIL: could not list the nodes, so their readiness is unknown." >&2
  echo "  Is the cluster reachable? kubectl get nodes" >&2
  exit 1
fi
NOT_READY=$(printf '%s\n' "$READINESS" | awk '$2 != "True" {print $1}')

if [ -n "$NOT_READY" ]; then
  echo "FAIL: the following node(s) are not Ready:" >&2
  echo "$NOT_READY" >&2
  exit 1
fi

CORDONED=$(kubectl get nodes \
  -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null || true)

if [ -n "$CORDONED" ]; then
  echo "FAIL: the following node(s) are still cordoned (SchedulingDisabled):" >&2
  echo "$CORDONED" >&2
  exit 1
fi

echo "OK: all nodes are Ready and schedulable."
