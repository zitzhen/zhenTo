#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Install ZhenTo wallpapers from the zhento-backgrounds GitHub Releases into an
# unpacked ISO root, and set them as the GNOME default (light + dark variants).
# Runs on the host against an explicit root path; never runs inside chroot and
# never ships in the final image.
#
# Usage:
#   sudo ./edit-backgrounds.sh <unpacked-root-dir>
#
# Environment:
#   WALLPAPER_REPO   GitHub owner/repo (default: zitzhen/zhento-backgrounds)
#   WALLPAPER_TAG    Release tag (default: zhenTo-coffee-1.0.0)
#
# Wallpapers are downloaded at build time from the release assets and verified
# against pinned SHA256 checksums; a mismatch or download failure aborts the
# build, so no partially-patched root is ever repacked.

set -e

# switch to script dir, so relative paths always work
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

# target: unpacked root directory, required
root=${1:-}
if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "Usage: $0 <unpacked-root-dir>" >&2
    exit 2
fi

# where to fetch from
repo=${WALLPAPER_REPO:-zitzhen/zhento-backgrounds}
tag=${WALLPAPER_TAG:-zhenTo-coffee-1.0.0}
base="https://github.com/$repo/releases/download/$tag"

# asset name -> installed filename -> pinned sha256
assets="
oliver-ZhenTo_Coffee_Mug_Light.png zhento-light.png 3441abd80c7473ac6499b67fbbbebdb99c419201b22d94a64749b370cb575093
oliver-ZhenTo_Coffee_Mug_Dark.png  zhento-dark.png  2604d26c4b7c72cca74c1e61711708bf6ef187fc386e628c6c08a55cebf1fab6
copyright                          zhento-wallpapers.copyright 1f818d3daff9a3a3ad8320a58afca8100517e21615c28fbf7feddd91077291a0
"

for c in curl sha256sum; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "Missing command: $c" >&2
        exit 1
    }
done

backgrounds="$root/usr/share/backgrounds"
mkdir -p "$backgrounds" || {
    echo "mkdir fail error!" >&2
    exit 1
}

# Download to a temporary dir first, verify every asset, then copy into the
# target. This keeps a failed download from leaving a half-written wallpaper.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

printf '%s\n' "$assets" >"$tmp/assets.list"
while IFS=' ' read -r asset dest sha; do
    [ -n "$asset" ] || continue
    echo "Downloading $asset ..."
    curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset" || {
        echo "download fail error: $asset" >&2
        exit 1
    }
    got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
    if [ "$got" != "$sha" ]; then
        echo "checksum mismatch: $asset (expected $sha, got $got)" >&2
        exit 1
    fi
    cp -f "$tmp/$asset" "$backgrounds/$dest" || {
        echo "copy wallpaper fail error: $dest" >&2
        exit 1
    }
done <"$tmp/assets.list"

# Set the light image as the light-mode wallpaper and the dark image as the
# dark-mode wallpaper via a gschema override (the standard, user-overridable
# way to change GNOME defaults). Only emit keys the target schema actually
# defines, so this stays compatible across GNOME versions.
schemas="$root/usr/share/glib-2.0/schemas"
bg_xml="$schemas/org.gnome.desktop.background.gschema.xml"
if [ -f "$bg_xml" ]; then
    override="$schemas/zz-zhento-wallpaper.gschema.override"
    {
        echo '[org.gnome.desktop.background]'
        echo "picture-uri='file:///usr/share/backgrounds/zhento-light.png'"
        if grep -q 'name="picture-uri-dark"' "$bg_xml"; then
            echo "picture-uri-dark='file:///usr/share/backgrounds/zhento-dark.png'"
        fi
    } >"$override"

    if command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas "$schemas" || {
            echo "glib-compile-schemas fail error!" >&2
            exit 1
        }
    else
        echo "Warn: glib-compile-schemas not found; override written but schemas not recompiled" >&2
    fi
else
    echo "Warn: org.gnome.desktop.background.gschema.xml not found; wallpaper installed but not set as default" >&2
fi

echo "Done! Edit backgrounds OK! -> $root"
