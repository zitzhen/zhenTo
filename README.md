# ZhenTo

> An Ubuntu-based operating system crafted by ZIT Studio (ZIT 小圳工作室).

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

ZhenTo is a customized Linux distribution derived from **Ubuntu 26.04.1 LTS "Resolute Raccoon"**. It rebrands the base desktop image, installs a small set of developer tools out of the box, and produces an **UEFI-only** live/install ISO that can be written straight to a USB drive.

The whole image is assembled by shell scripts — the old dependency on Cubic has been removed. Everything from unpacking the official ISO and patching it inside a `chroot`, to repacking a bootable image, is reproducible from this repository.

| | |
|---|---|
| **Current version** | 0.1.1 |
| **Base image** | Ubuntu 26.04.1 Desktop (amd64) |
| **Firmware** | UEFI only (legacy BIOS is not supported) |
| **License** | [AGPL-3.0-only](LICENSE) |
| **Homepage** | https://zitzhen.cn/ |
| **Issues** | https://github.com/zitzhen/zhenTo/issues |

---

## Table of Contents

- [Features](#features)
- [Repository Layout](#repository-layout)
- [Building the ISO](#building-the-iso)
  - [Prerequisites](#prerequisites)
  - [Quick Build](#quick-build)
  - [Build Modes](#build-modes)
  - [Environment Variables](#environment-variables)
  - [Brand Assets](#brand-assets)
- [Using the ISO](#using-the-iso)
- [Downloading a Release](#downloading-a-release)
- [Testing](#testing)
- [Continuous Integration](#continuous-integration)
- [Contributing](#contributing)
- [License & Credits](#license--credits)

---

## Features

- **Rebranded identity** — `/etc/os-release`, the GRUB boot menu, the brand icons in `/usr/share/pixmaps/`, and a ZhenTo wallpaper all identify the system as ZhenTo.
- **UEFI-only image** — a single EFI system partition is appended to the ISO; boot entries are generated with `xorriso`.
- **Developer tools preinstalled** — `curl`, `git`, `zsh`, and [patchsplit](https://github.com/zitzhen/patchsplit) (from the `ppa:zitzhen/patchsplit` PPA).
- **zsh for every account** — existing accounts are switched to `/bin/zsh` with a Starship-enabled `.zshrc`, and `/etc/default/useradd` gives new accounts the same shell.
- **ZhenTo Desktop Installer** — the `ubuntu-desktop-bootstrap` snap from [zhento-desktop-install](https://github.com/zitzhen/zhento-desktop-install) is seeded into the image. On a live system it is installed directly; inside the `chroot` a one-shot systemd unit finishes the installation on first boot.
- **Layer-aware patching** — only the base squashfs layer of the default install source is modified. Language and enhanced-secureboot overlay layers are left untouched.
- **Checksums and verification** — `md5sum.txt` is regenerated, and CI publishes MD5 and SHA256 files for every release.
- **Automated CI** — pull requests are gated by lint/unit tests; tagged builds produce a draft GitHub Release with split, under-2 GB archives.

## Repository Layout

```text
.
├── build.sh                  # Main ISO build script (unpack → chroot → repack)
├── edit-backgrounds/
│   └── edit-backgrounds.sh   # Download ZhenTo wallpapers from GitHub Releases and set as GNOME default
├── edit-etc-default-useradd/
│   ├── edit-etc-default-useradd.sh # Write SHELL=/bin/zsh into /etc/default/useradd (new accounts)
│   ├── useradd               # ZhenTo /etc/default/useradd
│   └── .zshrc                # ZhenTo ~/.zshrc with the Starship prompt
├── edit-grub/
│   ├── grub.cfg              # ZhenTo GRUB menu
│   └── replace-grub.sh       # Install the menu into a target grub.cfg (with backup)
├── edit-icon/
│   ├── edit-icon.sh          # Install brand icons + wallpaper into an unpacked root
│   ├── generate-icons.sh     # Maintenance tool: regenerate icons from sources (needs ImageMagick)
│   ├── sources/              # Original brand PNGs (short logo + full banner)
│   └── files/pixmaps/        # Pre-generated brand icons, committed to git
├── edit-os-release/
│   ├── os-release            # ZhenTo /etc/os-release branding
│   └── edit.sh               # Install the file into /etc/os-release
├── edit-terminal/
│   └── edit-terminal.sh      # Switch every existing account to zsh and install the ZhenTo .zshrc
├── install-app/
│   ├── ppa.list              # Extra PPAs to enable during the build
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # ZhenTo Desktop Installer (snap) setup
├── scripts/
│   └── download-release.*    # Download all assets of a GitHub release (sh / ps1 / cmd)
├── tests/                    # Four-layer smoke tests (see tests/README.md)
└── .github/
    ├── actions/build-iso/    # Reusable composite action: build + verify + package
    ├── workflows/            # CI workflows (PR gate, ISO build, VM smoke, DCO, ...)
    └── ISSUE_TEMPLATE/       # Issue/PR templates
```

## Building the ISO

### Prerequisites

- A Linux host running as **root** (`chroot` and mounts are required).
- The following commands: `xorriso`, `unsquashfs`, `mksquashfs`, `rsync`, `dd`, `awk` (on Ubuntu: `sudo apt-get install xorriso squashfs-tools rsync`).
- The Ubuntu 26.04.1 desktop base ISO, with layered squashfs and a `casper/install-sources.yaml` file.
- At least **25 GB** of free disk space (peak usage is roughly 23 GB).

### Quick Build

```bash
# 1. Read-only preflight: root, commands, base ISO, space, inputs, version consistency
sudo ./build.sh --check

# 2. Build the ISO
sudo BASE_ISO=/path/to/ubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

On success, `out/zhenTo-<VERSION>-amd64.iso` and its `.md5` file are produced. Intermediate files under `work/` are removed unless `KEEP_WORK=1` is set.

> **Note:** the default `BASE_ISO` points to the maintainer's local path. Always pass your own via `BASE_ISO=...` or edit the default in `build.sh`.

### Build Modes

| Command | Description |
|---|---|
| `sudo ./build.sh` | Full build: unpack ISO → add PPAs → install apps in `chroot` → rebrand → repack → verify |
| `sudo ./build.sh --check` | Read-only preflight. Exits before any apt/PPA or filesystem changes |
| `sudo ./build.sh --apps-only` | Run only `install-app/*.sh` — useful inside a `chroot` or on a running system |

### Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `BASE_ISO` | `/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso` | Source Ubuntu desktop ISO |
| `VERSION` | `0.1.1` | Product version (embedded in the ISO name and `os-release`) |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO volume label (truncated to 32 characters) |
| `WORK_DIR` | `<repo>/work` | Intermediate build directory |
| `OUT_DIR` | `<repo>/out` | Output directory for the ISO |
| `PATCH_LAYERS` | `auto` | `auto` or a space-separated list of casper layer files to patch |
| `KEEP_WORK` | `0` | Set to `1` to keep intermediate files for debugging |
| `SQUASHFS_COMP` | inherited | Squashfs compression (`zstd` is much faster than `xz`) |
| `SQUASHFS_BLOCK` | inherited | Squashfs block size (usually `131072`) |
| `ICON_SRC_DIR` | `<repo>/edit-icon/sources` | Brand icon source directory (short + full PNG) |
| `WALLPAPER_REPO` | `zitzhen/zhento-backgrounds` | GitHub repo whose Release supplies the wallpapers |
| `WALLPAPER_TAG` | `zhenTo-coffee-1.0.0` | Wallpaper Release tag (assets are checksum-pinned in the installer) |

The build script refuses to run if `VERSION` does not match `edit-os-release/os-release`, so branding never drifts from the release number.

### Default Shell

Every account on the image uses **zsh**, with the Starship prompt initialised from `~/.zshrc`:

- `edit-terminal/edit-terminal.sh` runs inside the `chroot` and rewrites `/etc/passwd`: the login shell of `root` and of every regular account (uid ≥ 1000) becomes `/bin/zsh`. System accounts and accounts already pinned to `nologin`/`false` are left alone.
- The same script installs `edit-etc-default-useradd/.zshrc` into `/etc/skel/.zshrc` and into every existing home directory. A pre-existing `.zshrc` is kept as `.zshrc.bak.<timestamp>`, and the installed copy keeps the account's uid/gid.
- `edit-etc-default-useradd/edit-etc-default-useradd.sh` overwrites `/etc/default/useradd` with `SHELL=/bin/zsh` (no merging), so accounts created later — by the installer, `useradd` or `adduser` — start with zsh too.

Both scripts also run against a real system or an unpacked root: `sudo ./edit-terminal/edit-terminal.sh [<root>]` and `sudo ./edit-etc-default-useradd/edit-etc-default-useradd.sh [<target>]`. Neither is shipped in the final image.

### Brand Assets

The brand artwork lives in [zitzhen/zhenTo-icon](https://github.com/zitzhen/zhenTo-icon) and is vendored into `edit-icon/sources/`:

| File | Source | SHA256 |
|---|---|---|
| `zhento-short.png` | `zhento短图标.png` (548×545) | `e6d3cbedf49f04319c0a5709d3469411d8a1357bb18f971e93d4bc9faa64513e` |
| `zhento-full.png` | `zhento.png` (1774×887) | `2f2949680a77be8c1d050d4741a91fb9b5dd0834473ca8e6f1ba7095a398ff5d` |

The short logo replaces the seven `ubuntu-logo*` / `debian-logo*` slots in `/usr/share/pixmaps/`; the full banner is added as `/usr/share/backgrounds/zhento.png`. Other icons in the image are left untouched. The PNG/SVG files in `edit-icon/files/pixmaps/` are **pre-generated and committed**, so the build needs no ImageMagick and no network access. To regenerate them after an artwork change, run `./edit-icon/generate-icons.sh` (requires ImageMagick) and commit the result. The `-text-dark` variants reuse the light artwork because no separate dark asset exists.

Desktop wallpapers come from the [zitzhen/zhento-backgrounds](https://github.com/zitzhen/zhento-backgrounds) Releases and are **downloaded at build time** by `edit-backgrounds/edit-backgrounds.sh`. The `oliver-ZhenTo_Coffee_Mug_Light.png` and `...Dark.png` assets are installed as `zhento-light.png` / `zhento-dark.png` in `/usr/share/backgrounds/`, together with the upstream `copyright` notice (CC-BY-SA-4.0). A gschema override sets them as the default wallpaper for light and dark mode respectively (user-overridable); if the target has no GNOME background schema, the images are still installed without changing the default. Each asset's SHA256 is pinned in the installer — a missing file or checksum mismatch fails the build rather than shipping an unverified wallpaper. To use a different release, set `WALLPAPER_TAG` (and update the pinned checksums).

## Using the ISO

1. **Write to a USB drive** (replace `/dev/sdX` with your actual device — this erases it):

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **Boot** the target machine in UEFI mode and select the USB drive. Legacy BIOS boot is not supported.
3. Choose **Try or Install ZhenTo** (or **ZhenTo (safe graphics)** if you hit display driver issues), then run the ZhenTo Desktop Installer.

## Downloading a Release

GitHub Release assets are split into 1800 MB compressed volumes to stay below the 2 GB per-file limit. Reassemble and verify them like this:

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

Helper scripts are provided to download **all** assets of a release (including drafts) with the GitHub CLI:

```bash
# Requires: gh auth login (write access is needed for drafts)
./scripts/download-release.sh v0.1.1
./scripts/download-release.sh v0.1.1 zitzhen/zhenTo ./out   # explicit repo and output dir
```

Windows users can use `scripts\download-release.ps1` (PowerShell) or `scripts\download-release.cmd`.

## Testing

Four layers of checks are arranged by increasing cost. The lower layers are mandatory PR gates; higher layers run during build/release.

| Layer | Command | Requires | Blocks PR |
|---|---|---|---|
| Unit tests / version consistency | `node --test tests/*.test.js` and `bash tests/check-version-consistency.sh` | Node.js 22+; no root, no network | Yes |
| Preflight (mocked) | `bash tests/preflight.test.sh` | bash; no root, no network | Yes |
| Installer (mocked) | `bash tests/icon.test.sh` and `bash tests/backgrounds.test.sh` | bash; no root, no network | Yes |
| Artifact verification | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`, `unsquashfs`, `md5sum`, `sha256sum` | No (blocks the build job) |
| VM boot smoke | `bash tests/vm-smoke.sh <iso> [timeout]` | `qemu-system-x86_64`, OVMF | No (advisory) |

Run the local gates in one shot:

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
bash tests/icon.test.sh
bash tests/backgrounds.test.sh
```

See [tests/README.md](tests/README.md) for details and safety notes.

## Continuous Integration

| Workflow | Trigger | Purpose |
|---|---|---|
| `pr-check.yml` | Every pull request | Syntax checks, unit tests, version consistency, shellcheck, actionlint, gitleaks, non-root preflight |
| `dco.yml` | Pushes and PRs | Enforces `Signed-off-by` trailers (Developer Certificate of Origin) |
| `build-iso.yml` | `v*` tag or manual dispatch | Resolve version → build via `.github/actions/build-iso` → verify → split → release (draft/publish/none) |
| `vm-smoke.yml` | `v*` tag or manual dispatch | Advisory QEMU + OVMF boot check (`continue-on-error`) |
| `auto-label.yml` | PR activity | Automatic labeling |
| `contributors.yml` | PR merged | Rebuild `CONTRIBUTORS` from all `Signed-off-by` trailers and label the merged PR |

## Contributing

1. Fork the repository and create a branch from `main`.
2. Make your change, keeping the version consistent between `build.sh` and `edit-os-release/os-release`. The build workflow derives its version from `os-release`, so there is no third copy to keep in sync.
3. Run the local checks above.
4. Commit with a DCO sign-off:

   ```bash
   git commit -s -m "feat: describe your change"
   ```

   The sign-off email must match your commit author/committer email and must not be a GitHub `noreply` address. `CONTRIBUTORS` is rebuilt from these trailers automatically after each merge — do not edit it by hand.
5. Open a pull request. Choose the [English](.github/PULL_REQUEST_TEMPLATE/english.md) or [Chinese](.github/PULL_REQUEST_TEMPLATE/chinese.md) template, and make sure all required checks pass.

Bug reports and feature requests are welcome via the issue templates in `.github/ISSUE_TEMPLATE/`.

## License & Credits

Licensed under the **GNU Affero General Public License v3.0 only** — see [LICENSE](LICENSE).

Created by **ZIT Studio (ZIT 小圳工作室)**.

- Author / maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
- Contributors: see [CONTRIBUTORS](CONTRIBUTORS)
- Homepage: https://zitzhen.cn/
