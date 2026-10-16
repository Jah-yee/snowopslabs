#!/usr/bin/env bash
set -euo pipefail

# Create a kind (Kubernetes IN Docker) cluster - a headless, CI-friendly local
# runtime. Mirrors k3d's host-port exposure: the control-plane node
# maps host 80/443 -> node 80/443 via extraPortMappings, and is labelled
# `ingress-ready=true` so an ingress controller can bind those ports. This keeps
# platform scripts runtime-agnostic.
#
# Config (env, with defaults - scripts never source .env themselves):
#   CLUSTER_NAME     cluster name (default: snowops-kind)
#   HTTP_PORT        host port mapped to node :80 (default: 80)
#   HTTPS_PORT       host port mapped to node :443 (default: 443)
#   AGENTS           number of worker nodes (default: 1)
#   KIND_NODE_IMAGE  pin the node image, e.g. kindest/node:v1.29.4 (default: kind's)

CLUSTER_NAME="${1:-${CLUSTER_NAME:-snowops-kind}}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
AGENTS="${AGENTS:-1}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"

for bin in docker kind kubectl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' is required but not installed." >&2
    echo "       kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" >&2
    exit 1
  fi
done

# shellcheck source=../_lib/docker.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib/docker.sh"

ensure_docker_running || exit 1

# An existing cluster is only usable if its kubeconfig entry is present and its
# API answers. A cluster whose containers linger but whose context was removed
# (e.g. a kubeconfig reset) would make `kubectl config use-context` abort the
# whole run under `set -e`. Heal the kubeconfig, skip creation only when the API
# is reachable, and recreate a broken cluster rather than failing every later
# step (mirrors runtimes/k3d/up.sh).
REACHABLE_WAIT="${REACHABLE_WAIT:-180}"
kind_reachable() {
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1 &&
    kubectl --request-timeout=20s get --raw=/healthz >/dev/null 2>&1
}
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists - checking it is healthy."
  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  # A stopped Docker VM stops the node containers; start them again.
  for node in $(docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}' 2>/dev/null); do
    docker start "$node" >/dev/null 2>&1 || true
  done
  waited=0
  until kind_reachable; do
    if [ "$waited" -ge "$REACHABLE_WAIT" ]; then
      # The cluster holds the user's lab, so it is left in place; 'labctl reset' rebuilds it.
      echo "ERROR: cluster '$CLUSTER_NAME' exists but its API server is not answering." >&2
      echo "  To rebuild the lab from scratch (this loses its apps and scenarios): labctl reset" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "Cluster '$CLUSTER_NAME' is healthy; skipping creation."
  record_ingress_ports "$CLUSTER_NAME" "${CLUSTER_NAME}-control-plane"
  exit 0
fi

if name_used_by k3d "$CLUSTER_NAME"; then
  echo "ERROR: a k3d cluster named '$CLUSTER_NAME' already exists on this machine." >&2
  echo "  Lab names are unique per machine. Set CLUSTER_NAME to another name in .env (kind's default is snowops-kind), then 'labctl init'." >&2
  exit 1
fi

# Fall back to free host ports when the defaults are already bound (e.g. another
# cluster is running). Keeps the golden path on 80/443 untouched.
http_port="$(pick_port "$HTTP_PORT" 8080)" || exit 1
https_port="$(pick_port "$HTTPS_PORT" 8443)" || exit 1
if [ "$http_port" != "$HTTP_PORT" ] || [ "$https_port" != "$HTTPS_PORT" ]; then
  echo "Host ports ${HTTP_PORT}/${HTTPS_PORT} are already in use (another cluster or service)."
  echo "Exposing ingress on ${http_port}/${https_port} instead - reach services at" \
    "http://<name>.${DOMAIN_SUFFIX:-${CLUSTER_NAME}.localhost}:${http_port}"
  HTTP_PORT="$http_port"
  HTTPS_PORT="$https_port"
fi

# Build the kind config. The control-plane node carries the ingress-ready label
# and the host port mappings; worker nodes (AGENTS) give day-2 drills somewhere
# to reschedule pods.
node_image_line=""
if [ -n "$KIND_NODE_IMAGE" ]; then
  node_image_line="  image: ${KIND_NODE_IMAGE}"
fi

config_file="$(mktemp)"
trap 'rm -f "$config_file"' EXIT

{
  echo "kind: Cluster"
  echo "apiVersion: kind.x-k8s.io/v1alpha4"
  echo "nodes:"
  echo "  - role: control-plane"
  [ -n "$node_image_line" ] && echo "$node_image_line"
  echo "    kubeadmConfigPatches:"
  echo "      - |"
  echo "        kind: InitConfiguration"
  echo "        nodeRegistration:"
  echo "          kubeletExtraArgs:"
  echo '            node-labels: "ingress-ready=true"'
  echo "    extraPortMappings:"
  echo "      - containerPort: 80"
  echo "        hostPort: ${HTTP_PORT}"
  echo "        protocol: TCP"
  echo "      - containerPort: 443"
  echo "        hostPort: ${HTTPS_PORT}"
  echo "        protocol: TCP"
  i=0
  while [ "$i" -lt "$AGENTS" ]; do
    echo "  - role: worker"
    [ -n "$node_image_line" ] && echo "$node_image_line"
    i=$((i + 1))
  done
} >"$config_file"

echo "Creating kind cluster '$CLUSTER_NAME' (control-plane + ${AGENTS} worker(s))..."
kind create cluster --name "$CLUSTER_NAME" --config "$config_file" --wait 120s

kubectl config use-context "kind-$CLUSTER_NAME"
record_ingress_ports "$CLUSTER_NAME" "${CLUSTER_NAME}-control-plane"

echo ""
echo "kind cluster '$CLUSTER_NAME' is ready."
echo "  Host ports ${HTTP_PORT}/${HTTPS_PORT} -> ingress on the control-plane node."
echo "  Install ingress: labctl platform up ingress"
