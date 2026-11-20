@echo off
chcp 65001 > nul
for %%I in ("%~dp0..") do set "ROOT=%%~fI\"
set "Z2_VER=1.0.0"
if exist "%ROOT%utils\version.txt" set /p Z2_VER=<"%ROOT%utils\version.txt"
title Zapret2 Kotek v%Z2_VER% — Deep Optimize (=^^.^^=)
cd /d "%ROOT%"

net session >nul 2>&1
if %errorlevel% neq 0 (
    set "Z2_SELF=%~f0"
    set "Z2_DIR=%ROOT%"
    powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\"\"') -WorkingDirectory $env:Z2_DIR -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deep_optimize.ps1" -Root "%ROOT%"
echo.
echo   Нажми любую клавишу для выхода...
pause >nul
