#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# prose-check rejects padding and hype phrases in docs and content text. It
# must name the file and line, ignore case, pass plain text, and leave the
# writing guide (which quotes the phrases) alone.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CHECK="$ROOT/scripts/prose-check.sh"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/prose.XXXXXX")"
}

teardown() {
  rm -rf "$WORK"
}

# check <file>... - run the gate over the given paths.
check() {
  PROSE_FILES="$(printf '%s\n' "$@")" run sh "$CHECK"
}

@test "plain technical text passes" {
  printf 'Run labctl init. It restarts the cluster and keeps your apps.\n' >"$WORK/plain.md"
  check "$WORK/plain.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no listed phrases"* ]] || false
}

@test "a listed phrase fails and names the file and line" {
  printf 'Intro\nThe lab works seamlessly with Istio.\n' >"$WORK/hype.md"
  check "$WORK/plain.md" "$WORK/hype.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$WORK/hype.md:2:"* ]] || false
}

@test "matching ignores case" {
  printf 'In Summary, it works.\n' >"$WORK/closer.md"
  check "$WORK/closer.md"
  [ "$status" -ne 0 ]
}

@test "phrases with apostrophes are caught" {
  printf "It's worth noting that k3d is fast.\n" >"$WORK/filler.md"
  check "$WORK/filler.md"
  [ "$status" -ne 0 ]
}

@test "content YAML is checked too" {
  printf 'description: "A cutting-edge chaos drill."\n' >"$WORK/scenario.yaml"
  check "$WORK/scenario.yaml"
  [ "$status" -ne 0 ]
}

@test "the writing guide may quote the phrases it forbids" {
  run sh -c "cd '$ROOT' && PROSE_FILES='docs/WRITING.md' sh scripts/prose-check.sh"
  [ "$status" -eq 0 ]
}

@test "the repository itself passes" {
  run sh "$CHECK"
  [ "$status" -eq 0 ]
}
