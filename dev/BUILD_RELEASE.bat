@echo off
chcp 65001 > nul
title Zapret2 — Сборка чистого релиза для отправки

net session >nul 2>&1
if %errorlevel% neq 0 (
    set "Z2_SELF=%~f0"
    set "Z2_DIR=%~dp0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:Z2_SELF -WorkingDirectory $env:Z2_DIR -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1"
if %errorlevel% equ 0 (
    set "Z2_SELF=%~f0"
    powershell -NoProfile -Command "$d = Split-Path -Parent (Split-Path -Parent $env:Z2_SELF); $p = Split-Path -Parent $d; $z = Get-ChildItem -LiteralPath $p -Filter 'zapret2-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($z) { Start-Process explorer.exe -ArgumentList ('/select,"' + $z.FullName + '"') }"
)
echo.
pause
