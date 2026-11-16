@echo off
rem 用 gh CLI 下载 GitHub 发行版（Release）中的全部附件，支持草稿（draft）发行版。
rem
rem 用法:
rem   download-release.cmd <tag>
rem   download-release.cmd <tag> <owner/name>
rem   download-release.cmd <tag> <owner/name> <输出目录>
rem
rem 说明:
rem   - 只需提供 tag 编号；仓库默认取当前目录对应的 GitHub 仓库。
rem   - 默认输出目录为 .\<仓库名>-<tag>（去掉 tag 开头的小写 v）。
rem   - 依赖已登录的 gh CLI（gh auth login）；下载草稿需要该仓库的写权限。
rem
rem 注意: 下面两个 for /f 的 delims 参数里是一个真实的 TAB 字符，请勿改成空格。

rem 以 UTF-8 解析本文件，保证中文输出正常
chcp 65001 >nul

setlocal EnableDelayedExpansion

set "TAG=%~1"
set "REPO=%~2"
set "OUTDIR=%~3"

if "%TAG%"=="" goto :usage

where gh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未找到 gh CLI，请先安装 GitHub CLI 并执行 gh auth login。 1>&2
    exit /b 1
)

rem 1. 认证（草稿发行版只能由有权限的账号看到）
for /f "delims=" %%t in ('gh auth token 2^>nul') do set "TOKEN=%%t"
if not defined TOKEN (
    echo [ERROR] GitHub 认证失败，请先执行 gh auth login。 1>&2
    exit /b 1
)

rem 2. 仓库
if not defined REPO for /f "delims=" %%r in ('gh repo view --json nameWithOwner -q .nameWithOwner 2^>nul') do set "REPO=%%r"
if not defined REPO (
    echo [ERROR] 无法自动识别当前仓库，请显式传入仓库，例如: download-release.cmd %TAG% owner/name 1>&2
    exit /b 1
)

set "RELFILE=%TEMP%\ghdl_rel_%RANDOM%%RANDOM%.tsv"
set "ASSETFILE=%TEMP%\ghdl_assets_%RANDOM%%RANDOM%.tsv"

rem 3. 定位发行版
rem    /releases/tags/<tag> 对草稿返回 404，因此遍历全部分页后按 tag 匹配，命中多个时草稿优先。
set "DL_TAG=%TAG%"
set "RELEASE_JQ=[.[] | select(.tag_name == env.DL_TAG)] | sort_by(.draft) | reverse | .[0] | [.id, .draft] | @tsv"

gh api "repos/%REPO%/releases?per_page=100" --paginate --jq "%RELEASE_JQ%" > "%RELFILE%" 2>nul
if errorlevel 1 (
    echo [ERROR] 获取发行版列表失败（仓库 %REPO%）。 1>&2
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
    echo [ERROR] 未找到 tag 为 %TAG% 的发行版（已包含草稿）。 1>&2
    if exist "%RELFILE%" del /f /q "%RELFILE%" >nul 2>&1
    exit /b 1
)

rem 4. 输出目录
for /f "tokens=2 delims=/" %%n in ("%REPO%") do set "REPO_NAME=%%n"
set "TAG_DIR=%TAG%"
if /i "%TAG_DIR:~0,1%"=="v" set "TAG_DIR=%TAG_DIR:~1%"
set "TAG_DIR=%TAG_DIR:/=-%"
if not defined OUTDIR set "OUTDIR=.\%REPO_NAME%-%TAG_DIR%"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem 5. 附件列表
gh api "repos/%REPO%/releases/%RELEASE_ID%/assets?per_page=100" --paginate --jq ".[] | [.id, .name, .size] | @tsv" > "%ASSETFILE%" 2>nul
if errorlevel 1 (
    echo [ERROR] 获取发行版附件列表失败（release id: %RELEASE_ID%）。 1>&2
    if exist "%ASSETFILE%" del /f /q "%ASSETFILE%" >nul 2>&1
    exit /b 1
)

set /a TOTAL=0
for /f "usebackq tokens=1,2,3 delims=	" %%a in ("%ASSETFILE%") do set /a TOTAL+=1
if %TOTAL%==0 (
    echo [ERROR] 发行版 %TAG% 没有可下载的附件。 1>&2
    del /f /q "%RELFILE%" "%ASSETFILE%" >nul 2>&1
    exit /b 1
)

if "%IS_DRAFT%"=="true" (set "KIND=草稿") else (set "KIND=已发布")
echo 仓库: %REPO%
echo 发行版: %TAG%（%KIND%，id: %RELEASE_ID%），附件 %TOTAL% 个
echo 输出目录: %OUTDIR%
echo.

rem 6. 逐个下载并校验大小
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
        echo 失败
    ) else (
        set "ACTUAL=0"
        for %%F in ("%OUTDIR%\!ASSET_NAME!") do set "ACTUAL=%%~zF"
        if "!ACTUAL!"=="!ASSET_SIZE!" (
            set /a SUCCESS+=1
            echo OK
        ) else (
            if exist "%OUTDIR%\!ASSET_NAME!" del /f /q "%OUTDIR%\!ASSET_NAME!" >nul 2>&1
            echo 失败: 文件大小不一致 ^(期望 !ASSET_SIZE!，实际 !ACTUAL!^)
        )
    )
)

echo.
echo 下载完成: %SUCCESS%/%TOTAL% -^> %OUTDIR%
del /f /q "%RELFILE%" "%ASSETFILE%" >nul 2>&1
if not "%SUCCESS%"=="%TOTAL%" exit /b 1
exit /b 0

:usage
echo 用法: download-release.cmd ^<tag^> [owner/name] [输出目录]
echo.
echo   tag        必填，发行版的 git tag 编号，例如 v0.1.1
echo   owner/name 可选，仓库全名；默认取当前目录对应的 GitHub 仓库
echo   输出目录     可选，默认 .\<仓库名^-^<tag^>
echo.
echo 示例:
echo   download-release.cmd v0.1.1
echo   download-release.cmd v0.1.1 zitzhen/zhenTo .\zhenTo-0.1.1
exit /b 1
