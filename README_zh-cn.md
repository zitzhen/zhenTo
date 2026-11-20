# ZhenTo

> 由 ZIT 小圳工作室打造的基于 Ubuntu 的操作系统。

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

ZhenTo 是一款基于 **Ubuntu 26.04.1 LTS "Resolute Raccoon"** 定制的 Linux 发行版。它对原版桌面镜像进行品牌重塑，预装了一组开发工具，并生成可直接写入 U 盘的 **仅 UEFI** 启动/安装 ISO 镜像。

整个镜像由 shell 脚本组装完成——旧的 Cubic 依赖已被移除。从解压官方 ISO、在 `chroot` 中打补丁，到重新打包成可启动镜像，一切都可以在本仓库中复现。

| | |
|---|---|
| **当前版本** | 0.1.1 |
| **基础镜像** | Ubuntu 26.04.1 Desktop（amd64） |
| **固件** | 仅 UEFI（不支持传统 BIOS） |
| **许可证** | [AGPL-3.0-only](LICENSE) |
| **主页** | https://zitzhen.cn/ |
| **问题反馈** | https://github.com/zitzhen/zhenTo/issues |

---

## 目录

- [ZhenTo](#zhento)
  - [目录](#目录)
  - [特性](#特性)
  - [仓库结构](#仓库结构)
  - [构建 ISO](#构建-iso)
    - [准备工作](#准备工作)
    - [快速构建](#快速构建)
    - [构建模式](#构建模式)
    - [环境变量](#环境变量)
    - [品牌素材](#品牌素材)
  - [使用 ISO](#使用-iso)
  - [下载发行版](#下载发行版)
  - [测试](#测试)
  - [持续集成](#持续集成)
  - [参与贡献](#参与贡献)
  - [许可证与致谢](#许可证与致谢)

---

## 特性

- **品牌重塑** —— `/etc/os-release`、GRUB 启动菜单、`/usr/share/pixmaps/` 中的品牌图标以及 ZhenTo 壁纸均标识为 ZhenTo。
- **仅 UEFI 镜像** —— 向 ISO 追加单个 EFI 系统分区，并使用 `xorriso` 生成启动项。
- **预装开发工具** —— `curl`、`git`、`zsh` 和 [patchsplit](https://github.com/zitzhen/patchsplit)（来自 `ppa:zitzhen/patchsplit` PPA）。
- **ZhenTo 桌面安装器** —— 来自 [zhento-desktop-install](https://github.com/zitzhen/zhento-desktop-install) 的 `ubuntu-desktop-bootstrap` snap 被预置到镜像中。在真实系统中直接安装；在 `chroot` 内则通过一次性 systemd 服务在首次启动时完成安装。
- **感知分层的补丁机制** —— 仅修改默认安装源的基础 squashfs 层，语言层和 enhanced-secureboot 覆盖层保持不变。
- **校验和与验证** —— 重新生成 `md5sum.txt`，CI 为每个发行版发布 MD5 和 SHA256 校验文件。
- **自动化 CI** —— Pull Request 由 lint/单元测试把关；tag 构建会生成 GitHub 草稿 Release，并拆分为小于 2 GB 的压缩包。

## 仓库结构

```text
.
├── build.sh                  # 主 ISO 构建脚本（解压 → chroot → 重新打包）
├── edit-backgrounds/
│   └── edit-backgrounds.sh   # 从 GitHub Releases 下载 ZhenTo 壁纸并设为 GNOME 默认壁纸
├── edit-grub/
│   ├── grub.cfg              # ZhenTo GRUB 菜单
│   └── replace-grub.sh       # 将菜单写入目标 grub.cfg（自动备份）
├── edit-icon/
│   ├── edit-icon.sh          # 将品牌图标与壁纸写入解压后的根目录
│   ├── generate-icons.sh     # 维护工具：从素材重新生成图标（需 ImageMagick）
│   ├── sources/              # 原始品牌 PNG（短图标 + 完整横幅）
│   └── files/pixmaps/        # 预生成的品牌图标，已提交进 git
├── edit-os-release/
│   ├── os-release            # ZhenTo /etc/os-release 品牌信息
│   └── edit.sh               # 将文件写入 /etc/os-release
├── install-app/
│   ├── ppa.list              #     # 维护期工具（build.sh 不调用）：构建时启用的额外 PPA
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # ZhenTo 桌面安装器（snap）配置
├── scripts/
│   └── download-release.*    # 下载 GitHub Release 的全部资产（sh / ps1 / cmd）
├── tests/                    # 四层冒烟测试（详见 tests/README.md）
└── .github/                  # Issue/PR 模板、CI 工作流、自动标签
```

## 构建 ISO

### 准备工作

- 一台以 **root** 身份运行的 Linux 主机（需要 `chroot` 和挂载操作）。
- 以下命令：`xorriso`、`unsquashfs`、`mksquashfs`、`rsync`、`dd`、`awk`（在 Ubuntu 上：`sudo apt-get install xorriso squashfs-tools rsync`）。
- Ubuntu 26.04.1 桌面基础 ISO，需带分层 squashfs 和 `casper/install-sources.yaml` 文件。
- 至少 **25 GB** 可用磁盘空间（峰值占用约 23 GB）。

### 快速构建

```bash
# 1. 只读预检：root、命令、基础 ISO、空间、输入文件、版本一致性
sudo ./build.sh --check

# 2. 构建 ISO
sudo BASE_ISO=/path/to/ubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

成功后会生成 `out/zhenTo-<VERSION>-amd64.iso` 及其 `.md5` 文件。除非设置 `KEEP_WORK=1`，否则 `work/` 下的中间文件会被清除。

> **注意：** `BASE_ISO` 默认值指向维护者本机的路径。请务必通过 `BASE_ISO=...` 传入你自己的路径，或修改 `build.sh` 中的默认值。

### 构建模式

| 命令 | 说明 |
|---|---|
| `sudo ./build.sh` | 完整构建：解压 ISO → 添加 PPA → 在 `chroot` 中安装应用 → 品牌重塑 → 重新打包 → 验证 |
| `sudo ./build.sh --check` | 只读预检。在进行任何 apt/PPA 或文件系统更改之前退出 |
| `sudo ./build.sh --apps-only` | 仅运行 `install-app/*.sh` —— 适用于 `chroot` 内或正在运行的系统 |

### 环境变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `BASE_ISO` | `/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso` | 源 Ubuntu 桌面 ISO |
| `VERSION` | `0.1.1` | 产品版本（写入 ISO 名称和 `os-release`） |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO 卷标（截断为 32 个字符） |
| `WORK_DIR` | `<repo>/work` | 中间构建目录 |
| `OUT_DIR` | `<repo>/out` | ISO 输出目录 |
| `PATCH_LAYERS` | `auto` | `auto` 或以空格分隔的待修改 casper 层文件列表 |
| `KEEP_WORK` | `0` | 设为 `1` 以保留中间文件用于调试 |
| `SQUASHFS_COMP` | 继承原值 | Squashfs 压缩算法（`zstd` 比 `xz` 快得多） |
| `SQUASHFS_BLOCK` | 继承原值 | Squashfs 块大小（通常为 `131072`） |
| `ICON_SRC_DIR` | `<repo>/edit-icon/sources` | 品牌图标素材目录（短图标 + 完整横幅 PNG） |
| `WALLPAPER_REPO` | `zitzhen/zhento-backgrounds` | 提供壁纸的 GitHub 仓库（Release 资产） |
| `WALLPAPER_TAG` | `zhenTo-coffee-1.0.0` | 壁纸 Release 标签（资产 SHA256 已在安装器中固定） |

如果 `VERSION` 与 `edit-os-release/os-release` 中的版本不一致，构建脚本将拒绝运行，从而确保品牌信息不会与版本号脱节。

### 品牌素材

品牌图稿来自 [zitzhen/zhenTo-icon](https://github.com/zitzhen/zhenTo-icon)，已随仓库存放在 `edit-icon/sources/`：

| 文件 | 来源 | SHA256 |
|---|---|---|
| `zhento-short.png` | `zhento短图标.png`（548×545） | `e6d3cbedf49f04319c0a5709d3469411d8a1357bb18f971e93d4bc9faa64513e` |
| `zhento-full.png` | `zhento.png`（1774×887） | `2f2949680a77be8c1d050d4741a91fb9b5dd0834473ca8e6f1ba7095a398ff5d` |

短图标替换 `/usr/share/pixmaps/` 下的 7 个 `ubuntu-logo*` / `debian-logo*` 品牌位；完整横幅作为 `/usr/share/backgrounds/zhento.png` 新增壁纸。镜像中的其他图标保持不变。`edit-icon/files/pixmaps/` 中的 PNG/SVG 文件是**预生成并提交进 git** 的，因此构建时无需 ImageMagick、也无需联网。图稿变更后运行 `./edit-icon/generate-icons.sh`（需 ImageMagick）重新生成并提交即可。由于没有单独的暗色素材，`-text-dark` 变体复用浅色图稿。

桌面壁纸来自 [zitzhen/zhento-backgrounds](https://github.com/zitzhen/zhento-backgrounds) 的 Releases，由 `edit-backgrounds/edit-backgrounds.sh` **在构建时下载**。`oliver-ZhenTo_Coffee_Mug_Light.png` 与 `...Dark.png` 会安装为 `/usr/share/backgrounds/` 下的 `zhento-light.png` / `zhento-dark.png`，并附带上游的 `copyright` 声明（CC-BY-SA-4.0）。gschema override 会将它们分别设为浅色 / 深色模式的默认壁纸（用户可在设置中覆盖）；若目标系统没有 GNOME 壁纸 schema，则只安装图片、不修改默认壁纸。每个资产的 SHA256 都固定在安装器中——文件缺失或校验不符会让构建失败，不会把未经验证的壁纸打进镜像。要使用其他版本，请设置 `WALLPAPER_TAG`（并同步更新固定的校验值）。

## 使用 ISO

1. **写入 U 盘**（请将 `/dev/sdX` 替换为你的实际设备——此操作会清空该设备）：

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **启动**目标机器并进入 UEFI 模式，选择 U 盘。不支持传统 BIOS 启动。
3. 选择 **Try or Install ZhenTo**（若遇到显卡驱动问题则选择 **ZhenTo (safe graphics)**），然后运行 ZhenTo 桌面安装器。

## 下载发行版

GitHub Release 的资产被拆分为 1800 MB 的压缩分卷，以低于每个文件 2 GB 的限制。按如下方式合并并校验：

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

仓库提供了辅助脚本，可通过 GitHub CLI 下载某个发行版的**全部**资产（包括草稿）：

```bash
# 需要：gh auth login（下载草稿需要写权限）
./scripts/download-release.sh v0.1.1
./scripts/download-release.sh v0.1.1 zitzhen/zhenTo ./out   # 显式指定仓库和输出目录
```

Windows 用户可使用 `scripts\download-release.ps1`（PowerShell）或 `scripts\download-release.cmd`。

## 测试

四层检查按成本从低到高排列。较低层是 PR 的强制门禁，较高层在构建/发布期间作为补充验收。

| 层级 | 命令 | 依赖 | 阻断 PR |
|---|---|---|---|
| 单元测试 / 版本一致性 | `node --test tests/*.test.js` 和 `bash tests/check-version-consistency.sh` | Node.js 22+；无需 root、无需网络 | 是 |
| 预检（mock） | `bash tests/preflight.test.sh` | bash；无需 root、无需网络 | 是 |
| 安装器（mock） | `bash tests/icon.test.sh` 和 `bash tests/backgrounds.test.sh` | bash；无需 root、无需网络 | 是 |
| 产物验证 | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`、`unsquashfs`、`md5sum`、`sha256sum` | 否（在 build job 内阻断构建） |
| VM 启动冒烟 | `bash tests/vm-smoke.sh <iso> [超时秒数]` | `qemu-system-x86_64`、OVMF | 否（仅供参考） |

一次性运行本地门禁检查：

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
bash tests/icon.test.sh
bash tests/backgrounds.test.sh
```

详情与安全注意事项见 [tests/README.md](tests/README.md)。

## 持续集成

| 工作流 | 触发条件 | 用途 |
|---|---|---|
| `pr-check.yml` | 每次 Pull Request | 语法检查、单元测试、版本一致性、shellcheck、actionlint、gitleaks、非 root 预检 |
| `dco.yml` | push 和 PR | 强制 `Signed-off-by` 签署（开发者来源认证 DCO） |
| `build-iso.yml` | `v*` tag 或手动触发 | 预检 → 构建 → 验证 → 拆分 → 发布草稿 |
| `vm-smoke.yml` | `v*` tag 或手动触发 | 参考性 QEMU + OVMF 启动检查（`continue-on-error`） |
| `auto-label.yml` | PR 活动 | 自动添加标签 |

## 参与贡献

1. Fork 本仓库，从 `main` 创建分支。
2. 进行改动，并保持版本在 `build.sh`、`edit-os-release/os-release` 和 `.github/workflows/build-iso.yml` 三处一致。
3. 运行上述本地检查。
4. 提交时带上 DCO 签署：

   ```bash
   git commit -s -m "feat: describe your change"
   ```

   签署邮箱必须与提交作者/提交者邮箱一致，且不得使用 GitHub 的 `noreply` 地址。
5. 发起 Pull Request。选择[英文](.github/PULL_REQUEST_TEMPLATE/english.md)或[中文](.github/PULL_REQUEST_TEMPLATE/chinese.md)模板，并确保所有必需检查通过。

欢迎通过 `.github/ISSUE_TEMPLATE/` 中的模板提交 Bug 报告和功能建议。

## 许可证与致谢

本项目采用 **GNU Affero General Public License v3.0 only** 许可证 —— 详见 [LICENSE](LICENSE)。

由 **ZIT 小圳工作室** 创建。

- 作者 / 维护者：Oliver Lin <oliver@liuxiaozhen.dev>
- 贡献者：见 [CONTRIBUTORS](CONTRIBUTORS)
- 主页：https://zitzhen.cn/
