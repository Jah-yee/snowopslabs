#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Guards the WSL-detection helper in bootstrap/setup-tools.sh, which drives the
# post-setup "open it in your Windows browser" notice. The helper is
# kept pure (env var + kernel files only) precisely so it can be sourced here
# without running the installer.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  helpers="$(mktemp "${TMPDIR:-/tmp}/is_wsl.XXXXXX.sh")"
  sed -n '/^is_wsl()/,/^}$/p' "$ROOT/bootstrap/setup-tools.sh" >"$helpers"
  # shellcheck source=/dev/null
  source "$helpers"
  rm -f "$helpers"
}

@test "is_wsl is false when OS is not linux even with WSL_DISTRO_NAME set" {
  OS="darwin" WSL_DISTRO_NAME="Ubuntu" run is_wsl
  [ "$status" -ne 0 ]
}

@test "is_wsl is true when WSL_DISTRO_NAME is set on linux" {
  OS="linux" WSL_DISTRO_NAME="Ubuntu" run is_wsl
  [ "$status" -eq 0 ]
}

@test "is_wsl is false on a plain linux box (no env, no kernel signature)" {
  # Point the kernel-file scan at files that exist but lack the signature by
  # overriding nothing - a normal CI linux runner has neither the env var nor a
  # microsoft/wsl kernel string, which is exactly this case. Run on WSL itself,
  # the real kernel files say WSL, so there is no plain box to check.
  if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
    skip "running on a WSL kernel"
  fi
  OS="linux" WSL_DISTRO_NAME="" run is_wsl
  [ "$status" -ne 0 ]
}
