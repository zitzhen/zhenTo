#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Smoke test: the product version has a single source of truth split across
# build.sh (the default used by the script) and the in-ISO os-release. The
# build workflow must derive the version from there instead of hardcoding a
# third copy, and it must call the shared composite action. The Ubuntu base
# version in os-release must also match the base ISO (26.04.1).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_SH="$REPO_DIR/build.sh"
OS_RELEASE="$REPO_DIR/edit-os-release/os-release"
WORKFLOW="$REPO_DIR/.github/workflows/build-iso.yml"
ACTION="$REPO_DIR/.github/actions/build-iso/action.yml"

fail() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

for f in "$BUILD_SH" "$OS_RELEASE" "$WORKFLOW" "$ACTION"; do
    [ -f "$f" ] || fail "Missing file: $f"
done

build_v=$(sed -n 's/^VERSION=${VERSION:-\([^}]*\)}$/\1/p' "$BUILD_SH")
os_v=$(sed -n 's/^VERSION_ID="\([^"]*\)"$/\1/p' "$OS_RELEASE")
wf_v=$(awk '
    /^  workflow_dispatch:/ { wd = 1 }
    wd && /^      version:/  { ver = 1 }
    ver && /default:/ {
        if (match($0, /"[^"]*"/)) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    }
' "$WORKFLOW")
wf_inputs=$(grep -c '^      version:$' "$WORKFLOW" || true)
pretty_v=$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$OS_RELEASE")
codename=$(sed -n 's/^VERSION_CODENAME=\(.*\)$/\1/p' "$OS_RELEASE")
ubuntu_codename=$(sed -n 's/^UBUNTU_CODENAME=\(.*\)$/\1/p' "$OS_RELEASE")

[ -n "$build_v" ] || fail "Cannot read VERSION from build.sh"
[ -n "$os_v" ] || fail "Cannot read VERSION_ID from os-release"
[ "$wf_inputs" -ge 1 ] || fail "build-iso.yml has no 'version' workflow_dispatch input"

printf 'build.sh VERSION           : %s\n' "$build_v"
printf 'os-release VERSION_ID      : %s\n' "$os_v"
printf 'os-release VERSION         : %s\n' "$pretty_v"

# A hardcoded workflow default is allowed only while it still matches; leaving
# it empty is the preferred "derive from os-release" mode.
if [ -n "$wf_v" ]; then
    printf 'build-iso.yml default      : %s\n' "$wf_v"
    [ "$build_v" = "$wf_v" ] || fail "Version drift: build.sh=$build_v workflow default=$wf_v"
else
    printf 'build-iso.yml default      : (auto from os-release)\n'
fi

[ "$build_v" = "$os_v" ] || fail "Version drift: build.sh=$build_v os-release=$os_v"

grep -q 'uses: \./\.github/actions/build-iso' "$WORKFLOW" ||
    fail "build-iso.yml does not call ./.github/actions/build-iso"
grep -q '^  version:' "$ACTION" || fail "Composite action has no version input"

case "$pretty_v" in
*26.04*) ;;
*) fail "os-release VERSION must describe the 26.04 base ISO, got: $pretty_v" ;;
esac

[ -n "$codename" ] && [ "$codename" = "$ubuntu_codename" ] ||
    fail "Codename mismatch: VERSION_CODENAME=$codename UBUNTU_CODENAME=$ubuntu_codename"

printf 'OK  version consistency (%s), base 26.04.1, codename %s\n' "$build_v" "$codename"
