param(
    [string]$Root = '',
    [Parameter(Mandatory=$true)][string]$BatPath
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

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

$env:GameFilterTCP = $gfTcp; $env:GameFilterUDP = $gfUdp
$env:GameFilter = if ($gfTcp -ne '12') { $gfTcp } else { $gfUdp }
$env:Z2_ROOT = $Root; $env:Z2_BAT = $BatPath; $env:Z2_CONF = Join-Path $Root 'bin\service.conf'
$env:Z2_AUTOHOST = if (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')) { '1' } else { '0' }
$env:BIN = Join-Path $Root 'bin\'; $env:LISTS = Join-Path $Root 'lists\'; $env:LUA = Join-Path $Root 'lua\'
$env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
$env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'

$existingSvc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
if ($null -ne $existingSvc) {
    Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
}
Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 250

$global:LASTEXITCODE = 0
try {
    & (Join-Path $Root 'utils\build_service_conf.ps1')
} catch {
    Write-Host "[X] Ошибка сборки конфига для $batName"
    exit 1
}
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Root 'bin\service.conf'))) {
    Write-Host "[X] Ошибка сборки service.conf для $batName (код $LASTEXITCODE)"
    exit 1
}

Write-Host "Запуск службы zapret ($batName)..."
$winwsExe   = Join-Path $Root 'bin\winws2.exe'
$confWin    = Join-Path $Root 'bin\service.conf'
$binEscaped = "\`"$winwsExe\`" @\`"$confWin\`""

if ($null -ne $existingSvc) {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret binPath= `"$binEscaped`" start= auto" -WindowStyle Hidden -Wait | Out-Null
} else {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEscaped`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait | Out-Null
}
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description zapret `"Zapret2 Kotek DPI bypass software (winws2)`"" -WindowStyle Hidden -Wait | Out-Null
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure zapret reset= 60 actions= restart/2000/restart/5000/restart/10000" -WindowStyle Hidden -Wait | Out-Null
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start zapret" -WindowStyle Hidden -Wait | Out-Null
& reg.exe add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d $stratShort /f >$null 2>&1
for ($w = 0; $w -lt 10; $w++) {
    $scNow = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $scNow -and $scNow.Status -eq 'Running') { break }
    Start-Sleep -Milliseconds 300
}

$svcCheck = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
if ($null -ne $svcCheck -and $svcCheck.Status -eq 'Running') {
    Write-Host "[OK] Установлена стратегия: $batName"
    exit 0
} else {
    Write-Host "[X] Служба zapret не запустилась со стратегией $batName"
    exit 1
}
