#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# bash 3.2, the bash macOS ships, does not stop a bats test when a [[ ]] that
# is not the test's last command fails, so such an assertion never fails
# there. Every [[ ]] that stands as an assertion ends in `|| false`, which
# fails under any bash.

load 'helpers/stub'

@test "every [[ ]] assertion in the shell suite ends in || false" {
  bare=$(grep -n '^[[:space:]]*\[\[.*\]\][[:space:]]*$' "$(project_root)"/src/test/shell/*.bats || true)
  [ -z "$bare" ] || {
    echo "these [[ ]] assertions pass vacuously under bash 3.2; end each with || false:"
    echo "$bare"
    false
  }
}
