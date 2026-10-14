#!/usr/bin/env bash
set -euo pipefail

# Teardown, in the one order that does not wedge.
#
# ArgoCD's resources-finalizer cascades a delete through everything an
# Application manages. If the controller is uninstalled before that finalizer
# runs, the delete never completes and the namespace hangs in Terminating
# forever. So: delete the Application first, while the controller is still
# alive, then remove what it managed explicitly.

for app in gitops-demo gitops-broken; do
  kubectl -n argocd get application "$app" >/dev/null 2>&1 || continue
  echo "Removing the ${app} Application..."
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl -n argocd delete application "$app" --ignore-not-found --timeout=60s || true
done

echo "Removing the workloads those Applications managed..."
kubectl delete namespace gitops-demo gitops-broken --ignore-not-found --timeout=120s || true

# The deletes above are allowed to fail so every one is tried; what decides
# the outcome is whether the namespaces are gone.
left=""
for ns in gitops-demo gitops-broken; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    left="$left $ns"
  fi
done
if [ -n "$left" ]; then
  echo "Still present:$left. Re-run 'labctl scenario down gitops-cicd' once the cluster answers." >&2
  exit 1
fi
echo "✓ gitops-demo and gitops-broken removed"
