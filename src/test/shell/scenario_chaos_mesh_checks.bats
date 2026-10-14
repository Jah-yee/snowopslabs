#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Grading scripts of chaos-engineering and mesh-traffic-management. Each is run
# against the lab before the work, the solved lab, and the states that look
# solved without the property being true.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop
  export PROMETHEUS_URL=http://prometheus.lab.test
  NOW_S="$(date -u +%s)"
  stub_script kubectl <<'STUB'
case "$*" in
  *"apply"*"-f -"*) cat >>"$STUB_DIR/applied.yaml" ;;

  # chaos-engineering
  *"get deploy cart -o jsonpath={.status.readyReplicas}"*) printf '%s' "${READY-1}" ;;
  *"get configmap chaos-steady-state"*) printf '%s' "${HARDENED-}" ;;
  *"get configmap chaos-experiment-witness"*"last-seen"*) printf '%s' "${LAST_EXP-}" ;;
  *"get configmap chaos-experiment-witness"*"first-seen"*) printf '%s' "${FIRST_EXP-}" ;;
  *"get configmap chaos-experiment-witness"*"detail"*) printf '%s' "${EXP_DETAIL-}" ;;
  *"get podchaos,networkchaos,stresschaos"*) printf '%s' "${EXPERIMENTS-}" ;;
  *"create configmap"*) echo "kind: ConfigMap" ;;

  # mesh-traffic-management
  *"get pods -l app=cart-canary"*"-o name"*) [ -z "${CANARY-set}" ] || echo "pod/cart-canary-abc" ;;
  *"get pods -l app=cart-canary"*) [ -z "${CANARY-set}" ] || printf '%s\n' "${CANARY-cart-canary-abc=app istio-proxy}" ;;
  *"wait --for=condition=complete"*) [ "${PLAINTEXT:-refused}" = refused ] || exit 1 ;;
  *"logs job/cart-mtls-probe"*) echo "SERVED: plaintext from an unmeshed client was accepted" ;;
esac
exit 0
STUB
  # Prometheus: the floor query and the current-rate query answer separately.
  stub_script curl <<'STUB'
case "$*" in
  *min_over_time*) v="${FLOOR-}" ;;
  *) v="${RATE-}" ;;
esac
[ -z "$v" ] || printf '{"status":"success","data":{"result":[{"value":[1700000000,"%s"]}]}}' "$v"
STUB
}

teardown() {
  stub_teardown
}

check() {
  run bash "$ROOT/scenarios/$1"
}

# ── chaos-engineering: an experiment was run ──────────────────────────────────

@test "experiment-was-run is pending when no experiment has ever been seen" {
  check chaos-engineering/checks/experiment-was-run.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no chaos experiment has been seen in shop"* ]] || false
  refute_called kubectl "create configmap"
}

@test "experiment-was-run passes on a live experiment and records having seen it" {
  EXPERIMENTS="PodChaos/pod-kill-cart " check chaos-engineering/checks/experiment-was-run.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"PodChaos/pod-kill-cart"* ]] || false
  assert_called kubectl "create configmap chaos-experiment-witness"
}

@test "experiment-was-run keeps the first sighting when it records a later one" {
  FIRST_EXP=1700000000 EXPERIMENTS="PodChaos/pod-kill-cart " check chaos-engineering/checks/experiment-was-run.sh
  assert_called kubectl "--from-literal=first-seen=1700000000"
}

@test "experiment-was-run passes from the record after the experiment is cleaned up" {
  FIRST_EXP=1700000000 EXP_DETAIL="experiment(s) observed against shop: PodChaos/pod-kill-cart" \
    check chaos-engineering/checks/experiment-was-run.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"have since been cleaned up"* ]] || false
}

# ── chaos-engineering: the blast radius is contained ──────────────────────────

# hardened sets three ready replicas, hardened ten minutes ago, an experiment
# run since, steady traffic and a request rate that never reached zero.
hardened() {
  export READY=3 HARDENED="$((NOW_S - 600))" LAST_EXP="$((NOW_S - 300))" RATE=18.4 FLOOR=9.2
}

