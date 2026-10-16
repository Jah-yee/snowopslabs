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

work=$(mktemp -d "${TMPDIR:-/tmp}/prose-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$phrases" >"$work/phrases"

# The guide quotes the phrases it forbids, so it is not checked.
printf '%s\n' "$files" | while IFS= read -r f; do
  if [ -n "$f" ] && [ -f "$f" ] && [ "$f" != docs/WRITING.md ]; then
    printf '%s\n' "$f"
  fi
done >"$work/files"

# One awk pass, lowercasing each line and looking for each phrase as plain
# text. POSIX awk only, so it behaves the same on macOS and Linux.
: >"$work/found"
if [ -s "$work/files" ]; then
  # shellcheck disable=SC2016 # $0 and the rest are awk's, not the shell's
  xargs awk -v list="$work/phrases" '
    BEGIN { while ((getline p < list) > 0) if (p != "") phrase[++n] = tolower(p) }
    {
      line = tolower($0)
      for (i = 1; i <= n; i++) if (index(line, phrase[i])) { print FILENAME ":" FNR ":" $0; break }
    }' <"$work/files" >"$work/found"
fi

if [ -s "$work/found" ]; then
  cat "$work/found"
  echo
  echo "prose: reword these lines; docs/WRITING.md says what to write instead."
  exit 1
fi
echo "prose: no listed phrases found"
