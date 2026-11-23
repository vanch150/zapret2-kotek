@echo off
chcp 65001 > nul
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI"
set "Z2_ROOT_ARG=%Z2_ROOT%"
if "%Z2_ROOT_ARG:~-1%"=="\" set "Z2_ROOT_ARG=%Z2_ROOT_ARG%\"
set "Z2_VER=1.1.1"
if exist "%~dp0version.txt" set /p Z2_VER=<"%~dp0version.txt"
title Zapret2 Kotek v%Z2_VER% — Deep Optimize (=^^.^^=)
cd /d "%Z2_ROOT%"

"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if %errorlevel% neq 0 (
    if /i "%~1"=="admin" (
        echo [X] Требуются права администратора. Запустите скрипт от имени администратора.
        pause
        exit /b 1
    )
    set "Z2_SELF=%~f0"
    "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath ($env:SystemRoot + '\System32\cmd.exe') -ArgumentList ('/d /s /c \"\"' + ($env:Z2_SELF.Replace([string][char]37, '\"^' + [char]37 + '\"')) + '\" admin\"') -WorkingDirectory $env:Z2_ROOT -Verb RunAs"
    exit /b
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0deep_optimize.ps1" -Root "%Z2_ROOT_ARG%"
echo.
echo   Нажми любую клавишу для выхода...
pause >nul
