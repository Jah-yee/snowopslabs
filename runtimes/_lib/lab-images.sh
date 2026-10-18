#!/usr/bin/env bash
# The lab's own app images, for a node that joins after they were imported.
#
# Sourced, not executed:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib/lab-images.sh"

# lab_images <project-root> prints every locally built tag of every app under
# apps/. A node created after the build has none of them, and scenarios run
# tags no pod uses yet (go-api:latest, an older release), so all are imported.
lab_images() {
  local app_env app
  for app_env in "$1"/apps/*/app.env; do
    [ -f "$app_env" ] || continue
    app="$(basename "$(dirname "$app_env")")"
    docker images --format '{{.Repository}}:{{.Tag}}' "$app" 2>/dev/null | grep -v ':<none>$' || true
  done
}
