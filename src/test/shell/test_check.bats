#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# test-check decides whether a change brought tests with it. It must name what
# is missing, accept a stated reason, and never pass a change it could not see.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CHECK="$ROOT/scripts/test-check.sh"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check.XXXXXX")"
}

teardown() {
  rm -rf "$WORK"
}

# check <changed-file>... — run the gate over a list of changed paths.
check() {
  CHANGED_FILES="$(printf '%s\n' "$@")" COMMIT_MESSAGES="${MESSAGES:-}" \
    TESTS_NOT_NEEDED="${WAIVER:-}" run sh "$CHECK"
}

@test "passes when nothing that needs a test changed" {
  check docs/TESTING.md scenarios/demo/scenario.yaml Makefile
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-check passed"* ]] || false
}

@test "Go source with a changed test in the same directory passes" {
  check src/internal/run/engine.go src/internal/run/engine_test.go
  [ "$status" -eq 0 ]
}

@test "Go source with no changed test in its directory fails and is named" {
  check src/internal/run/engine.go src/internal/store/runs_test.go
  [ "$status" -ne 0 ]
  [[ "$output" == *"Go source changed"* ]] || false
  [[ "$output" == *"src/internal/run/engine.go"* ]] || false
}

@test "only the Go directories missing a test are listed" {
  check src/internal/run/engine.go src/internal/run/engine_test.go src/internal/cli/lab.go
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/internal/cli/lab.go"* ]] || false
  [[ "$output" != *"src/internal/run/engine.go"* ]] || false
}

@test "a shell script needs a bats file, a Go test or a fixture" {
  check incidents/oom-kill/inject.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Shell scripts changed"* ]] || false
  [[ "$output" == *"incidents/oom-kill/inject.sh"* ]] || false

  check incidents/oom-kill/inject.sh src/test/shell/incident_oom_kill.bats
  [ "$status" -eq 0 ]
  check src/services/traffic/start.sh src/internal/traffic/scripts_test.go
  [ "$status" -eq 0 ]
  check incidents/oom-kill/inject.sh incidents/oom-kill/test/solved/expect.yaml
  [ "$status" -eq 0 ]
}

@test "a script under a test directory is a test, not source" {
  check scenarios/demo/test/solve.sh src/test/shell/helpers/stub.bash
  [ "$status" -eq 0 ]
}

@test "UI source needs a component test or a browser journey" {
  check src/ui/src/views/Apps.tsx
  [ "$status" -ne 0 ]
  [[ "$output" == *"UI source changed"* ]] || false
  [[ "$output" == *"src/ui/src/views/Apps.tsx"* ]] || false

  check src/ui/src/views/Apps.tsx src/ui/src/views/Apps.test.tsx
  [ "$status" -eq 0 ]
  check src/ui/src/views/Apps.tsx src/ui/e2e/apps.spec.ts
  [ "$status" -eq 0 ]
}

@test "UI types, test helpers and config need no test" {
  check src/ui/src/types/index.ts src/ui/src/test/setup.ts src/ui/vitest.config.ts src/ui/src/main.tsx
  [ "$status" -eq 0 ]
}

@test "a Go test does not excuse a UI change" {
  check src/ui/src/views/Apps.tsx src/internal/run/engine_test.go
  [ "$status" -ne 0 ]
  [[ "$output" == *"UI source changed"* ]] || false
}

@test "a commit trailer with a reason waives the check and shows what it waived" {
  MESSAGES="refactor: move helpers

Tests-Not-Needed: pure move, covered by the existing engine tests"
  check src/internal/run/engine.go
  [ "$status" -eq 0 ]
  [[ "$output" == *"waived"* ]] || false
  [[ "$output" == *"pure move, covered by the existing engine tests"* ]] || false
  [[ "$output" == *"src/internal/run/engine.go"* ]] || false
}

@test "a trailer with no real reason does not waive" {
  MESSAGES="Tests-Not-Needed: n/a"
  check src/internal/run/engine.go
  [ "$status" -ne 0 ]
  [[ "$output" == *"too short to be a reason"* ]] || false
}

@test "the reason can be given for uncommitted work" {
  WAIVER="comment-only edit in the engine"
  check src/internal/run/engine.go
  [ "$status" -eq 0 ]
  [[ "$output" == *"waived"* ]] || false
}

@test "the failure says how to add tests or waive" {
  check src/internal/run/engine.go
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tests-Not-Needed: <reason>"* ]] || false
  [[ "$output" == *"docs/TESTING.md"* ]] || false
}

@test "git: reads changes and trailers from the repository" {
  REPO="$WORK/repo"
  mkdir -p "$REPO/scripts" "$REPO/src/pkg"
  cp "$CHECK" "$REPO/scripts/test-check.sh"
  git -C "$WORK" init -q repo
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo "package pkg" >"$REPO/src/pkg/a.go"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" branch -q base

  echo "// edit" >>"$REPO/src/pkg/a.go"
  BASE_REF=base run sh "$REPO/scripts/test-check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/pkg/a.go"* ]] || false

  echo "package pkg" >"$REPO/src/pkg/a_test.go"
  BASE_REF=base run sh "$REPO/scripts/test-check.sh"
  [ "$status" -eq 0 ]

  rm "$REPO/src/pkg/a_test.go"
  git -C "$REPO" commit -q -am "tidy

Tests-Not-Needed: comment-only change"
  BASE_REF=base run sh "$REPO/scripts/test-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waived"* ]] || false
}

@test "git: a missing base ref skips locally and fails in CI" {
  CI="" BASE_REF=no-such-ref run sh "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || false
  CI=true BASE_REF=no-such-ref run sh "$CHECK"
  [ "$status" -ne 0 ]
}
