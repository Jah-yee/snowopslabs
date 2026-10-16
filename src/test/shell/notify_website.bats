#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# notify-website.sh asks the website to sync when `stable` moves. It must send
# one dispatch naming the branch, keep the token off the command line, say
# what to do when GitHub refuses, and skip quietly when no token is set.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  SCRIPT="$ROOT/scripts/notify-website.sh"
  # curl's stub prints the HTTP status the test wants, as -w '%{http_code}' would.
  stub_script curl <<'EOF'
for arg in "$@"; do
  case "$arg" in
    @*) cat "${arg#@}" >>"$STUB_DIR/headers.seen" ;;
  esac
done
printf '%s' "${CURL_CODE:-204}"
EOF
}

teardown() { stub_teardown; }

@test "without a token it skips and says the daily sync will catch up" {
  WEBSITE_DISPATCH_TOKEN="" run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily sync"* ]] || false
  refute_called curl
}

@test "with a token it sends one dispatch for stable to the website" {
  WEBSITE_DISPATCH_TOKEN=secret SYNC_SHA=abc123 run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_call_count curl 1
  assert_called curl "https://api.github.com/repos/snowopscloud/snowopslabs-web/dispatches"
  assert_called curl '"event_type":"snowopslabs-stable"'
  assert_called curl '"ref":"stable","sha":"abc123"'
  [[ "$output" == *"sync stable at abc123"* ]] || false
}

@test "the token is sent as a header but never on the command line" {
  WEBSITE_DISPATCH_TOKEN=secret run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  refute_called curl "secret"
  grep -q "Authorization: Bearer secret" "$STUB_DIR/headers.seen"
}

@test "the repository and branch can be overridden" {
  WEBSITE_DISPATCH_TOKEN=secret WEBSITE_REPO=me/site SYNC_REF=main run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_called curl "/repos/me/site/dispatches"
  assert_called curl '"ref":"main"'
}

@test "a refused token fails and says to check the token" {
  WEBSITE_DISPATCH_TOKEN=secret CURL_CODE=403 run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 403"* ]] || false
  [[ "$output" == *"WEBSITE_DISPATCH_TOKEN"* ]] || false
}

@test "any other failure fails and says how to sync by hand" {
  WEBSITE_DISPATCH_TOKEN=secret CURL_CODE=502 run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 502"* ]] || false
  [[ "$output" == *"by hand"* ]] || false
}
