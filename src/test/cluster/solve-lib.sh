#!/bin/sh
# Helpers for test/solve.sh scripts: the cluster suite runs them with
# WORKLOAD_NAME, WORKLOAD_NAMESPACE, PROJECT_ROOT and LABCTL set.

# wait_until <seconds> <what> <command...> runs the command every
# SOLVE_POLL_SECONDS (default 5) until it succeeds, and fails naming <what>
# once <seconds> have passed.
wait_until() {
  limit=$1 what=$2
  shift 2
  poll=${SOLVE_POLL_SECONDS:-5}
  waited=0
  until "$@"; do
    if [ "$waited" -ge "$limit" ]; then
      echo "$what did not happen within ${limit}s" >&2
      return 1
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
}

# render <scenario> <path> prints one of the scenario's files rendered for
# the bound workload, as the learner copies it from the UI.
render() {
  "${LABCTL:-labctl}" scenario render "$1" "$2" --app "$WORKLOAD_NAME"
}

# prom <query> prints the value of an instant query, read through the lab's
# ingress the way the scenarios' checks read it.
prom() {
  url="${PROMETHEUS_URL:-http://prometheus.${INGRESS_URL_SUFFIX:-${DOMAIN_SUFFIX:-${CLUSTER_NAME:-snowops}.localhost}}}"
  curl -s -m 20 --get "$url/api/v1/query" --data-urlencode "query=$1" |
    sed -n 's/.*"value":\[[^,]*,"\([^"]*\)".*/\1/p' | head -1
}

# at_least <query> <n> succeeds when the query answers n or more.
at_least() {
  value=$(prom "$1")
  [ -n "$value" ] && awk -v v="$value" -v n="$2" 'BEGIN { exit !(v + 0 >= n + 0) }'
}
