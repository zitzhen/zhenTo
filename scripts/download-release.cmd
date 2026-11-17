@echo off
rem Copyright (C) 2026 ZIT STUDIO
rem Author: Oliver Lin <oliver@liuxiaozhen.dev>
rem SPDX-License-Identifier: AGPL-3.0-only
rem
rem Download all assets from a GitHub release (including drafts) with the gh CLI.
rem
rem Usage:
rem   download-release.cmd <tag>
rem   download-release.cmd <tag> <owner/name>
rem   download-release.cmd <tag> <owner/name> <output dir>
rem
rem Notes:
rem   - Only the tag is required; the repository defaults to the current git remote.
rem   - Default output dir is .\[repo name]-[tag] (leading lowercase v is stripped).
rem   - Requires an authenticated gh CLI (gh auth login); downloading drafts needs write access to the repo.
rem
rem Note: the delims arguments of the two for /f loops below contain a real TAB character; do not replace it with a space.

rem Parse this file as UTF-8 so output is displayed correctly
chcp 65001 >nul

setlocal EnableDelayedExpansion

set "TAG=%~1"
set "REPO=%~2"
set "OUTDIR=%~3"

if "%TAG%"=="" goto :usage

where gh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] gh CLI not found. Install GitHub CLI and run gh auth login first. 1>&2
    exit /b 1
)

rem 1. Authenticate (draft releases are only visible to authorized accounts)
for /f "delims=" %%t in ('gh auth token 2^>nul') do set "TOKEN=%%t"
if not defined TOKEN (
    echo [ERROR] GitHub authentication failed. Run gh auth login first. 1>&2
    exit /b 1
)

rem 2. Repository
if not defined REPO for /f "delims=" %%r in ('gh repo view --json nameWithOwner -q .nameWithOwner 2^>nul') do set "REPO=%%r"
if not defined REPO (
    echo [ERROR] Cannot detect the current repository. Pass it explicitly, e.g. download-release.cmd %TAG% owner/name 1>&2
    exit /b 1
)

set "RELFILE=%TEMP%\ghdl_rel_%RANDOM%%RANDOM%.tsv"
set "ASSETFILE=%TEMP%\ghdl_assets_%RANDOM%%RANDOM%.tsv"

rem 3. Locate the release
rem    /releases/tags/tag returns 404 for drafts, so scan all pages and match by tag;
rem    when multiple releases match, prefer the draft one.
set "DL_TAG=%TAG%"
set "RELEASE_JQ=[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv"

gh api "repos/%REPO%/releases?per_page=100" --paginate --jq "%RELEASE_JQ%" > "%RELFILE%" 2>nul
if errorlevel 1 (
    echo [ERROR] Failed to list releases (repo %REPO%). 1>&2
    if exist "%RELFILE%" del /f /q "%RELFILE%" >nul 2>&1
    exit /b 1
)

set "FIRST_ID="
set "DRAFT_ID="
for /f "usebackq tokens=1,2" %%a in ("%RELFILE%") do (
    if not "%%a"=="" (
        if not defined FIRST_ID set "FIRST_ID=%%a"
        if "%%b"=="true" if not defined DRAFT_ID set "DRAFT_ID=%%a"
    )
)

set "RELEASE_ID=%FIRST_ID%"
set "IS_DRAFT=false"
if defined DRAFT_ID (
    set "RELEASE_ID=%DRAFT_ID%"
    set "IS_DRAFT=true"
)
if not defined RELEASE_ID (
    echo [ERROR] No release found with tag %TAG% (drafts included). 1>&2
    if exist "%RELFILE%" del /f /q "%RELFILE%" >nul 2>&1
    exit /b 1
)

rem 4. Output directory
for /f "tokens=2 delims=/" %%n in ("%REPO%") do set "REPO_NAME=%%n"
set "TAG_DIR=%TAG%"
if /i "%TAG_DIR:~0,1%"=="v" set "TAG_DIR=%TAG_DIR:~1%"
set "TAG_DIR=%TAG_DIR:/=-%"
if not defined OUTDIR set "OUTDIR=.\%REPO_NAME%-%TAG_DIR%"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem 5. Asset list
gh api "repos/%REPO%/releases/%RELEASE_ID%/assets?per_page=100" --paginate --jq ".[] | [.id, .name, .size] | @tsv" > "%ASSETFILE%" 2>nul
if errorlevel 1 (
    echo [ERROR] Failed to list release assets (release id: %RELEASE_ID%). 1>&2
    if exist "%ASSETFILE%" del /f /q "%ASSETFILE%" >nul 2>&1
    exit /b 1
)

set /a TOTAL=0
for /f "usebackq tokens=1,2,3 delims=	" %%a in ("%ASSETFILE%") do set /a TOTAL+=1
if %TOTAL%==0 (
    echo [ERROR] Release %TAG% has no downloadable assets. 1>&2
    del /f /q "%RELFILE%" "%ASSETFILE%" >nul 2>&1
    exit /b 1
)

if "%IS_DRAFT%"=="true" (set "KIND=draft") else (set "KIND=published")
echo Repo: %REPO%
echo Release: %TAG% (%KIND%, id: %RELEASE_ID%), %TOTAL% assets
echo Output dir: %OUTDIR%
echo.

rem 6. Download each asset and verify its size
set /a INDEX=0
set /a SUCCESS=0
for /f "usebackq tokens=1,2,3 delims=	" %%a in ("%ASSETFILE%") do (
    set /a INDEX+=1
    set "ASSET_ID=%%a"
    set "ASSET_NAME=%%b"
    set "ASSET_SIZE=%%c"
    <nul set /p "=[!INDEX!/%TOTAL%] !ASSET_NAME! (!ASSET_SIZE! bytes) ... "

    gh api "repos/%REPO%/releases/assets/!ASSET_ID!" -H "Accept: application/octet-stream" > "%OUTDIR%\!ASSET_NAME!" 2>nul
    if errorlevel 1 (
        if exist "%OUTDIR%\!ASSET_NAME!" del /f /q "%OUTDIR%\!ASSET_NAME!" >nul 2>&1
        echo Failed
    ) else (
        set "ACTUAL=0"
        for %%F in ("%OUTDIR%\!ASSET_NAME!") do set "ACTUAL=%%~zF"
        if "!ACTUAL!"=="!ASSET_SIZE!" (
            set /a SUCCESS+=1
            echo OK
        ) else (
            if exist "%OUTDIR%\!ASSET_NAME!" del /f /q "%OUTDIR%\!ASSET_NAME!" >nul 2>&1
            echo Failed: file size mismatch ^(expected !ASSET_SIZE!, actual !ACTUAL!^)
        )
    )
)

echo.
echo Done: %SUCCESS%/%TOTAL% -^> %OUTDIR%
del /f /q "%RELFILE%" "%ASSETFILE%" >nul 2>&1
if not "%SUCCESS%"=="%TOTAL%" exit /b 1
exit /b 0

:usage
echo Usage: download-release.cmd ^<tag^> [owner/name] [output dir]
echo.
echo   tag         Required, release git tag, e.g. v0.1.1
echo   owner/name  Optional, full repository name; defaults to the current GitHub repo
echo   output dir  Optional, defaults to .\[repo name]-[tag]
echo.
echo Examples:
echo   download-release.cmd v0.1.1
echo   download-release.cmd v0.1.1 zitzhen/zhenTo .\zhenTo-0.1.1
exit /b 1
