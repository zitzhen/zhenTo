#!/usr/bin/env bash
# Verify Developer Certificate of Origin Signed-off-by trailers on a commit range.
# Called by .github/workflows/dco.yml, which supplies the environment below.
#
# Rules:
#   1. Every non-merge commit must carry a "Signed-off-by: Name <email>" trailer
#   2. The sign-off email must match the commit author or committer email
#   3. A sign-off must not use a *noreply* privacy address
#   4. If a maintainer rebases a contributor's commit, GitHub/GitLab keeps the
#      contributor's noreply address as author while the committer becomes the
#      maintainer. When that noreply login is the PR author, a real (non-noreply)
#      sign-off is accepted as the contributor's DCO certification.
#   5. Automation accounts keep their noreply author address and sign off with
#      a fixed service email; only the exact author/sign-off pairs below pass.

set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
PR_BASE_SHA="${PR_BASE_SHA:-}"
PR_HEAD_SHA="${PR_HEAD_SHA:-}"
PUSH_BEFORE="${PUSH_BEFORE:-}"
PUSH_AFTER="${PUSH_AFTER:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
PR_AUTHOR_LOGIN="${PR_AUTHOR_LOGIN:-}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

zero="0000000000000000000000000000000000000000"

# Format: <author email>|<accepted Signed-off-by email>
bot_signoffs=(
    "49699333+dependabot[bot]@users.noreply.github.com|support@github.com"
    "358577549+zhento-bot[bot]@users.noreply.github.com|zhento-bot-noreply@zit.email"
)

# Compute the commit range to check
if [ "$EVENT_NAME" = "pull_request" ]; then
    rev_args=("${PR_BASE_SHA}..${PR_HEAD_SHA}")
    scope="commits added in this PR"
elif [ "${PUSH_BEFORE}" != "$zero" ] && git cat-file -e "${PUSH_BEFORE}^{commit}" 2>/dev/null; then
    rev_args=("${PUSH_BEFORE}..${PUSH_AFTER}")
    scope="commits from this push"
elif git rev-parse --verify --quiet "origin/${DEFAULT_BRANCH}" >/dev/null; then
    # New branch: commits after the divergence point from the default branch
    rev_args=("origin/${DEFAULT_BRANCH}..${PUSH_AFTER}")
    scope="commits on the new branch relative to ${DEFAULT_BRANCH}"
else
    rev_args=(-n 1 "${PUSH_AFTER}")
    scope="the latest commit of this push"
fi

echo "Scope: ${scope} (${rev_args[*]})"

list=$(mktemp)
git rev-list --no-merges "${rev_args[@]}" >"$list"
mapfile -t commits <"$list"
rm -f "$list"
if [ "${#commits[@]}" -eq 0 ]; then
    echo "No commits to check"
    {
        echo "## DCO"
        echo
        echo "No commits to check (${scope})."
    } >>"$GITHUB_STEP_SUMMARY"
    exit 0
fi

fail=0
report=()

