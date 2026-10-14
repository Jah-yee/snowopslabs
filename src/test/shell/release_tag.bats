#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# scripts/release-tag.sh tags the release commit a push to main brought in, and
# only that commit. Each test builds the push in a throwaway repository.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  REPO="$(mktemp -d "${TMPDIR:-/tmp}/snowops-release-tag.XXXXXX")"
  export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
  export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  cd "$REPO"
  git init --quiet -b main
  commit 1.6.0-dev "feat: something"
  BEFORE="$(git rev-parse HEAD)"
}

teardown() {
  rm -rf "$REPO"
}

# commit <LAB_VERSION> <subject>
commit() {
  echo "$1" >LAB_VERSION
  git add LAB_VERSION
  git commit --quiet --allow-empty -m "$2"
}

# release_branch leaves a release/v1.6.0 branch shaped as make release makes it.
release_branch() {
  git switch --quiet -c release/v1.6.0
  commit 1.6.0 "release: v1.6.0"
  commit 1.7.0-dev "chore: start 1.7.0-dev"
  git switch --quiet main
}

tag_push() {
  run sh "$ROOT/scripts/release-tag.sh" "$BEFORE" "$(git rev-parse HEAD)"
}

@test "a merge commit of the release pull request tags the release commit" {
  release_branch
  git merge --quiet --no-ff -m "Merge pull request #65 from x/release/v1.6.0" release/v1.6.0
  tag_push
  [ "$status" -eq 0 ]
  [ "$output" = "v1.6.0" ]
  [ "$(git rev-parse 'v1.6.0^{commit}')" = "$(git rev-parse release/v1.6.0~1)" ]
  [ "$(git cat-file -t v1.6.0)" = "tag" ]
}

@test "a rebase merge tags the rebased release commit" {
  release_branch
  git merge --quiet --ff-only release/v1.6.0
  tag_push
  [ "$status" -eq 0 ]
  [ "$output" = "v1.6.0" ]
  [ "$(git show v1.6.0:LAB_VERSION)" = "1.6.0" ]
}

@test "an ordinary push tags nothing" {
  commit 1.6.0-dev "fix: something"
  tag_push
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(git tag)" ]
}

@test "a release that is already tagged is left alone" {
  release_branch
  git tag -a v1.6.0 -m v1.6.0 release/v1.6.0~1
  git merge --quiet --no-ff -m merge release/v1.6.0
  tag_push
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a squash merge fails and says how to recover" {
  commit 1.7.0-dev "release: v1.6.0 (#65)"
  tag_push
  [ "$status" -eq 1 ]
  [[ "$output" == *"v1.6.0 was merged without its release commit"* ]] || false
  [[ "$output" == *"make release VERSION=1.6.0"* ]] || false
}

@test "the first push of a branch scans its whole history" {
  commit 1.6.0 "release: v1.6.0"
  run sh "$ROOT/scripts/release-tag.sh" 0000000000000000000000000000000000000000 "$(git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.6.0" ]
}
