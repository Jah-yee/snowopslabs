#!/bin/sh
# The hand fix from solution.md, for the cluster suite: let the namespace's
# pods reach cluster DNS, keeping the rest of the egress baseline.
set -eu
kubectl -n "$WORKLOAD_NAMESPACE" patch networkpolicy default-deny-egress --type=json -p \
  '[{"op":"add","path":"/spec/egress/-","value":{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}}]'
