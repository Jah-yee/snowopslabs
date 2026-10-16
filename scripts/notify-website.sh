#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tells snowopslabs-web that `stable` moved, so the website syncs its docs,
# catalog and release notes from the new release. The website's sync workflow
# listens for this repository_dispatch event; it also runs daily, so a missing
# token only delays the update.
#
# Environment:
#   WEBSITE_DISPATCH_TOKEN  token allowed to dispatch to the website repository
#                           (fine-grained, Contents: read and write on it)
#   WEBSITE_REPO            owner/name of the website (default snowopscloud/snowopslabs-web)
#   SYNC_REF                branch the website should sync (default stable)
#   SYNC_SHA                commit that branch now points at, for the run log
#   GITHUB_API              API base URL (default https://api.github.com)
set -eu

repo=${WEBSITE_REPO:-snowopscloud/snowopslabs-web}
ref=${SYNC_REF:-stable}
sha=${SYNC_SHA:-}
api=${GITHUB_API:-https://api.github.com}

if [ -z "${WEBSITE_DISPATCH_TOKEN:-}" ]; then
  echo "notify-website: WEBSITE_DISPATCH_TOKEN is not set; the website picks up $ref on its daily sync instead."
  exit 0
fi

# The token goes to curl in a header file, so it never appears in a process list.
headers=$(mktemp "${TMPDIR:-/tmp}/notify-website.XXXXXX")
trap 'rm -f "$headers"' EXIT
chmod 600 "$headers"
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
  "$WEBSITE_DISPATCH_TOKEN" >"$headers"

body=$(printf '{"event_type":"snowopslabs-stable","client_payload":{"ref":"%s","sha":"%s"}}' "$ref" "$sha")

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "@$headers" \
  -d "$body" \
  "$api/repos/$repo/dispatches")

case "$code" in
  204)
    echo "notify-website: asked $repo to sync $ref${sha:+ at $sha}."
    ;;
  401 | 403 | 404)
    echo "notify-website: $repo refused the dispatch (HTTP $code). Check that WEBSITE_DISPATCH_TOKEN can write to $repo and has not expired." >&2
    exit 1
    ;;
  *)
    echo "notify-website: dispatch to $repo failed (HTTP $code). Run the website's sync workflow by hand from its Actions tab." >&2
    exit 1
    ;;
esac
