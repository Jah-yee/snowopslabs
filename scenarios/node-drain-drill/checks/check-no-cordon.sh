#!/usr/bin/env bash
set -euo pipefail

# check-no-cordon.sh - exit 0 only if no node is left cordoned
# (SchedulingDisabled). The drill must always return the cluster to full
# scheduling capacity; a lingering cordon means the drain did not clean up.

# A failed query is not an empty answer: without the node list nothing says
# whether a node is still cordoned.
if ! CORDONED=$(kubectl get nodes \
  -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null); then
  echo "FAIL: could not list the nodes, so their scheduling state is unknown." >&2
  echo "  Is the cluster reachable? kubectl get nodes" >&2
  exit 1
fi

if [ -n "$CORDONED" ]; then
  echo "FAIL: the following node(s) are still cordoned (SchedulingDisabled):" >&2
  echo "$CORDONED" >&2
  echo "Run: kubectl uncordon <node>" >&2
  exit 1
fi

echo "OK: all nodes are schedulable."
