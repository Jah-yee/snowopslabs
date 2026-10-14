#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The demo apps' charts serve the app on the host the deploy engine passes as
# ingress.host, which follows the lab's domain. A chart that ignores it serves
# every lab on the default lab's host, so a lab with another name finds its
# app answering 404.

load 'helpers/stub'

setup() {
  ROOT="$(project_root)"
  if ! command -v helm >/dev/null 2>&1; then
    # CI must run these; a developer without helm is told why they skipped.
    [ -z "${CI:-}" ] || { echo "helm is not installed on this CI runner"; false; }
    skip "helm is not installed"
  fi
}

charts() {
  printf '%s\n' "$ROOT/apps/go-api/deploy/helm" "$ROOT/apps/echo-server/deploy/helm" "$ROOT/apps/_shared/chart"
}

@test "each app chart serves ingress.host, and only it" {
  while read -r chart; do
    run helm template t "$chart" --set appName=zz-app --set image.repository=zz-app --set ingress.host=zz-app.lab.test
    [ "$status" -eq 0 ] || { echo "$chart: $output"; false; }
    [[ "$output" == *'host: "zz-app.lab.test"'* || "$output" == *"host: zz-app.lab.test"* ]] || { echo "$chart ignores ingress.host"; false; }
    [[ "$output" != *"snowops.localhost"* ]] || { echo "$chart still serves the default host"; false; }
  done < <(charts)
}

@test "without ingress.host a chart serves its default host" {
  while read -r chart; do
    run helm template t "$chart" --set appName=zz-app --set image.repository=zz-app
    [ "$status" -eq 0 ] || { echo "$chart: $output"; false; }
    [[ "$output" == *"snowops.localhost"* ]] || { echo "$chart has no default host"; false; }
  done < <(charts)
}

@test "the deploy engine passes the lab's domain as ingress.host" {
  grep -q -- '--set "ingress.host=${APP_NAME}.${DOMAIN_SUFFIX:-${CLUSTER_NAME:-snowops}.localhost}"' \
    "$ROOT/src/engine/deploy/helm.sh"
}
