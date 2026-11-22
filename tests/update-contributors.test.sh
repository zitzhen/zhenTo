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

# 1. Extract from Signed-off-by, de-duplicate by email, keep first-contribution
#    order (the existing file has no prior entries, so history order wins).
commit "first" "Signed-off-by: freedom-323 <long@example.com>"
commit "second" "Signed-off-by: Oliver Lin <oliver@example.com>"
run_generator
expected=$'freedom-323 <long@example.com>\nOliver Lin <oliver@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "extraction / history order"
grep -qx 'changed=1' "$workdir/output" || fail "first run must report changed=1"

# 2. Idempotent: a second run rewrites nothing.
run_generator
grep -qx 'changed=0' "$workdir/output" || fail "unchanged run must report changed=0"
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "idempotent run must not touch the file"

# 3. Bots and privacy addresses never become contributors.
commit "bot" $'Signed-off-by: dependabot[bot] <support@github.com>\nSigned-off-by: Bot User <123+bot@users.noreply.github.com>'
run_generator
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "bot sign-offs leaked in"
grep -qx 'changed=0' "$workdir/output" || fail "bot-only commits must not change the file"

# 4. A new contributor is appended at the bottom, even when their name sorts
#    first: existing entries must never move.
commit "newcomer" "Signed-off-by: AAA First <aaa@example.com>"
run_generator
expected=$'freedom-323 <long@example.com>\nOliver Lin <oliver@example.com>\nAAA First <aaa@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "new contributor must be appended, not inserted"
grep -qx 'changed=1' "$workdir/output" || fail "a new contributor must report changed=1"

# 5. A hand-ordered file is preserved exactly as written; new people go last.
printf 'Oliver Lin <oliver@example.com>\nfreedom-323 <long@example.com>\n' >"$workdir/CONTRIBUTORS"
run_generator
expected=$'Oliver Lin <oliver@example.com>\nfreedom-323 <long@example.com>\nAAA First <aaa@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "existing order must be preserved verbatim"
grep -qx 'changed=1' "$workdir/output" || fail "appending must report changed=1"

# 6. An entry whose email differs only by case is the same person: it is not
#    appended again, it keeps its position, and its spelling follows the newest
#    sign-off.
printf 'Oliver Lin <oliver@Example.com>\nfreedom-323 <long@example.com>\nAAA First <aaa@example.com>\n' >"$workdir/CONTRIBUTORS"
run_generator
expected=$'Oliver Lin <oliver@example.com>\nfreedom-323 <long@example.com>\nAAA First <aaa@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "case-variant email was treated as a new contributor"
grep -qx 'changed=1' "$workdir/output" || fail "spelling refresh must report changed=1"
run_generator
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "case-variant run must settle"
grep -qx 'changed=0' "$workdir/output" || fail "settled run must report changed=0"

# 7. Newest sign-off wins the name spelling for the same email, keeping its slot.
commit "rename" "Signed-off-by: Oliver L. <oliver@example.com>"
printf 'Oliver Lin <oliver@example.com>\nfreedom-323 <long@example.com>\nAAA First <aaa@example.com>\n' >"$workdir/CONTRIBUTORS"
run_generator
expected=$'Oliver L. <oliver@example.com>\nfreedom-323 <long@example.com>\nAAA First <aaa@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "newest spelling should replace the old one in place"

# 8. Missing file is created; ignored trailer forms are not parsed.
rm -f "$workdir/CONTRIBUTORS"
commit "noise" $'not-a-trailer: Someone <someone@example.com>\nSigned-off-by: No Email Here'
run_generator
expected=$'freedom-323 <long@example.com>\nAAA First <aaa@example.com>\nOliver L. <oliver@example.com>'
[ "$(cat "$workdir/CONTRIBUTORS")" = "$expected" ] || fail "invalid trailers must be ignored"
grep -qx 'changed=1' "$workdir/output" || fail "recreated file must report changed=1"

echo "update-contributors tests passed"
