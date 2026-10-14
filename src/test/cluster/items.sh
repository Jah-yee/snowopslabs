#!/bin/sh
# Prints one JSON object per item with an executable test/solve.sh, for the
# cluster-suite matrix: its kind and name, the runtime to build it on (kind
# unless the scenario's runtimes leave kind out) and how many workers it needs
# (the scenario's requirements.agents, default 1).
#
# Usage: items.sh [root]   (default: this checkout)
set -eu
root="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

for f in "$root"/scenarios/*/test/solve.sh "$root"/incidents/*/test/solve.sh; do
  [ -x "$f" ] || continue
  dir=$(dirname "$(dirname "$f")")
  name=$(basename "$dir")
  kind=$(basename "$(dirname "$dir")")
  kind=${kind%s}
  profile=kind
  agents=1
  if [ "$kind" = scenario ]; then
    spec="$dir/scenario.yaml"
    runtimes=$(awk '/^runtimes:/ { on = 1; next } on && /^  - / { print $2; next } on { exit }' "$spec")
    if [ -n "$runtimes" ] && ! echo "$runtimes" | grep -qx kind; then
      profile=$(echo "$runtimes" | head -1)
    fi
    want=$(awk '/^requirements:/ { on = 1; next } on && /^  agents:/ { print $2; exit } on && /^[^ ]/ { exit }' "$spec")
    [ -z "$want" ] || agents=$want
  fi
  printf '{"kind":"%s","name":"%s","profile":"%s","agents":%s}\n' "$kind" "$name" "$profile" "$agents"
done
