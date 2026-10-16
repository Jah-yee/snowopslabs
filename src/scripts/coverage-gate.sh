#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Per-package coverage gate with a ratchet.
#
# Every package must reach COVERAGE_MIN (default 80%) - except packages listed
# in .coverage-exceptions, which must reach at least their recorded floor. The
# floor is a ratchet in both directions: a package below it fails, a package
# more than COVERAGE_SLACK points above it fails until the floor is raised, and
# a package that clears the bar fails until its entry is deleted.
#
# Coverage is computed exactly from the profile (covered statements / total
# statements per package), not by averaging per-file percentages.
#
# Usage: coverage-gate.sh [coverage-profile] [min-percent]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-${COVERAGE_PROFILE:-$root/coverage.out}}"
min="${2:-${COVERAGE_MIN:-80}}"
slack="${COVERAGE_SLACK:-2}"
exceptions="${COVERAGE_EXCEPTIONS:-$root/.coverage-exceptions}"

if [ ! -f "$profile" ]; then
  echo "coverage profile not found: $profile (run 'make test-go')" >&2
  exit 1
fi

# Aggregate statements per package directory.
#   line format: <import/path/file.go>:<range> <numStmts> <count>
totals=$(
  awk '
    NR == 1 { next }                       # skip the "mode:" header
    {
      split($1, a, ":");
      pkg = a[1];
      sub(/\/[^\/]*$/, "", pkg);           # strip the file name
      total[pkg] += $2;
      if ($3 > 0) covered[pkg] += $2;
    }
    END {
      for (p in total) {
        if (total[p] == 0) continue;       # no statements: nothing to measure
        printf "%s %.1f\n", p, (covered[p] * 100.0) / total[p];
      }
    }
  ' "$profile" | sort
)

lookup_exception() {
  [ -f "$exceptions" ] || return 1
  # Fields: <package> <min> <reason>. Comments and blanks ignored.
  awk -v want="$1" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    $1 == want { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$exceptions"
}

status=0
exempt_used=""

while read -r pkg pct; do
  [ -n "$pkg" ] || continue

  if floor=$(lookup_exception "$pkg"); then
    exempt_used="$exempt_used $pkg"
    if awk "BEGIN { exit !($pct < $floor) }"; then
      printf '  FAIL %-58s %5s%% (exception floor %s%%)\n' "$pkg" "$pct" "$floor" >&2
      status=1
    elif awk "BEGIN { exit !($pct >= $min) }"; then
      printf '  RATCHET %-55s %5s%% now clears %s%% - remove its .coverage-exceptions entry\n' \
        "$pkg" "$pct" "$min" >&2
      status=1
    elif awk "BEGIN { exit !($pct >= $floor + $slack) }"; then
      printf '  RAISE %-57s %5s%% is %s points or more above its floor %s%% - set the floor to %s\n' \
        "$pkg" "$pct" "$slack" "$floor" "$(awk "BEGIN { printf \"%d.0\", $pct }")" >&2
      status=1
    fi
    continue
  fi

  if awk "BEGIN { exit !($pct < $min) }"; then
    printf '  FAIL %-58s %5s%% (minimum %s%%)\n' "$pkg" "$pct" "$min" >&2
    status=1
  fi
done <<EOF
$totals
EOF

# A stale exception (for a package that no longer exists, or that the profile
# never reached) hides a gap. Flag it.
if [ -f "$exceptions" ]; then
  while read -r pkg _rest; do
    case "$pkg" in '' | '#'*) continue ;; esac
    case " $exempt_used " in
      *" $pkg "*) ;;
      *)
        printf '  STALE %-58s no coverage recorded - remove the exception\n' "$pkg" >&2
        status=1
        ;;
    esac
  done <"$exceptions"
fi

if [ "$status" -ne 0 ]; then
  printf '\ncoverage gate failed - see docs/TESTING.md\n' >&2
  exit 1
fi

echo "coverage gate passed (minimum ${min}%)"
