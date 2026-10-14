#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Changed-lines coverage gate.
#
# Of the code lines a change adds or edits, at least CHANGED_MIN percent
# (default 85) must be run by a test. A package below the per-package bar is
# not exempt: this gate makes new code arrive with tests while older code
# catches up.
#
# Usage: changed-lines-gate.sh go   [coverage.out]
#        changed-lines-gate.sh lcov [lcov.info]
#
# Environment:
#   CHANGED_MIN   minimum percent of changed code lines covered (default 85)
#   BASE_REF      ref the change is measured against (default origin/main)
#   MODULE_ROOT   the Go module directory (default: this script's parent)
#   DIFF_FILE     a unified diff (-U0) to read instead of asking git
#   SOURCE_ROOT   directory the diff's paths are relative to (with DIFF_FILE)
#   PATH_PREFIX   path of MODULE_ROOT inside SOURCE_ROOT (with DIFF_FILE)

set -euo pipefail

mode="${1:-}"
case "$mode" in
  go | lcov) ;;
  *)
    echo "usage: changed-lines-gate.sh go|lcov [profile]" >&2
    exit 2
    ;;
esac

root="${MODULE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
min="${CHANGED_MIN:-85}"
base="${BASE_REF:-origin/main}"

if [ "$mode" = go ]; then
  profile="${2:-$root/coverage.out}"
  hint="make test-go"
else
  profile="${2:-$root/ui/coverage/lcov.info}"
  hint="make test-ui"
fi

if [ ! -f "$profile" ]; then
  echo "coverage profile not found: $profile (run '$hint')" >&2
  exit 1
fi

# skip_or_fail explains why the change cannot be measured. A developer's
# machine carries on; CI must never pass a gate it did not run.
skip_or_fail() {
  if [ -n "${CI:-}" ]; then
    echo "changed-lines gate ($mode): $1" >&2
    exit 1
  fi
  echo "changed-lines gate ($mode): skipped — $1"
  exit 0
}

tmp=""
cleanup() { [ -z "$tmp" ] || rm -f "$tmp"; }
trap cleanup EXIT

if [ -n "${DIFF_FILE:-}" ]; then
  diff="$DIFF_FILE"
  top="${SOURCE_ROOT:-$root}"
  prefix="${PATH_PREFIX:-}"
else
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
    skip_or_fail "not a git checkout"
  prefix="$(git -C "$root" rev-parse --show-prefix)"
  git -C "$top" rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    skip_or_fail "base ref '$base' not found (git fetch origin, or set BASE_REF)"
  merge_base="$(git -C "$top" merge-base "$base" HEAD)" ||
    skip_or_fail "no common ancestor with '$base'"

  tmp="$(mktemp "${TMPDIR:-/tmp}/changed-lines.XXXXXX")"
  diff="$tmp"
  # Working tree against the merge base: committed and uncommitted edits alike.
  git -C "$top" diff -U0 -M --no-color --no-ext-diff "$merge_base" -- >"$diff"
  # A file git does not track yet is new in full.
  git -C "$top" ls-files --others --exclude-standard | while IFS= read -r f; do
    [ -f "$top/$f" ] || continue
    lines="$(awk 'END { print NR }' "$top/$f")"
    [ "$lines" -gt 0 ] || continue
    printf '+++ b/%s\n@@ -0,0 +1,%s @@\n' "$f" "$lines"
  done >>"$diff"
fi

module=""
if [ "$mode" = go ]; then
  module="${GO_MODULE:-$(awk '$1 == "module" { print $2; exit }' "$root/go.mod")}"
fi

