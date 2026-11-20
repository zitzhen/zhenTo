#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Post-build smoke checks: verify the ISO is bootable-by-design and contains
# the expected branding / preinstalled tools, without booting it or unpacking
# the full 6.5G rootfs. Usage:
#   bash tests/verify-artifact.sh <iso> <version>

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
ISO=${1:-}
VERSION=${2:-}

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok  %s\n' "$*"; }

[ -n "$ISO" ] || die "Usage: bash tests/verify-artifact.sh <iso> <version>"
[ -n "$VERSION" ] || die "Usage: bash tests/verify-artifact.sh <iso> <version>"
[ -f "$ISO" ] || die "ISO not found: $ISO"

for c in xorriso unsquashfs md5sum sha256sum cmp awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. External checksum (produced by the build workflow), if present.
if [ -f "${ISO}.sha256" ]; then
    (cd "$(dirname "$ISO")" && sha256sum -c "$(basename "$ISO").sha256") ||
        die "ISO sha256 check failed"
    ok "ISO sha256 checksum"
else
    printf '..  no %s, skipping external checksum\n' "${ISO}.sha256"
fi

# 2. Volume label (same 32-char truncation rule as build.sh) and UEFI catalog.
LABEL="ZhenTo ${VERSION} amd64"
[ "${#LABEL}" -le 32 ] || LABEL=${LABEL:0:32}
actual_label=$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p')
[ "$actual_label" = "$LABEL" ] || die "Volume label mismatch: expected '$LABEL', got '$actual_label'"
ok "volume label: $actual_label"

torito=$(LC_ALL=C xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>/dev/null)
case "$torito" in
*appended_partition_2* | *efi* | *EFI*) ;;
*) die "No UEFI/EFI boot entry found in El Torito report: $torito" ;;
esac
ok "UEFI boot catalog entry"

# 3. Extract only the small ISO-tree files needed for assertions.
extract_iso() {
    xorriso -osirrox on:auto_chmod_on -indev "$ISO" -extract "$1" "$2" >/dev/null 2>&1 ||
        die "Cannot extract $1 from ISO"
}
extract_iso /boot/grub/grub.cfg "$TMP/grub.cfg"
extract_iso /casper/install-sources.yaml "$TMP/install-sources.yaml"
extract_iso /md5sum.txt "$TMP/md5sum.txt"

# 4. GRUB menu must be the one shipped in this repository.
cmp -s "$TMP/grub.cfg" "$REPO_DIR/edit-grub/grub.cfg" ||
    die "boot/grub/grub.cfg differs from edit-grub/grub.cfg"
ok "GRUB menu matches repository config"

# 5. Rebuild hash for a few extracted files from the ISO's own manifest.
for pair in "boot/grub/grub.cfg:$TMP/grub.cfg" "casper/install-sources.yaml:$TMP/install-sources.yaml"; do
    iso_path=${pair%%:*}
    local_file=${pair#*:}
    expected=$(awk -v p="./$iso_path" '$2 == p { print $1; exit }' "$TMP/md5sum.txt")
    [ -n "$expected" ] || die "md5sum.txt has no entry for ./$iso_path"
    actual=$(md5sum "$local_file" | awk '{print $1}')
    [ "$expected" = "$actual" ] || die "md5sum.txt mismatch for $iso_path: expected $expected, got $actual"
    ok "ISO md5sum.txt covers $iso_path"
done

# 6. Locate the default casper layer and extract the in-image os-release.
layer=$(awk '
    /^- default: true/  { def = 1; next }
    /^- default: false/ { def = 0; next }
    def && /^  path: /  { sub(/^  path: /, ""); print; exit }
' "$TMP/install-sources.yaml")
[ -n "$layer" ] || die "Cannot find default layer in casper/install-sources.yaml"
extract_iso "/casper/$layer" "$TMP/$layer"
unsquashfs -cat "$TMP/$layer" /etc/os-release >"$TMP/os-release" 2>/dev/null ||
    die "Cannot read /etc/os-release from $layer"

cmp -s "$TMP/os-release" "$REPO_DIR/edit-os-release/os-release" ||
    die "/etc/os-release in ISO differs from edit-os-release/os-release"
image_version=$(sed -n 's/^VERSION_ID="\([^"]*\)"$/\1/p' "$TMP/os-release")
[ "$image_version" = "$VERSION" ] ||
    die "VERSION_ID in ISO is '$image_version', expected '$VERSION'"
ok "in-image os-release matches repository and version $VERSION"

# 7. Preinstalled tools, brand icons, wallpaper and build-time residue.
#    Use -cat as a cheap existence probe: it succeeds for regular files and
#    fails (rc=2) when absent.
for f in usr/bin/curl usr/bin/git usr/bin/zsh usr/bin/patchsplit \
    var/lib/snapd/seed/seed.yaml etc/systemd/system/zhento-install-snap.service \
    usr/share/pixmaps/ubuntu-logo.svg \
    usr/share/pixmaps/ubuntu-logo-text.svg \
    usr/share/pixmaps/ubuntu-logo-text.png \
    usr/share/pixmaps/ubuntu-logo-text-dark.svg \
    usr/share/pixmaps/ubuntu-logo-text-dark.png \
    usr/share/pixmaps/debian-logo.png \
    usr/share/pixmaps/debian-logo.bmp \
    usr/share/backgrounds/zhento.png \
    usr/share/backgrounds/zhento-light.png \
    usr/share/backgrounds/zhento-dark.png \
    usr/share/backgrounds/zhento-wallpapers.copyright \
    usr/share/glib-2.0/schemas/zz-zhento-wallpaper.gschema.override; do
    unsquashfs -cat "$TMP/$layer" "/$f" >/dev/null 2>&1 ||
        die "Missing in image: /$f"
    ok "present in image: /$f"
done

# The wallpaper must be byte-identical to the shipped source image.
unsquashfs -cat "$TMP/$layer" /usr/share/backgrounds/zhento.png 2>/dev/null |
    sha256sum | awk '{print $1}' >"$TMP/wallpaper.sha256"
expected_wallpaper=$(sha256sum "$REPO_DIR/edit-icon/sources/zhento-full.png" | awk '{print $1}')
actual_wallpaper=$(cat "$TMP/wallpaper.sha256")
[ "$actual_wallpaper" = "$expected_wallpaper" ] ||
    die "Wallpaper sha256 mismatch: expected $expected_wallpaper, got $actual_wallpaper"
ok "wallpaper matches edit-icon/sources/zhento-full.png"

for leftover in opt/zhento-build/build.sh usr/sbin/policy-rc.d; do
    if unsquashfs -cat "$TMP/$layer" "/$leftover" >/dev/null 2>&1; then
        die "Build residue found in image: /$leftover"
    fi
    ok "no build residue: /$leftover"
done

printf '\nAll artifact checks passed for %s\n' "$ISO"
