#!/usr/bin/env bash
# Regression tests for .github/scripts/dco-check.sh.
# Covers the maintainer-rebase case, the noreply rejections, and the fixed
# author/sign-off pairs allowed for automation accounts.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checker="$repo_root/.github/scripts/dco-check.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
case_dir=""
case_base_sha=""
case_head_sha=""
case_pr_login=""

# make_case <name> <author_email> <committer_email> <message_file> <pr_login>
# Sets case_base_sha / case_head_sha for the synthetic repo.
make_case() {
    local name=$1 author_email=$2 committer_email=$3 message_file=$4 pr_login=$5
    local dir="$tmp/$name"
    mkdir -p "$dir"
    git init -q "$dir"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config user.email "test@example.com"

    printf 'base\n' >"$dir/file"
    git -C "$dir" add file
    GIT_AUTHOR_NAME="Base" GIT_AUTHOR_EMAIL="base@example.com" \
        GIT_COMMITTER_NAME="Base" GIT_COMMITTER_EMAIL="base@example.com" \
        git -C "$dir" commit -q -m base

    printf 'change\n' >"$dir/file"
    git -C "$dir" add file
    GIT_AUTHOR_NAME="Contributor" GIT_AUTHOR_EMAIL="$author_email" \
        GIT_COMMITTER_NAME="Maintainer" GIT_COMMITTER_EMAIL="$committer_email" \
        git -C "$dir" commit -q -F "$message_file"

    case_dir="$dir"
    case_base_sha=$(git -C "$dir" rev-parse HEAD~1)
    case_head_sha=$(git -C "$dir" rev-parse HEAD)
    case_pr_login="$pr_login"
}

check_case() {
    local name=$1 expected=$2
    local rc=0
    (
        cd "$case_dir" || exit 1
        EVENT_NAME=pull_request \
            PR_BASE_SHA="$case_base_sha" \
            PR_HEAD_SHA="$case_head_sha" \
            PR_AUTHOR_LOGIN="$case_pr_login" \
            GITHUB_STEP_SUMMARY="$tmp/summary" \
            bash "$checker" >"$tmp/last.out" 2>&1
    ) || rc=$?
    if [ "$rc" = "$expected" ]; then
        printf 'ok   %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s (expected exit %s, got %s)\n' "$name" "$expected" "$rc"
        while IFS= read -r line; do printf '       %s\n' "$line"; done <"$tmp/last.out"
        failed=$((failed + 1))
    fi
}

msg="$tmp/msg"
real_signoff=$'Topic\n\nSigned-off-by: freedom-323 <long.hummingbird.wivo@mask.me>\n'
noreply_signoff=$'Topic\n\nSigned-off-by: freedom-323 <210706743+freedom-323@users.noreply.github.com>\n'
plain_msg=$'Topic\n'

noreply_author="210706743+freedom-323@users.noreply.github.com"
maintainer="oliver@liuxiaozhen.dev"

printf '%s' "$real_signoff" >"$msg"
make_case rebase_by_maintainer "$noreply_author" "$maintainer" "$msg" freedom-323
check_case "maintainer rebase: noreply author + real sign-off" 0

printf '%s' "$real_signoff" >"$msg"
make_case wrong_pr_login "$noreply_author" "$maintainer" "$msg" someone-else
check_case "noreply author not matching PR author still fails" 1

printf '%s' "$noreply_signoff" >"$msg"
make_case noreply_signoff "$noreply_author" "$maintainer" "$msg" freedom-323
check_case "human noreply sign-off is rejected" 1

printf '%s' "$plain_msg" >"$msg"
make_case missing_signoff "$noreply_author" "$maintainer" "$msg" freedom-323
check_case "missing sign-off fails" 1

printf '%s' $'Topic\n\nSigned-off-by: Dev <dev@example.com>\n' >"$msg"
make_case normal_commit dev@example.com dev@example.com "$msg" dev
check_case "normal commit with matching sign-off passes" 0

printf '%s' $'Topic\n\nSigned-off-by: Elsewhere <else@example.com>\n' >"$msg"
make_case mismatched_signoff dev@example.com "$maintainer" "$msg" dev
check_case "sign-off matching neither author nor committer fails" 1

printf '%s' $'Topic\n\nSigned-off-by: dependabot[bot] <support@github.com>\n' >"$msg"
make_case dependabot "49699333+dependabot[bot]@users.noreply.github.com" "$maintainer" "$msg" dependabot
check_case "dependabot exception still passes" 0

bot_author="358577549+zhento-bot[bot]@users.noreply.github.com"

printf '%s' $'Topic\n\nSigned-off-by: zhento[bot] <zhento-bot-noreply@zit.email>\n' >"$msg"
make_case zhento_bot "$bot_author" "$bot_author" "$msg" zhento-bot
check_case "zhento-bot service sign-off passes" 0

printf '%s' $'Topic\n\nSigned-off-by: zhento[bot] <wrong@example.com>\n' >"$msg"
make_case zhento_bot_wrong "$bot_author" "$bot_author" "$msg" zhento-bot
check_case "zhento-bot with a different sign-off fails" 1

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
