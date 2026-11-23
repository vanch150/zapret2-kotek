@echo off
chcp 65001 > nul
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
for %%I in ("%~dp0..") do set "Z2_ROOT=%%~fI"
set "Z2_BASE=%Z2_ROOT%"
if not "%Z2_BASE:~-1%"=="\" set "Z2_BASE=%Z2_BASE%\"
set "Z2_ROOT_ARG=%Z2_ROOT%"
if "%Z2_ROOT_ARG:~-1%"=="\" set "Z2_ROOT_ARG=%Z2_ROOT_ARG%\"
set "LOCAL_VERSION=1.1.1"
if exist "%Z2_BASE%utils\version.txt" set /p LOCAL_VERSION=<"%Z2_BASE%utils\version.txt"

:: =====================================================================
:: External helpers called by standalone strategies\*.bat & configs_archive\*.bat
:: =====================================================================
if "%~1"=="status_zapret" (
    call :tcp_enable
    if exist "%Z2_BASE%utils\tgws_helper.ps1" (
        "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\tgws_helper.ps1" ensure-service-silent >nul 2>&1
    )
    exit /b
)
if "%~1"=="check_updates" exit /b
if "%~1"=="load_game_filter" (
    call :load_game_filter
    exit /b
)
if "%~1"=="load_user_lists" (
    call :load_user_lists
    exit /b
)
if "%~1"=="load_autohost" exit /b
if "%~1"=="load_nlm_filter" exit /b

:: =====================================================================
:: Main Entrypoint: UAC Elevation -> WPF GUI (or --cli menu)
:: =====================================================================
cd /d "%Z2_ROOT%"
if /i "%~1"=="--cli" set "Z2_FORCE_CLI=1"
if /i "%~2"=="--cli" set "Z2_FORCE_CLI=1"
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if %errorlevel%==0 goto :init_admin
if /i "%~1"=="admin" (
    echo [X] Требуются права администратора. Запустите скрипт от имени администратора.
    pause
    exit /b 1
)

echo Requesting administrator rights...
set "Z2_SELF=%~f0"
set "Z2_DIR=%Z2_ROOT%"
if defined Z2_FORCE_CLI (set "Z2_ARG=admin --cli") else (set "Z2_ARG=admin")
"%PS_EXE%" -NoProfile -Command "Start-Process -FilePath ($env:SystemRoot + '\System32\cmd.exe') -ArgumentList ('/d /s /c \"\"' + ($env:Z2_SELF.Replace([string][char]37, '\"^' + [char]37 + '\"')) + '\" ' + $env:Z2_ARG + '\"') -WorkingDirectory $env:Z2_DIR -Verb RunAs"
exit /b

:init_admin
call :load_user_lists
if defined Z2_FORCE_CLI (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\cli_menu.ps1" -Root "%Z2_ROOT_ARG%"
    exit /b
)
if exist "%Z2_BASE%utils\gui_app.ps1" (
    start "" "%PS_EXE%" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%Z2_BASE%utils\gui_app.ps1" -Root "%Z2_ROOT_ARG%"
    exit /b
)
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\cli_menu.ps1" -Root "%Z2_ROOT_ARG%"
exit /b

:: =====================================================================
:: Minimal Helper Subroutines
:: =====================================================================
:tcp_enable
"%PS_EXE%" -NoProfile -Command "$t = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue; if ($null -eq $t -or $t.Timestamps -ne 'Enabled') { & \"$env:SystemRoot\System32\netsh.exe\" interface tcp set global timestamps=enabled | Out-Null }" >nul 2>&1
exit /b

:load_user_lists
if not exist "%Z2_BASE%lists\" mkdir "%Z2_BASE%lists" >nul 2>&1
if not exist "%Z2_BASE%lists\list-general-user.txt" type nul > "%Z2_BASE%lists\list-general-user.txt"
if not exist "%Z2_BASE%lists\list-exclude-user.txt" type nul > "%Z2_BASE%lists\list-exclude-user.txt"
if not exist "%Z2_BASE%lists\ipset-exclude-user.txt" type nul > "%Z2_BASE%lists\ipset-exclude-user.txt"
if not exist "%Z2_BASE%lists\list-auto.txt" type nul > "%Z2_BASE%lists\list-auto.txt"
exit /b

:load_game_filter
set "GameFilter=12"
set "GameFilterTCP=12"
set "GameFilterUDP=12"
set "GF_TCP_VAL="
set "GF_UDP_VAL="
set "GF_FILE=%Z2_BASE%utils\game_filter.enabled"
if not exist "%GF_FILE%" exit /b
set "GF_MODE=disabled"
for /f "usebackq tokens=1,2 delims==" %%A in ("%GF_FILE%") do (
    if /i "%%A"=="mode" set "GF_MODE=%%B"
    if /i "%%A"=="tcp" set "GF_TCP_VAL=%%B"
    if /i "%%A"=="udp" set "GF_UDP_VAL=%%B"
)
if /i "%GF_MODE%"=="all" (
    if defined GF_TCP_VAL (set "GameFilterTCP=%GF_TCP_VAL%") else (set "GameFilterTCP=1024-65535")
    if defined GF_UDP_VAL (set "GameFilterUDP=%GF_UDP_VAL%") else (set "GameFilterUDP=1024-65535")
) else if /i "%GF_MODE%"=="tcp" (
    if defined GF_TCP_VAL (set "GameFilterTCP=%GF_TCP_VAL%") else (set "GameFilterTCP=1024-65535")
) else if /i "%GF_MODE%"=="udp" (
    if defined GF_UDP_VAL (set "GameFilterUDP=%GF_UDP_VAL%") else (set "GameFilterUDP=1024-65535")
)
if /i "%GF_MODE%"=="tcp" (set "GameFilter=%GameFilterTCP%") else if /i "%GF_MODE%"=="all" (set "GameFilter=%GameFilterTCP%") else if /i "%GF_MODE%"=="udp" (set "GameFilter=%GameFilterUDP%")
exit /b
