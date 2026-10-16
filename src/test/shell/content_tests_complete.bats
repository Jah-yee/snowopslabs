#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Every grading script and every fault script has a behaviour test. A new check
# or fault that arrives without one fails here, naming the script.

load 'helpers/stub'

setup() {
  ROOT="$(project_root)"
  TESTS="$ROOT/src/test/shell"
}

# tested <owner> <script-name> - a bats file names both the scenario or fault
# and the script.
tested() {
  grep -l -- "$1" "$TESTS"/*.bats 2>/dev/null | xargs grep -l -- "$2" >/dev/null 2>&1
}

@test "every scenario check script has a behaviour test" {
  missing=""
  for script in "$ROOT"/scenarios/*/checks/*.sh; do
    name="$(basename "$script" .sh)"
    case "$name" in _*) continue ;; esac
    scenario="$(basename "$(dirname "$(dirname "$script")")")"
    tested "$scenario" "$name" || missing="$missing
  scenarios/$scenario/checks/$name.sh"
  done
  [ -z "$missing" ] || {
    echo "no test in src/test/shell names these check scripts:$missing"
    return 1
  }
}

@test "every fault's detection check, inject.sh and resolve.sh have behaviour tests" {
  missing=""
  for dir in "$ROOT"/incidents/*/; do
    fault="$(basename "$dir")"
    case "$fault" in _*) continue ;; esac
    grep -q -- "$fault" "$TESTS/incident_checks.bats" || missing="$missing
  incidents/$fault/checks (incident_checks.bats)"
    grep -q -- "^$fault|" "$TESTS/incident_faults.bats" || missing="$missing
  incidents/$fault/inject.sh and resolve.sh (the faults table in incident_faults.bats)"
  done
  [ -z "$missing" ] || {
    echo "these fault scripts have no test:$missing"
    return 1
  }
}

@test "the gate sees content: the repository ships checks and faults" {
  [ "$(ls "$ROOT"/scenarios/*/checks/*.sh | wc -l)" -gt 20 ]
  [ "$(ls -d "$ROOT"/incidents/*/ | wc -l)" -gt 5 ]
}
