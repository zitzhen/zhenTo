#!/usr/bin/env bash
# Update CONTRIBUTORS from the Signed-off-by trailers in the whole git history.
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
#   4. The file is append-only in practice: every entry already in CONTRIBUTORS
#      keeps its line and its position (only the name spelling is refreshed in
#      place from the newest sign-off), and people who are new to the file are
#      appended at the bottom in first-contribution order. Nothing is ever
#      sorted, so a new contributor never shifts an existing one.

set -euo pipefail

CONTRIBUTORS_FILE="${CONTRIBUTORS_FILE:-CONTRIBUTORS}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

newest="$workdir/newest" # one "Name <email>" per contributor, newest first
oldest="$workdir/oldest" # the same people, oldest first

# 1. Collect every Signed-off-by line, newest first. A single awk pass keeps
#    extraction, bot filtering and de-duplication in one place; it also avoids
#    grep's exit status 1 on an empty history breaking `set -o pipefail`.
git log --format='%B' |
    awk '
        tolower($0) ~ /^signed-off-by:[[:space:]]*[^<>]+<[^<>]+>/ {
            line = $0
            sub(/^[Ss]igned-off-by:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)

            if (!match(line, /<[^<>]+>/)) next
            low = tolower(substr(line, RSTART + 1, RLENGTH - 2))
            if (low ~ /noreply|\[bot\]|support@github\.com/) next
            if (low in seen) next

            seen[low] = 1
            print line
        }
    ' >"$newest"

# 2. Merge. ARGV[1] is the newest-first history, so `latest[]` is complete before
#    the existing file is seen; ARGV[2] is the existing file, ARGV[3] the
#    oldest-first history used only to order the newcomers.
if [ -f "$CONTRIBUTORS_FILE" ]; then
    tac "$newest" >"$oldest"
    awk '
        FILENAME == ARGV[1] {
            match($0, /<[^<>]+>/)
            latest[tolower(substr($0, RSTART + 1, RLENGTH - 2))] = $0
            next
        }
        FILENAME == ARGV[2] {
            if ($0 == "") next
            if (match($0, /<[^<>]+>/)) {
                low = tolower(substr($0, RSTART + 1, RLENGTH - 2))
                if (low in latest) print latest[low]
                else print $0
                listed[low] = 1
            } else {
                print $0
            }
            next
        }
        {
            match($0, /<[^<>]+>/)
            low = tolower(substr($0, RSTART + 1, RLENGTH - 2))
            if (low in listed) next
            listed[low] = 1
            print
        }
    ' "$newest" "$CONTRIBUTORS_FILE" "$oldest" >"$workdir/merged"
else
    # First ever run: the history itself is the order (oldest sign-off first).
    tac "$newest" >"$workdir/merged"
fi

changed=0
if [ -s "$workdir/merged" ] && { [ ! -f "$CONTRIBUTORS_FILE" ] || ! cmp -s "$workdir/merged" "$CONTRIBUTORS_FILE"; }; then
    mkdir -p "$(dirname "$CONTRIBUTORS_FILE")"
    cat "$workdir/merged" >"$CONTRIBUTORS_FILE"
    changed=1
fi

if [ -n "$GITHUB_OUTPUT" ]; then
    printf 'changed=%s\n' "$changed" >>"$GITHUB_OUTPUT"
fi

if [ "$changed" -eq 1 ]; then
    echo "CONTRIBUTORS updated with newly signed-off contributors"
else
    echo "CONTRIBUTORS already up to date"
fi
