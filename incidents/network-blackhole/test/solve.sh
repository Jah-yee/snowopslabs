#!/bin/sh
# The hand fix from solution.md, for the cluster suite: delete the policy that
# denies all ingress.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" delete networkpolicy default-deny-ingress
