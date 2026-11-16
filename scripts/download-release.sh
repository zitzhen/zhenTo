#!/usr/bin/env sh
# 用 gh CLI 下载 GitHub 发行版（Release）中的全部附件，支持草稿（draft）发行版。
#
# 用法:
#   ./download-release.sh <tag>
#   ./download-release.sh <tag> <owner/name>
#   ./download-release.sh <tag> <owner/name> <输出目录>
#
# 说明:
#   - 只需提供 tag 编号；仓库默认取当前目录对应的 GitHub 仓库。
#   - 默认输出目录为 ./<仓库名>-<tag>（去掉 tag 开头的小写 v）。
#   - 适用于 sh / bash / zsh（Linux、macOS、Git Bash）。
#   - 依赖已登录的 gh CLI（gh auth login）；下载草稿需要该仓库的写权限。

set -eu

TAG=${1:-}
REPO=${2:-}
OUTDIR=${3:-}

usage() {
    cat >&2 <<'EOF'
用法: ./download-release.sh <tag> [owner/name] [输出目录]

  tag       必填，发行版的 git tag 编号，例如 v0.1.1
  owner/name 可选，仓库全名；默认取当前目录对应的 GitHub 仓库
  输出目录    可选，默认 ./<仓库名>-<tag>

示例:
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

command -v gh >/dev/null 2>&1 || fail "未找到 gh CLI，请先安装 GitHub CLI 并执行 gh auth login。"

# 1. 认证（草稿发行版只能由有权限的账号看到）
if ! gh auth token >/dev/null 2>&1; then
    fail "GitHub 认证失败，请先执行 gh auth login。"
fi

# 2. 仓库
if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || fail "无法自动识别当前仓库，请显式传入仓库，例如: ./download-release.sh $TAG owner/name"
fi

TAB=$(printf '\t')
WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t ghdl)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

# 3. 定位发行版
#    /releases/tags/<tag> 对草稿返回 404，因此遍历全部分页后按 tag 匹配，命中多个时草稿优先。
DL_TAG="$TAG"
export DL_TAG
RELEASE_JQ='[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv'
if ! gh api "repos/$REPO/releases?per_page=100" --paginate --jq "$RELEASE_JQ" > "$WORKDIR/releases.tsv"; then
    fail "获取发行版列表失败（仓库 $REPO）。"
fi

FIRST_ID=''
DRAFT_ID=''
while IFS="$TAB" read -r id draft; do
    if [ -n "$id" ]; then
        if [ -z "$FIRST_ID" ]; then FIRST_ID=$id; fi
        if [ "$draft" = "true" ] && [ -z "$DRAFT_ID" ]; then DRAFT_ID=$id; fi
    fi
done < "$WORKDIR/releases.tsv"

RELEASE_ID=$FIRST_ID
IS_DRAFT=false
if [ -n "$DRAFT_ID" ]; then
    RELEASE_ID=$DRAFT_ID
    IS_DRAFT=true
fi
[ -n "$RELEASE_ID" ] || fail "未找到 tag 为 $TAG 的发行版（已包含草稿）。"

# 4. 输出目录
REPO_NAME=${REPO##*/}
TAG_DIR=$(printf '%s' "$TAG" | sed 's/^v//; s#[/\\:*?"<>|]#-#g')
if [ -z "$OUTDIR" ]; then
    OUTDIR="./$REPO_NAME-$TAG_DIR"
fi
mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)

# 5. 附件列表
if ! gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" --paginate \
        --jq '.[] | [.id, .name, .size] | @tsv' > "$WORKDIR/assets.tsv"; then
    fail "获取发行版附件列表失败（release id: $RELEASE_ID）。"
fi

TOTAL=$(wc -l < "$WORKDIR/assets.tsv" | tr -d ' ')
[ "$TOTAL" -gt 0 ] || fail "发行版 $TAG 没有可下载的附件。"

if [ "$IS_DRAFT" = "true" ]; then KIND='草稿'; else KIND='已发布'; fi
echo "仓库: $REPO"
echo "发行版: $TAG（$KIND，id: $RELEASE_ID），附件 $TOTAL 个"
echo "输出目录: $OUTDIR"
echo ""

# 6. 逐个下载并校验大小
INDEX=0
SUCCESS=0
while IFS="$TAB" read -r asset_id asset_name asset_size; do
    INDEX=$((INDEX + 1))
    printf '[%s/%s] %s (%s bytes) ... ' "$INDEX" "$TOTAL" "$asset_name" "$asset_size"

    if gh api "repos/$REPO/releases/assets/$asset_id" \
            -H "Accept: application/octet-stream" > "$OUTDIR/$asset_name" 2>"$WORKDIR/err"; then
        ACTUAL=$(wc -c < "$OUTDIR/$asset_name" | tr -d ' ')
        if [ "$asset_size" != "$ACTUAL" ]; then
            rm -f "$OUTDIR/$asset_name"
            echo "失败: 文件大小不一致（期望 $asset_size，实际 $ACTUAL）"
        else
            SUCCESS=$((SUCCESS + 1))
            echo "OK"
        fi
    else
        rm -f "$OUTDIR/$asset_name"
        echo "失败: $(tr -d '\r' < "$WORKDIR/err" | head -n 1)"
    fi
done < "$WORKDIR/assets.tsv"

echo ""
echo "下载完成: $SUCCESS/$TOTAL -> $OUTDIR"
[ "$SUCCESS" -eq "$TOTAL" ] || exit 1
