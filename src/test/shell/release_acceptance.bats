#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# scripts/release-acceptance.sh walks a live lab and reports each step. These
# tests stub labctl and kubectl to pin the harness contract: every step runs
# and is reported, a failure fails the run, and an injected fault is always
# resolved, even when its detection check never fires.

load 'helpers/stub'

setup() {
  stub_setup
  stub_command labctl kubectl
  ROOT="$(project_root)"
  export RA_OUT="$STUB_DIR/out" LABCTL="$STUB_BIN/labctl" RA_WAIT=0
}

teardown() {
  stub_teardown
}

@test "--list prints every step" {
  run bash "$ROOT/scripts/release-acceptance.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"init"* ]] || false
  [[ "$output" == *"incident"* ]] || false
}

@test "an unknown step is refused before anything runs" {
  run bash "$ROOT/scripts/release-acceptance.sh" --only init,nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown step: nope"* ]] || false
  refute_called labctl
}

@test "a failing step fails the run, and later steps still run and are reported" {
  stub_when labctl "doctor" 0 "✗ Docker is not running"
  stub_when labctl "validate" 0 "✓ all content valid"
  run bash "$ROOT/scripts/release-acceptance.sh" --only doctor,content
  [ "$status" -ne 0 ]
  grep -q "| doctor | FAIL |" "$RA_OUT/report.md"
  grep -q "| content | PASS |" "$RA_OUT/report.md"
}

@test "the incident is resolved even when its detection check never fires" {
  stub_when labctl "incident status" 0 "No incident is active."
  run bash "$ROOT/scripts/release-acceptance.sh" --only incident
  [ "$status" -ne 0 ]
  assert_called labctl "incident inject crashloop-bad-config"
  assert_called labctl "incident resolve"
  grep -q "never fired" "$RA_OUT/incident.log"
}

@test "an incident already active is left alone" {
  stub_when labctl "incident status" 0 "NOT RESOLVED - detection check fails"
  run bash "$ROOT/scripts/release-acceptance.sh" --only incident
  [ "$status" -eq 0 ]
  refute_called labctl "incident inject"
  grep -q "| incident | SKIP |" "$RA_OUT/report.md"
}
