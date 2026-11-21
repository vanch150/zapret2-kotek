param(
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
$Root = if (Get-Command Resolve-Z2Root -ErrorAction SilentlyContinue) {
    Resolve-Z2Root $Root
} else {
    if (-not $Root) { $Root = $env:Z2_ROOT }
    if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
    $Root.Trim('"', "'", '\', '/') + '\'
}

Clear-Host
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '                ПАУЗА / ВОЗОБНОВЛЕНИЕ ZAPRET2                       ' -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan

if (-not (Test-Z2IsAdmin)) {
    Write-Host '  [X] Требуются права администратора. Запустите PAUSE_RESUME.bat от имени администратора.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

$svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$tgSvc = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
$pauseStateFile = Join-Path $env:TEMP 'zapret2_kotek_pause_tgws.flag'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $svc) {
    Write-Host '  [!] Служба zapret не установлена. Сначала запустите !_START_KOTEK.bat.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if ($svc.Status -eq 'Running') {
    Write-Host '  [*] Приостановка служб Zapret2...' -ForegroundColor Yellow

    # Remember whether zapret-tgws was running before pause
    $tgWasRunning = ($null -ne $tgSvc -and $tgSvc.Status -eq 'Running')
    try {
        [System.IO.File]::WriteAllText($pauseStateFile, $(if ($tgWasRunning) { '1' } else { '0' }), $utf8NoBom)
    } catch {}
    if ($tgWasRunning) {
        try {
            Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
            $tgSvc.Refresh()
            if ($tgSvc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                $tgSvc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(5))
            }
        } catch {}
    }

    # 1) Stop zapret service and winws2/winws processes cleanly before unloading drivers
    Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

    # 2) Unload WinDivert and WinDivert14 drivers
    $scExe = "$env:SystemRoot\System32\sc.exe"
    foreach ($drv in @('WinDivert', 'WinDivert14')) {
        Start-Process -FilePath $scExe -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
    }

    # 3) Verify drivers are actually stopped before reporting [ПАУЗА]
    $stillLoaded = @()
    for ($i = 0; $i -lt 10; $i++) {
        $stillLoaded = @()
        foreach ($drv in @('WinDivert', 'WinDivert14')) {
            $q = (& $scExe query $drv 2>$null | Out-String)
            if ($q -match ':\s*\d+\s+(RUNNING|STOP_PENDING|START_PENDING)') {
                $stillLoaded += $drv
            }
        }
        if ($stillLoaded.Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }

    Write-Host ''
    if ($stillLoaded.Count -eq 0) {
        Write-Host '  [ПАУЗА] Обход временно отключён (драйвер WinDivert выгружен).' -ForegroundColor Yellow
        Write-Host '  Банки, игры с жёсткими античитами и сайты работают напрямую.' -ForegroundColor Gray
    } else {
        Write-Host ("  [!] Служба zapret остановлена, но драйвер не выгружен: {0}" -f ($stillLoaded -join ', ')) -ForegroundColor Red
        Write-Host '  Возможно, другой процесс всё ещё удерживает WinDivert.' -ForegroundColor Gray
        exit 1
    }
    Write-Host '  Запустите PAUSE_RESUME.bat ещё раз, чтобы снова включить обход.' -ForegroundColor Cyan
} else {
    Write-Host '  [*] Возобновление служб Zapret2...' -ForegroundColor Cyan
    Start-Service -Name 'zapret' -ErrorAction SilentlyContinue

    $shouldStartTg = $false
    if (Test-Path -LiteralPath $pauseStateFile) {
        try {
            $flag = ([System.IO.File]::ReadAllText($pauseStateFile, [System.Text.Encoding]::UTF8)).Trim()
            if ($flag -eq '1') { $shouldStartTg = $true }
        } catch {}
        Remove-Item -LiteralPath $pauseStateFile -Force -ErrorAction SilentlyContinue
    }
    if ($shouldStartTg -and $null -ne $tgSvc) {
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
        exit 1
    }
}
Write-Host ''
