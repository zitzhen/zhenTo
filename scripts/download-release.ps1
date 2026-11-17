<#
.SYNOPSIS
    Download all assets from a GitHub release (including drafts) with the gh CLI.

.DESCRIPTION
    Usage:
        .\download-release.ps1 <tag>
        .\download-release.ps1 <tag> <owner/name>
        .\download-release.ps1 <tag> <owner/name> <output dir>

    Notes:
        - Only the tag is required; the repository defaults to the current git remote.
        - Default output dir is .\<repo name>-<tag> (leading lowercase v is stripped).
        - Compatible with Windows PowerShell 5.1 and PowerShell 7+.
        - Requires an authenticated gh CLI (gh auth login); downloading drafts needs write access to the repo.

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
    Stop-WithError "Please provide a release tag, e.g. .\download-release.ps1 v0.1.1"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Stop-WithError "gh CLI not found. Install GitHub CLI and run gh auth login first."
}

# 1. Authenticate (draft releases are only visible to authorized accounts)
$token = $null
try { $token = gh auth token 2>$null } catch { $token = $null }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    Stop-WithError "GitHub authentication failed. Run gh auth login first."
}
$token = $token.Trim()

# 2. Repository
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = $null
    try { $Repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>$null } catch { $Repo = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Repo)) {
        Stop-WithError "Cannot detect the current repository. Pass it explicitly, e.g. .\download-release.ps1 $Tag owner/name"
    }
    $Repo = $Repo.Trim()
}

# 3. Locate the release
#    /releases/tags/<tag> returns 404 for drafts, so scan all pages and match by tag;
#    when multiple releases match, prefer the draft one.
$env:DL_TAG = $Tag
$releaseJq = '[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv'
$releaseLines = @(gh api "repos/$Repo/releases?per_page=100" --paginate --jq $releaseJq)
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "Failed to list releases (repo $Repo)."
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
    Stop-WithError "No release found with tag $Tag (drafts included)."
}

# 4. Output directory
$repoName = ($Repo -split '/')[-1]
$tagDir = ($Tag -replace '^v', '') -replace '[\\/:*?"<>|]', '-'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Get-Location).Path "$repoName-$tagDir"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# 5. Asset list
$assets = @()
$assetLines = @(gh api "repos/$Repo/releases/$releaseId/assets?per_page=100" --paginate --jq '.[] | [.id, .name, .size] | @tsv')
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "Failed to list release assets (release id: $releaseId)."
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
    Stop-WithError "Release $Tag has no downloadable assets."
}

$kind = if ($isDraft) { 'draft' } else { 'published' }
Write-Host "Repo: $Repo"
Write-Host "Release: $Tag ($kind, id: $releaseId), $($assets.Count) assets"
Write-Host "Output dir: $OutDir"
Write-Host ""

# 6. Download each asset and verify its size
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
            throw "File size mismatch (expected $($asset.Size), actual $actual)"
        }

        $success++
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done: $success/$($assets.Count) -> $OutDir" -ForegroundColor Green
if ($success -ne $assets.Count) {
    exit 1
}
