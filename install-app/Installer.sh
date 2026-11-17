#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://github.com/zitzhen/zhento-desktop-install
# OS-repository: https://github.com/zitzhen/zhento-desktop-install
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# curl is installed centrally by build.sh via install-app/manifest.conf, so it is
# available here both during the build (chroot) and on a real system.

VERSION="1.0.0"
SNAP_FILE="ubuntu-desktop-bootstrap_${VERSION}-1-g21e8ae6a1_amd64.snap"
BASE_URL="https://github.com/zitzhen/zhento-desktop-install/releases/download/v${VERSION}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fL -o "$WORK_DIR/$SNAP_FILE" "$BASE_URL/$SNAP_FILE"
curl -fL -o "$WORK_DIR/$SNAP_FILE.sha256" "$BASE_URL/$SNAP_FILE.sha256"

(cd "$WORK_DIR" && sha256sum -c "$SNAP_FILE.sha256")

SNAP_NAME="ubuntu-desktop-bootstrap"

# snapd is running (real system): install directly
if [ -S /run/snapd.socket ]; then
    if snap list "$SNAP_NAME" >/dev/null 2>&1; then
        snap remove "$SNAP_NAME"
    fi
    snap install --dangerous "$WORK_DIR/$SNAP_FILE"
    exit 0
fi

# snapd is not running inside chroot, and a locally --dangerous snap cannot be seeded:
# leave the snap in the image and let a systemd unit install it on first boot; the unit
# cleans up and disables itself after installing.
SNAP_STORE=/var/lib/zhento/snaps
UNIT=/etc/systemd/system/zhento-install-snap.service

install -d -m 0755 "$SNAP_STORE"
install -m 0644 "$WORK_DIR/$SNAP_FILE" "$SNAP_STORE/$SNAP_FILE"

cat >"$UNIT" <<EOS
[Unit]
Description=Install preinstalled snap: ${SNAP_NAME}
After=snapd.service
Wants=snapd.service
ConditionPathExists=${SNAP_STORE}/${SNAP_FILE}

[Service]
Type=oneshot
ExecStartPre=/usr/bin/snap wait system seed.loaded
ExecStart=/usr/bin/snap install --dangerous ${SNAP_STORE}/${SNAP_FILE}
ExecStartPost=/bin/rm -f ${SNAP_STORE}/${SNAP_FILE}

[Install]
WantedBy=multi-user.target
EOS

install -d /etc/systemd/system/multi-user.target.wants
ln -sf "$UNIT" /etc/systemd/system/multi-user.target.wants/zhento-install-snap.service
