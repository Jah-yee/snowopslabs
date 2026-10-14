#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# autoscaling-under-load's remove-autoscaler.sh runs at activation and on
# teardown: the learner's ScaledObject must not outlive the scenario, or KEDA
# keeps scaling the shared workload in every scenario after it.

load 'helpers/stub'

setup() {
  stub_setup
  stub_command kubectl
  ROOT="$(project_root)"
  SCRIPT="$ROOT/scenarios/autoscaling-under-load/scripts/remove-autoscaler.sh"
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop
}

teardown() { stub_teardown; }

@test "removes the learner's ScaledObject and KEDA's HPA, and scales the workload back to one" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called kubectl "-n shop delete scaledobject cart --ignore-not-found"
  assert_called kubectl "-n shop delete hpa keda-hpa-cart --ignore-not-found"
  assert_called kubectl "-n shop scale deployment cart --replicas=1"
}

@test "fails when the autoscaler cannot be removed" {
  stub_when kubectl "delete scaledobject" 1 "the server is unavailable"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  refute_called kubectl "scale deployment"
}
