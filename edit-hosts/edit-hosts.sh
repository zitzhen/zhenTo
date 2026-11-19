#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Usage:
#   sudo ./edit-hosts.sh                    # write /etc/hosts on this system (or inside chroot)
#   sudo ./edit-hosts.sh <target etc/hosts> # e.g. an unpacked ISO tree's etc/hosts

set -e

# switch to script dir, so the relative hosts path always works
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

if [ ! -f hosts ]; then
    echo "hosts not found, exiting" >&2
    exit 1
fi

# An empty hosts file would leave the target system without localhost entries.
if [ ! -s hosts ]; then
    echo "hosts is empty, refusing to overwrite the target" >&2
    exit 1
fi

# Target: prefer the argument, otherwise write to the running system / chroot.
if [ -n "${1:-}" ]; then
    target=$1
else
    target=/etc/hosts
fi

dir=$(dirname "$target")
mkdir -p "$dir" || {
    echo "mkdir fail error!" >&2
    exit 1
}

# awk 1 guarantees a trailing newline even when the source file does not have one.
awk 1 hosts >"$target" || {
    echo "write fail error!" >&2
    exit 1
}

echo "Done! Edit hosts OK! -> $target"
