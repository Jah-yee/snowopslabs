#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Code changed, test changed.
#
# A change to Go, shell or UI source must change a test with it:
#   - a Go file needs a changed _test.go in the same directory;
#   - a shell script needs a changed bats file, Go test or test fixture;
#   - a UI source file needs a changed component test or browser journey.
# A change that needs no test says why in a commit trailer:
#   Tests-Not-Needed: <reason>
#
# Environment:
#   BASE_REF          ref the change is measured against (default origin/main)
#   TESTS_NOT_NEEDED  the reason, for a change that is not committed yet
#   CHANGED_FILES     changed paths, one per line, instead of asking git
#   COMMIT_MESSAGES   commit messages to search, instead of asking git
set -eu

root=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")/.." && pwd
)
cd "$root"

base=${BASE_REF:-origin/main}

# skip_or_fail explains why the change cannot be measured. A developer's
# machine carries on; CI must never pass a gate it did not run.
skip_or_fail() {
  if [ -n "${CI:-}" ]; then
    echo "test-check: $1" >&2
    exit 1
  fi
  echo "test-check: skipped - $1"
  exit 0
}

if [ -z "${CHANGED_FILES+set}" ]; then
  git rev-parse --show-toplevel >/dev/null 2>&1 || skip_or_fail "not a git checkout"
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    skip_or_fail "base ref '$base' not found (git fetch origin, or set BASE_REF)"
  merge_base=$(git merge-base "$base" HEAD) || skip_or_fail "no common ancestor with '$base'"
  # Deleted files are left out: removing code needs no test, and a deleted
  # test proves nothing.
  CHANGED_FILES=$(
    git diff --name-only --diff-filter=d -M "$merge_base" --
    git ls-files --others --exclude-standard
  )
  COMMIT_MESSAGES=${COMMIT_MESSAGES-$(git log --format=%B "$merge_base"..HEAD)}
fi

reason=${TESTS_NOT_NEEDED:-}
if [ -z "$reason" ]; then
  reason=$(printf '%s\n' "${COMMIT_MESSAGES:-}" |
    sed -n 's/^[Tt]ests-[Nn]ot-[Nn]eeded:[[:space:]]*\(.*\)$/\1/p' | head -n 1)
fi

go_sources=""
go_test_dirs=""
shell_sources=""
shell_tests=0
ui_sources=""
ui_tests=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    src/ui/src/test/* | src/ui/src/types/* | src/ui/src/main.tsx | *.d.ts) ;;
    src/ui/src/*.test.ts | src/ui/src/*.test.tsx | src/ui/e2e/*) ui_tests=1 ;;
    src/ui/src/*.ts | src/ui/src/*.tsx) ui_sources="$ui_sources$f
" ;;
    src/ui/*) ;;
    *_test.go)
      shell_tests=1
      go_test_dirs="$go_test_dirs$(dirname "$f")
"
      ;;
    *.bats | */testdata/* | */test/*) shell_tests=1 ;;
    *.go) go_sources="$go_sources$f
" ;;
    *.sh) shell_sources="$shell_sources$f
" ;;
  esac
done <<EOF
$CHANGED_FILES
EOF

problems=""

go_missing=$(printf '%s' "$go_sources" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  dir=$(dirname "$f")
  printf '%s' "$go_test_dirs" | grep -Fxq -- "$dir" || echo "  $f"
done)
if [ -n "$go_missing" ]; then
  problems="${problems}Go source changed with no _test.go changed in the same directory:
$go_missing
"
fi

if [ -n "$shell_sources" ] && [ "$shell_tests" -eq 0 ]; then
  problems="${problems}Shell scripts changed with no bats file, Go test or test fixture changed:
$(printf '%s' "$shell_sources" | sed 's/^/  /')
"
fi

if [ -n "$ui_sources" ] && [ "$ui_tests" -eq 0 ]; then
  problems="${problems}UI source changed with no component test or browser journey changed:
$(printf '%s' "$ui_sources" | sed 's/^/  /')
"
fi

if [ -z "$problems" ]; then
  echo "test-check passed: every changed area changed a test"
  exit 0
fi

if [ -n "$reason" ]; then
  if [ "${#reason}" -lt 10 ]; then
    echo "test-check: 'Tests-Not-Needed: $reason' is too short to be a reason" >&2
    exit 1
  fi
  echo "test-check waived - Tests-Not-Needed: $reason"
  printf '%s' "$problems" | sed 's/^/  /'
  exit 0
fi

{
  echo "test-check failed"
  echo
  printf '%s' "$problems"
  echo
  echo "Add the tests (docs/TESTING.md says which), or say why none are needed in"
  echo "a commit message trailer:  Tests-Not-Needed: <reason>"
} >&2
exit 1
