#!/bin/sh
# The drill a learner walks, for the cluster suite: rotate the workload's API
# key in Vault and touch nothing in Kubernetes. ESO and the kubelet carry the
# new value into the running pod's mounted file; verify --watch waits for it.
set -eu
token="${VAULT_DEV_ROOT_TOKEN:-root}"
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='$token' vault kv patch secret/$WORKLOAD_NAME api-key=rotated-$(date +%s)"
