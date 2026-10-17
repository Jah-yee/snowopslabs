#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

# A stand-in go lists one package with two fuzz targets and prints, for each
# fuzz run, the output and exit status named by FAKE_OUT_<target> and
# FAKE_STATUS_<target>.
setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/fuzz.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN"
  cat >"$BIN/go" <<'EOF'
#!/bin/sh
echo "$*" >>"$CALLS"
case "$1 $2" in
  "list ./...") echo example.com/pkg ;;
  "test -list") printf 'FuzzA\nFuzzB\nok  \texample.com/pkg\t0.01s\n' ;;
  "test -run")
    target=$(printf '%s\n' "$5" | tr -d '^$')
    eval "out=\${FAKE_OUT_$target:-ok}; status=\${FAKE_STATUS_$target:-0}"
    printf '%b\n' "$out"
    exit "$status"
    ;;
esac
EOF
  chmod +x "$BIN/go"
  export PATH="$BIN:$PATH" CALLS
}

deadline='--- FAIL: FuzzA (11.01s)\n    context deadline exceeded\nFAIL\nexit status 1\nFAIL\texample.com/pkg\t11.010s'

@test "every target runs for FUZZTIME and a clean run passes" {
  FUZZTIME=3s run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '-fuzz ^FuzzA$ -fuzztime=3s example.com/pkg' "$CALLS"
  grep -q -- '-fuzz ^FuzzB$ -fuzztime=3s example.com/pkg' "$CALLS"
}

@test "FUZZTIME defaults to 20s, also when make passes it empty" {
  FUZZTIME= run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '-fuzztime=20s' "$CALLS"
}

@test "Go reporting its own timeout as the only failure passes, and the next target still runs" {
  FAKE_OUT_FuzzA="$deadline" FAKE_STATUS_FuzzA=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FuzzA: fuzzed for 20s with no failing input"* ]] || false
  grep -q -- '-fuzz ^FuzzB\$' "$CALLS"
}

@test "a failing input fails, even when the deadline is also reported" {
  FAKE_OUT_FuzzA='--- FAIL: FuzzA (2.10s)\n    --- FAIL: FuzzA (0.00s)\n        fuzz_test.go:20: Load returned a hard error\n    context deadline exceeded\n    Failing input written to testdata/fuzz/FuzzA/abc\nFAIL' \
    FAKE_STATUS_FuzzA=1 run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failing input written"* ]] || false
  ! grep -q -- '-fuzz ^FuzzB\$' "$CALLS"
}

@test "a failing seed corpus entry fails" {
  FAKE_OUT_FuzzB='failure while testing seed corpus entry: FuzzB/seed#0\n--- FAIL: FuzzB (0.18s)\n    --- FAIL: FuzzB (0.00s)\n        fuzz_test.go:24: stat .: no such file or directory\nFAIL' \
    FAKE_STATUS_FuzzB=1 run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "any other failure fails, including a hung worker" {
  FAKE_OUT_FuzzA='--- FAIL: FuzzA (11.00s)\n    fuzzing process hung or terminated unexpectedly: exit status 2\nFAIL' \
    FAKE_STATUS_FuzzA=1 run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the deadline next to another message is not the timeout alone, so it fails" {
  FAKE_OUT_FuzzA='--- FAIL: FuzzA (11.00s)\n    context deadline exceeded\n    fuzzing process hung or terminated unexpectedly: exit status 2\nFAIL' \
    FAKE_STATUS_FuzzA=1 run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "a build failure fails" {
  FAKE_OUT_FuzzA='# example.com/pkg\n./fuzz_test.go:3:2: undefined: nope\nFAIL\texample.com/pkg [build failed]' \
    FAKE_STATUS_FuzzA=1 run "$SCRIPT"
  [ "$status" -eq 1 ]
}
