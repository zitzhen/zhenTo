#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# ZhenTo ISO build script (UEFI-only, no longer depends on Cubic)
#
#   sudo ./build.sh              Unpack official ISO -> install APPs in chroot -> repack -> output ISO
#   sudo ./build.sh --apps-only  Provision apt + run install-app/*.sh (inside chroot or on a real system)
#
# Preinstalled APPs are declared in install-app/manifest.conf (apt sources and packages);
# install-app/*.sh hold only the per-app customisation that is not plain apt install.
#
# Overridable environment variables:
#   BASE_ISO       Base ISO (default /home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso)
#   VERSION        Version string (default 0.1.0)
#   VOLID          Disc volume label (default "ZhenTo <VERSION> amd64")
#   WORK_DIR       Intermediate build directory (default <repo>/work, needs ~35G free)
#   OUT_DIR        Output directory (default <repo>/out)
#   PATCH_LAYERS   auto or space-separated casper layer file names
#   KEEP_WORK      1 to keep intermediate files for debugging
#   SQUASHFS_COMP  Squashfs compression algorithm (default inherited from original layer, e.g. xz; zstd is much faster)
#   SQUASHFS_BLOCK Squashfs block size (default inherited from original layer, usually 131072)
#
# Note: Ubuntu 26.04 desktop ISO uses layered squashfs (described in casper/install-sources.yaml).
# By default only the base layer of the "default install source" is modified; the language layer
# and enhanced-secureboot overlay layer are left untouched.

set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

BASE_ISO=${BASE_ISO:-/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso}
VERSION=${VERSION:-0.1.0}
VOLID=${VOLID:-"ZhenTo ${VERSION} amd64"}
WORK_DIR=${WORK_DIR:-"$SELF_DIR/work"}
OUT_DIR=${OUT_DIR:-"$SELF_DIR/out"}
PATCH_LAYERS=${PATCH_LAYERS:-auto}
KEEP_WORK=${KEEP_WORK:-0}
SQUASHFS_COMP=${SQUASHFS_COMP:-}
SQUASHFS_BLOCK=${SQUASHFS_BLOCK:-}

ISO_NAME="zhenTo-${VERSION}-amd64.iso"
ISO_DIR="$WORK_DIR/iso"
ROOT_DIR="$WORK_DIR/root"
EFI_IMG="$WORK_DIR/efi.img"

RESOLV_RESTORE=""

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

human() {
    awk -v b="$1" 'BEGIN { printf "%.1fG", b / 1024 / 1024 / 1024 }'
}

# ISO 9660 volume label (-V) is limited to 32 characters; exceeding it makes xorriso fail.
# Truncate it here to keep things consistent.
if [ "${#VOLID}" -gt 32 ]; then
    warn "Volume label exceeds 32 chars (${#VOLID}); truncating to: ${VOLID:0:32}"
    VOLID=${VOLID:0:32}
fi

