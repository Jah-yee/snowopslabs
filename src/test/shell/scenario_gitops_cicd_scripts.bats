#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# gitops-cicd's teardown script. It is the uninstall of the Applications'
# workloads, so it must fail when they are left behind: `scenario down` keeps
# the scenario active on that failure, and the learner can run it again.

load 'helpers/stub'

setup() {
  stub_setup
  SCRIPT="$(project_root)/scenarios/gitops-cicd/scripts/remove-apps.sh"
  # The cluster as the scenario leaves it: both Applications and both
  # namespaces exist. DELETES_FAIL makes every delete fail; LEFT names the
  # namespaces still present after the deletes.
  export DELETES_FAIL=no LEFT=""
  stub_script kubectl <<'STUB'
case "$*" in
  *"get application"*) exit 0 ;;
  *"patch application"*) exit 0 ;;
  *"delete "*)
    [ "$DELETES_FAIL" = yes ] && { echo 'Unable to connect to the server: TLS handshake timeout' >&2; exit 1; }
    exit 0
    ;;
  *"get namespace "*)
    for ns in $LEFT; do case "$*" in *"get namespace $ns"*) exit 0 ;; esac; done
    exit 1
    ;;
esac
exit 0
STUB
}

@test "removes both Applications, then their namespaces, and reports it" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called kubectl "-n argocd delete application gitops-demo"
  assert_called kubectl "-n argocd delete application gitops-broken"
  assert_called kubectl "delete namespace gitops-demo gitops-broken"
  [[ "$output" == *"gitops-demo and gitops-broken removed"* ]] || false
}

@test "fails, and does not report success, when the deletes fail" {
  DELETES_FAIL=yes LEFT="gitops-demo gitops-broken" run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" != *"removed"* ]] || false
  [[ "$output" == *"gitops-demo"* ]] || false
}

@test "fails when a namespace is still there after its delete" {
  LEFT="gitops-broken" run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gitops-broken"* ]] || false
  [[ "$output" != *"gitops-demo and gitops-broken removed"* ]] || false
}

@test "a second run on a lab already cleaned succeeds" {
  run "$SCRIPT"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}
