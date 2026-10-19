#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# .devcontainer/setup.sh is a codespace's first run: it puts labctl on PATH
# from a release on stable, from source on main, then runs labctl init. Every
# command it calls is a stub that logs its name.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/snowops-devcontainer.XXXXXX")" && pwd)"
  LOG="$WORK/calls"
  export LOG
  unset SNOWOPS_VERSION

  CLONE="$WORK/lab"
  mkdir -p "$CLONE/.devcontainer" "$CLONE/config" "$WORK/bin"
  cp "$ROOT/.devcontainer/setup.sh" "$CLONE/.devcontainer/setup.sh"
  echo "PROFILE=k3d" >"$CLONE/config/.env.example"
  stub "$CLONE/install.sh" install.sh
  for cmd in make labctl docker timeout; do stub "$WORK/bin/$cmd" "$cmd"; done
  export PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

# stub <path> <name> writes a command that logs its name and arguments.
stub() {
  printf '#!/bin/sh\necho "%s $*" >>"$LOG"\n' "$2" >"$1"
  chmod +x "$1"
}

@test "a release checkout installs the released labctl, then builds the lab" {
  echo "1.8.0" >"$CLONE/LAB_VERSION"
  run sh "$CLONE/.devcontainer/setup.sh"
  [ "$status" -eq 0 ]
  grep -q '^install.sh' "$LOG"
  ! grep -q '^make' "$LOG"
  [ "$(tail -n 1 "$LOG")" = "labctl init" ]
}

@test "main builds labctl from source and creates .env, then builds the lab" {
  echo "1.8.0-dev" >"$CLONE/LAB_VERSION"
  run sh "$CLONE/.devcontainer/setup.sh"
  [ "$status" -eq 0 ]
  grep -qxF "make -C $CLONE cli-install" "$LOG"
  ! grep -q '^install.sh' "$LOG"
  [ "$(cat "$CLONE/.env")" = "PROFILE=k3d" ]
  [ "$(tail -n 1 "$LOG")" = "labctl init" ]
}

@test "main keeps an existing .env" {
  echo "1.8.0-dev" >"$CLONE/LAB_VERSION"
  echo "PROFILE=kind" >"$CLONE/.env"
  run sh "$CLONE/.devcontainer/setup.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLONE/.env")" = "PROFILE=kind" ]
}

@test "SNOWOPS_VERSION installs that release even on main" {
  echo "1.8.0-dev" >"$CLONE/LAB_VERSION"
  SNOWOPS_VERSION=9.9.9 run sh "$CLONE/.devcontainer/setup.sh"
  [ "$status" -eq 0 ]
  grep -q '^install.sh' "$LOG"
  ! grep -q '^make' "$LOG"
}

@test "a failed source build stops before labctl init" {
  echo "1.8.0-dev" >"$CLONE/LAB_VERSION"
  printf '#!/bin/sh\necho "make $*" >>"$LOG"\nexit 2\n' >"$WORK/bin/make"
  run sh "$CLONE/.devcontainer/setup.sh"
  [ "$status" -ne 0 ]
  ! grep -q '^labctl' "$LOG"
}
