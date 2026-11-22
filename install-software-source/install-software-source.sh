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

# The repository sits behind Cloudflare, which answers the build egress IPs with
# an HTTP 403 managed challenge (a "Just a moment..." bot check). That is not a
# transient error: retrying gets 403 again every time, because no plain HTTP
# client can solve the JavaScript challenge. CI must therefore not depend on
# fetching the key over the network at all.
#
# The key is pinned below, byte-for-byte, and its fingerprint is verified after
# dearmoring. Embedding it is safe: a public key cannot be abused to sign
# packages, and the fingerprint check still rejects any tampering. Rotate this
# block whenever the repository key changes.
read_key_from_network() {
    # Optional refresh path, used only when ZENTO_APT_KEY_ALLOW_NETWORK=1.
    attempt=1
    while [ "$attempt" -le "$FETCH_ATTEMPTS" ]; do
        if curl -fsSL --connect-timeout 15 --max-time 120 -o "$KEY_TMP" "$KEY_URL"; then
            return 0
        fi
        echo "Warning: fetching $KEY_URL failed (attempt $attempt/$FETCH_ATTEMPTS);" \
            "Cloudflare may be challenging this egress IP" >&2
        attempt=$((attempt + 1))
        [ "$attempt" -le "$FETCH_ATTEMPTS" ] && sleep $((attempt * 2))
    done
    return 1
}

# $1 is the severity tag to use: "XX" for the pinned-key path (fatal) and
# "Warning" for the optional network path (the caller then falls back).
validate_key_file() {
    tag=${1:-XX}
    key_bytes=$(wc -c <"$KEY_TMP")
    if [ "$key_bytes" -lt 200 ]; then
        echo "$tag  Apt key is truncated ($key_bytes bytes)" >&2
        head -c 300 "$KEY_TMP" >&2 || true
        echo >&2
        return 1
    fi
    if ! grep -q -- "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$KEY_TMP"; then
        echo "$tag  Response is not an ASCII-armored PGP key; it looks like a" \
            "Cloudflare challenge or other non-key page" >&2
        head -c 300 "$KEY_TMP" >&2 || true
        echo >&2
        return 1
    fi
    return 0
}

fetch_apt_key() {
    FETCH_ATTEMPTS=5

    if [ "${ZENTO_APT_KEY_ALLOW_NETWORK:-0}" = "1" ]; then
        if read_key_from_network && validate_key_file Warning; then
            echo "==> Fetched ZhenTo apt key from $KEY_URL"
            return 0
        fi
        echo "Warning: network key fetch failed; falling back to the pinned key" >&2
    fi

    cat >"$KEY_TMP" <<'ZENTO_APT_KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEav+6jRYJKwYBBAHaRw8BAQdAn68aQjH+mPgrGhAkNYnflmA9UhR8OBZTJY5U
Sc8xzEm0QXpoZW50by1Tb2Z0d2FyZS1Tb3VyY2UgPHpoZW50by1zb2Z0d2FyZS1z
b3VyY2Utbm9yZXBseUB6aXQuZW1haWw+iJYEExYKAD4WIQQ7MQFB39ved6gCwGJ9
+9QU+B3AuwUCav+6jQIbAwUJBaT3MwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAK
CRB9+9QU+B3Au9g2AP40wxLrtT4aZsP4si8yNXG89516sAikEbLmVHtF2Ig+AAD+
Nl2Ub5ODgQB+YbC1CfnsU7O1pJaPkoXa/LOZb8P+ngq4OARq/7qNEgorBgEEAZdV
AQUBAQdAuuStYgFlAuDeZhbMHF72h2o31xNHRqNchT3motxcBXADAQgHiH4EGBYK
ACYWIQQ7MQFB39ved6gCwGJ9+9QU+B3AuwUCav+6jQIbDAUJBaT3MwAKCRB9+9QU
+B3Au1cvAQCO7SRXi003r8axVrfsPChuvBuwujEFU64z6ZmA2F7k2wEAo1aZlh50
rrBseWdWjTfUX0xSWE6hCrdN8q+50/rJFA4=
=kFTp
-----END PGP PUBLIC KEY BLOCK-----
ZENTO_APT_KEY
    validate_key_file XX || exit 1
    echo "==> Using pinned ZhenTo apt key"
}

fetch_apt_key

GNUPGHOME="$GNUPGHOME_TMP" gpg --dearmor -o "$KEYRING" <"$KEY_TMP"
chmod 0644 "$KEYRING"

# Verify the key fingerprint to guard against a compromised or stale key.
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
