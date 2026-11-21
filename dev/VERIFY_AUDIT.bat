@echo off
chcp 65001 > nul
title Zapret2 Kotek — Проверка аудита (verify_audit)
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_audit.ps1"
echo.
pause
