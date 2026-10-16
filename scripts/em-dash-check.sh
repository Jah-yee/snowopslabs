#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Fails when a tracked text file contains an em dash. Docs, content and code
# use a comma, a colon, parentheses or a plain " - " instead, so the text reads
# the same here, in the CLI and UI, and on the website.
#
# Environment:
#   EM_DASH_FILES  paths to check, one per line, instead of every tracked file
set -eu

root=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")/.." && pwd
)
cd "$root"

# The character is built from its UTF-8 bytes so this script does not match itself.
dash=$(printf '\342\200\224')

if [ -n "${EM_DASH_FILES+set}" ]; then
  files=$EM_DASH_FILES
else
  files=$(git ls-files)
fi

found=$(printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  grep -n -I -F -- "$dash" "$f" 2>/dev/null | sed "s|^|$f:|" || true
done)

if [ -n "$found" ]; then
  printf '%s\n' "$found"
  echo
  echo "em-dash: replace each one with a comma, a colon, parentheses or ' - '."
  exit 1
fi
echo "em-dash: none found"
