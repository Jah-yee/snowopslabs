#!/usr/bin/env bash
# Passes when the learner has injected service-selector-broken and fixed it
# themselves. Cluster state after a resolve is identical to state before the
# inject, so the run history is the only evidence the module was actually done
# - and resolvedBy distinguishes a real fix from the escape hatch.
#
# Only the most recent run of this fault counts: an older fix must not pass a
# lab where the fault was injected again and left alone. That last run has to
# be the learner fixing it by hand.
set -euo pipefail

# labctl sets LAB_STATE_DIR; the fallback is its default location.
HISTORY="${LAB_STATE_DIR:-${SNOWOPS_HOME:-$HOME/.snowops}/state/${CLUSTER_NAME:-snowops}}/history/results.jsonl"

[ -f "$HISTORY" ] || exit 1

LAST="$(grep '"kind":"incident"' "$HISTORY" |
  grep '"name":"service-selector-broken"' | tail -1)"

if [ -z "$LAST" ]; then
  echo "No run of service-selector-broken recorded yet - inject it and fix it." >&2
  exit 1
fi

if ! printf '%s\n' "$LAST" | grep -q '"resolvedBy":"manual"'; then
  echo "The last service-selector-broken run was not resolved by hand." >&2
  echo "  'labctl incident resolve' is the escape hatch, not the exercise:" >&2
  echo "  inject it again and repair the Service yourself." >&2
  exit 1
fi
