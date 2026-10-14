#!/bin/sh
# The drill a learner walks, for the cluster suite: watch the backlog the
# ramped producers build, read how many partitions 'orders' has, and scale the
# consumer group to exactly that many so the backlog drains.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"

# The scenario grades that the backlog was seen before it was fixed.
wait_until 420 "a backlog of 1500 orders" at_least \
  'sum(kafka_consumergroup_lag{consumergroup="order-processors",topic="orders"})' 1500
partitions=$(kubectl -n kafka get kafkatopic orders -o 'jsonpath={.spec.partitions}')
[ -n "$partitions" ] || {
  echo "could not read the partition count of topic 'orders'" >&2
  exit 1
}
kubectl -n kafka scale deployment/orders-consumer "--replicas=$partitions"
kubectl -n kafka rollout status deployment/orders-consumer --timeout=180s
