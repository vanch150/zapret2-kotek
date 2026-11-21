@echo off
chcp 65001 > nul
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI"
cd /d "%Z2_ROOT%"

"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if %errorlevel% neq 0 (
    if /i "%~1"=="admin" (
        echo [X] Требуются права администратора. Запустите скрипт от имени администратора.
        pause
        exit /b 1
    )
    set "Z2_SELF=%~f0"
    "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\" admin\"') -WorkingDirectory $env:Z2_ROOT -Verb RunAs"
    exit /b
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0pause_resume.ps1" -Root "%Z2_ROOT%"
pause
