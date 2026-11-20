param(
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$tgSvc = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue

Clear-Host
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '                ПАУЗА / ВОЗОБНОВЛЕНИЕ ZAPRET2                       ' -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan

if (-not $svc) {
    Write-Host '  [!] Служба zapret не установлена. Сначала запустите !_START_KOTEK.bat.' -ForegroundColor Yellow
    exit 1
}

if ($svc.Status -eq 'Running') {
    Write-Host '  [*] Приостановка служб Zapret2...' -ForegroundColor Yellow
    Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList 'stop WinDivert' -WindowStyle Hidden -Wait | Out-Null
    if ($tgSvc -and $tgSvc.Status -eq 'Running') {
        Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    Write-Host ''
    Write-Host '  [ПАУЗА] Обход временно отключён.' -ForegroundColor Yellow
    Write-Host '  Банки, игры с жёсткими античитами и сайты работают напрямую.' -ForegroundColor Gray
    Write-Host '  Запустите PAUSE_RESUME.bat ещё раз, чтобы снова включить обход.' -ForegroundColor Cyan
} else {
    Write-Host '  [*] Возобновление служб Zapret2...' -ForegroundColor Cyan
    Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($tgSvc) {
        Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 700
    $svcNow = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($svcNow -and $svcNow.Status -eq 'Running') {
        Write-Host ''
        Write-Host '  [АКТИВНО] Служба zapret снова запущена и работает!' -ForegroundColor Green
        if ($tgSvc) {
            $tgNow = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
            Write-Host ("  Telegram WS Proxy: {0}" -f $(if ($tgNow) { $tgNow.Status } else { 'нет' })) -ForegroundColor Gray
        }
    } else {
        Write-Host '  [X] Не удалось запустить службу zapret. Запустите !_START_KOTEK.bat или диагностику.' -ForegroundColor Red
    }
}
Write-Host ''
