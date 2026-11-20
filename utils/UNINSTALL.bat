@echo off
chcp 65001 > nul
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI\"
cd /d "%TEMP%"

net session >nul 2>&1
if errorlevel 1 (
    set "Z2_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\"\"') -WorkingDirectory $env:TEMP -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Root "%Z2_ROOT%"
if "%errorlevel%"=="20" exit /b 0
pause
