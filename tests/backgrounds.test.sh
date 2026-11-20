#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for edit-backgrounds/edit-backgrounds.sh: root guard, argument checks,
# download + checksum + install flow, gschema override generation, graceful
# degradation, and abort on a checksum mismatch.
#
# Wallpapers are NOT vendored into the repo, so curl/sha256sum are mocked: the
# fake curl returns dummy image bytes and the fake sha256sum returns the pinned
# checksums, letting every branch run fully offline. No real system files are
# touched. Usage:
#   bash tests/backgrounds.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_DIR/edit-backgrounds/edit-backgrounds.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

[ -f "$INSTALLER" ] || fail "installer not found: $INSTALLER"
[ -x "$INSTALLER" ] || fail "installer is not executable: $INSTALLER"

# Pinned checksums (must stay in sync with the installer).
SHA_LIGHT=3441abd80c7473ac6499b67fbbbebdb99c419201b22d94a64749b370cb575093
SHA_DARK=2604d26c4b7c72cca74c1e61711708bf6ef187fc386e628c6c08a55cebf1fab6
SHA_COPY=1f818d3daff9a3a3ad8320a58afca8100517e21615c28fbf7feddd91077291a0

# --- mock bin -------------------------------------------------------------
MOCK="$TMP/mockbin"
mkdir -p "$MOCK"
cat >"$MOCK/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat >"$MOCK/id-nonroot" <<'EOF'
#!/bin/sh
echo 1000
EOF
# fake curl: write dummy bytes to the -o target, log the URL
cat >"$MOCK/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -fsSL|--retry|-3) shift ;;
    http*) url=\$1; shift ;;
    *) shift ;;
  esac
done
printf 'dummy-wallpaper-bytes' > "\$out"
printf '%s\n' "\$url" >> "$TMP/curl.urls"
EOF
# fake sha256sum: return the pinned checksum for each known asset name.
# BAD_SUM=1 makes every check fail, to exercise the abort path.
cat >"$MOCK/sha256sum" <<EOF
#!/bin/sh
name=\$(basename "\$1")
if [ "\${BAD_SUM:-0}" = 1 ]; then
  echo "deadbeef  \$1"
  exit 0
fi
case "\$name" in
  oliver-ZhenTo_Coffee_Mug_Light.png) sum=$SHA_LIGHT ;;
  oliver-ZhenTo_Coffee_Mug_Dark.png)  sum=$SHA_DARK ;;
  copyright)                          sum=$SHA_COPY ;;
  *) sum=0000000000000000000000000000000000000000000000000000000000000000 ;;
