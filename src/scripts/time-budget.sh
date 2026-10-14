#!/usr/bin/env bash
# Fails when a Go test takes longer than the budget. A slow test is usually
# one waiting on real time, which is also a flaky one.
#
# Usage: time-budget.sh <go-test-output>
# Environment: TIME_BUDGET (seconds per top-level test, default 5).
#
# Reads the "--- PASS: TestX (1.23s)" lines `go test -v -p 1` prints and names
# each slow test with the package its "ok <package>" line reports after it.
set -euo pipefail

log="${1:?usage: time-budget.sh <go-test-output>}"
budget="${TIME_BUDGET:-5}"

[ -r "$log" ] || {
  echo "time-budget: cannot read $log" >&2
  exit 2
}

awk -v budget="$budget" '
  /^--- (PASS|FAIL): [^ ]+ \([0-9.]+s\)$/ {
    secs = $4; gsub(/[()s]/, "", secs)
    measured++
    if (secs + 0 > budget + 0) pending[++np] = $3 "  " secs "s"
    next
  }
  ($1 == "ok" || $1 == "FAIL") && NF >= 3 {
    for (i = 1; i <= np; i++) over[++n] = $2 "." pending[i]
    np = 0
  }
  END {
    if (measured == 0) {
      print "time-budget: no test timings in the log; run go test -v -count=1" > "/dev/stderr"
      exit 2
    }
    if (n == 0) {
      printf "time-budget passed: %d tests, each under %ss\n", measured, budget
      exit 0
    }
    printf "time-budget failed: %d test(s) over %ss:\n", n, budget > "/dev/stderr"
    for (i = 1; i <= n; i++) print "  " over[i] > "/dev/stderr"
    print "\nA slow test is usually waiting on real time: use synctest, a shorter interval knob, or a fake clock — see docs/TESTING.md" > "/dev/stderr"
    exit 1
  }
' "$log"
