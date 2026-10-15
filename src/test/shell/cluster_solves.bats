#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The scenarios' test/solve.sh scripts and the library they share. Each solve
# runs against a scratch project root that holds the real solve library and
# stand-ins for the item's own helper scripts, so a test asserts what the
# solve does: the commands it runs, in order, and where it gives up.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  SCRATCH="$BATS_TEST_TMPDIR/root"
  mkdir -p "$SCRATCH/src/test/cluster"
  cp "$ROOT/src/test/cluster/solve-lib.sh" "$SCRATCH/src/test/cluster/"
  export WORKLOAD_NAME=go-api WORKLOAD_NAMESPACE=go-api PROJECT_ROOT="$SCRATCH"
  export LABCTL="$STUB_BIN/labctl" APPLIED="$BATS_TEST_TMPDIR/applied"
  # A large poll with sleep stubbed: a wait that never succeeds gives up after
  # a few polls instead of spinning.
  export SOLVE_POLL_SECONDS=100
  stub_script sleep <<'STUB'
exit 0
STUB
  # labctl renders a file as a marker naming it; verify fails unless told.
  stub_script labctl <<'STUB'
case "$*" in
  "scenario render "*) echo "rendered: $4" ;;
  "scenario verify "*) [ "${VERIFY_PASSES:-no}" = yes ] ;;
esac
STUB
}

teardown() { stub_teardown; }

# solve_copy <scenario> copies the solve into the scratch root, so it finds
# the scratch library and the stand-in scripts.
solve_copy() {
  mkdir -p "$SCRATCH/scenarios/$1/test" "$SCRATCH/scenarios/$1/scripts"
  cp "$ROOT/scenarios/$1/test/solve.sh" "$SCRATCH/scenarios/$1/test/solve.sh"
  SOLVE="$SCRATCH/scenarios/$1/test/solve.sh"
}

# fake_script <scenario> <script> stands in for one of the item's scripts and
# records its arguments, with any VAR it is told to report.
fake_script() {
  printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" %s "$*" >>"$STUB_LOG"\n%s\n' "$2" "${3:-}" \
    >"$SCRATCH/scenarios/$1/scripts/$2"
  chmod +x "$SCRATCH/scenarios/$1/scripts/$2"
}

# kubectl_with records what `kubectl apply -f -` was fed, then runs the
# rest of the stub body given on stdin.
kubectl_with() {
  {
    printf 'case "$*" in "apply -f -") cat >>"$APPLIED"; exit 0 ;; esac\n'
    cat
  } | stub_script kubectl
}

# in_order <name> <substring>... fails unless the calls appear in that order.
in_order() {
  local name="$1" last=0 n
  shift
  for want in "$@"; do
    n=$(calls_for "$name" | tail -n "+$((last + 1))" | grep -n -F -- "$want" | head -1 | cut -d: -f1)
    [ -n "$n" ] || { echo "no $name call with '$want' after the previous step"; return 1; }
    last=$((last + n))
  done
}

# ── solve-lib ────────────────────────────────────────────────────────────────

@test "wait_until retries until the command succeeds" {
  export COUNT="$BATS_TEST_TMPDIR/count"
  echo 0 >"$COUNT"
  third_time() { n=$(($(cat "$COUNT") + 1)); echo "$n" >"$COUNT"; [ "$n" -ge 3 ]; }
  . "$SCRATCH/src/test/cluster/solve-lib.sh"
  SOLVE_POLL_SECONDS=1 wait_until 10 "the third try" third_time
  [ "$(cat "$COUNT")" -eq 3 ]
}

@test "wait_until gives up after its limit, naming what never happened" {
  . "$SCRATCH/src/test/cluster/solve-lib.sh"
  run wait_until 250 "the moon landing" false
  [ "$status" -ne 0 ]
  [[ "$output" == *"the moon landing did not happen within 250s"* ]] || false
}

@test "at_least compares the query's answer, and an empty answer is not enough" {
  stub_script curl <<'STUB'
[ -n "$PROM_VALUE" ] && printf '{"data":{"result":[{"value":[1,"%s"]}]}}' "$PROM_VALUE"
exit 0
STUB
  . "$SCRATCH/src/test/cluster/solve-lib.sh"
  PROM_VALUE=1500 at_least 'q' 1500
  PROM_VALUE=1499.5 run at_least 'q' 1500
  [ "$status" -ne 0 ]
  PROM_VALUE="" run at_least 'q' 0
  [ "$status" -ne 0 ]
}

# ── autoscaling-under-load ───────────────────────────────────────────────────

