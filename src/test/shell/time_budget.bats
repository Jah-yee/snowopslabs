#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/time-budget.sh"
  LOG="$BATS_TEST_TMPDIR/go-test.log"
}

@test "tests under the budget pass, and the count is reported" {
  printf '=== RUN   TestA\n--- PASS: TestA (1.20s)\n=== RUN   TestB\n--- PASS: TestB (4.99s)\n    --- PASS: TestB/case (4.90s)\nPASS\nok  \tgithub.com/x/a\t6.3s\n?   \tgithub.com/x/c\t[no test files]\n' >"$LOG"
  run "$SCRIPT" "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 tests, each under 5s"* ]] || false
}

@test "a test over the budget fails and is named with its package and time" {
  printf -- '--- PASS: TestQuick (0.10s)\nok  \tgithub.com/x/a\t1.2s\n--- PASS: TestSlow (31.50s)\n--- PASS: TestFine (0.20s)\nok  \tgithub.com/x/b\t32s\n' >"$LOG"
  run "$SCRIPT" "$LOG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.com/x/b.TestSlow  31.50s"* ]] || false
  [[ "$output" != *"TestQuick"* ]] || false
  [[ "$output" != *"TestFine"* ]] || false
}

@test "a slow failing test is still timed" {
  printf -- '--- FAIL: TestSlow (9.00s)\nFAIL\nFAIL\tgithub.com/x/a\t9.1s\n' >"$LOG"
  run "$SCRIPT" "$LOG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"github.com/x/a.TestSlow  9.00s"* ]] || false
}

@test "a slow subtest counts only through its parent" {
  printf -- '--- PASS: TestParent (2.00s)\n    --- PASS: TestParent/slow (9.00s)\nok  \tgithub.com/x/a\t2s\n' >"$LOG"
  run "$SCRIPT" "$LOG"
  [ "$status" -eq 0 ]
}

@test "the budget can be set" {
  printf -- '--- PASS: TestA (12.00s)\nok  \tgithub.com/x/a\t12s\n' >"$LOG"
  TIME_BUDGET=10 run "$SCRIPT" "$LOG"
  [ "$status" -eq 1 ]
  TIME_BUDGET=15 run "$SCRIPT" "$LOG"
  [ "$status" -eq 0 ]
}

@test "a log with no timings is an error, not a pass" {
  printf 'ok  \tgithub.com/x/a\t(cached)\n' >"$LOG"
  run "$SCRIPT" "$LOG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no test timings"* ]] || false
}

@test "a missing log is an error" {
  run "$SCRIPT" "$BATS_TEST_TMPDIR/none.log"
  [ "$status" -eq 2 ]
}
