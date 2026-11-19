#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Usage:
#   sudo ./edit-hostname.sh                       # write /etc/hostname on this system (or inside chroot)
#   sudo ./edit-hostname.sh <target etc/hostname> # e.g. an unpacked ISO tree's etc/hostname

set -e

# switch to script dir, so the relative hostname path always works
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

if [ ! -f hostname ]; then
    echo "hostname not found, exiting" >&2
    exit 1
fi

# The shipped hostname file has no trailing newline; read the first line and validate it.
name=$(sed -n '1p' hostname | tr -d '\r\n')
case "$name" in
    ''|*[!A-Za-z0-9-]*|-*|*-*)
        echo "Invalid hostname in hostname: $name" >&2
        exit 1
        ;;
esac
if [ "${#name}" -gt 63 ]; then
    echo "Hostname too long (max 63 chars): $name" >&2
    exit 1
fi

# Target: prefer the argument, otherwise write to the running system / chroot.
if [ -n "${1:-}" ]; then
    target=$1
else
    target=/etc/hostname
fi
mkdir -p "${target%/*}" || {
    echo "mkdir fail error!" >&2
    exit 1
}
printf '%s\n' "$name" >"$target" || {
    echo "write fail error!" >&2
    exit 1
}

echo "Done! Edit hostname OK! -> $name"
