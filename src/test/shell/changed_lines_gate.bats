#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The changed-lines gate decides whether new code arrived with tests. It must
# count exactly the lines a change touched, ignore lines no test can run, and
# never pass a change it could not measure.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  GATE="$ROOT/scripts/changed-lines-gate.sh"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/changed-lines.XXXXXX")"
  DIFF="$WORK/change.diff"
  PROFILE="$WORK/coverage.out"
  LCOV="$WORK/lcov.info"
  : >"$DIFF"
  echo "mode: atomic" >"$PROFILE"
  : >"$LCOV"
}

teardown() {
  rm -rf "$WORK"
}

# hunk <path> <first-line> <count> — one added hunk in the diff.
hunk() {
  printf '+++ b/%s\n@@ -1,0 +%s,%s @@\n' "$1" "$2" "$3" >>"$DIFF"
}

# block <file> <first-line> <last-line> <count> — one coverage block.
block() {
  echo "example.com/m/$1:$2.1,$3.10 1 $4" >>"$PROFILE"
}

run_go() {
  DIFF_FILE="$DIFF" SOURCE_ROOT="$WORK" PATH_PREFIX="src/" GO_MODULE="example.com/m" \
    run bash "$GATE" go "$PROFILE"
}

run_lcov() {
  DIFF_FILE="$DIFF" SOURCE_ROOT="$WORK" PATH_PREFIX="src/" \
    run bash "$GATE" lcov "$LCOV"
}

@test "passes when every changed line is covered" {
  hunk src/pkg/a.go 10 3
  block pkg/a.go 10 12 4
  run_go
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 of 3 changed lines covered"* ]] || false
}

@test "fails below the minimum and lists the uncovered lines as ranges" {
  hunk src/pkg/a.go 10 6
  block pkg/a.go 10 11 1
  block pkg/a.go 12 14 0
  block pkg/a.go 15 15 0
  run_go
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 of 6 changed lines covered (33.3%"* ]] || false
  [[ "$output" == *"src/pkg/a.go: 12-15"* ]] || false
}

@test "lines outside the change do not count, covered or not" {
  hunk src/pkg/a.go 10 1
  block pkg/a.go 10 10 1
  block pkg/a.go 20 90 0
  run_go
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 1 changed lines covered"* ]] || false
}

@test "a line shared by two blocks is covered when either ran" {
  hunk src/pkg/a.go 10 1
  block pkg/a.go 9 10 1
  block pkg/a.go 10 12 0
  run_go
  [ "$status" -eq 0 ]
}

@test "changed lines with no statements are not measured" {
  hunk src/pkg/types.go 1 40
  run_go
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changed code lines"* ]] || false
}

@test "test files and files outside the module are ignored" {
  hunk src/pkg/a_test.go 1 5
  hunk docs/notes.go 1 5
  block pkg/a_test.go 1 5 0
  run_go
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changed code lines"* ]] || false
}

@test "blank lines, comments and lone brackets inside a block are not counted" {
  mkdir -p "$WORK/src/pkg"
  printf 'x := 1\n\n// why\n}\n*p = x\n' >"$WORK/src/pkg/a.go"
  hunk src/pkg/a.go 1 5
  block pkg/a.go 1 5 0
  run_go
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 of 2 changed lines covered"* ]] || false
  [[ "$output" == *"src/pkg/a.go: 1, 5"* ]] || false
}

@test "a pure deletion measures nothing" {
  printf '+++ b/src/pkg/a.go\n@@ -10,4 +9,0 @@\n' >>"$DIFF"
  block pkg/a.go 9 9 0
  run_go
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changed code lines"* ]] || false
}

@test "the minimum is configurable and exact on the line" {
  hunk src/pkg/a.go 1 4
  block pkg/a.go 1 3 1
  block pkg/a.go 4 4 0
  CHANGED_MIN=75 run_go
  [ "$status" -eq 0 ]
  CHANGED_MIN=76 run_go
  [ "$status" -ne 0 ]
}

@test "lcov: measures changed UI lines and skips test files" {
  hunk src/ui/src/views/A.tsx 3 2
  hunk src/ui/src/views/A.test.tsx 1 9
  printf 'SF:src/views/A.tsx\nDA:3,1\nDA:4,0\nend_of_record\n' >"$LCOV"
  printf 'SF:src/views/A.test.tsx\nDA:1,0\nend_of_record\n' >>"$LCOV"
  run_lcov
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 changed lines covered (50.0%"* ]] || false
  [[ "$output" == *"src/ui/src/views/A.tsx: 4"* ]] || false
}

@test "a missing profile is an actionable error, not a silent pass" {
  run bash "$GATE" go "$WORK/nope.out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"coverage profile not found"* ]] || false
}

@test "an unknown mode prints usage" {
  run bash "$GATE" python
  [ "$status" -eq 2 ]
}

# make_repo builds a git repository with one module and one base commit.
make_repo() {
  REPO="$WORK/repo"
  mkdir -p "$REPO/src/pkg"
  git -C "$WORK" init -q repo
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo "module example.com/m" >"$REPO/src/go.mod"
  printf 'package pkg\n\nfunc A() int {\n\treturn 1\n}\n' >"$REPO/src/pkg/a.go"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" branch -q base
}

run_repo() {
  MODULE_ROOT="$REPO/src" BASE_REF=base run bash "$GATE" go "$PROFILE"
}

@test "git: uncommitted edits and untracked files are both measured" {
  make_repo
  printf 'package pkg\n\nfunc A() int {\n\treturn 2\n}\n' >"$REPO/src/pkg/a.go"
  printf 'package pkg\n\nfunc B() int {\n\treturn 3\n}\n' >"$REPO/src/pkg/b.go"
  block pkg/a.go 3 5 1
  block pkg/b.go 3 5 0
  run_repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 3 changed lines covered"* ]] || false
  [[ "$output" == *"src/pkg/b.go: 3-4"* ]] || false
}

@test "git: a missing base ref skips locally and fails in CI" {
  make_repo
  CI="" MODULE_ROOT="$REPO/src" BASE_REF=no-such-ref run bash "$GATE" go "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || false
  CI=true MODULE_ROOT="$REPO/src" BASE_REF=no-such-ref run bash "$GATE" go "$PROFILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"base ref 'no-such-ref' not found"* ]] || false
}
