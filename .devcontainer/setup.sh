#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# The codespace's postCreateCommand: put labctl on PATH, then build the lab.
# A release checkout (stable) or a SNOWOPS_VERSION override installs the
# released labctl with install.sh; development content (main) has no release,
# so labctl is built from this clone instead.
set -eu

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Docker comes from a feature that starts dockerd in the background; give it
# up to two minutes. labctl init names the problem if it is still down.
timeout 120 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done' || true

version="$(tr -d '[:space:]' <"$LAB_DIR/LAB_VERSION")"
case "${SNOWOPS_VERSION:-}:$version" in
  :*-*)
    echo "==> $version is development content: building labctl from source"
    make -C "$LAB_DIR" cli-install
    if [ ! -f "$LAB_DIR/.env" ]; then
      cp "$LAB_DIR/config/.env.example" "$LAB_DIR/.env"
    fi
    ;;
  *) "$LAB_DIR/install.sh" ;;
esac

labctl init
