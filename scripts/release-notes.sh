#!/bin/sh
# Prints release notes (markdown) for the commits since the last release tag, written by Claude Code.
# Usage: scripts/release-notes.sh [since-ref]
# Falls back to the plain list of commit subjects when the claude CLI isn't available or fails.
set -e
cd "$(dirname "$0")/.."
SINCE=${1:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}
RANGE=${SINCE:+$SINCE..}HEAD

# Release bookkeeping isn't a change anyone uses.
COMMITS=$(git log --no-merges --format='%s%n%b%n---' "$RANGE" \
  | grep -v -e '^Co-Authored-By:' -e '^Appcast: ' -e '^Release [0-9]' | sed '/^$/d')
[ -n "$COMMITS" ] || { echo "release-notes: no commits since ${SINCE:-the beginning}" >&2; exit 1; }

PROMPT="Write the release notes for a new version of Shift, a native macOS app that runs coding tasks \
in parallel with Claude Code or Codex. They are shown to users in the app's update window.

Below are the commits since the last release (subject, body, then ---).

Rules:
- A markdown bullet list only: no heading, no intro, no closing line.
- One bullet per change a user would notice, 2 to 8 bullets, most noticeable first. Merge commits about the same change.
- Plain, short, present tense, from the user's point of view (\"Drag projects to reorder them\"), not implementation details.
- Leave out tests, refactors, build and release tooling, docs, and internal fixes users can't see.

Commits:
$COMMITS"

if command -v claude >/dev/null 2>&1 && NOTES=$(printf '%s' "$PROMPT" | claude -p 2>/dev/null) && [ -n "$NOTES" ]; then
  printf '%s\n' "$NOTES"
else
  echo "release-notes: claude unavailable, listing commit subjects" >&2
  git log --no-merges --format='- %s' "$RANGE" | grep -v -e '^- Appcast: ' -e '^- Release [0-9]'
fi