@test "autoscaling: applies the ScaledObject, drives the spike, waits for a scale-up" {
  solve_copy autoscaling-under-load
  export REPLICAS_FILE="$BATS_TEST_TMPDIR/replicas"
  echo 1 >"$REPLICAS_FILE"
  kubectl_with <<'STUB'
case "$*" in
  *currentReplicas*) cat "$REPLICAS_FILE"; echo 3 >"$REPLICAS_FILE" ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  grep -q "rendered: manifests/scaledobject.yaml" "$APPLIED"
  assert_called labctl "traffic start --app go-api --profile spike --rps 10"
  [ "$(call_count kubectl currentReplicas)" -eq 2 ]
}

@test "autoscaling: fails when KEDA never scales the workload" {
  solve_copy autoscaling-under-load
  kubectl_with <<'STUB'
case "$*" in *currentReplicas*) echo 1 ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"go-api scaling above one replica did not happen"* ]] || false
}

# ── backup-restore-drill ─────────────────────────────────────────────────────

backup_root() {
  solve_copy backup-restore-drill
  cp "$ROOT/scenarios/backup-restore-drill/scripts/_backup_lib.sh" "$SCRATCH/scenarios/backup-restore-drill/scripts/"
  export BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$BACKUP_DIR"
  fake_script backup-restore-drill backup.sh 'echo "2026-10-14T10:00:00Z old-boot" >"$BACKUP_DIR/go-api-bootid.log"'
  fake_script backup-restore-drill restore.sh
}

@test "backup-restore: backs up, proves the loss, restores, then replaces the volume" {
  backup_root
  kubectl_with <<'STUB'
case "$*" in
  *"get pod"*) echo data-writer-1 ;;
  *"exec data-writer-1"*) echo new-boot ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  assert_called backup.sh "go-api"
  assert_called labctl "scenario verify backup-restore-drill"
  in_order kubectl "delete configmap restore-marker" \
    "apply --server-side --force-conflicts -f $BACKUP_DIR/go-api-latest.json" \
    "delete deploy data-writer" "delete pvc restore-data"
  assert_called restore.sh "go-api"
}

@test "backup-restore: stops when verify passes with the marker deleted" {
  backup_root
  kubectl_with <<'STUB'
case "$*" in
  *"get pod"*) echo data-writer-1 ;;
  *"exec data-writer-1"*) echo old-boot ;;
esac
exit 0
STUB
  VERIFY_PASSES=yes run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verify passed with the restore marker deleted"* ]] || false
  refute_called kubectl "apply --server-side"
}

@test "backup-restore: fails when the backup recorded no boot-id to compare against" {
  backup_root
  fake_script backup-restore-drill backup.sh
  kubectl_with <<'STUB'
case "$*" in
  *"get pod"*) echo data-writer-1 ;;
  *"exec data-writer-1"*) echo new-boot ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the backup recorded no boot-id"* ]] || false
  refute_called kubectl "delete pvc"
}

@test "backup-restore: waits for the data-writer before it backs up" {
  backup_root
  kubectl_with <<'STUB'
case "$*" in *"get pod"*) exit 0 ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the data-writer serving a boot-id did not happen"* ]] || false
  refute_called backup.sh
}

@test "backup-restore: fails when the restored volume still holds the old data" {
  backup_root
  kubectl_with <<'STUB'
case "$*" in
  *"get pod"*) echo data-writer-1 ;;
  *"exec data-writer-1"*) echo old-boot ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a boot-id from a new volume did not happen"* ]] || false
}

# ── chaos-engineering ────────────────────────────────────────────────────────

@test "chaos: kills a pod, hardens to three replicas, verifies, and re-runs the experiment" {
  solve_copy chaos-engineering
  fake_script chaos-engineering inject.sh
  kubectl_with <<'STUB'
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  assert_called labctl "traffic start --app go-api --profile browse --rps 20"
  [ "$(call_count inject.sh "pod-kill --app go-api --namespace go-api")" -eq 2 ]
  in_order kubectl "-n go-api scale deploy/go-api --replicas=3" "rollout status deploy/go-api" \
    "delete podchaos pod-kill-go-api -n go-api"
  in_order labctl "traffic start" "scenario verify chaos-engineering"
}

@test "chaos: stops when verify passes before the hardened service is re-tested" {
  solve_copy chaos-engineering
  fake_script chaos-engineering inject.sh
  kubectl_with <<'STUB'
exit 0
STUB
  VERIFY_PASSES=yes run "$SOLVE"
  [ "$status" -ne 0 ]
  [ "$(call_count inject.sh pod-kill)" -eq 1 ]
}

# ── cluster-upgrade-drill ────────────────────────────────────────────────────

