#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../_lib/workload.sh"

# Grades the objective the drill previously only suggested: recovering prod from
# a bad release.
#
# Rolling forward always creates a new ReplicaSet; going back ('kubectl rollout
# undo', or setting the image to a tag prod ran before) re-activates an older
# one, and the Deployment controller records the revisions it served before in
# its deployment.kubernetes.io/revision-history annotation. So a serving
# ReplicaSet with a revision history is a prod that went somewhere and came
# back, whichever route was taken and however quickly.

NS="env-prod"
APP="${WORKLOAD_NAME}"

if ! kubectl -n "$NS" get deploy "$APP" >/dev/null 2>&1; then
  echo "NOT COMPLETE: no ${APP} Deployment in ${NS}." >&2
  exit 1
fi

# One line per ReplicaSet: revision, name, and the revisions it served before.
if ! RS="$(kubectl -n "$NS" get rs -l "app=${APP}" \
  -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision} {.metadata.name} {.metadata.annotations.deployment\.kubernetes\.io/revision-history}{"\n"}{end}' \
  2>/dev/null)"; then
  echo "NOT COMPLETE: could not read the ReplicaSets in ${NS}." >&2
  exit 1
fi
COUNT="$(printf '%s\n' "$RS" | grep -c . || true)"

if [ "${COUNT:-0}" -lt 2 ]; then
  echo "PENDING: ${NS} has only had one ReplicaSet, so nothing has been rolled out to roll back." >&2
  echo "  Promote a release to prod first, then rehearse the recovery." >&2
  exit 1
fi

# The ReplicaSet carrying the highest revision is the one serving.
SERVING="$(printf '%s\n' "$RS" | grep . | sort -rn | head -1)"
SERVING_REV="$(printf '%s' "$SERVING" | awk '{print $1}')"
SERVING_RS="$(printf '%s' "$SERVING" | awk '{print $2}')"
SERVED_BEFORE="$(printf '%s' "$SERVING" | awk '{print $3}')"

if [ -z "$SERVED_BEFORE" ]; then
  echo "PENDING: ${NS} is serving its newest ReplicaSet (${SERVING_RS}), so it has only ever rolled forward." >&2
  echo "  Rehearse the recovery. Ship something that cannot land, watch verify report the drift," >&2
  echo "  then undo it:" >&2
  echo "    kubectl -n ${NS} set image deployment/${APP} ${APP}=${APP}:v9.9.9" >&2
  echo "    labctl scenario verify env-promotion        # drift: spec says v9.9.9, pods do not" >&2
  echo "    kubectl -n ${NS} rollout undo deployment/${APP}" >&2
  echo "    kubectl -n ${NS} rollout status deployment/${APP}" >&2
  echo "  Then put env-metadata's declared_tag back to the release you rolled back to." >&2
  exit 1
fi

echo "OK: ${NS} is serving ${SERVING_RS} (revision ${SERVING_REV}), which it served before as"
echo "revision ${SERVED_BEFORE}. Prod went forward and was brought back - and the rollback reused"
echo "an existing ReplicaSet rather than building anything, which is why it is the fastest lever"
echo "you have in an incident."
