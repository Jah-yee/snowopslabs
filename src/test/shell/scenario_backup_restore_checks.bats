#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# backup-restore-drill grades a backup that can be restored, a loss that was
# really seen, a restore that round-tripped, and a volume whose data did not
# come back. Each check is run against the lab as activation leaves it, the
# solved lab, and the shortcuts that leave the right files without the work.

load 'helpers/stub'

setup() {
  stub_setup
  command -v jq >/dev/null 2>&1 || {
    echo "these tests need jq, which the checks themselves require" >&2
    return 1
  }
  ROOT="$(project_root)"
  CHECKS="$ROOT/scenarios/backup-restore-drill/checks"
  export WORKLOAD_NAMESPACE=shop
  export BACKUP_DIR="$STUB_DIR/backups"
  mkdir -p "$BACKUP_DIR"
  ARCHIVE="$BACKUP_DIR/shop-latest.json"
  LOSS_LOG="$BACKUP_DIR/shop-loss.log"
  BOOT_LOG="$BACKUP_DIR/shop-bootid.log"
  # The lab right after activation: the marker is live, nothing is backed up.
  export MARKER=present TOKEN=tok-activation CANARY=do-not-delete
  export WRITER_POD=data-writer-abc BOOT_ID=boot-original
  stub_script kubectl <<'STUB'
case "$*" in
  *"get configmap restore-marker -o jsonpath={.data.token}"*) [ "$MARKER" = present ] && printf '%s' "$TOKEN" ;;
  *"get configmap restore-marker -o jsonpath={.data.canary}"*) [ "$MARKER" = present ] && printf '%s' "$CANARY" ;;
  *"get configmap restore-marker"*) [ "$MARKER" = present ] || exit 1 ;;
  *"get pod -l app=data-writer"*) printf '%s' "${WRITER_POD-}" ;;
  *"exec data-writer-"*) printf '%s' "${BOOT_ID-}" ;;
esac
exit 0
STUB
}

teardown() {
  stub_teardown
}

check() {
  run bash "$CHECKS/$1.sh"
}

all_checks() {
  echo backup-archive-usable
  echo loss-was-observed
  echo restore-round-tripped
  echo pv-data-loss-demonstrated
}

# archive_with <token> — a backup holding the marker with this token.
archive_with() {
  cat >"$ARCHIVE" <<JSON
{"kind":"List","items":[
  {"kind":"ConfigMap","metadata":{"name":"restore-marker"},"data":{"token":"$1","canary":"do-not-delete"}},
  {"kind":"PersistentVolumeClaim","metadata":{"name":"restore-data"}}
]}
JSON
}

# solved leaves the files and state a correct drill ends with.
solved() {
  archive_with tok-activation
  echo "2026-01-01T00:00:00Z restore-marker missing from shop" >"$LOSS_LOG"
  echo "2026-01-01T00:00:00Z boot-original" >"$BOOT_LOG"
  export BOOT_ID=boot-after-restore
}

@test "no check passes on the lab as activation leaves it" {
  for c in $(all_checks); do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed with no work done: $output"; return 1; }
    [[ "$output" == *"FAIL"* ]] || { echo "$c: $output"; return 1; }
  done
}

@test "every check passes after a backup, a witnessed loss, a restore and a lost volume" {
  solved
  for c in $(all_checks); do
    check "$c"
    [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
  done
}

@test "empty files in place of the backup and the logs pass nothing" {
  : >"$ARCHIVE"
  : >"$LOSS_LOG"
  : >"$BOOT_LOG"
  for c in $(all_checks); do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed on an empty file: $output"; return 1; }
  done
}

@test "an archive that is not a manifest list, or holds nothing, is not usable" {
  echo '{"kind":"ConfigMap"}' >"$ARCHIVE"
  check backup-archive-usable
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a manifest archive"* ]] || false

  echo '{"kind":"List","items":[]}' >"$ARCHIVE"
  check backup-archive-usable
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds no objects"* ]] || false
}

@test "an archive without the marker cannot prove a round-trip" {
  echo '{"kind":"List","items":[{"kind":"Deployment","metadata":{"name":"data-writer"}}]}' >"$ARCHIVE"
  check backup-archive-usable
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain the restore-marker"* ]] || false
  check restore-round-tripped
  [ "$status" -ne 0 ]
}

@test "an archive taken before this activation's marker is stale" {
  solved
  archive_with tok-older-run
  check backup-archive-usable
  [ "$status" -ne 0 ]
  [[ "$output" == *"predates the current marker"* ]] || false
}

@test "a missing marker is recorded as a loss, and only its return passes" {
  archive_with tok-activation
  MARKER=gone check loss-was-observed
  [ "$status" -ne 0 ]
  [[ "$output" == *"Loss confirmed and recorded"* ]] || false
  [ -s "$LOSS_LOG" ]

  check loss-was-observed
  [ "$status" -eq 0 ]
  [[ "$output" == *"observed missing 1 time(s)"* ]] || false
}

@test "the wrong fix of re-creating the marker by hand does not round-trip" {
  solved
  TOKEN=tok-hand-made check restore-round-tripped
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-created rather than restored"* ]] || false

  CANARY="" check restore-round-tripped
  [ "$status" -ne 0 ]
}

@test "a marker still missing fails the round-trip with the restore command" {
  solved
  MARKER=gone check restore-round-tripped
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/restore.sh shop"* ]] || false
}

@test "a volume that still holds the original data has not been lost" {
  solved
  BOOT_ID=boot-original check pv-data-loss-demonstrated
  [ "$status" -ne 0 ]
  [[ "$output" == *"still holds the original data"* ]] || false
}

@test "no running data-writer is not proof of data loss" {
  solved
  WRITER_POD="" check pv-data-loss-demonstrated
  [ "$status" -ne 0 ]
  [[ "$output" == *"no data-writer pod is serving"* ]] || false
}

@test "every check refuses to run without a namespace" {
  unset WORKLOAD_NAMESPACE
  for c in $(all_checks); do
    check "$c"
    [ "$status" -eq 2 ]
    [[ "$output" == *"name the namespace"* ]] || false
  done
}
