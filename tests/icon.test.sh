#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for edit-icon/edit-icon.sh: root guard, fail-fast on missing sources,
# and correct installation of all brand files into a fake unpacked root.
# No real system files are touched; `id -u` is mocked and all writes go to a
# temporary directory. Usage:
#   bash tests/icon.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_DIR/edit-icon/edit-icon.sh"
SOURCES="$REPO_DIR/edit-icon/sources"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

[ -f "$INSTALLER" ] || fail "installer not found: $INSTALLER"
[ -x "$INSTALLER" ] || fail "installer is not executable: $INSTALLER"

# Mock id so we can exercise the root guard without real privileges.
ROOT_BIN="$TMP/root-bin"
mkdir -p "$ROOT_BIN"
cat >"$ROOT_BIN/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat >"$ROOT_BIN/id-nonroot" <<'EOF'
#!/bin/sh
echo 1000
EOF
chmod +x "$ROOT_BIN"/*

# 1. Non-root callers are rejected without writing anything.
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$NONROOT_BIN"
cp "$ROOT_BIN/id-nonroot" "$NONROOT_BIN/id"
FAKE_ROOT="$TMP/fake-root-nonroot"
mkdir -p "$FAKE_ROOT"
set +e
out=$(PATH="$NONROOT_BIN:$PATH" sh "$INSTALLER" "$FAKE_ROOT" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "installer as non-root exited $rc, expected 1"
case "$out" in *'No root! exit!'*) ;; *) fail "root guard missing: $out" ;; esac
[ -z "$(find "$FAKE_ROOT" -type f 2>/dev/null)" ] || fail "non-root run wrote files"
ok "installer refuses non-root callers and writes nothing"

# 2. A missing target directory is rejected.
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$INSTALLER" "$TMP/does-not-exist" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "installer with missing target exited $rc, expected 2"
case "$out" in *'Usage:'*) ;; *) fail "usage message missing: $out" ;; esac
ok "installer rejects a missing target directory"

# 3. Missing icon sources fail fast without touching the target.
EMPTY_SRC="$TMP/empty-src"
mkdir -p "$EMPTY_SRC"
FAKE_ROOT="$TMP/fake-root-missing"
mkdir -p "$FAKE_ROOT"
set +e
out=$(PATH="$ROOT_BIN:$PATH" ICON_SRC_DIR="$EMPTY_SRC" \
    sh "$INSTALLER" "$FAKE_ROOT" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "installer with empty ICON_SRC_DIR exited $rc, expected 1"
case "$out" in *'Icon source not found'*) ;; *) fail "missing-source diagnostic missing: $out" ;; esac
[ -z "$(find "$FAKE_ROOT" -type f 2>/dev/null)" ] || fail "failed run left files behind"
ok "installer fails fast on missing icon sources"

# 4. A valid run installs every brand file and the wallpaper.
FAKE_ROOT="$TMP/fake-root-ok"
mkdir -p "$FAKE_ROOT"
PATH="$ROOT_BIN:$PATH" sh "$INSTALLER" "$FAKE_ROOT" >/dev/null

for rel in \
    usr/share/pixmaps/ubuntu-logo.svg \
    usr/share/pixmaps/ubuntu-logo-text.svg \
    usr/share/pixmaps/ubuntu-logo-text.png \
    usr/share/pixmaps/ubuntu-logo-text-dark.svg \
    usr/share/pixmaps/ubuntu-logo-text-dark.png \
    usr/share/pixmaps/debian-logo.png \
    usr/share/pixmaps/debian-logo.bmp \
    usr/share/backgrounds/zhento.png; do
    [ -f "$FAKE_ROOT/$rel" ] || fail "not installed: $rel"
done
ok "all 7 brand icons and the wallpaper are installed"

# 5. Installed content matches the repository's generated files / source.
for rel in \
    ubuntu-logo.svg ubuntu-logo-text.svg ubuntu-logo-text.png \
    ubuntu-logo-text-dark.svg ubuntu-logo-text-dark.png \
    debian-logo.png debian-logo.bmp; do
    cmp -s "$FAKE_ROOT/usr/share/pixmaps/$rel" \
        "$REPO_DIR/edit-icon/files/pixmaps/$rel" ||
        fail "content mismatch for pixmaps/$rel"
done
cmp -s "$FAKE_ROOT/usr/share/backgrounds/zhento.png" "$SOURCES/zhento-full.png" ||
    fail "content mismatch for backgrounds/zhento.png"
ok "installed content matches repository sources"

# 6. The full banner and text logos must keep an alpha channel. Issue #53:
# GDM3 and GNOME Settings show the logo on their own backgrounds, so an opaque
# white banner appears as a jarring white box. PNG IHDR byte 25 is the color
# type: 6 = truecolor with alpha. No ImageMagick dependency, so this runs in CI.
for rel in \
    "$SOURCES/zhento-full.png" \
    "$REPO_DIR/edit-icon/files/pixmaps/ubuntu-logo-text.png" \
    "$REPO_DIR/edit-icon/files/pixmaps/ubuntu-logo-text-dark.png"; do
    [ -f "$rel" ] || fail "missing transparency check target: $rel"
    color_type=$(od -An -tu1 -j25 -N1 "$rel" | tr -d '[:space:]')
    [ "$color_type" = "6" ] || fail "no alpha channel (IHDR color type $color_type): $rel"
done
ok "full banner and text logo PNGs have alpha channels"

printf '\nAll icon installer tests passed.\n'
