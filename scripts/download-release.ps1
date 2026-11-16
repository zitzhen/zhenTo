<#
.SYNOPSIS
    用 gh CLI 下载 GitHub 发行版（Release）中的全部附件，支持草稿（draft）发行版。

.DESCRIPTION
    用法:
        .\download-release.ps1 <tag>
        .\download-release.ps1 <tag> <owner/name>
        .\download-release.ps1 <tag> <owner/name> <输出目录>

    说明:
        - 只需提供 tag 编号；仓库默认取当前目录对应的 GitHub 仓库。
        - 默认输出目录为 .\<仓库名>-<tag>（去掉 tag 开头的小写 v）。
        - 兼容 Windows PowerShell 5.1 与 PowerShell 7+。
        - 依赖已登录的 gh CLI（gh auth login）；下载草稿需要该仓库的写权限。

.EXAMPLE
    .\download-release.ps1 v0.1.1

.EXAMPLE
    .\download-release.ps1 v0.1.1 zitzhen/zhenTo D:\out
#>
param(
    [Parameter(Position = 0)][string]$Tag,
    [Parameter(Position = 1)][string]$Repo,
    [Parameter(Position = 2)][string]$OutDir
)

$ErrorActionPreference = "Stop"

function Stop-WithError([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    Stop-WithError "请提供发行版 tag，例如: .\download-release.ps1 v0.1.1"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Stop-WithError "未找到 gh CLI，请先安装 GitHub CLI 并执行 gh auth login。"
}

# 1. 认证（草稿发行版只能由有权限的账号看到）
$token = $null
try { $token = gh auth token 2>$null } catch { $token = $null }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    Stop-WithError "GitHub 认证失败，请先执行 gh auth login。"
}
$token = $token.Trim()

# 2. 仓库
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = $null
    try { $Repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>$null } catch { $Repo = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Repo)) {
        Stop-WithError "无法自动识别当前仓库，请显式传入仓库，例如: .\download-release.ps1 $Tag owner/name"
    }
    $Repo = $Repo.Trim()
}

# 3. 定位发行版
#    /releases/tags/<tag> 对草稿返回 404，因此遍历全部分页后按 tag 匹配，命中多个时草稿优先。
$env:DL_TAG = $Tag
$releaseJq = '[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv'
$releaseLines = @(gh api "repos/$Repo/releases?per_page=100" --paginate --jq $releaseJq)
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "获取发行版列表失败（仓库 $Repo）。"
}

$firstId = $null
$draftId = $null
foreach ($line in $releaseLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = $line -split "`t"
    if ([string]::IsNullOrWhiteSpace($fields[0])) { continue }
    if (-not $firstId) { $firstId = $fields[0].Trim() }
    if ($fields.Count -gt 1 -and $fields[1].Trim() -eq 'true' -and -not $draftId) {
        $draftId = $fields[0].Trim()
    }
}

$releaseId = $firstId
$isDraft = $false
if ($draftId) { $releaseId = $draftId; $isDraft = $true }
if (-not $releaseId) {
    Stop-WithError "未找到 tag 为 $Tag 的发行版（已包含草稿）。"
}

# 4. 输出目录
$repoName = ($Repo -split '/')[-1]
$tagDir = ($Tag -replace '^v', '') -replace '[\\/:*?"<>|]', '-'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Get-Location).Path "$repoName-$tagDir"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# 5. 附件列表
$assets = @()
$assetLines = @(gh api "repos/$Repo/releases/$releaseId/assets?per_page=100" --paginate --jq '.[] | [.id, .name, .size] | @tsv')
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "获取发行版附件列表失败（release id: $releaseId）。"
}
foreach ($line in $assetLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = $line -split "`t"
    if ($fields.Count -lt 3) { continue }
    $assets += [pscustomobject]@{
        Id   = $fields[0].Trim()
        Name = $fields[1]
        Size = [long]$fields[2].Trim()
    }
}
if ($assets.Count -eq 0) {
    Stop-WithError "发行版 $Tag 没有可下载的附件。"
}

$kind = if ($isDraft) { '草稿' } else { '已发布' }
Write-Host "仓库: $Repo"
Write-Host "发行版: $Tag（$kind，id: $releaseId），附件 $($assets.Count) 个"
Write-Host "输出目录: $OutDir"
Write-Host ""

# 6. 逐个下载并校验大小
$downloadHeaders = @{
    Authorization = "Bearer $token"
    Accept        = "application/octet-stream"
}

$success = 0
$index = 0
foreach ($asset in $assets) {
    $index++
    $path = Join-Path $OutDir $asset.Name
    Write-Host "[$index/$($assets.Count)] $($asset.Name) ($($asset.Size) bytes) ... " -NoNewline -ForegroundColor Cyan
    try {
        Invoke-WebRequest `
            -Uri "https://api.github.com/repos/$Repo/releases/assets/$($asset.Id)" `
            -Headers $downloadHeaders `
            -OutFile $path `
            -UseBasicParsing

        $actual = (Get-Item -LiteralPath $path).Length
        if ($asset.Size -gt 0 -and $actual -ne $asset.Size) {
            throw "文件大小不一致（期望 $($asset.Size)，实际 $actual）"
        }

        $success++
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "下载完成: $success/$($assets.Count) -> $OutDir" -ForegroundColor Green
if ($success -ne $assets.Count) {
    exit 1
}
