#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# em-dash-check keeps em dashes out of tracked text. It must name the file and
# line that has one, pass clean text, and leave binary files alone.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CHECK="$ROOT/scripts/em-dash-check.sh"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/em-dash.XXXXXX")"
  DASH="$(printf '\342\200\224')"
}

teardown() {
  rm -rf "$WORK"
}

# check <file>... - run the gate over the given paths.
check() {
  EM_DASH_FILES="$(printf '%s\n' "$@")" run sh "$CHECK"
}

@test "clean text passes" {
  printf 'One sentence, then another - with a hyphen.\n' >"$WORK/clean.md"
  check "$WORK/clean.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"none found"* ]] || false
}

@test "an em dash fails and names the file and line" {
  printf 'first line\nsecond %s line\n' "$DASH" >"$WORK/dirty.md"
  check "$WORK/clean.md" "$WORK/dirty.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$WORK/dirty.md:2:"* ]] || false
}

@test "an em dash in code fails too" {
  printf 'echo "done %s ok"\n' "$DASH" >"$WORK/script.sh"
  check "$WORK/script.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"script.sh:1:"* ]] || false
}

@test "an en dash is allowed" {
  printf 'takes 5%s10 minutes\n' "$(printf '\342\200\223')" >"$WORK/range.md"
  check "$WORK/range.md"
  [ "$status" -eq 0 ]
}

@test "binary files are skipped" {
  printf 'GIF89a\000\000%s\000' "$DASH" >"$WORK/image.gif"
  check "$WORK/image.gif"
  [ "$status" -eq 0 ]
}

@test "the repository itself has no em dashes" {
  run sh "$CHECK"
  [ "$status" -eq 0 ]
}
