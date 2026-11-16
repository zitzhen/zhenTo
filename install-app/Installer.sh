#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://github.com/zitzhen/zhento-desktop-install
# OS-repository: https://github.com/zitzhen/zhento-desktop-install
# SPDX-License-Identifier: AGPL-3.0-only

set -e

VERSION="1.0.0"
SNAP_FILE="ubuntu-desktop-bootstrap_${VERSION}-1-g21e8ae6a1_amd64.snap"
BASE_URL="https://github.com/zitzhen/zhento-desktop-install/releases/download/v${VERSION}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fL -o "$WORK_DIR/$SNAP_FILE" "$BASE_URL/$SNAP_FILE"
curl -fL -o "$WORK_DIR/$SNAP_FILE.sha256" "$BASE_URL/$SNAP_FILE.sha256"

( cd "$WORK_DIR" && sha256sum -c "$SNAP_FILE.sha256" )

if snap list ubuntu-desktop-bootstrap >/dev/null 2>&1; then
    snap remove ubuntu-desktop-bootstrap
fi

snap install --dangerous "$WORK_DIR/$SNAP_FILE"
