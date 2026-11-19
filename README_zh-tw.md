# ZhenTo

> 由 ZIT 小圳工作室打造的基於 Ubuntu 作業系統。

[English](README.md) · [简体中文](README_zh-cn.md) · [繁體中文](README_zh-tw.md)

ZhenTo 是一款基於 **Ubuntu 26.04.1 LTS "Resolute Raccoon"** 客製化的 Linux 發行版。它重新塑造了原始桌面映像的品牌形象，預裝了一組開發工具，並產生可直接寫入 USB 隨身碟的 **僅 UEFI** 開機／安裝 ISO 映像。

整個映像由 shell 腳本組裝完成——舊有的 Cubic 依賴已被移除。從解壓官方 ISO、在 `chroot` 中修補，到重新封裝成可開機映像，一切都能在本儲存庫中重現。

| | |
|---|---|
| **目前版本** | 0.1.1 |
| **基礎映像** | Ubuntu 26.04.1 Desktop（amd64） |
| **韌體** | 僅 UEFI（不支援傳統 BIOS） |
| **授權** | [AGPL-3.0-only](LICENSE) |
| **首頁** | https://zitzhen.cn/ |
| **問題回報** | https://github.com/zitzhen/zhenTo/issues |

---

## 目錄

- [特色](#特色)
- [儲存庫結構](#儲存庫結構)
- [建置 ISO](#建置-iso)
  - [準備工作](#準備工作)
  - [快速建置](#快速建置)
  - [建置模式](#建置模式)
  - [環境變數](#環境變數)
  - [品牌素材](#品牌素材)
- [使用 ISO](#使用-iso)
- [下載發行版](#下載發行版)
- [測試](#測試)
- [持續整合](#持續整合)
- [參與貢獻](#參與貢獻)
- [授權與致謝](#授權與致謝)

---

## 特色

- **品牌重塑** —— `/etc/os-release`、GRUB 開機選單、`/usr/share/pixmaps/` 中的品牌圖示與 ZhenTo 桌布皆標示為 ZhenTo。
- **僅 UEFI 映像** —— 附加單一 EFI 系統分割區至 ISO，並使用 `xorriso` 產生開機項目。
- **預裝開發工具** —— `curl`、`git`、`zsh` 與 [patchsplit](https://github.com/zitzhen/patchsplit)（來自 `ppa:zitzhen/patchsplit` PPA）。
- **ZhenTo 桌面安裝程式** —— 來自 [zhento-desktop-install](https://github.com/zitzhen/zhento-desktop-install) 的 `ubuntu-desktop-bootstrap` snap 已預置於映像中。在真實系統中直接安裝；在 `chroot` 內則透過一次性 systemd 服務於首次開機時完成安裝。
- **感知分層的修補機制** —— 僅修改預設安裝來源的基礎 squashfs 層，語言層與 enhanced-secureboot 覆蓋層保持不變。
- **總和檢查碼與驗證** —— 重新產生 `md5sum.txt`，CI 為每個發行版發佈 MD5 與 SHA256 檢查碼檔案。
- **自動化 CI** —— Pull Request 由 lint／單元測試把關；標籤建置會產生 GitHub 草稿 Release，並分割為小於 2 GB 的壓縮檔。

## 儲存庫結構

```text
.
├── build.sh                  # 主 ISO 建置腳本（解壓 → chroot → 重新封裝）
├── edit-grub/
│   ├── grub.cfg              # ZhenTo GRUB 選單
│   └── replace-grub.sh       # 將選單寫入目標 grub.cfg（自動備份）
├── edit-icon/
│   ├── edit-icon.sh          # 將品牌圖示與桌布寫入解壓後的根目錄
│   ├── generate-icons.sh     # 維護工具：從素材重新產生圖示（需 ImageMagick）
│   ├── sources/              # 原始品牌 PNG（短圖示 + 完整橫幅）
│   └── files/pixmaps/        # 預先產生的品牌圖示，已提交至 git
├── edit-os-release/
│   ├── os-release            # ZhenTo /etc/os-release 品牌資訊
│   └── edit.sh               # 將檔案寫入 /etc/os-release
├── install-app/
│   ├── ppa.list              # 建置時啟用的額外 PPA
│   ├── curl.sh, git.sh, zsh.sh, patchsplit.sh
│   └── Installer.sh          # ZhenTo 桌面安裝程式（snap）設定
├── scripts/
│   └── download-release.*    # 下載 GitHub Release 的全部資產（sh / ps1 / cmd）
├── tests/                    # 四層煙霧測試（詳見 tests/README.md）
└── .github/
    ├── actions/build-iso/    # 可複用 composite action：建置 + 驗證 + 打包
    ├── workflows/            # CI 工作流程（PR 門檻、ISO 建置、VM 冒煙、DCO 等）
    └── ISSUE_TEMPLATE/       # Issue/PR 範本
```

## 建置 ISO

### 準備工作

- 一台以 **root** 身份執行的 Linux 主機（需要 `chroot` 與掛載操作）。
- 下列指令：`xorriso`、`unsquashfs`、`mksquashfs`、`rsync`、`dd`、`awk`（在 Ubuntu 上：`sudo apt-get install xorriso squashfs-tools rsync`）。
- Ubuntu 26.04.1 桌面基礎 ISO，需具備分層 squashfs 與 `casper/install-sources.yaml` 檔案。
- 至少 **25 GB** 可用磁碟空間（尖峰佔用約 23 GB）。

### 快速建置

```bash
# 1. 唯讀預檢：root、指令、基礎 ISO、空間、輸入檔案、版本一致性
sudo ./build.sh --check

# 2. 建置 ISO
sudo BASE_ISO=/path/to/ubuntu-26.04.1-desktop-amd64.iso ./build.sh
```

成功後會產生 `out/zhenTo-<VERSION>-amd64.iso` 及其 `.md5` 檔案。除非設定 `KEEP_WORK=1`，否則 `work/` 下的中間檔案會被清除。

> **注意：** `BASE_ISO` 預設值指向維護者本機的路徑。請務必透過 `BASE_ISO=...` 傳入你自己的路徑，或修改 `build.sh` 中的預設值。

### 建置模式

| 指令 | 說明 |
|---|---|
| `sudo ./build.sh` | 完整建置：解壓 ISO → 新增 PPA → 在 `chroot` 中安裝應用程式 → 品牌重塑 → 重新封裝 → 驗證 |
| `sudo ./build.sh --check` | 唯讀預檢。在進行任何 apt/PPA 或檔案系統變更之前結束 |
| `sudo ./build.sh --apps-only` | 僅執行 `install-app/*.sh` —— 適用於 `chroot` 內或正在執行的系統 |

### 環境變數

| 變數 | 預設值 | 用途 |
|---|---|---|
| `BASE_ISO` | `/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso` | 來源 Ubuntu 桌面 ISO |
| `VERSION` | `0.1.1` | 產品版本（寫入 ISO 名稱與 `os-release`） |
| `VOLID` | `ZhenTo <VERSION> amd64` | ISO 磁碟區標籤（截斷為 32 個字元） |
| `WORK_DIR` | `<repo>/work` | 中間建置目錄 |
| `OUT_DIR` | `<repo>/out` | ISO 輸出目錄 |
| `PATCH_LAYERS` | `auto` | `auto` 或以空格分隔的待修改 casper 層檔案清單 |
| `KEEP_WORK` | `0` | 設為 `1` 以保留中間檔案供偵錯 |
| `SQUASHFS_COMP` | 沿用原值 | Squashfs 壓縮演算法（`zstd` 比 `xz` 快得多） |
| `SQUASHFS_BLOCK` | 沿用原值 | Squashfs 區塊大小（通常為 `131072`） |
| `ICON_SRC_DIR` | `<repo>/edit-icon/sources` | 品牌圖示素材目錄（短圖示 + 完整橫幅 PNG） |

若 `VERSION` 與 `edit-os-release/os-release` 中的版本不一致，建置腳本將拒絕執行，以確保品牌形象不會與版本號脫節。

### 品牌素材

品牌圖稿來自 [zitzhen/zhenTo-icon](https://github.com/zitzhen/zhenTo-icon)，已隨儲存庫存放於 `edit-icon/sources/`：

| 檔案 | 來源 | SHA256 |
|---|---|---|
| `zhento-short.png` | `zhento短图标.png`（548×545） | `e6d3cbedf49f04319c0a5709d3469411d8a1357bb18f971e93d4bc9faa64513e` |
| `zhento-full.png` | `zhento.png`（1774×887） | `2f2949680a77be8c1d050d4741a91fb9b5dd0834473ca8e6f1ba7095a398ff5d` |

短圖示替換 `/usr/share/pixmaps/` 下的 7 個 `ubuntu-logo*` / `debian-logo*` 品牌位；完整橫幅做為 `/usr/share/backgrounds/zhento.png` 新增桌布。映像中的其他圖示保持不變。`edit-icon/files/pixmaps/` 中的 PNG/SVG 檔案是**預先產生並提交至 git** 的，因此建置時無需 ImageMagick、也無需網路。圖稿變更後執行 `./edit-icon/generate-icons.sh`（需 ImageMagick）重新產生並提交即可。由於沒有單獨的暗色素材，`-text-dark` 變體重用淺色圖稿。

## 使用 ISO

1. **寫入 USB 隨身碟**（請將 `/dev/sdX` 替換為你的實際裝置——此操作會清空該裝置）：

   ```bash
   sudo dd if=zhenTo-<VERSION>-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. **開機**目標機器並進入 UEFI 模式，選擇 USB 隨身碟。不支援傳統 BIOS 開機。
3. 選擇 **Try or Install ZhenTo**（若遇到顯示卡驅動問題則選擇 **ZhenTo (safe graphics)**），然後執行 ZhenTo 桌面安裝程式。

## 下載發行版

GitHub Release 的資產被分割為 1800 MB 的壓縮分卷，以低於單一檔案 2 GB 的限制。請依下列方式合併並驗證：

```bash
unzip zhenTo-<VERSION>-amd64.iso.zip
sha256sum -c zhenTo-<VERSION>-amd64.iso.sha256
```

儲存庫提供輔助腳本，可透過 GitHub CLI 下載某個發行版的**全部**資產（包含草稿）：

```bash
# 需要：gh auth login（下載草稿需要寫入權限）
./scripts/download-release.sh v0.1.1
./scripts/download-release.sh v0.1.1 zitzhen/zhenTo ./out   # 明確指定儲存庫與輸出目錄
```

Windows 使用者可使用 `scripts\download-release.ps1`（PowerShell）或 `scripts\download-release.cmd`。

## 測試

四層檢查依成本由低至高排列。較低層是 PR 的強制關卡，較高層在建置／發行期間作為補充驗收。

| 層級 | 指令 | 依賴 | 阻斷 PR |
|---|---|---|---|
| 單元測試／版本一致性 | `node --test tests/*.test.js` 與 `bash tests/check-version-consistency.sh` | Node.js 22+；無需 root、無需網路 | 是 |
| 預檢（mock） | `bash tests/preflight.test.sh` | bash；無需 root、無需網路 | 是 |
| 產物驗證 | `bash tests/verify-artifact.sh <iso> <version>` | `xorriso`、`unsquashfs`、`md5sum`、`sha256sum` | 否（在 build job 內阻斷建置） |
| VM 開機煙霧測試 | `bash tests/vm-smoke.sh <iso> [逾時秒數]` | `qemu-system-x86_64`、OVMF | 否（僅供參考） |

一次執行本機關卡檢查：

```bash
node --test tests/*.test.js
bash tests/check-version-consistency.sh
bash tests/preflight.test.sh
```

詳情與安全注意事項請見 [tests/README.md](tests/README.md)。

## 持續整合

| 工作流程 | 觸發條件 | 用途 |
|---|---|---|
| `pr-check.yml` | 每次 Pull Request | 語法檢查、單元測試、版本一致性、shellcheck、actionlint、gitleaks、非 root 預檢 |
| `dco.yml` | push 與 PR | 強制 `Signed-off-by` 簽署（開發者來源認證 DCO） |
| `build-iso.yml` | `v*` 標籤或手動觸發 | 解析版本 → 透過 `.github/actions/build-iso` 建置 → 驗證 → 分割 → 發佈（草稿／正式／不發佈） |
| `vm-smoke.yml` | `v*` 標籤或手動觸發 | 參考性 QEMU + OVMF 開機檢查（`continue-on-error`） |
| `auto-label.yml` | PR 活動 | 自動新增標籤 |

## 參與貢獻

1. Fork 本儲存庫，從 `main` 建立分支。
2. 進行變更，並保持版本在 `build.sh` 與 `edit-os-release/os-release` 兩處一致。建置工作流程會從 `os-release` 自動讀取版本，不再維護第三份拷貝。
3. 執行上述本機檢查。
4. 提交時附上 DCO 簽署：

   ```bash
   git commit -s -m "feat: describe your change"
   ```

   簽署郵件必須與提交作者／提交者郵件一致，且不得使用 GitHub 的 `noreply` 位址。
5. 發起 Pull Request。選擇[英文](.github/PULL_REQUEST_TEMPLATE/english.md)或[中文](.github/PULL_REQUEST_TEMPLATE/chinese.md)範本，並確保所有必要檢查皆通過。

歡迎透過 `.github/ISSUE_TEMPLATE/` 中的範本提交 Bug 回報與功能建議。

## 授權與致謝

本專案採用 **GNU Affero General Public License v3.0 only** 授權 —— 詳見 [LICENSE](LICENSE)。

由 **ZIT 小圳工作室** 建立。

- 作者／維護者：Oliver Lin <oliver@liuxiaozhen.dev>
- 貢獻者：請見 [CONTRIBUTORS](CONTRIBUTORS)
- 首頁：https://zitzhen.cn/
