#!/bin/sh
# The drill a learner walks, for the cluster suite: build a newer release,
# promote it through dev, staging and prod with each env's release record,
# then roll prod back from a release that cannot land.
set -eu
app="${WORKLOAD_NAME:-go-api}"
ns="${WORKLOAD_NAMESPACE:-$app}"

for env_name in dev staging prod; do
  kubectl -n "env-$env_name" rollout status "deployment/$app" --timeout=180s
done

bash "$PROJECT_ROOT/scenarios/env-promotion/scripts/build-image.sh" v1.1.0 --app "$app" --namespace "$ns"
promoted_from=""
for env_name in dev staging prod; do
  kubectl -n "env-$env_name" set image "deployment/$app" "$app=$app:v1.1.0"
  kubectl -n "env-$env_name" rollout status "deployment/$app" --timeout=180s
  kubectl -n "env-$env_name" patch cm env-metadata --type=merge \
    -p "{\"data\":{\"declared_tag\":\"v1.1.0\",\"promoted_from\":\"$promoted_from\",\"promoted_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  promoted_from="$env_name"
done

# Undo must return to v1.1.0, so wait until the v9.9.9 ReplicaSet exists.
kubectl -n env-prod set image "deployment/$app" "$app=$app:v9.9.9"
waited=0
until kubectl -n env-prod get rs -o 'jsonpath={.items[*].spec.template.spec.containers[0].image}' | grep -q "$app:v9.9.9"; do
  [ "$waited" -lt 60 ] || {
    echo "the v9.9.9 ReplicaSet never appeared" >&2
    exit 1
  }
  sleep 1
  waited=$((waited + 1))
done
kubectl -n env-prod rollout undo "deployment/$app"
kubectl -n env-prod rollout status "deployment/$app" --timeout=180s
