@echo off
chcp 65001 > nul
title Zapret2 Kotek — Публикация на GitHub (код + релиз)
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI"
cd /d "%Z2_ROOT%"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_github.ps1" -Root "%Z2_ROOT%"
echo.
pause