esac
echo "\$sum  \$1"
EOF
cat >"$MOCK/glib-compile-schemas" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/compile.calls"
EOF
chmod +x "$MOCK"/*

NONROOT="$TMP/nonroot"
mkdir -p "$NONROOT"
cp "$MOCK/id-nonroot" "$NONROOT/id"
cp "$MOCK/curl" "$MOCK/sha256sum" "$MOCK/glib-compile-schemas" "$NONROOT/"

run() { PATH="$MOCK:$PATH" sh "$INSTALLER" "$@"; }

# A schema xml that declares both keys.
mk_schema_root() {
    local r=$1
    mkdir -p "$r/usr/share/glib-2.0/schemas"
    cat >"$r/usr/share/glib-2.0/schemas/org.gnome.desktop.background.gschema.xml" <<'EOF'
<schemalist><schema id="org.gnome.desktop.background">
  <key name="picture-uri" type="s"><default>'file:///x'</default></key>
  <key name="picture-uri-dark" type="s"><default>'file:///y'</default></key>
</schema></schemalist>
EOF
}

# 1. Non-root callers are rejected without downloading anything.
R="$TMP/root-nonroot"
mkdir -p "$R"
set +e
out=$(PATH="$NONROOT:$PATH" sh "$INSTALLER" "$R" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "non-root exited $rc, expected 1"
case "$out" in *'No root! exit!'*) ;; *) fail "root guard missing: $out" ;; esac
[ -z "$(find "$R" -type f 2>/dev/null)" ] || fail "non-root run wrote files"
ok "installer refuses non-root callers and writes nothing"

# 2. Missing/invalid target directory is rejected.
set +e
out=$(run "$TMP/does-not-exist" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing target exited $rc, expected 2"
case "$out" in *'Usage:'*) ;; *) fail "usage message missing: $out" ;; esac
ok "installer rejects a missing target directory"

# 3. Full happy path: download, verify, install, override, recompile.
R="$TMP/root-ok"
mk_schema_root "$R"
run "$R" >/dev/null
for rel in \
    usr/share/backgrounds/zhento-light.png \
    usr/share/backgrounds/zhento-dark.png \
    usr/share/backgrounds/zhento-wallpapers.copyright; do
    [ -f "$R/$rel" ] || fail "not installed: $rel"
done
ok "all three wallpaper assets are installed"

grep -q "picture-uri='file:///usr/share/backgrounds/zhento-light.png'" \
    "$R/usr/share/glib-2.0/schemas/zz-zhento-wallpaper.gschema.override" ||
    fail "light picture-uri override missing"
grep -q "picture-uri-dark='file:///usr/share/backgrounds/zhento-dark.png'" \
    "$R/usr/share/glib-2.0/schemas/zz-zhento-wallpaper.gschema.override" ||
    fail "dark picture-uri override missing"
ok "gschema override contains both light and dark picture-uri"

grep -q "$(printf '%s' "$R/usr/share/glib-2.0/schemas")" "$TMP/compile.calls" ||
    fail "glib-compile-schemas was not called on the target schema dir"
ok "glib-compile-schemas recompiled the target schema dir"

[ "$(wc -l <"$TMP/curl.urls" | tr -d ' ')" -eq 3 ] ||
    fail "expected 3 download requests"
grep -q "zhento-backgrounds/releases/download/zhenTo-coffee-1.0.0/oliver-ZhenTo_Coffee_Mug_Light.png" "$TMP/curl.urls" ||
    fail "download URL does not point at the pinned release asset"
ok "all assets are fetched from the pinned GitHub release"

# 4. Override only emits picture-uri when the schema lacks picture-uri-dark.
R="$TMP/root-old-gnome"
mkdir -p "$R/usr/share/glib-2.0/schemas"
cat >"$R/usr/share/glib-2.0/schemas/org.gnome.desktop.background.gschema.xml" <<'EOF'
<schemalist><schema id="org.gnome.desktop.background">
  <key name="picture-uri" type="s"><default>'file:///x'</default></key>
</schema></schemalist>
EOF
run "$R" >/dev/null
if grep -q 'picture-uri-dark' "$R/usr/share/glib-2.0/schemas/zz-zhento-wallpaper.gschema.override"; then
    fail "picture-uri-dark emitted for a schema that does not define it"
fi
ok "override omits picture-uri-dark on older GNOME schemas"

# 5. Root without a background schema degrades gracefully.
R="$TMP/root-no-schema"
mkdir -p "$R"
set +e
out=$(run "$R" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "no-schema root exited $rc, expected 0"
case "$out" in *'not set as default'*) ;; *) fail "degradation warning missing: $out" ;; esac
[ -f "$R/usr/share/backgrounds/zhento-light.png" ] || fail "wallpaper not installed on no-schema root"
ok "root without GNOME schema keeps wallpapers and warns"

# 6. A checksum mismatch aborts the run and leaves no installed wallpaper.
R="$TMP/root-bad-sum"
mk_schema_root "$R"
set +e
out=$(BAD_SUM=1 PATH="$MOCK:$PATH" sh "$INSTALLER" "$R" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "checksum mismatch did not abort"
case "$out" in *'checksum mismatch'*) ;; *) fail "checksum diagnostic missing: $out" ;; esac
[ ! -f "$R/usr/share/backgrounds/zhento-light.png" ] || fail "bad checksum left a wallpaper installed"
ok "checksum mismatch aborts before any wallpaper is installed"

printf '\nAll wallpaper installer tests passed.\n'