awk -v mode="$mode" -v min="$min" -v top="$top" -v prefix="$prefix" \
  -v module="$module" -v difffile="$diff" '
  function wanted(f) {
    if (index(f, prefix) != 1) return 0
    if (mode == "go") return f ~ /\.go$/ && f !~ /_test\.go$/
    return f ~ /\.tsx?$/ && f !~ /\.test\.tsx?$/ && f !~ /\.d\.ts$/
  }

  # is_code reports whether a source line holds code. Coverage ranges also
  # span blank lines, comments and lone brackets, which no test can "run".
  function is_code(f, n,    path, line, i) {
    if (!(f in loaded)) {
      loaded[f] = 1
      path = top "/" f
      i = 0
      while ((getline line < path) > 0) src[f, ++i] = line
      close(path)
      known[f] = i
    }
    if (known[f] == 0) return 1
    line = src[f, n]
    if (line ~ /^[[:space:]]*$/) return 0
    if (line ~ /^[[:space:]]*(\/\/|\/\*)/) return 0
    if (mode == "lcov" && line ~ /^[[:space:]]*\*/) return 0
    if (line ~ /^[[:space:]]*[{}()\[\];,]+[[:space:]]*$/) return 0
    return 1
  }

  function mark(f, first, last, hit,    l) {
    if (!(f in files)) return
    for (l = first; l <= last; l++) {
      if (!((f, l) in changed)) continue
      measured[f, l] = 1
      if (hit > 0) covered[f, l] = 1
      if (l > maxline[f]) maxline[f] = l
    }
  }

  FILENAME == difffile {
    if ($0 ~ /^\+\+\+ /) {
      cur = substr($0, 5)
      sub(/\t.*$/, "", cur)
      sub(/^b\//, "", cur)
      if (cur == "/dev/null" || !wanted(cur)) cur = ""
    } else if ($0 ~ /^@@ / && cur != "") {
      n = split($3, part, ",")
      start = substr(part[1], 2) + 0
      count = (n > 1) ? part[2] + 0 : 1
      for (i = 0; i < count; i++) changed[cur, start + i] = 1
      if (count > 0) files[cur] = 1
    }
    next
  }

  mode == "go" {
    if ($0 ~ /^mode:/) next
    cut = index($1, ":")
    path = substr($1, 1, cut - 1)
    if (index(path, module "/") == 1) path = substr(path, length(module) + 2)
    split(substr($1, cut + 1), range, ",")
    split(range[1], from, ".")
    split(range[2], to, ".")
    mark(prefix path, from[1] + 0, to[1] + 0, $3 + 0)
    next
  }

  mode == "lcov" {
    if ($0 ~ /^SF:/) {
      sf = substr($0, 4)
      if (index(sf, top "/") == 1) sf = substr(sf, length(top) + 2)
      else sf = prefix "ui/" sf
    } else if ($0 ~ /^DA:/) {
      split(substr($0, 4), da, ",")
      mark(sf, da[1] + 0, da[1] + 0, da[2] + 0)
    }
    next
  }

  END {
    total = 0; hit = 0
    for (f in files) {
      missing = ""; inrun = 0; prev = 0
      for (l = 1; l <= maxline[f]; l++) {
        if (!((f, l) in measured) || !is_code(f, l)) continue
        total++
        if ((f, l) in covered) { hit++; continue }
        if (inrun && l == prev + 1) { prev = l; continue }
        if (inrun) missing = missing (first == prev ? first : first "-" prev) ", "
        inrun = 1; first = l; prev = l
      }
      if (inrun) missing = missing (first == prev ? first : first "-" prev)
      if (missing != "") report[f] = missing
    }

    if (total == 0) {
      printf "changed-lines gate passed (%s): no changed code lines to measure\n", mode
      exit 0
    }
    pct = hit * 100.0 / total
    if (pct + 0.00001 >= min) {
      printf "changed-lines gate passed (%s): %d of %d changed lines covered (%.1f%%, minimum %s%%)\n", \
        mode, hit, total, pct, min
      exit 0
    }
    err = "cat 1>&2"
    printf "changed-lines gate failed (%s): %d of %d changed lines covered (%.1f%%, minimum %s%%)\n", \
      mode, hit, total, pct, min | err
    for (f in report) printf "  %s: %s\n", f, report[f] | err
    printf "\nAdd tests that run these lines — see docs/TESTING.md\n" | err
    close(err)
    exit 1
  }
' "$diff" "$profile"