@test "cluster-upgrade: rolls every worker onto the control plane's version, one at a time" {
  solve_copy cluster-upgrade-drill
  fake_script cluster-upgrade-drill roll-node.sh 'echo "target=$TARGET_K3S_VERSION" >>"$STUB_LOG"'
  fake_script cluster-upgrade-drill reclaim-stranded-pvcs.sh
  kubectl_with <<'STUB'
case "$*" in
  "get node -l node-role"*) echo "v1.33.6+k3s1" ;;
  "get nodes -l !node-role"*) echo "agent-0 agent-1" ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  grep -q "rendered: manifests/baseline.yaml" "$APPLIED"
  in_order kubectl "cordon agent-0" "drain agent-0 --ignore-daemonsets" "cordon agent-1" "drain agent-1"
  [ "$(grep -c 'target=v1.33.6-k3s1' "$STUB_LOG")" -eq 2 ]
  assert_called roll-node.sh "agent-1"
  assert_called reclaim-stranded-pvcs.sh
  [ "$(call_count labctl "traffic start")" -eq 2 ]
}

@test "cluster-upgrade: fails when there is no worker to roll" {
  solve_copy cluster-upgrade-drill
  fake_script cluster-upgrade-drill roll-node.sh
  kubectl_with <<'STUB'
case "$*" in "get node -l node-role"*) echo "v1.33.6+k3s1" ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worker nodes to roll"* ]] || false
  refute_called kubectl drain
}

# ── event-driven-arch ────────────────────────────────────────────────────────

@test "event-driven: waits for the backlog, then scales consumers to the partition count" {
  solve_copy event-driven-arch
  stub_script curl <<'STUB'
printf '{"data":{"result":[{"value":[1,"1800"]}]}}'
STUB
  kubectl_with <<'STUB'
case "$*" in *"kafkatopic orders"*) echo 3 ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  assert_called curl "kafka_consumergroup_lag"
  assert_called kubectl "-n kafka scale deployment/orders-consumer --replicas=3"
}

@test "event-driven: does not scale before a backlog was seen" {
  solve_copy event-driven-arch
  stub_script curl <<'STUB'
printf '{"data":{"result":[{"value":[1,"200"]}]}}'
STUB
  kubectl_with <<'STUB'
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a backlog of 1500 orders did not happen"* ]] || false
  refute_called kubectl scale
}

# ── gitops-cicd ──────────────────────────────────────────────────────────────

# git clones a seed repo and keeps a copy of each file at every commit.
stub_git() {
  stub_script git <<'STUB'
case "$1" in
  clone)
    mkdir -p "$3/demo" "$3/broken"
    printf 'replicas: 2\nimage: nginx:1.27.3-alpine\n' >"$3/demo/deployment.yaml"
    printf 'kind: Service\n' >"$3/demo/service.yaml"
    printf 'image: nginx:1.27.3-alpine-THIS-TAG-DOES-NOT-EXIST\n' >"$3/broken/deployment.yaml"
    ;;
  rm) rm -f "$2" ;;
  commit)
    n=$(cat "$STUB_DIR/commits" 2>/dev/null || echo 0)
    echo $((n + 1)) >"$STUB_DIR/commits"
    mkdir -p "$STUB_DIR/commit-$n"
    cp -R demo broken "$STUB_DIR/commit-$n/"
    ;;
esac
exit 0
STUB
}

@test "gitops: pushes a new state, watches selfHeal and prune, repairs the broken app in Git" {
  solve_copy gitops-cicd
  stub_git
  kubectl_with <<'STUB'
case "$*" in
  *readyReplicas*) echo 3 ;;
  *"jsonpath={.spec.replicas}"*) echo 3 ;;
  *"get service gitops-demo"*) exit 1 ;;
  *"application gitops-broken -o"*) echo Synced/Healthy ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  grep -q "replicas: 3" "$STUB_DIR/commit-0/demo/deployment.yaml"
  grep -q "nginx:1.27.4-alpine" "$STUB_DIR/commit-0/demo/deployment.yaml"
  [ ! -f "$STUB_DIR/commit-1/demo/service.yaml" ]
  grep -qx "image: nginx:1.27.3-alpine" "$STUB_DIR/commit-2/broken/deployment.yaml"
  [ "$(call_count git "push origin main")" -eq 3 ]
  in_order kubectl "patch application gitops-demo" "rollout status deployment/gitops-demo" \
    "scale deployment/gitops-demo --replicas=7" "patch application gitops-demo" "patch application gitops-broken"
}

@test "gitops: fails when ArgoCD never reverts a hand-scaled Deployment" {
  solve_copy gitops-cicd
  stub_git
  kubectl_with <<'STUB'
case "$*" in
  *readyReplicas*) echo 3 ;;
  *"jsonpath={.spec.replicas}"*) echo 7 ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ArgoCD reverting gitops-demo to 3 replicas did not happen"* ]] || false
  [ "$(call_count git "push origin main")" -eq 1 ]
}

