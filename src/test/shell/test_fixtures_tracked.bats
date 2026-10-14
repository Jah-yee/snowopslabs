#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The hermetic tests' fixtures must reach the repository. A broad ignore rule
# (such as bin/) silently drops one, the tests pass on the machine that has it
# and every other checkout fails.

load 'helpers/stub'

@test "no file under src/test/fixtures is ignored by git" {
  root="$(project_root)"
  command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  ignored=$(cd "$root" && find src/test/fixtures -type f | git check-ignore --stdin || true)
  [ -z "$ignored" ] || {
    echo "ignored by .gitignore, so never committed:"
    echo "$ignored"
    false
  }
}
