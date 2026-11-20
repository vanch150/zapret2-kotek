@echo off
chcp 65001 > nul
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI\"
cd /d "%Z2_ROOT%"

net session >nul 2>&1
if errorlevel 1 (
    set "Z2_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\"\"') -WorkingDirectory $env:Z2_ROOT -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pause_resume.ps1" -Root "%Z2_ROOT%"
pause
