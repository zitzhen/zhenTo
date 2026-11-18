# 冒烟测试工作流

四层检查按成本递增排列，低层是 PR 必过门禁，高层是构建/发布期的补充验收。

| 层 | 文件 | 运行方式 | 前置条件 | 是否阻断 PR |
|---|---|---|---|---|
| PR 快检 / 单测 | `auto-label.test.js`、`dco-check.test.sh`、`check-version-consistency.sh` | `node --test tests/*.test.js`、`bash tests/dco-check.test.sh`、`bash tests/check-version-consistency.sh` | Node.js 22+；git、bash；无网络 | 是 |
| 构建前预检 | `preflight.test.sh` | `bash tests/preflight.test.sh` | bash；无 root、无网络（外部命令用 fake bin mock） | 是 |
| 构建后产物验收 | `verify-artifact.sh` | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`、`unsquashfs`、`md5sum`、`sha256sum` | 否（在 build job 内阻断构建） |
| VM 启动冒烟 | `vm-smoke.sh` | `bash tests/vm-smoke.sh <iso> [超时秒数]` | `qemu-system-x86_64`、OVMF | 否（advisory） |

## 本地一键跑

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/dco-check.test.sh
bash tests/preflight.test.sh
```

## 版本真值

产品版本统一为 `0.1.1`（`build.sh`、`edit-os-release/os-release` 的 `VERSION_ID`、`.github/workflows/build-iso.yml` 的 `inputs.version default`）。基础镜像仍为 Ubuntu 26.04.1，`os-release` 的 `VERSION` 文案为 `26.04.1 (Resolute Raccoon)`。`check-version-consistency.sh` 负责防止这三处再次漂移。

## 安全约定

- `preflight.test.sh` 用临时 fake bin 拦截 `apt-get`、`add-apt-repository`、`curl`、`snap`、`gh`，并 mock `id`/`df`/`cp`；不会真的装包、联网或改系统。
- 绝不要无参数运行 `edit-grub/replace-grub.sh`（会覆盖 `/boot/grub/grub.cfg`）或 `edit-os-release/edit.sh`（会无备份覆盖 `/etc/os-release`）。测试里只走非 root 快速失败路径，或给 `replace-grub.sh` 显式传临时目标文件。
- `verify-artifact.sh` 只从 ISO 提取少量小文件，不展开 6.5G 根文件系统；ISO 自带 `md5sum.txt` 只抽查关键文件，不做全量校验。
- `vm-smoke.sh` 以 QEMU + OVMF 启动 ISO（UEFI-only 镜像不能用传统 BIOS），串口日志作为主要观测手段。受限于镜像自带 GRUB 的 `quiet splash` 且未开启串口控制台，登录提示符不保证出现；这一层主要用于捕获固件/GRUB/内核级灾难性失败，失败也不会阻断发布。

## CI 接线

- `.github/workflows/pr-check.yml`：lint job 内增加单测与版本一致性；新增无 root 的 `preflight` job。
- `.github/workflows/build-iso.yml`：`Build ISO` 前跑 `./build.sh --check`，`Build ISO` 后跑 `verify-artifact.sh`。
- `.github/workflows/vm-smoke.yml`：仅手动或 `v*` tag 触发，独立 job 且 `continue-on-error: true`。GitHub 托管 runner 无 `/dev/kvm`，TCG 软件模拟很慢；需要稳定结果时应迁到带 KVM 的自托管 runner。

## 新增测试时

纯 JS 规则继续放 `auto-label.test.js`；shell 冒烟脚本放本目录，统一 `set -euo pipefail`、写操作限定 `mktemp -d` 并 `trap` 清理，任何危险系统命令都必须 mock 或显式传临时路径。
