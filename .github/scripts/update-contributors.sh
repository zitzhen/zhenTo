#!/usr/bin/env bash
# Rebuild CONTRIBUTORS from the Signed-off-by trailers in the whole git history.
# Called by .github/workflows/contributors.yml after a PR is merged.
#
# Environment:
#   CONTRIBUTORS_FILE  target file (default: CONTRIBUTORS, relative to cwd)
#   GITHUB_OUTPUT      optional file that receives "changed=<0|1>"
#
# Rules:
#   1. Only "Signed-off-by: Name <email>" trailers are used as the source of truth.
#   2. Bot identities and privacy addresses are ignored (they are not contributors).
#   3. De-duplicate by lower-cased email; the newest sign-off wins the spelling
#      because `git log` walks commits newest-first.
#   4. Sort case-insensitively so the output is deterministic and idempotent.

set -euo pipefail

CONTRIBUTORS_FILE="${CONTRIBUTORS_FILE:-CONTRIBUTORS}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# git log --format=%B prints each commit body newest-first. A single awk pass
# keeps extraction, bot filtering and de-duplication in one place; it also
# avoids grep's exit status 1 on an empty history breaking `set -o pipefail`.
git log --format='%B' |
    awk '
        tolower($0) ~ /^signed-off-by:[[:space:]]*[^<>]+<[^<>]+>/ {
            line = $0
            sub(/^[Ss]igned-off-by:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)

            if (!match(line, /<[^<>]+>/)) next
            email = substr(line, RSTART + 1, RLENGTH - 2)

            low = tolower(email)
            if (low ~ /noreply|\[bot\]|support@github\.com/) next
            if (low in seen) next

            seen[low] = 1
            print line
        }
    ' |
    LC_ALL=C sort -f >"$tmp"

changed=0
if [ ! -f "$CONTRIBUTORS_FILE" ] || ! cmp -s "$tmp" "$CONTRIBUTORS_FILE"; then
    mkdir -p "$(dirname "$CONTRIBUTORS_FILE")"
    cat "$tmp" >"$CONTRIBUTORS_FILE"
    changed=1
fi

if [ -n "$GITHUB_OUTPUT" ]; then
    printf 'changed=%s\n' "$changed" >>"$GITHUB_OUTPUT"
fi

if [ "$changed" -eq 1 ]; then
    echo "CONTRIBUTORS rebuilt from Signed-off-by trailers"
else
    echo "CONTRIBUTORS already up to date"
fi
