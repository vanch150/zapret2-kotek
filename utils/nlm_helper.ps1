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
$WarpFlag    = Join-Path $Root 'utils\warp_unblock.enabled'
$WinwsExe    = Join-Path $Root 'bin\winws2.exe'

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

$VpnRxCommon = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|\b(TAP|TUN)\b|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'
$GuidRxStrict = '^!?\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'

function Invoke-NlmAutoExclude {
    if (-not (Test-Path -LiteralPath $WinwsExe)) {
        Write-Host '[X] bin\winws2.exe не найден.' -ForegroundColor Red
        return $false
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $global:LASTEXITCODE = 0
    $rawOut = @(& $WinwsExe '--nlm-list=all' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $rawOut.Count -eq 0) {
        Write-Host '[!] Не удалось прочитать список сетей NLM (winws2 --nlm-list=all) — текущий фильтр сохранён.' -ForegroundColor Yellow
        return $false
    }
    [IO.File]::WriteAllText($NlmAutoFile, '1', $utf8NoBom)
    $vpnGuids = New-Object System.Collections.Generic.List[string]
    $vpnNames = New-Object System.Collections.Generic.List[string]
    $curName = ''
    $curGid  = ''
    foreach ($line in $rawOut) {
        if ($line -match '^Name\s*:\s*(.+)$') {
            $curName = $matches[1].Trim()
            $curGid  = ''
        } elseif ($line -match '^NetID\s*:\s*(\S+)') {
            $curGid = $matches[1].Trim()
            if ($curName -and ($curName -match $VpnRxCommon) -and -not $vpnGuids.Contains($curGid)) {
                $vpnGuids.Add($curGid)
                $vpnNames.Add($curName)
            }
        } elseif ($line -match '^Adapter\s*:\s*(.+)$') {
            $curAd = $matches[1].Trim()
            if ($curGid -and ($curAd -match $VpnRxCommon) -and -not $vpnGuids.Contains($curGid)) {
                $vpnGuids.Add($curGid)
                $vpnNames.Add($(if ($curName) { "$curName ($curAd)" } else { $curAd }))
            }
        }
    }
    if ($vpnGuids.Count -gt 0) {
        $val = 'NEG:' + ($vpnGuids -join ',')
        [IO.File]::WriteAllText($NlmFile, $val, $utf8NoBom)
        [IO.File]::WriteAllText($NamesFile, ($vpnNames -join ', '), $utf8NoBom)
        Write-Host "[OK] NLM-фильтр (инверсия): исключены VPN-адаптеры ($($vpnGuids.Count)); все физ. сети и новые Wi-Fi активны." -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath $NlmFile) { Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $NamesFile) { Remove-Item -LiteralPath $NamesFile -Force -ErrorAction SilentlyContinue }
        Write-Host '[OK] Авто-исключение VPN активно (сейчас активных VPN-адаптеров не найдено; новые VPN будут исключаться автоматически).' -ForegroundColor Green
    }
    return $true
}

function Clear-NlmFilter {
    if (Test-Path -LiteralPath $NlmAutoFile) { Remove-Item -LiteralPath $NlmAutoFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $NlmFile) { Remove-Item -LiteralPath $NlmFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $NamesFile) { Remove-Item -LiteralPath $NamesFile -Force -ErrorAction SilentlyContinue }
}

if ($Action -eq 'auto') {
    if (Invoke-NlmAutoExclude) { exit 0 } else { exit 1 }
}
if ($Action -eq 'clear') {
    Clear-NlmFilter
    Write-Host '[OK] NLM-фильтр отключён (активны все сети)'
    exit 0
}
if ($Action -eq 'reset') {
    [IO.File]::WriteAllText($WarpFlag, "1`n")
    Clear-NlmFilter
    Write-Host '[OK] Сброс выполнен: WARP ВКЛ, активны все сети.'
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
        if (Invoke-NlmAutoExclude) {
            exit 10
        } else {
            Read-Host '  Нажмите Enter для продолжения...' | Out-Null
        }
    }
    elseif ($ch -eq '3') {
        Write-Host "`n  --- winws2.exe --nlm-list=all ---" -ForegroundColor Cyan
        & $WinwsExe '--nlm-list=all'
        $val = Read-Host "`n  Введите NetID в формате {GUID} или !{GUID} (пусто для отмены)"
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $trimmed = $val.Trim()
            if ($trimmed -match $GuidRxStrict) {
                Clear-NlmFilter
                [IO.File]::WriteAllText($NlmFile, $trimmed, (New-Object System.Text.UTF8Encoding($false)))
                exit 10
            } else {
                Write-Host '  [!] Неверный формат. Введите строго {GUID} или !{GUID}, например !{12345678-1234-1234-1234-1234567890AB}.' -ForegroundColor Red
                Read-Host '  Нажмите Enter для продолжения...' | Out-Null
            }
        }
    }
    elseif ($ch -eq '4') {
        [IO.File]::WriteAllText($WarpFlag, "1`n")
        Clear-NlmFilter
        Write-Host "`n  [OK] Сброс выполнен: WARP ВКЛ, активны все сети." -ForegroundColor Green
        exit 10
    }
}
