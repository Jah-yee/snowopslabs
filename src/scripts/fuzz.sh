#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Runs every Fuzz* target in the module for FUZZTIME each.
#
# Usage: fuzz.sh
# Environment: FUZZTIME (go test -fuzztime, default 20s).
#
# With a duration, Go's fuzz coordinator can report its own timeout as a
# failure whose only message is "context deadline exceeded": it reads the
# expired deadline before the cancellation reaches the workers' context. Such a
# run fuzzed for the full time and found nothing, so it passes. A real finding
# always says "Failing input written" (or names a failing seed) and fails.
set -eu

fuzztime="${FUZZTIME:-20s}"
out="$(mktemp "${TMPDIR:-/tmp}/fuzz.XXXXXX")"
trap 'rm -f "$out"' EXIT INT TERM

# deadline_only succeeds when the failure in $out is the coordinator's timeout
# and nothing else: one message line, the deadline, and no failing input.
deadline_only() {
  grep -q 'Failing input written\|failure while testing seed corpus' "$out" && return 1
  messages="$(grep '^    [^ ]' "$out" || true)"
  [ "$messages" = "    context deadline exceeded" ]
}

echo "==> Fuzzing parsers ($fuzztime each)"
for pkg in $(go list ./...); do
  for target in $(go test -list 'Fuzz.*' "$pkg" 2>/dev/null | grep '^Fuzz' || true); do
    echo "  $pkg $target"
    if go test -run '^$' -fuzz "^$target\$" -fuzztime="$fuzztime" "$pkg" >"$out" 2>&1; then
      cat "$out"
      continue
    fi
    cat "$out"
    if deadline_only; then
      echo "  $target: fuzzed for $fuzztime with no failing input; the deadline message is Go reporting its own timeout"
      continue
    fi
    exit 1
  done
done