@test "blast-radius-contained is pending on the single replica activation leaves" {
  check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 ready replica(s)"* ]] || false
}

@test "blast-radius-contained passes a hardened service that kept serving through the experiment" {
  hardened
  check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"never reached zero in the 10 minute(s)"* ]] || false
}

@test "blast-radius-contained is pending when the experiment was not repeated after hardening" {
  hardened
  LAST_EXP="$((NOW_S - 900))" check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no experiment has been run since"* ]] || false

  LAST_EXP="" check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -ne 0 ]
}

@test "blast-radius-contained is pending without load to measure" {
  hardened
  for rate in "" 0 0.4; do
    RATE="$rate" check chaos-engineering/checks/blast-radius-contained.sh
    [ "$status" -ne 0 ] || { echo "rate '$rate' passed"; return 1; }
    [[ "$output" == *"almost no requests"* ]] || false
  done
}

@test "blast-radius-contained is pending when hardening is too recent to measure" {
  hardened
  HARDENED="$((NOW_S - 30))" LAST_EXP="$((NOW_S - 10))" check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"too recent to measure"* ]] || false
}

@test "blast-radius-contained fails when the request rate hit zero after hardening" {
  hardened
  for floor in 0 0.0 ""; do
    FLOOR="$floor" check chaos-engineering/checks/blast-radius-contained.sh
    [ "$status" -ne 0 ] || { echo "floor '$floor' passed"; return 1; }
    [[ "$output" == *"hit zero"* ]] || false
  done
}

@test "blast-radius-contained measures at most the last fifteen minutes" {
  hardened
  HARDENED="$((NOW_S - 7200))" check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"in the 15 minute(s)"* ]] || false
}

@test "blast-radius-contained stamps the moment it first sees the service hardened" {
  READY=3 check chaos-engineering/checks/blast-radius-contained.sh
  [ "$status" -ne 0 ]
  assert_called kubectl "patch configmap chaos-steady-state"
}

# ── mesh-traffic-management: sidecars injected ────────────────────────────────

@test "sidecars-injected passes when every running canary pod has the proxy" {
  CANARY="$(printf 'cart-canary-a=app istio-proxy\ncart-canary-b=istio-proxy app')" \
    check mesh-traffic-management/checks/sidecars-injected.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 2 Running canary pod(s)"* ]] || false
}

@test "sidecars-injected fails naming the pods the mesh cannot see" {
  CANARY="$(printf 'cart-canary-a=app istio-proxy\ncart-canary-b=app')" \
    check mesh-traffic-management/checks/sidecars-injected.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no istio-proxy sidecar: cart-canary-b"* ]] || false
  [[ "$output" != *"cart-canary-a"* ]] || false
}

@test "sidecars-injected fails when no canary pod is running" {
  CANARY="" check mesh-traffic-management/checks/sidecars-injected.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Running canary pods"* ]] || false
}

# ── mesh-traffic-management: plaintext is refused ─────────────────────────────

@test "mtls-rejects-plaintext passes when an unmeshed client is refused, and removes its probe" {
  check mesh-traffic-management/checks/mtls-rejects-plaintext.sh
  [ "$status" -eq 0 ]
  grep -q 'sidecar.istio.io/inject: "false"' "$STUB_DIR/applied.yaml"
  grep -q 'value: "http://cart-canary.shop.svc.cluster.local"' "$STUB_DIR/applied.yaml"
  assert_called kubectl "delete job cart-mtls-probe --ignore-not-found --wait=false"
}

@test "mtls-rejects-plaintext fails while plaintext is served, showing the probe's output" {
  PLAINTEXT=served check mesh-traffic-management/checks/mtls-rejects-plaintext.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT refused"* ]] || false
  [[ "$output" == *"SERVED: plaintext"* ]] || false
}

@test "mtls-rejects-plaintext does not take a canary that is down for a refusal" {
  CANARY="" check mesh-traffic-management/checks/mtls-rejects-plaintext.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to refuse a client"* ]] || false
  refute_called kubectl "apply"
}
