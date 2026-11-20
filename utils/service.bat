@echo off
chcp 65001 > nul
set "Z2_BASE=%~dp0..\"
set "LOCAL_VERSION=1.0.0"
if exist "%Z2_BASE%utils\version.txt" set /p LOCAL_VERSION=<"%Z2_BASE%utils\version.txt"

:: =====================================================================
:: External helpers called by standalone strategies\*.bat & configs_archive\*.bat
:: =====================================================================
if "%~1"=="status_zapret" (
    call :tcp_enable
    set "Z2_ROOT=%Z2_BASE%"
    if exist "%Z2_BASE%utils\tgws_helper.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\tgws_helper.ps1" ensure-service-silent >nul 2>&1
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
cd /d "%Z2_BASE%"
if /i "%~1"=="--cli" set "Z2_FORCE_CLI=1"
if /i "%~2"=="--cli" set "Z2_FORCE_CLI=1"
net session >nul 2>&1
if %errorlevel%==0 goto :init_admin
if "%~1"=="admin" (
    echo [X] Требуются права администратора. Запустите скрипт от имени администратора.
    pause
    exit /b 1
)

echo Requesting administrator rights...
set "Z2_SELF=%~f0"
set "Z2_DIR=%Z2_BASE%"
if defined Z2_FORCE_CLI (set "Z2_ARG=admin --cli") else (set "Z2_ARG=admin")
powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c \"\"' + $env:Z2_SELF + '\" ' + $env:Z2_ARG + '\"') -WorkingDirectory $env:Z2_DIR -Verb RunAs"
exit /b

:init_admin
call :load_user_lists
if defined Z2_FORCE_CLI (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\cli_menu.ps1"
    exit /b
)
if exist "%Z2_BASE%utils\gui_app.ps1" (
    start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%Z2_BASE%utils\gui_app.ps1"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%Z2_BASE%utils\cli_menu.ps1"
exit /b

:: =====================================================================
:: Minimal Helper Subroutines
:: =====================================================================
:tcp_enable
powershell -NoProfile -Command "$o=(netsh interface tcp show global 2>$null|Out-String); if($o -notmatch '(?i)Timestamps\s*:\s*enabled|\u041C\u0435\u0442\u043A\u0438[^\r\n]*:\s*\u0432\u043A\u043B\u044E\u0447'){netsh interface tcp set global timestamps=enabled|Out-Null}" >nul 2>&1
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
if /i "%GF_MODE%"=="tcp" (set "GameFilter=%GameFilterTCP%") else if /i "%GF_MODE%"=="all" (set "GameFilter=%GameFilterUDP%") else if /i "%GF_MODE%"=="udp" (set "GameFilter=%GameFilterUDP%")
exit /b
