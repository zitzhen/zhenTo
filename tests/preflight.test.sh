#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Smoke tests for safe failure paths and the read-only build preflight.
# No root, no network, no real apt/gh/snap calls: dangerous commands are
# replaced by stubs in a temporary fake bin directory.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCK_BIN="$TMP/fake-bin"
MOCK_LOG="$TMP/mock.log"
mkdir -p "$MOCK_BIN"
: >"$MOCK_LOG"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

# Stubs. `id -u` is intercepted separately below; other id arguments are not used.
# Build tools are stubbed too: PR runners do not install xorriso/squashfs-tools,
# and --check only needs `command -v` to find them (it must not execute them).
cat >"$MOCK_BIN/id" <<'EOF'
#!/bin/sh
echo 0
EOF
for cmd in apt apt-get add-apt-repository curl snap gh \
    xorriso unsquashfs mksquashfs rsync dd; do
    cat >"$MOCK_BIN/$cmd" <<EOF
#!/bin/sh
echo "$cmd \$*" >> "$MOCK_LOG"
EOF
done
# `cp -a` preserves timestamps, which sandboxed runners may reject. The stub
# records the call and delegates to real cp without -a/-f; the test still
# verifies target selection and backup creation, not filesystem metadata.
REAL_CP=$(command -v cp)
cat >"$MOCK_BIN/cp" <<EOF
#!/bin/sh
echo "cp \$*" >> "$MOCK_LOG"
while [ "\$1" = "-a" ] || [ "\$1" = "-f" ]; do shift; done
exec "$REAL_CP" -- "\$@"
EOF
cat >"$MOCK_BIN/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
# Sandboxed runners may report a tiny filesystem; preflight must still be
# exercised, so report a large disk from the stub (real df is used in builds).
cat >"$MOCK_BIN/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "mock 100000000 1 100000000 1% /mock"
EOF
chmod +x "$MOCK_BIN"/*
[ "$(PATH="$MOCK_BIN:$PATH" command -v xorriso)" = "$MOCK_BIN/xorriso" ] ||
    fail "build tool stubs are not shadowing PATH"

# 1. Missing tag must fail fast, before any gh call.
set +e
out=$(cd "$REPO_DIR" && sh scripts/download-release.sh 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "download-release.sh without tag exited $rc, expected 1"
case "$out" in *'Usage: ./download-release.sh'*) ;; *) fail "usage text missing: $out" ;; esac
ok "download-release.sh rejects a missing tag without touching gh"

# 2. Windows variants are checked statically (they cannot run on this runner).
grep -q 'goto :usage' "$REPO_DIR/scripts/download-release.cmd" || fail 'cmd usage branch missing'
grep -q 'echo Usage: download-release.cmd' "$REPO_DIR/scripts/download-release.cmd" || fail 'cmd usage text missing'
grep -q 'IsNullOrWhiteSpace($Tag)' "$REPO_DIR/scripts/download-release.ps1" || fail 'ps1 tag guard missing'
grep -q 'Stop-WithError' "$REPO_DIR/scripts/download-release.ps1" || fail 'ps1 failure helper missing'
ok "download-release.cmd/.ps1 keep their no-tag failure paths"

# 3. Root-only scripts must fail immediately for an unprivileged caller.
#    Mock `id -u` instead of dropping privileges: these scripts only consult
#    that one command before returning, so no real system write can happen.
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$NONROOT_BIN"
cat >"$NONROOT_BIN/id" <<'EOF'
#!/bin/sh
echo 1000
EOF
chmod +x "$NONROOT_BIN/id"
run_as_nobody() { PATH="$NONROOT_BIN:$PATH" "$@"; }

os_before=$(cksum /etc/os-release 2>/dev/null || true)
set +e
out=$(run_as_nobody sh "$REPO_DIR/edit-os-release/edit.sh" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "edit.sh as nobody exited $rc, expected 1"
case "$out" in *'No root! exit!'*) ;; *) fail "edit.sh root guard missing: $out" ;; esac
[ "$os_before" = "$(cksum /etc/os-release 2>/dev/null || true)" ] || fail '/etc/os-release was modified'
ok "edit.sh refuses non-root callers and leaves /etc/os-release untouched"

grub_baks_before=$(find "$REPO_DIR/edit-grub" -name 'grub.cfg.bak.*' | wc -l)
set +e
out=$(run_as_nobody sh "$REPO_DIR/edit-grub/replace-grub.sh" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "replace-grub.sh as nobody exited $rc, expected 1"
case "$out" in *'No root! exit!'*) ;; *) fail "replace-grub.sh root guard missing: $out" ;; esac
[ "$grub_baks_before" -eq "$(find "$REPO_DIR/edit-grub" -name 'grub.cfg.bak.*' | wc -l)" ] || fail 'unexpected GRUB backup file'
ok "replace-grub.sh refuses non-root callers without writing backups"

# 4. GRUB replacement is safe when an explicit temporary target is supplied.
target="$TMP/grub-target.cfg"
printf 'ORIGINAL\n' >"$target"
set +e
out=$(PATH="$MOCK_BIN:$PATH" sh "$REPO_DIR/edit-grub/replace-grub.sh" "$target" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "replace-grub.sh with temp target exited $rc: $out"
grep -q 'Try or Install ZhenTo' "$target" || fail 'temp GRUB target was not replaced'
find "$TMP" -name 'grub-target.cfg.bak.*' | grep -q . || fail 'GRUB backup was not created in temp dir'
ok "replace-grub.sh works on an explicit temp target and creates a backup there"

# 5. --check is read-only: it must succeed without calling apt/PPA or creating dirs.
touch "$TMP/fake.iso"
: >"$MOCK_LOG"
set +e
out=$(PATH="$MOCK_BIN:$PATH" \
    BASE_ISO="$TMP/fake.iso" OUT_DIR="$TMP/out" WORK_DIR="$TMP/work" \
    bash "$REPO_DIR/build.sh" --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build.sh --check exited $rc: $out"
case "$out" in *'Preflight OK'*) ;; *) fail "preflight success marker missing: $out" ;; esac
[ ! -s "$MOCK_LOG" ] || fail "apt/PPA was called during --check: $(cat "$MOCK_LOG")"
[ ! -e "$TMP/out" ] && [ ! -e "$TMP/work" ] || fail '--check created output directories'
ok "build.sh --check passes and performs no apt/PPA or filesystem writes"

# 6. --check fails fast on a missing base ISO, again with no apt calls.
: >"$MOCK_LOG"
set +e
out=$(PATH="$MOCK_BIN:$PATH" \
    BASE_ISO="$TMP/missing.iso" OUT_DIR="$TMP/out2" WORK_DIR="$TMP/work2" \
    bash "$REPO_DIR/build.sh" --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "build.sh --check with missing ISO exited $rc, expected 1"
case "$out" in *'Base ISO not found'*) ;; *) fail "missing ISO diagnostic missing: $out" ;; esac
[ ! -s "$MOCK_LOG" ] || fail "apt/PPA was called on a failed preflight: $(cat "$MOCK_LOG")"
ok "build.sh --check fails fast on a missing base ISO"

# 7. A version override must match the in-image branding before build starts.
: >"$MOCK_LOG"
set +e
out=$(PATH="$MOCK_BIN:$PATH" \
    BASE_ISO="$TMP/fake.iso" VERSION="9.9.9" OUT_DIR="$TMP/out3" WORK_DIR="$TMP/work3" \
    bash "$REPO_DIR/build.sh" --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "build.sh --check with mismatched VERSION exited $rc, expected 1"
case "$out" in *'update branding first'*) ;; *) fail "version mismatch diagnostic missing: $out" ;; esac
[ ! -s "$MOCK_LOG" ] || fail "apt/PPA was called on a version mismatch: $(cat "$MOCK_LOG")"
ok "build.sh --check rejects a VERSION that disagrees with os-release"

# 7b. Missing brand icon sources must fail preflight before any build work.
: >"$MOCK_LOG"
mkdir -p "$TMP/empty-icons"
set +e
out=$(PATH="$MOCK_BIN:$PATH" \
    BASE_ISO="$TMP/fake.iso" ICON_SRC_DIR="$TMP/empty-icons" \
    OUT_DIR="$TMP/out4" WORK_DIR="$TMP/work4" \
    bash "$REPO_DIR/build.sh" --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "build.sh --check with empty ICON_SRC_DIR exited $rc, expected 1"
case "$out" in *'Missing build input'*) ;; *) fail "missing icon input diagnostic missing: $out" ;; esac
[ ! -s "$MOCK_LOG" ] || fail "apt/PPA was called on a missing-icon preflight: $(cat "$MOCK_LOG")"
ok "build.sh --check fails fast when brand icon sources are missing"

# 8. --apps-only still prepares apt/PPA before running install-app scripts.
APP_ROOT="$TMP/apps-root"
mkdir -p "$APP_ROOT/install-app"
cp "$REPO_DIR/build.sh" "$APP_ROOT/build.sh"
printf '%s\n' 'ppa:test/foo' >"$APP_ROOT/install-app/ppa.list"
cat >"$APP_ROOT/install-app/00-stub.sh" <<EOF
#!/bin/sh
echo "app-stub called" >> "$MOCK_LOG"
EOF
: >"$MOCK_LOG"
set +e
out=$(PATH="$MOCK_BIN:$PATH" bash "$APP_ROOT/build.sh" --apps-only 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build.sh --apps-only exited $rc: $out"
grep -q 'add-apt-repository -y ppa:test/foo' "$MOCK_LOG" || fail 'PPA was not added in --apps-only'
grep -q 'apt-get update' "$MOCK_LOG" || fail 'apt index was not updated in --apps-only'
grep -q 'app-stub called' "$MOCK_LOG" || fail 'install-app script was not executed'
ok "build.sh --apps-only keeps the PPA/apt step before install-app scripts"

# 9. The host build must not add target-system PPAs or refresh apt: the runner
#    codename may differ from the base ISO's. Let it run until the fake ISO
#    structure check fails, then assert no apt/PPA call was made on the host.
: >"$MOCK_LOG"
set +e
out=$(PATH="$MOCK_BIN:$PATH" \
    BASE_ISO="$TMP/fake.iso" OUT_DIR="$TMP/host-out" WORK_DIR="$TMP/host-work" \
    bash "$REPO_DIR/build.sh" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "host build with fake ISO exited $rc, expected 1: $out"
case "$out" in *'not a supported Ubuntu desktop image'*) ;; *) fail "host build did not reach the ISO structure check: $out" ;; esac
if grep -qE 'add-apt-repository|apt-get' "$MOCK_LOG"; then
    fail "host build touched apt/PPA: $(cat "$MOCK_LOG")"
fi
ok "host build does not add target PPAs or refresh apt"

printf '\nAll preflight smoke tests passed.\n'
