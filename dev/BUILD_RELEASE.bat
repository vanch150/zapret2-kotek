@echo off
chcp 65001 > nul
title Zapret2 — Сборка чистого релиза для отправки
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "Z2_BUILD_ARGS="
if /i "%~1"=="-PublicRelease" set "Z2_BUILD_ARGS=-PublicRelease"
if /i "%~2"=="-PublicRelease" set "Z2_BUILD_ARGS=-PublicRelease"

fltmc >nul 2>&1
if %errorlevel% neq 0 (
    if /i "%~1"=="admin" (
        echo [X] Требуются права администратора. Запустите скрипт от имени администратора.
        pause
        exit /b 1
    )
    set "Z2_SELF=%~f0"
    set "Z2_DIR=%~dp0"
    if defined Z2_BUILD_ARGS (set "Z2_ELEV_ARG=admin %Z2_BUILD_ARGS%") else (set "Z2_ELEV_ARG=admin")
    "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\" ' + $env:Z2_ELEV_ARG + '\"') -WorkingDirectory $env:Z2_DIR -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1" %Z2_BUILD_ARGS%
if %errorlevel% equ 0 (
    set "Z2_SELF=%~f0"
    "%PS_EXE%" -NoProfile -Command "$d = Split-Path -Parent (Split-Path -Parent $env:Z2_SELF); $p = Split-Path -Parent $d; $z = Get-ChildItem -LiteralPath $p -Filter 'zapret2-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($z) { Start-Process explorer.exe -ArgumentList ('/select,\"' + $z.FullName + '\"') }"
)
echo.
pause
