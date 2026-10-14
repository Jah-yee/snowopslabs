#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# An app is served on the lab's domain through the lab's ingress class,
# whether it brings its own chart or uses the shared one. A chart left on its
# defaults serves the default lab's host through traefik, so a lab with another
# name, or on nginx, finds its app answering 404.

load 'helpers/stub'

setup() {
  stub_setup
  stub_command docker k3d kind helm kubectl
  ROOT="$(project_root)"
  HELM_SH="$ROOT/src/engine/deploy/helm.sh"
  CONTENT="$STUB_DIR/content"
  mkdir -p "$CONTENT/apps/own/deploy/helm" "$CONTENT/apps/_shared/chart"
  printf 'APP_NAME=own\nDEPLOY_STRATEGY=helm\nHELM_RELEASE_NAME=own\nHELM_VALUES=values.yaml\n' >"$CONTENT/apps/own/app.env"
  : >"$CONTENT/apps/own/deploy/helm/values.yaml"
  mkdir -p "$CONTENT/apps/borrowed"
  printf 'APP_NAME=borrowed\nDEPLOY_STRATEGY=helm\nHELM_RELEASE_NAME=borrowed\n' >"$CONTENT/apps/borrowed/app.env"
  cd "$CONTENT"
  export CLUSTER_NAME=zz-lab INGRESS_CLASS=nginx
  unset DOMAIN_SUFFIX
}

teardown() { stub_teardown; }

@test "an app with its own chart is served on the lab's host through the lab's ingress class" {
  run bash "$HELM_SH" deploy own
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install own apps/own/deploy/helm"
  assert_called helm "ingress.host=own.zz-lab.localhost"
  assert_called helm "ingress.className=nginx"
}

@test "an app on the shared chart is served the same way" {
  run bash "$HELM_SH" deploy borrowed
  [ "$status" -eq 0 ]
  assert_called helm "upgrade --install borrowed apps/_shared/chart"
  assert_called helm "ingress.host=borrowed.zz-lab.localhost"
  assert_called helm "ingress.className=nginx"
}

@test "a pinned DOMAIN_SUFFIX names the host" {
  DOMAIN_SUFFIX=lab.example run bash "$HELM_SH" deploy own
  [ "$status" -eq 0 ]
  assert_called helm "ingress.host=own.lab.example"
}
