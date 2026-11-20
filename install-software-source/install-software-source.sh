#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# OS-repository: https://github.com/zitzhen/zhento-Software-Source
# SPDX-License-Identifier: AGPL-3.0-only
#
# Add the ZhenTo apt repository (https://apt.zitzhen.cn) to the target system.
# Source of truth: https://github.com/zitzhen/zhento-Software-Source

set -e

REPO_URL="https://apt.zitzhen.cn"
KEY_URL="$REPO_URL/apt-key.asc"
KEYRING="/usr/share/keyrings/zhento-apt.gpg"
SOURCES_LIST="/etc/apt/sources.list.d/zhento.list"
KEY_FINGERPRINT="3B310141DFDBDE77A802C0627DFBD414F81DC0BB"

export DEBIAN_FRONTEND=noninteractive

# Make sure curl and gpg are available (needed to fetch and dearmor the key).
need=0
for cmd in curl gpg; do
    command -v "$cmd" >/dev/null 2>&1 || need=1
done
if [ "$need" -eq 1 ]; then
    apt-get update
    apt-get install -y --no-install-recommends curl gnupg
fi

# Fetch the signing key and dearmor it into a dedicated keyring.
# Use an isolated GNUPGHOME so the script does not depend on (or pollute) the
# invoking user's gpg home, which may be unwritable in build environments.
GNUPGHOME_TMP=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME_TMP"' EXIT
curl -fsSL "$KEY_URL" | GNUPGHOME="$GNUPGHOME_TMP" gpg --dearmor -o "$KEYRING"
chmod 0644 "$KEYRING"

# Verify the key fingerprint to guard against a compromised key URL.
actual_fp=$(GNUPGHOME="$GNUPGHOME_TMP" gpg --show-keys --with-colons "$KEYRING" 2>/dev/null |
    awk -F: '/^fpr:/{print $10; exit}')
if [ "$actual_fp" != "$KEY_FINGERPRINT" ]; then
    echo "XX  ZhenTo apt key fingerprint mismatch: expected $KEY_FINGERPRINT, got ${actual_fp:-<none>}" >&2
    exit 1
fi

# Add the repository. amd64-only, signed by the dedicated keyring.
mkdir -p "$(dirname "$SOURCES_LIST")"
printf 'deb [signed-by=%s arch=amd64] %s stable main\n' \
    "$KEYRING" "$REPO_URL" >"$SOURCES_LIST"

# Refresh the package index so the new source is usable right away.
apt-get update

echo "Done! ZhenTo apt source installed -> $SOURCES_LIST"
