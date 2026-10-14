#!/bin/sh
# Applies a nightly cluster-suite run to the checkout: each item's verified
# flag follows its result, and a scenario's recorded check fixtures replace
# its old ones. A scenario with both fixtures leaves the list of unrecorded
# scenarios.
#
# Usage: apply-results.sh <results-dir> [root]
#   <results-dir>/<kind>-<name>/result      pass or fail
#   <results-dir>/<kind>-<name>/fixtures/   untouched.json and solved.json
set -eu
results="${1:?usage: apply-results.sh <results-dir> [root]}"
root="${2:-$(cd "$(dirname "$0")/../../.." && pwd)}"
unrecorded="$root/src/internal/scenario/testdata/unrecorded-scenarios.txt"

for dir in "$results"/*/; do
  item=$(basename "$dir")
  kind=${item%%-*}
  name=${item#*-}
  case "$kind" in
    scenario) spec="$root/scenarios/$name/scenario.yaml" ;;
    incident) spec="$root/incidents/$name/fault.yaml" ;;
    *)
      echo "skipping $item: not a scenario or incident result" >&2
      continue
      ;;
  esac
  [ -f "$spec" ] || {
    echo "skipping $item: $spec does not exist" >&2
    continue
  }
  verified=false
  [ "$(cat "$dir/result" 2>/dev/null)" = pass ] && verified=true

  tmp="$spec.tmp"
  if grep -q '^verified:' "$spec"; then
    sed "s/^verified:.*/verified: $verified/" "$spec" >"$tmp"
  else
    awk -v v="$verified" '{ print } /^name:/ && !done { print "verified: " v; done = 1 }' "$spec" >"$tmp"
  fi
  mv "$tmp" "$spec"
  echo "$kind $name: verified: $verified"

  if [ "$kind" = scenario ] && [ "$verified" = true ] &&
    [ -f "$dir/fixtures/untouched.json" ] && [ -f "$dir/fixtures/solved.json" ]; then
    mkdir -p "$root/scenarios/$name/test/fixtures"
    cp "$dir/fixtures/untouched.json" "$dir/fixtures/solved.json" "$root/scenarios/$name/test/fixtures/"
    if [ -f "$unrecorded" ]; then
      grep -vx "$name" "$unrecorded" >"$unrecorded.tmp" || true
      mv "$unrecorded.tmp" "$unrecorded"
    fi
    echo "scenario $name: check fixtures recorded"
  fi
done
