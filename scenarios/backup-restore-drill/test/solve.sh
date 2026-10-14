#!/bin/sh
# The drill a learner walks, for the cluster suite: back up the namespace,
# lose the marker and confirm the loss with verify, restore it from the
# archive, then destroy the data volume and restore its claim.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
dir="$PROJECT_ROOT/scenarios/backup-restore-drill/scripts"
. "$dir/_backup_lib.sh"
ns="$WORKLOAD_NAMESPACE"

# The backup fingerprints the volume by the data-writer's boot-id, so take it
# once the writer is serving one.
serving_boot_id() { [ -n "$(live_boot_id "$ns")" ]; }
wait_until 180 "the data-writer serving a boot-id" serving_boot_id
bash "$dir/backup.sh" "$ns"

kubectl -n "$ns" delete configmap restore-marker
if "${LABCTL:-labctl}" scenario verify backup-restore-drill; then
  echo "verify passed with the restore marker deleted" >&2
  exit 1
fi
kubectl apply --server-side --force-conflicts -f "$(archive_path "$ns")"

before=$(head -1 "$(bootid_log "$ns")" 2>/dev/null | awk '{print $2}')
[ -n "$before" ] || {
  echo "the backup recorded no boot-id for the data-writer's volume" >&2
  exit 1
}
kubectl -n "$ns" delete deploy data-writer
kubectl -n "$ns" delete pvc restore-data
bash "$dir/restore.sh" "$ns"

new_volume() {
  live=$(live_boot_id "$ns")
  [ -n "$live" ] && [ "$live" != "$before" ]
}
wait_until 180 "data-writer serving a boot-id from a new volume" new_volume
