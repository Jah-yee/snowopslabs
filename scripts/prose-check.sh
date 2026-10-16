#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Fails when Markdown or YAML text uses a phrase from the list below. They are
# padding or hype that make documentation read as generated; docs/WRITING.md
# explains each kind. Words that have honest technical uses ("robust") are
# left to review rather than listed here.
#
# Environment:
#   PROSE_FILES  paths to check, one per line, instead of every tracked file
set -eu

root=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")/.." && pwd
)
cd "$root"

# One phrase per line, matched case-insensitively as plain text.
phrases='delve
delving
seamless
cutting-edge
game-changer
game changer
best-in-class
world-class
supercharge
effortless
look no further
rest assured
in today'"'"'s
ever-evolving
it'"'"'s worth noting
it is worth noting
it'"'"'s important to note
it is important to note
plays a crucial role
plays a pivotal role
plays a vital role
navigate the complexities
harness the power
unlock the power
unleash the power
elevate your
empowers you
a testament to
rich tapestry
embark on
let'"'"'s dive
dive into
deep dive
in conclusion
in summary
to sum up
whether you'"'"'re a beginner'

if [ -n "${PROSE_FILES+set}" ]; then
  files=$PROSE_FILES
else
  files=$(git ls-files '*.md' '*.yaml' '*.yml')
fi

patterns=$(mktemp "${TMPDIR:-/tmp}/prose-check.XXXXXX")
trap 'rm -f "$patterns"' EXIT
printf '%s\n' "$phrases" >"$patterns"

found=$(printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case "$f" in
    # The guide quotes the phrases it forbids.
    docs/WRITING.md) continue ;;
  esac
  grep -n -i -F -f "$patterns" -- "$f" 2>/dev/null | sed "s|^|$f:|" || true
done)

if [ -n "$found" ]; then
  printf '%s\n' "$found"
  echo
  echo "prose: reword these lines; docs/WRITING.md says what to write instead."
  exit 1
fi
echo "prose: no listed phrases found"
