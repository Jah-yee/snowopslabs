#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# scripts/release.sh opens the release pull request: a branch off main whose
# first commit sets LAB_VERSION to the release and whose second moves it on to
# the next -dev. Each test runs it in a throwaway clone of a local bare remote,
# with gh stubbed.

load 'helpers/stub'

setup() {
  stub_setup
  stub_command gh
  ROOT="$(project_root)"
  export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
  export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

  REMOTE="$STUB_DIR/remote.git"
  CLONE="$STUB_DIR/clone"
  git init --quiet --bare -b main "$REMOTE"
  git init --quiet -b main "$CLONE"
  mkdir -p "$CLONE/scripts"
  cp "$ROOT/scripts/release.sh" "$CLONE/scripts/release.sh"
  echo "1.6.0-dev" >"$CLONE/LAB_VERSION"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit --quiet -m init
  git -C "$CLONE" remote add origin "$REMOTE"
  git -C "$CLONE" push --quiet origin main
}

teardown() {
  stub_teardown
}

version_at() {
  git -C "$REMOTE" show "$1:LAB_VERSION"
}

@test "pushes a release commit then the next -dev, and opens the pull request" {
  run sh "$CLONE/scripts/release.sh" 1.6.0
  [ "$status" -eq 0 ]
  [ "$(version_at release/v1.6.0~1)" = "1.6.0" ]
  [ "$(version_at release/v1.6.0)" = "1.7.0-dev" ]
  [ "$(git -C "$REMOTE" log -1 --format=%s release/v1.6.0~1)" = "release: v1.6.0" ]
  git -C "$REMOTE" log -1 --format=%B release/v1.6.0~1 | grep -q '^Signed-off-by: Tester'
  [ "$(git -C "$REMOTE" rev-parse release/v1.6.0~2)" = "$(git -C "$REMOTE" rev-parse main)" ]
  [ "$(git -C "$CLONE" symbolic-ref --short HEAD)" = "main" ]
  assert_called gh "pr create --base main --head release/v1.6.0 --title release: v1.6.0"
}

@test "the next version can be named" {
  run sh "$CLONE/scripts/release.sh" 1.6.0 2.0.0-dev
  [ "$status" -eq 0 ]
  [ "$(version_at release/v1.6.0)" = "2.0.0-dev" ]
}

@test "refuses a malformed version before touching git" {
  for bad in v1.6.0 1.6 1.6.0-rc1; do
    run sh "$CLONE/scripts/release.sh" "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"X.Y.Z"* ]] || false
  done
  run sh "$CLONE/scripts/release.sh" 1.6.0 1.7.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"X.Y.Z-dev"* ]] || false
  refute_called gh
}

@test "refuses a dirty working tree" {
  echo change >"$CLONE/LAB_VERSION"
  run sh "$CLONE/scripts/release.sh" 1.6.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree has changes"* ]] || false
  refute_called gh
}

@test "refuses a version that is already tagged" {
  git -C "$CLONE" tag v1.6.0
  git -C "$CLONE" push --quiet origin v1.6.0
  run sh "$CLONE/scripts/release.sh" 1.6.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"already tagged"* ]] || false
}

@test "refuses when main is not on a -dev version" {
  echo "1.5.0" >"$CLONE/LAB_VERSION"
  git -C "$CLONE" commit --quiet -am "release: v1.5.0"
  git -C "$CLONE" push --quiet origin main
  run sh "$CLONE/scripts/release.sh" 1.6.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a -dev version"* ]] || false
  refute_called gh
}
