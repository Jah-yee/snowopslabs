#!/usr/bin/env bash
# Shared helpers for reading a workload's shape in fault scripts and checks.
#
# Sourced, not executed:
#   . "$(cd "$(dirname "$0")/../_lib" && pwd)/workload.sh"

# workload_selector <namespace> <deployment>: print the Deployment's pod
# selector as "key=value,key=value", the form `kubectl get pods -l` takes.
# The Deployment's own selector finds its pods whatever labels the app's chart
# uses; a guessed label misses a bound workload's pods.
workload_selector() {
  kubectl -n "$1" get deploy "$2" \
    -o 'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null |
    sed 's/,$//' || true
}

# cpu_millicores <quantity>: print a Kubernetes CPU quantity ("2", "1.5",
# "250m") in millicores, or nothing when it is empty or unreadable.
cpu_millicores() {
  awk -v q="${1:-}" 'BEGIN {
    if (q ~ /^[0-9]+m$/)                { sub(/m$/, "", q); printf "%d", q }
    else if (q ~ /^[0-9]+(\.[0-9]+)?$/) { printf "%d", q * 1000 }
  }'
}
