#!/usr/bin/env bash
# Offline tests for the CONTRIBUTORS generator. No network, no token.
# Style follows tests/README.md: mktemp -d + trap, git history only.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/.github/scripts/update-contributors.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cd "$workdir"
git init -q
git config user.name "Test Committer"
git config user.email "committer@example.com"
git config commit.gpgsign false

commit() {
    local subject="$1" body="$2"
    printf '%s\n' "$subject" >>history.txt
    git add history.txt
    git commit -q -m "$subject" -m "$body"
}

run_generator() {
    : >"$workdir/output"
    CONTRIBUTORS_FILE="$workdir/CONTRIBUTORS" GITHUB_OUTPUT="$workdir/output" bash "$script"
}

# 1. Extract from Signed-off-by, de-duplicate by email, sort case-insensitively.
commit "first" "Signed-off-by: Oliver Lin <oliver@example.com>"
commit "second" "Signed-off-by: freedom-323 <long@example.com>"
run_generator
expected=$'freedom-323 <long@example.com>\nOliver Lin <oliver@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "extraction / sorting"
grep -qx 'changed=1' "$workdir/output" || fail "first run must report changed=1"

# 2. Idempotent: a second run rewrites nothing.
run_generator
grep -qx 'changed=0' "$workdir/output" || fail "unchanged run must report changed=0"

# 3. Bots and privacy addresses never become contributors.
commit "bot" $'Signed-off-by: dependabot[bot] <support@github.com>\nSigned-off-by: Bot User <123+bot@users.noreply.github.com>'
run_generator
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "bot sign-offs leaked in"
grep -qx 'changed=0' "$workdir/output" || fail "bot-only commits must not change the file"

# 4. Newest sign-off wins the name spelling for the same email.
commit "rename" "Signed-off-by: Oliver L. <oliver@example.com>"
run_generator
[ "$(cat "$workdir/CONTRIBUTORS")" = $'freedom-323 <long@example.com>\nOliver L. <oliver@example.com>' ] ||
    fail "newest spelling should replace the old one"

# 5. Missing file is created; ignored trailer forms are not parsed.
rm -f "$workdir/CONTRIBUTORS"
commit "noise" $'not-a-trailer: Someone <someone@example.com>\nSigned-off-by: No Email Here'
run_generator
[ "$(cat "$workdir/CONTRIBUTORS")" = $'freedom-323 <long@example.com>\nOliver L. <oliver@example.com>' ] ||
    fail "invalid trailers must be ignored"
grep -qx 'changed=1' "$workdir/output" || fail "recreated file must report changed=1"

echo "update-contributors tests passed"