# ── mesh-traffic-management ──────────────────────────────────────────────────

@test "mesh: applies the split, then the fault route, then STRICT mTLS" {
  solve_copy mesh-traffic-management
  kubectl_with <<'STUB'
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  [ "$(cat "$APPLIED")" = "$(printf 'rendered: manifests/virtualservice.yaml\nrendered: manifests/fault-injection.yaml\nrendered: manifests/peerauthentication.yaml')" ]
}

# ── node-drain-drill ─────────────────────────────────────────────────────────

drain_cluster() {
  kubectl_with <<'STUB'
case "$*" in
  "-n go-api get pods -o"*) printf 'agent-0\nagent-1\nserver-0\n' ;;
  "get node server-0"*) echo '{"node-role.kubernetes.io/control-plane":"true"}' ;;
  "get node "*) echo '{"kubernetes.io/os":"linux"}' ;;
  *"app.kubernetes.io/name=prometheus"*) echo "${PROMETHEUS_ON:-agent-0}" ;;
esac
exit 0
STUB
}

@test "node-drain: drains a worker with the workload, never the node Prometheus runs on" {
  solve_copy node-drain-drill
  drain_cluster
  run "$SOLVE"
  [ "$status" -eq 0 ]
  grep -q "rendered: manifests/baseline.yaml" "$APPLIED"
  in_order kubectl "cordon agent-1" "drain agent-1 --ignore-daemonsets --delete-emptydir-data" \
    "rollout status deploy/go-api" "uncordon agent-1"
  refute_called kubectl "drain agent-0"
  refute_called kubectl "drain server-0"
}

@test "node-drain: fails rather than drain Prometheus when it shares every worker with the workload" {
  solve_copy node-drain-drill
  drain_cluster
  PROMETHEUS_ON="agent-0 agent-1" run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"also runs Prometheus"* ]] || false
  refute_called kubectl drain
}

# ── observability-sre ────────────────────────────────────────────────────────

@test "observability: wires tracing, drives load, fails readiness until an alert fires, restores it" {
  solve_copy observability-sre
  fake_script observability-sre enable-tracing.sh
  stub_script curl <<'STUB'
printf '{"data":{"result":[{"value":[1,"1"]}]}}'
STUB
  kubectl_with <<'STUB'
case "$*" in
  *"get pods"*) echo go-api-abc ;;
  *containerPort*) echo 8080 ;;
esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  assert_called enable-tracing.sh "--app go-api --namespace go-api"
  assert_called labctl "traffic start --app go-api --profile steady --rps 25"
  [ "$(call_count kubectl "exec go-api-abc -- wget -qO- localhost:8080/toggle-failure")" -eq 2 ]
}

@test "observability: leaves readiness failing and says so when no alert fires" {
  solve_copy observability-sre
  fake_script observability-sre enable-tracing.sh
  stub_script curl <<'STUB'
printf '{"data":{"result":[{"value":[1,"0"]}]}}'
STUB
  kubectl_with <<'STUB'
case "$*" in *"get pods"*) echo go-api-abc ;; *containerPort*) echo 8080 ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a scenario alert firing did not happen"* ]] || false
}

# ── security-compliance ──────────────────────────────────────────────────────

@test "security: fixes the workload, enforces, exempts legacy, serves the lab certificate" {
  solve_copy security-compliance
  kubectl_with <<'STUB'
case "$*" in *"get ingress go-api"*) echo go-api.snowops.localhost ;; esac
exit 0
STUB
  run "$SOLVE"
  [ "$status" -eq 0 ]
  in_order kubectl "patch deployment go-api --type=json" "patch clusterpolicy deny-privilege-escalation" \
    "patch clusterpolicy require-non-root-user" "rollout restart deployment/legacy-reporter" \
    "wait certificate/go-api-tls --for=condition=Ready" "patch ingress go-api"
  assert_called kubectl "runAsNonRoot"
  assert_called kubectl 'go-api.snowops.localhost'
  assert_called kubectl '"secretName":"go-api-tls-secret"'
  [ "$(head -1 "$APPLIED")" = "rendered: manifests/policy-exception.yaml" ]
  [ "$(tail -1 "$APPLIED")" = "rendered: manifests/workload-tls-certificate.yaml" ]
}

@test "every scenario has a solve script" {
  for dir in "$ROOT"/scenarios/*/; do
    [ -f "$dir/scenario.yaml" ] || continue
    [ -x "$dir/test/solve.sh" ] || { echo "$(basename "$dir") has no test/solve.sh"; false; }
  done
}
