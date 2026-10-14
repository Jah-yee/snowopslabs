#!/bin/sh
# The drill a learner walks, for the cluster suite: put the workload under
# steady load, read its peak CPU and memory from Prometheus, and set requests
# with headroom above the peak and under the scenario's waste ceilings.
set -eu
. "$PROJECT_ROOT/scenarios/cost-right-sizing/scripts/_prom.sh"
ns="$WORKLOAD_NAMESPACE"
app="$WORKLOAD_NAME"

"${LABCTL:-labctl}" traffic start --app "$app" --profile steady --rps 25 --duration 30m

# The sizing floor is a peak under load, so wait until the load registers
# the way the scenario's workload-under-load check measures it.
metric="${WORKLOAD_METRIC:-http_server_request_duration_seconds}"
waited=0
until [ "$(prom_scalar "sum(rate(${metric}_count{app=\"$app\"}[5m])) or vector(0)" | cut -d. -f1)" -ge 5 ] 2>/dev/null; do
  [ "$waited" -lt 300 ] || {
    echo "the workload never reached 5 requests a second under traffic" >&2
    exit 1
  }
  sleep 15
  waited=$((waited + 15))
done
sleep 120

cpu=$(prom_scalar "max_over_time((sum(rate(container_cpu_usage_seconds_total{namespace=\"$ns\",container=\"$app\"}[1m])) or vector(0))[${USAGE_WINDOW}:1m])")
mem=$(prom_scalar "max_over_time((max(container_memory_working_set_bytes{namespace=\"$ns\",container=\"$app\"}) or vector(0))[${USAGE_WINDOW}:1m])")
[ -n "$cpu" ] && [ -n "$mem" ] || {
  echo "Prometheus returned no usage for $ns/$app" >&2
  exit 1
}

# Twice the peak, at least 20m or 16Mi above it, and never over the ceilings.
cpu_m=$(echo "$cpu" | awk '{p = $1 * 1000; r = p * 2; if (r < p + 20) r = p + 20; if (r > 100) r = 100; printf "%d", r}')
mem_mi=$(echo "$mem" | awk '{p = $1 / 1048576; r = p * 2; if (r < p + 16) r = p + 16; if (r > 256) r = 256; printf "%d", r}')
kubectl -n "$ns" set resources "deployment/$app" "--requests=cpu=${cpu_m}m,memory=${mem_mi}Mi"
kubectl -n "$ns" rollout status "deployment/$app" --timeout=180s