for sha in "${commits[@]}"; do
    short=$(git log -1 --format=%h "$sha")
    subject=$(git log -1 --format=%s "$sha")
    body=$(git log -1 --format=%B "$sha")
    author_email=$(git log -1 --format=%ae "$sha" | tr '[:upper:]' '[:lower:]')
    committer_email=$(git log -1 --format=%ce "$sha" | tr '[:upper:]' '[:lower:]')

    # GitHub/GitLab mask web-edit authors as e.g.
    # "210706743+freedom-323@users.noreply.github.com". When a maintainer
    # rebases on that contributor's behalf the committer becomes the
    # maintainer, so a sign-off with the contributor's real email matches
    # neither author nor committer. Resolve the login and tie it to the PR
    # author so only that contributor gets the exception.
    author_is_pr_noreply=0
    if [ -n "$PR_AUTHOR_LOGIN" ]; then
        case "$author_email" in
        *@users.noreply.github.com | *@users.noreply.gitlab.com)
            noreply_local="${author_email%%@*}"
            noreply_login="${noreply_local##*+}"
            if [ "${noreply_login,,}" = "${PR_AUTHOR_LOGIN,,}" ]; then
                author_is_pr_noreply=1
            fi
            ;;
        esac
    fi

    # An automation commit is allowed to keep its noreply author address, but
    # only with the service sign-off registered for that exact author.
    allowed_signoff=""
    for pair in "${bot_signoffs[@]}"; do
        if [ "$author_email" = "${pair%%|*}" ]; then
            allowed_signoff="${pair#*|}"
            break
        fi
    done

    sob_list=$(mktemp)
    printf '%s\n' "$body" |
        sed -n 's/^[Ss]igned-off-by:[[:space:]]*.*<\([^<>]*\)>[[:space:]]*$/\1/p' |
        tr '[:upper:]' '[:lower:]' >"$sob_list"
    mapfile -t sob_emails <"$sob_list"
    rm -f "$sob_list"

    problems=()

    if [ "${#sob_emails[@]}" -eq 0 ]; then
        problems+=("Missing Signed-off-by trailer (add it with 'git commit -s')")
    else
        matched=0
        for email in "${sob_emails[@]}"; do
            email_is_noreply=0
            case "$email" in *noreply*) email_is_noreply=1 ;; esac
            if [ "$email" = "$author_email" ] || [ "$email" = "$committer_email" ] ||
                { [ -n "$allowed_signoff" ] && [ "$email" = "$allowed_signoff" ]; } ||
                { [ "$author_is_pr_noreply" -eq 1 ] && [ "$email_is_noreply" -eq 0 ]; }; then
                matched=1
            fi
        done
        if [ "$matched" -eq 0 ]; then
            problems+=("Signed-off-by email must match the author (${author_email}) or committer (${committer_email})")
        fi
        for email in "${sob_emails[@]}"; do
            case "$email" in
            *noreply*)
                if [ "$email" != "$allowed_signoff" ]; then
                    problems+=("Signed-off-by uses a privacy email <${email}>, please use a real email")
                fi
                ;;
            esac
        done
    fi

    if [ -n "$allowed_signoff" ]; then
        echo "NOTE  ${short}: automation author ${author_email}; service sign-off accepted"
    else
        case "$author_email" in
        *noreply*)
            if [ "$author_is_pr_noreply" -eq 1 ]; then
                echo "NOTE  ${short}: author is PR author ${PR_AUTHOR_LOGIN} behind a noreply address; real-email sign-off accepted"
            else
                problems+=("Author email is a privacy email <${author_email}>, please configure a real email and re-commit")
            fi
            ;;
        esac
    fi

    if [ "${#problems[@]}" -eq 0 ]; then
        echo "OK   ${short} ${subject}"
    else
        fail=1
        echo "FAIL ${short} ${subject}"
        for p in "${problems[@]}"; do
            echo "     - ${p}"
            report+=("| \`${short}\` | ${subject} | ${p} |")
        done
    fi
done

{
    echo "## DCO Check"
    echo
    if [ "$fail" -eq 0 ]; then
        echo "All ${#commits[@]} commits (${scope}) are properly signed off."
    else
        echo "Commits that failed the check (${scope}):"
        echo
        echo "| Commit | Subject | Issue |"
        echo "| --- | --- | --- |"
        printf '%s\n' "${report[@]}"
        echo
        echo "How to fix:"
        echo
        echo '1. Configure a real email (do not use a privacy email):'
        echo '   ```bash'
        echo '   git config user.email "you@example.com"'
        echo '   ```'
        echo '2. Re-sign to add the trailer to your commits:'
        echo '   ```bash'
        echo '   git commit --amend -s --no-edit          # latest commit'
        echo '   git rebase --exec "git commit --amend -s --no-edit" <base>  # multiple commits'
        echo '   git push --force-with-lease'
        echo '   ```'
        echo
        echo 'If a maintainer rebased your commits, keep the contributor real-email'
        echo 'Signed-off-by trailer (or add one) on each commit.'
    fi
} >>"$GITHUB_STEP_SUMMARY"

exit "$fail"
