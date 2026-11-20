param(
    [string]$Action = 'menu',
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
try { $Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\' } catch { $Root = $Root.Trim('"', "'", '\', '/') + '\' }

$NlmFile     = Join-Path $Root 'utils\nlm_filter.enabled'
$NlmAutoFile = Join-Path $Root 'utils\nlm_auto.enabled'
$NamesFile   = Join-Path $Root 'utils\nlm_filter.names'
$WarpFlag = Join-Path $Root 'utils\warp_unblock.enabled'
$WinwsExe = Join-Path $Root 'bin\winws2.exe'

function Get-WarpState {
    if (Test-Path -LiteralPath $WarpFlag) { return 'ВКЛ (UDP 500, 1701, 2408, 4500 активны)' }
    return 'ВЫКЛ'
}

function Get-NlmState {
    if (Test-Path -LiteralPath $NlmFile) {
        $v = ([string](Get-Content -LiteralPath $NlmFile -Raw)).Trim()
        if ($v) { return "активен ($v)" }
    }
    return 'все сети'
}

$VpnRxCommon = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|TAP|TUN|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'

if ($Action -eq 'auto') {
    if (-not (Test-Path -LiteralPath $WinwsExe)) {
        Write-Host '[X] bin\winws2.exe не найден.'
        exit 1
    }
    [IO.File]::WriteAllText($NlmAutoFile, '1', (New-Object System.Text.UTF8Encoding $false))
    $rawOut = & $WinwsExe '--nlm-list=all' 2>$null
    $vpnGuids = New-Object System.Collections.Generic.List[string]
    $vpnNames = New-Object System.Collections.Generic.List[string]
    $curName = ''
    foreach ($line in $rawOut) {
        if ($line -match '^Name\s*:\s*(.+)$') { $curName = $matches[1].Trim() }
        elseif ($line -match '^NetID\s*:\s*(\S+)') {
            if ($curName -and ($curName -match $VpnRxCommon)) {
                $gid = $matches[1].Trim()
                if (-not $vpnGuids.Contains($gid)) { $vpnGuids.Add($gid); $vpnNames.Add($curName) }
            }
            $curName = ''
        }
    }
    if ($vpnGuids.Count -gt 0) {
        $val = 'NEG:' + ($vpnGuids -join ',')
        [IO.File]::WriteAllText($NlmFile, $val, (New-Object System.Text.UTF8Encoding $false))
        [IO.File]::WriteAllText($NamesFile, ($vpnNames -join ', '), (New-Object System.Text.UTF8Encoding $false))
        Write-Host "[OK] NLM-фильтр (инверсия): исключены VPN-адаптеры ($($vpnGuids.Count)); все физ. сети и новые Wi-Fi активны."
        exit 0
    } else {
        if (Test-Path -LiteralPath $NlmFile) { Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $NamesFile) { Remove-Item -LiteralPath $NamesFile -Force -ErrorAction SilentlyContinue }
        Write-Host '[OK] Авто-исключение VPN активно (сейчас активных VPN-адаптеров не найдено; новые VPN будут исключаться автоматически).'
        exit 0
    }
}
if ($Action -eq 'clear') {
    if (Test-Path -LiteralPath $NlmAutoFile) { Remove-Item -LiteralPath $NlmAutoFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $NlmFile) { Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $NamesFile) { Remove-Item -LiteralPath $NamesFile -Force -ErrorAction SilentlyContinue }
    Write-Host '[OK] NLM-фильтр отключён (активны все сети)'
    exit 0
}

while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '          РАЗБЛОКИРОВКА CLOUDFLARE WARP И ЗАЩИТА ОТ VPN         ' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host "  Обход блокировки Cloudflare WARP : $(Get-WarpState)" -ForegroundColor Green
    Write-Host "  Сетевой фильтр NLM               : $(Get-NlmState)" -ForegroundColor Yellow
    Write-Host '  --------------------------------------------------------------'
    Write-Host '  [1] Переключить разблокировку Cloudflare WARP [ВКЛ / ВЫКЛ]' -ForegroundColor Green
    Write-Host '  [2] Авто-исключение сторонних VPN (привязка к физ. сети провайдера)'
    Write-Host '  [3] Ручная настройка фильтра сетей NLM (winws2 --nlm-list=all)'
    Write-Host '  [4] Сбросить по умолчанию (WARP ВКЛ, все сети активны)'
    Write-Host '  [0] Назад в главное меню'
    Write-Host '  --------------------------------------------------------------'
    $ch = Read-Host '  Выберите пункт (0-4)'

    if ($ch -eq '0' -or $ch -eq '') { exit 0 }
    elseif ($ch -eq '1') {
        if (Test-Path -LiteralPath $WarpFlag) {
            Remove-Item -LiteralPath $WarpFlag -Force
            Write-Host "`n  [ИНФО] Разблокировка Cloudflare WARP отключена." -ForegroundColor Yellow
        } else {
            [IO.File]::WriteAllText($WarpFlag, "1`n")
            Write-Host "`n  [OK] Разблокировка Cloudflare WARP ВКЛЮЧЕНА." -ForegroundColor Green
        }
        exit 10
    }
    elseif ($ch -eq '2') {
        Write-Host "`n  [*] Сканирование профилей сетей Windows NLM..." -ForegroundColor Cyan
        $vpnRx = $VpnRxCommon
        $rawOut = & $WinwsExe '--nlm-list=all' 2>$null
        $vpnGuids = New-Object System.Collections.Generic.List[string]
        $curName = ''
        foreach ($line in $rawOut) {
            if ($line -match '^Name\s*:\s*(.+)$') { $curName = $matches[1].Trim() }
            elseif ($line -match '^NetID\s*:\s*(\S+)' -and $curName -and ($curName -match $vpnRx)) {
                $gid = $matches[1].Trim()
                if (-not $vpnGuids.Contains($gid)) { $vpnGuids.Add($gid) }
            }
        }
        if ($vpnGuids.Count -gt 0) {
            $val = 'NEG:' + ($vpnGuids -join ',')
            [IO.File]::WriteAllText($NlmFile, $val, (New-Object System.Text.UTF8Encoding $false))
            Write-Host "  [OK] Исключены VPN-адаптеры (--nlm-filter-neg=1): $val" -ForegroundColor Green
            exit 10
        } else {
            if (Test-Path -LiteralPath $NlmFile) { Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue }
            Write-Host '  [ИНФО] VPN-адаптеры не найдены — фильтр не ставится, все сети и новые Wi-Fi работают без ограничений.' -ForegroundColor Green
            exit 10
        }
    }
    elseif ($ch -eq '3') {
        Write-Host "`n  --- winws2.exe --nlm-list=all ---" -ForegroundColor Cyan
        & $WinwsExe '--nlm-list=all'
        $val = Read-Host "`n  Введите NetID GUID или имя сети (например !WARP, или пусто для отмены)"
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            [IO.File]::WriteAllText($NlmFile, $val.Trim(), (New-Object System.Text.UTF8Encoding $false))
            exit 10
        }
    }
    elseif ($ch -eq '4') {
        [IO.File]::WriteAllText($WarpFlag, "1`n")
        Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue
        Write-Host "`n  [OK] Сброс выполнен: WARP ВКЛ, активны все сети." -ForegroundColor Green
        exit 10
    }
}
