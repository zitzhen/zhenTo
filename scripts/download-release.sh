#!/usr/bin/env sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Download all assets from a GitHub release (including drafts) with the gh CLI.
#
# Usage:
#   ./download-release.sh <tag>
#   ./download-release.sh <tag> <owner/name>
#   ./download-release.sh <tag> <owner/name> <output dir>
#
# Notes:
#   - Only the tag is required; the repository defaults to the current git remote.
#   - Default output dir is ./<repo name>-<tag> (leading lowercase v is stripped).
#   - Works with sh / bash / zsh (Linux, macOS, Git Bash).
#   - Requires an authenticated gh CLI (gh auth login); downloading drafts needs write access to the repo.

set -eu

TAG=${1:-}
REPO=${2:-}
OUTDIR=${3:-}

usage() {
    cat >&2 <<'EOF'
Usage: ./download-release.sh <tag> [owner/name] [output dir]

  tag         Required, release git tag, e.g. v0.1.1
  owner/name  Optional, full repository name; defaults to the current GitHub repo
  output dir  Optional, defaults to ./<repo name>-<tag>

Examples:
  ./download-release.sh v0.1.1
  ./download-release.sh v0.1.1 zitzhen/zhenTo ./zhenTo-0.1.1
EOF
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

if [ -z "$TAG" ]; then
    usage
    exit 1
fi

command -v gh >/dev/null 2>&1 || fail "gh CLI not found. Install GitHub CLI and run gh auth login first."

# 1. Authenticate (draft releases are only visible to authorized accounts)
if ! gh auth token >/dev/null 2>&1; then
    fail "GitHub authentication failed. Run gh auth login first."
fi

# 2. Repository
if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || fail "Cannot detect the current repository. Pass it explicitly, e.g. ./download-release.sh $TAG owner/name"
fi

TAB=$(printf '\t')
WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t ghdl)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# 3. Locate the release
#    /releases/tags/<tag> returns 404 for drafts, so scan all pages and match by tag;
#    when multiple releases match, prefer the draft one.
DL_TAG="$TAG"
export DL_TAG
RELEASE_JQ='[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv'
if ! gh api "repos/$REPO/releases?per_page=100" --paginate --jq "$RELEASE_JQ" >"$WORKDIR/releases.tsv"; then
    fail "Failed to list releases (repo $REPO)."
fi

FIRST_ID=''
DRAFT_ID=''
while IFS="$TAB" read -r id draft; do
    if [ -n "$id" ]; then
        if [ -z "$FIRST_ID" ]; then FIRST_ID=$id; fi
        if [ "$draft" = "true" ] && [ -z "$DRAFT_ID" ]; then DRAFT_ID=$id; fi
    fi
done <"$WORKDIR/releases.tsv"

RELEASE_ID=$FIRST_ID
IS_DRAFT=false
if [ -n "$DRAFT_ID" ]; then
    RELEASE_ID=$DRAFT_ID
    IS_DRAFT=true
fi
[ -n "$RELEASE_ID" ] || fail "No release found with tag $TAG (drafts included)."

# 4. Output directory
REPO_NAME=${REPO##*/}
TAG_DIR=$(printf '%s' "$TAG" | sed 's/^v//; s#[/\\:*?"<>|]#-#g')
if [ -z "$OUTDIR" ]; then
    OUTDIR="./$REPO_NAME-$TAG_DIR"
fi
mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)

# 5. Asset list
if ! gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" --paginate \
    --jq '.[] | [.id, .name, .size] | @tsv' >"$WORKDIR/assets.tsv"; then
    fail "Failed to list release assets (release id: $RELEASE_ID)."
fi

TOTAL=$(wc -l <"$WORKDIR/assets.tsv" | tr -d ' ')
[ "$TOTAL" -gt 0 ] || fail "Release $TAG has no downloadable assets."

if [ "$IS_DRAFT" = "true" ]; then KIND='draft'; else KIND='published'; fi
echo "Repo: $REPO"
echo "Release: $TAG ($KIND, id: $RELEASE_ID), $TOTAL assets"
echo "Output dir: $OUTDIR"
echo ""

# 6. Download each asset and verify its size
INDEX=0
SUCCESS=0
while IFS="$TAB" read -r asset_id asset_name asset_size; do
    INDEX=$((INDEX + 1))
    printf '[%s/%s] %s (%s bytes) ... ' "$INDEX" "$TOTAL" "$asset_name" "$asset_size"

    if gh api "repos/$REPO/releases/assets/$asset_id" \
        -H "Accept: application/octet-stream" >"$OUTDIR/$asset_name" 2>"$WORKDIR/err"; then
        ACTUAL=$(wc -c <"$OUTDIR/$asset_name" | tr -d ' ')
        if [ "$asset_size" != "$ACTUAL" ]; then
            rm -f "$OUTDIR/$asset_name"
            echo "Failed: file size mismatch (expected $asset_size, actual $ACTUAL)"
        else
            SUCCESS=$((SUCCESS + 1))
            echo "OK"
        fi
    else
        rm -f "$OUTDIR/$asset_name"
        echo "Failed: $(tr -d '\r' <"$WORKDIR/err" | head -n 1)"
    fi
done <"$WORKDIR/assets.tsv"

echo ""
echo "Done: $SUCCESS/$TOTAL -> $OUTDIR"
[ "$SUCCESS" -eq "$TOTAL" ] || exit 1
