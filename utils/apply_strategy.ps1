param(
    [string]$Root = '',
    [Parameter(Mandatory=$true)][string]$BatPath
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
$Root = if (Get-Command Resolve-Z2Root -ErrorAction SilentlyContinue) {
    Resolve-Z2Root $Root
} else {
    if (-not $Root) { $Root = $env:Z2_ROOT }
    if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
    $Root.Trim('"', "'", '\', '/') + '\'
}

if (-not (Test-Path -LiteralPath $BatPath)) {
    Write-Host "[X] Стратегия не найдена: $BatPath"
    exit 1
}

$batName    = [System.IO.Path]::GetFileName($BatPath)
$stratShort = [System.IO.Path]::GetFileNameWithoutExtension($BatPath)
Write-Host "Сборка конфигурации для $batName..."

$gfFile = Join-Path $Root 'utils\game_filter.enabled'
$gfTcp = '12'; $gfUdp = '12'; $gfMode = 'disabled'; $tcpR = '1024-65535'; $udpR = '1024-65535'
if (Test-Path -LiteralPath $gfFile) {
    foreach ($gl in (Get-Content -LiteralPath $gfFile)) {
        if ($gl -match '^(?i)mode=(.+)$') { $gfMode = $matches[1].Trim() }
        elseif ($gl -match '^(?i)tcp=(.+)$') { $tcpR = $matches[1].Trim() }
        elseif ($gl -match '^(?i)udp=(.+)$') { $udpR = $matches[1].Trim() }
    }
    if ($gfMode -ieq 'all') { $gfTcp = $tcpR; $gfUdp = $udpR }
    elseif ($gfMode -ieq 'tcp') { $gfTcp = $tcpR }
    elseif ($gfMode -ieq 'udp') { $gfUdp = $udpR }
}

$confWin = Join-Path $Root 'bin\service.conf'
$tmpConf = Join-Path $Root "bin\service.conf.tmp_$PID"
$bakConf = Join-Path $Root "bin\service.conf.bak_$PID"

$env:GameFilterTCP = $gfTcp; $env:GameFilterUDP = $gfUdp
$env:GameFilter = if ($gfTcp -ne '12') { $gfTcp } else { $gfUdp }
$env:Z2_ROOT = $Root; $env:Z2_BAT = $BatPath; $env:Z2_CONF = $tmpConf
$env:Z2_AUTOHOST = if (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')) { '1' } else { '0' }
$env:BIN = Join-Path $Root 'bin\'; $env:LISTS = Join-Path $Root 'lists\'; $env:LUA = Join-Path $Root 'lua\'
$env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
$env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'

$existingSvc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$svcExists   = ($null -ne $existingSvc)
$wasRunning  = ($svcExists -and $existingSvc.Status -eq 'Running')
if ($null -ne $existingSvc) { try { $existingSvc.Dispose() } catch {} }

$installedNewService = $false
$serviceStopped = $false
$hadOldConf = $false
$exitCode = 1

try {
    $global:LASTEXITCODE = 0
    try {
        & (Join-Path $Root 'utils\build_service_conf.ps1')
    } catch {
        Write-Host "[X] Ошибка сборки конфига для $batName"
        exit 1
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpConf)) {
        Write-Host "[X] Ошибка сборки service.conf для $batName (код $LASTEXITCODE)"
        exit 1
    }

    $serviceStopped = $true
    Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

    $hadOldConf = Test-Path -LiteralPath $confWin
    if ($hadOldConf) {
        Copy-Item -LiteralPath $confWin -Destination $bakConf -Force -ErrorAction Stop
    }
    Move-Item -LiteralPath $tmpConf -Destination $confWin -Force -ErrorAction Stop

    Write-Host "Запуск службы zapret ($batName)..."
    $winwsExe   = Join-Path $Root 'bin\winws2.exe'
    $binEscaped = "\`"$winwsExe\`" @\`"$confWin\`""

    $zDepend = if (Get-Command Get-Z2ZapretDepend -ErrorAction SilentlyContinue) { Get-Z2ZapretDepend } else { 'BFE/nlasvc' }
    if ($svcExists) {
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret binPath= `"$binEscaped`" start= auto depend= $zDepend" -WindowStyle Hidden -Wait | Out-Null
    } else {
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEscaped`" DisplayName= `"zapret`" start= auto depend= $zDepend" -WindowStyle Hidden -Wait | Out-Null
    }
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description zapret `"Zapret2 Kotek DPI bypass software (winws2)`"" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure zapret reset= 60 actions= restart/2000/restart/5000/restart/10000" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failureflag zapret 1" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start zapret" -WindowStyle Hidden -Wait | Out-Null

    $startedOk = $false
    for ($w = 0; $w -lt 10; $w++) {
        $scNow = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $scNow -and $scNow.Status -eq 'Running') {
            $startedOk = $true
            try { $scNow.Dispose() } catch {}
            break
        }
        if ($null -ne $scNow) { try { $scNow.Dispose() } catch {} }
        Start-Sleep -Milliseconds 300
    }

    $installedNewService = $startedOk
    if ($installedNewService) {
        & reg.exe add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d $stratShort /f >$null 2>&1
        Write-Host "[OK] Установлена стратегия: $batName"
        $exitCode = 0
    } else {
        Write-Host "[X] Служба zapret не запустилась со стратегией $batName — откатываю прежнюю конфигурацию..."
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
        if ($hadOldConf -and (Test-Path -LiteralPath $bakConf)) {
            Move-Item -LiteralPath $bakConf -Destination $confWin -Force -ErrorAction SilentlyContinue
        }
        $exitCode = 1
    }
} finally {
    if (Test-Path -LiteralPath $tmpConf) { Remove-Item -LiteralPath $tmpConf -Force -ErrorAction SilentlyContinue }
    if (-not $installedNewService -and $hadOldConf -and (Test-Path -LiteralPath $bakConf)) {
        Move-Item -LiteralPath $bakConf -Destination $confWin -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $bakConf) {
        Remove-Item -LiteralPath $bakConf -Force -ErrorAction SilentlyContinue
    }
    if (-not $installedNewService -and $serviceStopped -and $wasRunning) {
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    }
}
exit $exitCode
