#!/usr/bin/env bash
set -eu
# The browser journeys hold the inject open while the file E2E_HOLD names exists.
if [ -n "${E2E_HOLD:-}" ]; then
  echo breaking the demo app
  while [ -f "$E2E_HOLD" ]; do sleep 0.2; done
  echo the demo app is broken
fi
touch "$(dirname "$0")/BROKEN"