# ---------------------------------------------------------------------------
# Preinstall APPs: provision everything in one pass, then run the per-app
# customisation scripts. Works on a real system or inside chroot.
#
# The apt layer is declared in install-app/manifest.conf:
#   APT_REPOS     third-party sources to register (e.g. ppa:owner/name)
#   APT_PACKAGES  packages installed in a single apt-get install
# This replaces the old pattern where every install-app/*.sh ran its own
# "apt-get update && apt-get install", refreshing the index several times.
# ---------------------------------------------------------------------------
install_apps() {
    local app repo found=0 add_repo_flag=""
    local manifest="$SELF_DIR/install-app/manifest.conf"

    cd "$SELF_DIR"
    echo "==> Installing preinstalled applications..."

    # Defaults first so the sourced manifest is safe under `set -u`.
    APT_REPOS=()
    APT_PACKAGES=()
    [ -f "$manifest" ] || die "Missing $manifest"
    # shellcheck source=/dev/null
    . "$manifest"

    # ---- apt layer: register sources, refresh ONCE, install all packages ONCE ----
    if [ "${#APT_REPOS[@]}" -gt 0 ]; then
        command -v add-apt-repository >/dev/null 2>&1 ||
            die "add-apt-repository is required (install software-properties-common)"
        # Prefer -n so registering sources does not refresh the index by itself;
        # older versions lack it and will refresh, which is still correct.
        if add-apt-repository --help 2>&1 | grep -q -- '--no-update'; then
            add_repo_flag="-n"
        fi
        echo "==> Registering apt sources (${#APT_REPOS[@]}): ${APT_REPOS[*]}"
        for repo in "${APT_REPOS[@]}"; do
            # shellcheck disable=SC2086
            add-apt-repository -y $add_repo_flag "$repo" ||
                die "Failed to add apt source: $repo"
        done
    fi

    if [ "${#APT_REPOS[@]}" -gt 0 ] || [ "${#APT_PACKAGES[@]}" -gt 0 ]; then
        echo "==> apt-get update (single pass)"
        apt-get update || die "apt-get update failed"
    fi

    if [ "${#APT_PACKAGES[@]}" -gt 0 ]; then
        echo "==> apt-get install (${#APT_PACKAGES[@]} packages): ${APT_PACKAGES[*]}"
        apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}" ||
            die "apt-get install failed"
    fi

    # ---- customisation layer: per-app scripts, no apt operations ----
    echo "==> Running app customisation scripts..."
    for app in install-app/*.sh; do
        [ -e "$app" ] || continue
        found=1
        echo "==> Running ${app}"
        sh "$app" || die "Failed: $app"
    done

    [ "$found" -eq 1 ] || echo "==> No customisation scripts under install-app/"
    echo "==> All applications installed."
}

if [ "${1:-}" = "--apps-only" ]; then
    install_apps
    exit 0
fi

# ---------------------------------------------------------------------------
# Cleanup: unmount bind mounts, restore resolv.conf
# ---------------------------------------------------------------------------
cleanup() {
    local m
    set +e
    if [ -d "$ROOT_DIR" ]; then
        for m in cdrom run sys proc dev/pts dev; do
            if mountpoint -q "$ROOT_DIR/$m" 2>/dev/null; then
                umount -R "$ROOT_DIR/$m" 2>/dev/null || umount -l "$ROOT_DIR/$m" 2>/dev/null
            fi
        done
        if [ -n "${RESOLV_RESTORE:-}" ]; then
            rm -f "$ROOT_DIR/etc/resolv.conf"
            ln -s "$RESOLV_RESTORE" "$ROOT_DIR/etc/resolv.conf" 2>/dev/null
            RESOLV_RESTORE=""
        fi
    fi
    set -e
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Read the base layer of the default install source from install-sources.yaml
# ---------------------------------------------------------------------------
detect_default_layer() {
    awk '
        /^- default: true/  { def = 1; next }
        /^- default: false/ { def = 0; next }
        def && /^  path: /  { sub(/^  path: /, ""); print; exit }
    ' "$ISO_DIR/casper/install-sources.yaml"
}

# ---------------------------------------------------------------------------
# Inject build-time helper commands into the chroot (they are not shipped in the final image)
# ---------------------------------------------------------------------------
write_chroot_helpers() {
    local bin="$ROOT_DIR/opt/zhento-build/bin"
    install -d "$bin"

    cat >"$bin/zhento-flatpak" <<'EOS'
#!/bin/sh
# Build-time flatpak preinstall: zhento-flatpak <app-id> [...]
set -e
export DEBIAN_FRONTEND=noninteractive

command -v flatpak >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends flatpak ca-certificates
}

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

[ "$#" -gt 0 ] || { echo "Usage: zhento-flatpak <app-id>..." >&2; exit 2; }

for id in "$@"; do
    flatpak install --system -y --noninteractive flathub "$id"
done
EOS

    cat >"$bin/zhento-snap" <<'EOS'
#!/bin/sh
# Build-time snap preinstall: snapd is not running inside chroot, so we write the seed
# instead of running "snap install".
# Note: only works when the image ships its own seed.yaml; otherwise it errors out.
set -e
export DEBIAN_FRONTEND=noninteractive

command -v snap >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends snapd
}

SEED=/var/lib/snapd/seed
CHANNEL=${SNAP_CHANNEL:-stable}

[ -f "$SEED/seed.yaml" ] || {
    echo "XX  No $SEED/seed.yaml in the image; cannot preinstall snap; use apt or flatpak instead" >&2
    exit 1
}

[ "$#" -gt 0 ] || { echo "Usage: zhento-snap <snap-name>..." >&2; exit 2; }

for name in "$@"; do
    tmp=$(mktemp -d)
    (
        cd "$tmp"
        snap download "$name" --channel="$CHANNEL"
    )
    snapfile=$(ls "$tmp"/*.snap | head -n1)
    assertfile=$(ls "$tmp"/*.assert | head -n1)
    base=$(basename "$snapfile")

    install -m 0644 "$snapfile" "$SEED/snaps/$base"
    install -m 0644 "$assertfile" "$SEED/assertions/$(basename "$assertfile")"

    if grep -q "^  - name: ${name}$" "$SEED/seed.yaml"; then
        rm -rf "$tmp"
        continue
    fi

    entry=$(printf '  - name: %s\n    channel: %s\n    file: %s\n' "$name" "$CHANNEL" "$base")
    awk -v block="$entry" '
        /^[a-zA-Z]/ && !done { print block; done = 1 }
        { print }
        END { if (!done) print block }
    ' "$SEED/seed.yaml" > "$SEED/seed.yaml.new"
    mv "$SEED/seed.yaml.new" "$SEED/seed.yaml"

    rm -rf "$tmp"
done
EOS

    chmod 0755 "$bin/zhento-flatpak" "$bin/zhento-snap"
}

# ---------------------------------------------------------------------------
# Branding: copy edit-os-release/ into the chroot and run it to rewrite the image's os-release
# ---------------------------------------------------------------------------
apply_os_release() {
    local src="$SELF_DIR/edit-os-release"
    local dst=/opt/zhento-build/edit-os-release

    [ -d "$src" ] || {
        warn "edit-os-release/ is missing, skipping os-release"
        return 0
    }

    log "Writing os-release"
    rm -rf "$ROOT_DIR$dst"
    cp -a "$src" "$ROOT_DIR$dst"
    chroot "$ROOT_DIR" /bin/sh "$dst/edit.sh" || die "Failed to write os-release"
}

# ---------------------------------------------------------------------------
# Boot menu: replace boot/grub/grub.cfg in the ISO tree with the config from edit-grub/
# ---------------------------------------------------------------------------
apply_grub() {
    local src="$SELF_DIR/edit-grub"
    local dst="$ISO_DIR/boot/grub/grub.cfg"

    [ -f "$src/grub.cfg" ] || {
        warn "edit-grub/grub.cfg is missing, skipping boot menu"
        return 0
    }
    [ -f "$dst" ] || {
        warn "boot/grub/grub.cfg not found in ISO tree, skipping boot menu"
        return 0
    }

    log "Replacing boot menu grub.cfg"
    sh "$src/replace-grub.sh" "$dst" || die "Failed to replace grub.cfg"

    # The backup file is for rollback on a real system; it must not be included in the ISO
    rm -f "$dst".bak.*
}

# ---------------------------------------------------------------------------
# Process a single casper layer: unpack -> install APPs in chroot -> repack -> update metadata
# ---------------------------------------------------------------------------
patch_layer() {
    local layer="$1"
    local sfs="$ISO_DIR/casper/$layer"
    local size_file="$ISO_DIR/casper/${layer%.squashfs}.size"
    local comp block old_size new_size avail need
    local -a env_args

    [ -f "$sfs" ] || die "Layer file not found: $sfs"

    comp=$(unsquashfs -s "$sfs" | awk '/^Compression /{print $2}')
    block=$(unsquashfs -s "$sfs" | awk '/^Block size /{print $3}')
    [ -n "$comp" ] && [ -n "$block" ] || die "Cannot read squashfs parameters: $sfs"
    comp=${SQUASHFS_COMP:-$comp}
    block=${SQUASHFS_BLOCK:-$block}

    # Space check: unpacked size + new layer (base ISO is already on disk, not counted twice)
    need=$(($(stat -c%s "$sfs") * 3 / 2))
    if [ -f "$size_file" ]; then
        need=$((need + $(tr -d '\n' <"$size_file")))
    fi
    avail=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4 * 1024}')
    if [ "$avail" -lt "$need" ]; then
        die "Not enough space: $WORK_DIR needs about $(human "$need"), available $(human "$avail"). Point WORK_DIR to a larger disk"
    fi

    log "Unpacking $layer ($comp / ${block} block)"
    rm -rf "$ROOT_DIR"
    unsquashfs -no-progress -d "$ROOT_DIR" "$sfs" >/dev/null

    log "Preparing chroot"
    install -d "$ROOT_DIR/opt/zhento-build" "$ROOT_DIR/dev" "$ROOT_DIR/dev/pts" \
        "$ROOT_DIR/proc" "$ROOT_DIR/sys" "$ROOT_DIR/run"
    cp -f "$SELF" "$ROOT_DIR/opt/zhento-build/build.sh"
    rm -rf "$ROOT_DIR/opt/zhento-build/install-app"
    cp -a "$SELF_DIR/install-app" "$ROOT_DIR/opt/zhento-build/install-app"
    write_chroot_helpers

    mount --bind /dev "$ROOT_DIR/dev"
    mount -t devpts devpts "$ROOT_DIR/dev/pts" 2>/dev/null || true
    mount --bind /proc "$ROOT_DIR/proc"
    mount --bind /sys "$ROOT_DIR/sys"
    mount -t tmpfs tmpfs "$ROOT_DIR/run"

    # The image ships a file:/cdrom apt source (offline install repo); without /cdrom in
    # the chroot, "apt update" fails outright. Bind-mount the ISO tree to fix the index and
    # also make the offline repo available.
    if [ -d "$ISO_DIR/dists" ]; then
        install -d "$ROOT_DIR/cdrom"
        mount --bind "$ISO_DIR" "$ROOT_DIR/cdrom"
    fi

    # resolv.conf inside the chroot is usually a systemd-resolved symlink; replace it with
    # a real file first.
    if [ -L "$ROOT_DIR/etc/resolv.conf" ]; then
        RESOLV_RESTORE=$(readlink "$ROOT_DIR/etc/resolv.conf")
        rm -f "$ROOT_DIR/etc/resolv.conf"
    fi
    cp -f /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"

    # Prevent postinst from starting services inside the chroot
    printf '#!/bin/sh\nexit 101\n' >"$ROOT_DIR/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOT_DIR/usr/sbin/policy-rc.d"

    log "Running build.sh --apps-only inside chroot"
    env_args=(
        HOME=/root
        TERM=dumb
        LC_ALL=C.UTF-8
        DEBIAN_FRONTEND=noninteractive
        PATH=/opt/zhento-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    )
    local v
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
        [ -n "${!v:-}" ] && env_args+=("$v=${!v}")
    done
    chroot "$ROOT_DIR" /usr/bin/env -i "${env_args[@]}" \
        /bin/bash /opt/zhento-build/build.sh --apps-only

    apply_os_release

    log "Cleaning up build-time artifacts"
    rm -rf "$ROOT_DIR/opt/zhento-build"
    rm -f "$ROOT_DIR/usr/sbin/policy-rc.d"
    rm -f "$ROOT_DIR"/var/cache/apt/archives/*.deb 2>/dev/null || true

    cleanup

    log "Repacking $layer"
    mksquashfs "$ROOT_DIR" "$WORK_DIR/$layer" \
        -comp "$comp" -b "$block" -noappend -no-progress -quiet
    mv -f "$WORK_DIR/$layer" "$sfs"

    # Update the layer size (casper uses it to compute the memory needed by the overlay)
    if [ -f "$size_file" ]; then
        old_size=$(tr -d '\n' <"$size_file")
        new_size=$(du -sb "$ROOT_DIR" | cut -f1)
        printf '%s\n' "$new_size" >"$size_file"
        sed -i "s/^  size: ${old_size}$/  size: ${new_size}/" \
            "$ISO_DIR/casper/install-sources.yaml"
    fi

    rm -rf "$ROOT_DIR"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
    local layer start end interval report need avail
    local -a layer_list

    [ "$(id -u)" -eq 0 ] || die "root is required (chroot / mount): sudo $0"
    for c in xorriso unsquashfs mksquashfs rsync dd awk; do
        command -v "$c" >/dev/null || die "Missing command: $c"
    done
    [ -f "$BASE_ISO" ] || die "Base ISO not found: $BASE_ISO"

    mkdir -p "$OUT_DIR"
    rm -rf "$WORK_DIR"
    mkdir -p "$ISO_DIR"

    log "Extracting ISO tree to $ISO_DIR"
    xorriso -osirrox on:auto_chmod_on -indev "$BASE_ISO" -extract / "$ISO_DIR" >/dev/null

    [ -f "$ISO_DIR/casper/install-sources.yaml" ] ||
        die "This ISO has no casper/install-sources.yaml; it is not a supported Ubuntu desktop image"

    # Extract the FAT partition used for UEFI boot (the original disc uses an "appended partition",
    # not an efi.img file)
    log "Extracting EFI boot partition"
    report=$(LC_ALL=C xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null)
    interval=$(printf '%s\n' "$report" |
        sed -n "s/.*--interval:local_fs:\([0-9][0-9]*\)d-\([0-9][0-9]*\)d.*/\1 \2/p" |
        head -n1)
    [ -n "$interval" ] || die "Cannot parse EFI partition location from base ISO"
    start=${interval% *}
    end=${interval#* }
    dd if="$BASE_ISO" of="$EFI_IMG" bs=512 skip="$start" \
        count=$((end - start + 1)) status=none
    [ -s "$EFI_IMG" ] || die "EFI partition extraction failed"

    # Choose which layers to patch
    if [ "$PATCH_LAYERS" = "auto" ]; then
        layer=$(detect_default_layer)
        [ -n "$layer" ] || die "Cannot determine the default install source from install-sources.yaml"
        layer_list=("$layer")
    else
        read -r -a layer_list <<<"$PATCH_LAYERS"
    fi

    log "Layers to modify: ${layer_list[*]}"
    warn "Only the above base layer(s) are processed; language and enhanced-secureboot overlay layers are kept as-is"
    warn "casper/*.manifest are not regenerated (only affects installer package stats, not the install result)"

    for layer in "${layer_list[@]}"; do
        patch_layer "$layer"
    done

    apply_grub

    # boot.catalog is regenerated by xorriso; delete the old one in the ISO tree so md5sum
    # does not record stale content.
    rm -f "$ISO_DIR/boot.catalog"

    log "Rebuilding md5sum.txt"
    (
        cd "$ISO_DIR"
        find . -type f ! -name md5sum.txt -print0 |
            sort -z |
            xargs -0 md5sum >md5sum.txt
    )

    need=$(($(du -sb "$ISO_DIR" | cut -f1) * 105 / 100))
    avail=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4 * 1024}')
    [ "$avail" -ge "$need" ] ||
        die "Not enough space in output directory: need about $(human "$need"), available $(human "$avail")"

    log "Generating UEFI-only ISO: $ISO_NAME"
    rm -f "$OUT_DIR/$ISO_NAME"
    xorriso -as mkisofs \
        -r -V "$VOLID" -J -joliet-long -l -iso-level 3 \
        -partition_offset 16 \
        --protective-msdos-label \
        -append_partition 2 0xef "$EFI_IMG" \
        -appended_part_as_gpt \
        -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
        -o "$OUT_DIR/$ISO_NAME" "$ISO_DIR"

    (
        cd "$OUT_DIR"
        md5sum "$ISO_NAME" >"zhenTo-${VERSION}-amd64.md5"
    )

    log "Done"
    printf '  ISO : %s (%s)\n' "$OUT_DIR/$ISO_NAME" "$(human "$(stat -c%s "$OUT_DIR/$ISO_NAME")")"
    printf '  MD5 : %s\n' "$OUT_DIR/zhenTo-${VERSION}-amd64.md5"
    xorriso -indev "$OUT_DIR/$ISO_NAME" -report_el_torito plain 2>/dev/null |
        grep 'El Torito boot img' || true

    if [ "$KEEP_WORK" = "1" ]; then
        log "Keeping intermediate files: $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}

main "$@"
