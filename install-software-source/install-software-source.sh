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
KEY_TMP=$(mktemp)
trap 'rm -rf "$GNUPGHOME_TMP" "$KEY_TMP"' EXIT

# Download to a file first, with retries. Cloudflare in front of the repo has
# been observed answering 403 to the occasionally-throttled GitHub Actions
# egress IPs; a fresh connection a moment later usually succeeds, so retry
# before failing. Never pipe curl straight into gpg: with `curl -f` a failed
# request yields no output, and gpg then fails with a misleading
# "no valid OpenPGP data found" instead of surfacing the HTTP error.
FETCH_ATTEMPTS=5
FETCH_OK=0
attempt=1
while [ "$attempt" -le "$FETCH_ATTEMPTS" ]; do
    if curl -fsSL \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 0 \
        -o "$KEY_TMP" \
        "$KEY_URL"; then
        FETCH_OK=1
        break
    fi
    echo "Warning: fetching $KEY_URL failed (attempt $attempt/$FETCH_ATTEMPTS)" >&2
    attempt=$((attempt + 1))
    [ "$attempt" -le "$FETCH_ATTEMPTS" ] && sleep $((attempt * 2))
done
if [ "$FETCH_OK" -ne 1 ]; then
    echo "XX  Unable to download ZhenTo apt key from $KEY_URL after $FETCH_ATTEMPTS attempts" >&2
    exit 1
fi

# Reject empty or truncated downloads before handing them to gpg.
key_bytes=$(wc -c <"$KEY_TMP")
if [ "$key_bytes" -lt 200 ]; then
    echo "XX  Downloaded apt key from $KEY_URL looks truncated ($key_bytes bytes); refusing to continue" >&2
    head -c 300 "$KEY_TMP" >&2 || true
    exit 1
fi
if ! grep -q -- "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$KEY_TMP"; then
    echo "XX  Downloaded file from $KEY_URL is not an ASCII-armored PGP key" >&2
    head -c 300 "$KEY_TMP" >&2 || true
    exit 1
fi

GNUPGHOME="$GNUPGHOME_TMP" gpg --dearmor -o "$KEYRING" <"$KEY_TMP"
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
