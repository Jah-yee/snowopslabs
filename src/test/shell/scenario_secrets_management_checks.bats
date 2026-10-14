#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# secrets-management grades a rotation that reaches a running pod without a
# redeploy. Each check is run against the lab as activation leaves it, the
# solved lab, and the shortcuts that produce the right value the wrong way.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  CHECKS="$ROOT/scenarios/secrets-management/checks"
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop
  unset SECRETS_BASELINE_VALUE
  # The lab right after activation: Vault, the file and the env var all hold
  # the baseline, and the consumer pod is the one the checkpoint recorded.
  export VAULT_VALUE=baseline-v1 FILE_VALUE=baseline-v1 ENV_VALUE=baseline-v1
  export CHECKPOINT_baseline=baseline-v1 CHECKPOINT_consumer_pod_uid=uid-1
  export POD_UID=uid-1 RESTARTS=0
  stub_script kubectl <<'STUB'
case "$*" in
  *"exec -n vault vault-0"*) printf '%s' "${VAULT_VALUE-}" ;;
  *"get configmap secret-rotation-checkpoint"*)
    args="$*"
    key="${args##*jsonpath=\{.data.}"
    key="${key%%\}*}"
    var="CHECKPOINT_$(printf '%s' "$key" | tr '-' '_')"
    printf '%s' "${!var:-}"
    ;;
  *"get pod -l app=secret-consumer"*) printf '%s' "${FILE_PODS-secret-consumer-abc }" ;;
  *"get pod -l app=env-consumer"*) printf '%s' "${ENV_PODS-env-consumer-xyz }" ;;
  *"exec secret-consumer-"*"cat /etc/api/api-key"*) printf '%s' "${FILE_VALUE-}" ;;
  *"exec env-consumer-"*) printf '%s' "${ENV_VALUE-}" ;;
  *"get pod secret-consumer-"*"jsonpath={.metadata.uid}"*) printf '%s' "${POD_UID-}" ;;
  *"get pod secret-consumer-"*"restartCount"*) printf '%s' "${RESTARTS-}" ;;
esac
STUB
}

teardown() {
  stub_teardown
}

check() {
  run sh "$CHECKS/$1.sh"
}

all_checks() {
  echo check-rotation-performed
  echo check-propagated-to-pod
  echo check-no-restart
  echo check-env-consumer-stale
}

# solved sets the state a correct drill ends in.
solved() {
  export VAULT_VALUE=rotated-v2 FILE_VALUE=rotated-v2 ENV_VALUE=baseline-v1
}

@test "no check passes on the lab as activation leaves it" {
  for c in $(all_checks); do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed with no work done: $output"; return 1; }
    [[ "$output" == *"PENDING"* ]] || { echo "$c: $output"; return 1; }
  done
}

@test "every check passes once the rotation reached the file and not the env var" {
  solved
  for c in $(all_checks); do
    check "$c"
    [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
  done
}

@test "a lab seeded with its own baseline is not graded as rotated" {
  export CHECKPOINT_baseline=team-seed-7 VAULT_VALUE=team-seed-7 FILE_VALUE=team-seed-7 ENV_VALUE=team-seed-7
  for c in $(all_checks); do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed with no work done: $output"; return 1; }
  done
}

@test "the wrong fix of redeploying the consumer fails check-no-restart" {
  solved
  POD_UID=uid-2 check check-no-restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the pod the drill started with"* ]] || false
}

@test "a consumer container that restarted fails check-no-restart" {
  solved
  RESTARTS=1 check check-no-restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"restarted 1 time(s)"* ]] || false
}

@test "an unreadable restart count is not taken for zero" {
  solved
  RESTARTS="" check check-no-restart
  [ "$status" -ne 0 ]
}

@test "check-no-restart cannot grade without the activation checkpoint" {
  solved
  CHECKPOINT_consumer_pod_uid="" check check-no-restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checkpoint was recorded"* ]] || false
}

@test "an env-var pod that was restarted to pick up the value fails the contrast check" {
  solved
  ENV_VALUE=rotated-v2 check check-env-consumer-stale
  [ "$status" -ne 0 ]
  [[ "$output" == *"the contrast is gone"* ]] || false
}

@test "a rotation that has not reached the file yet is pending, not passed" {
  solved
  export FILE_VALUE=baseline-v1
  for c in check-propagated-to-pod check-env-consumer-stale; do
    check "$c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PENDING"* ]] || false
  done
}

@test "a Vault that cannot be read fails every check that needs its value" {
  solved
  export VAULT_VALUE=""
  for c in check-rotation-performed check-propagated-to-pod check-env-consumer-stale; do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed with Vault unreadable"; return 1; }
    [[ "$output" == *"could not read secret/cart"* ]] || false
  done
}

@test "a missing consumer pod fails with the namespace it looked in" {
  solved
  export FILE_PODS=""
  for c in check-propagated-to-pod check-no-restart check-env-consumer-stale; do
    check "$c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shop"* ]] || false
  done
}

@test "the newest running consumer pod is the one graded" {
  solved
  FILE_PODS="secret-consumer-old secret-consumer-abc " check check-propagated-to-pod
  [ "$status" -eq 0 ]
  assert_called kubectl "exec secret-consumer-abc"
  refute_called kubectl "exec secret-consumer-old"
}

@test "every check refuses to run without a workload binding" {
  unset WORKLOAD_NAME WORKLOAD_NAMESPACE
  for c in $(all_checks); do
    check "$c"
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs to know which app"* ]] || false
  done
}
