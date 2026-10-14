#!/bin/sh
# The drill a learner walks, for the cluster suite: apply the weighted canary
# split, replace it with the route that also delays opted-in requests, and
# enforce STRICT mTLS on the canary. The staged client supplies the traffic.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
for manifest in virtualservice fault-injection peerauthentication; do
  render mesh-traffic-management "manifests/$manifest.yaml" | kubectl apply -f -
done
