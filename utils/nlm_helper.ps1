param(
    [string]$Action = 'menu',
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if ($MyInvocation.InvocationName -ne '.') { $ErrorActionPreference = 'SilentlyContinue' }
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
try { $Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\' } catch { $Root = $Root.Trim('"', "'", '\', '/') + '\' }

$VpnIfIdxFlag   = Join-Path $Root 'utils\vpn_ifidx.enabled'
$VpnIfIdxCustom = Join-Path $Root 'utils\vpn_ifidx.custom'
$VpnIfIdxNames  = Join-Path $Root 'utils\vpn_ifidx.names'
$VpnFilterFile  = Join-Path $Root 'bin\filters\vpn_exclude.txt'
$WarpFlag       = Join-Path $Root 'utils\warp_unblock.enabled'
$LegacyNlmFiles = @('utils\nlm_auto.enabled', 'utils\nlm_filter.enabled', 'utils\nlm_filter.names')

$script:Z2VpnAdapterRx = '(?i)WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|\b(TAP|TUN)\b|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN|Happ|Hyper-V|WSL|VMware|VirtualBox|Loopback'

function Get-Z2NetAdaptersInfo {
    $list = New-Object System.Collections.Generic.List[object]
    $seenIdx = New-Object System.Collections.Generic.HashSet[int]
    $gotNetAdapter = $false
    $errBefore = $Error.Count
    try {
        $ads = @(Get-NetAdapter -IncludeHidden:$false -ErrorAction Ignore)
        if ($ads.Count -gt 0) { $gotNetAdapter = $true }
        foreach ($ad in $ads) {
            $idx = 0
            try { $idx = [int]$ad.ifIndex } catch { continue }
            if ($idx -le 0 -or -not $seenIdx.Add($idx)) { continue }
            $name = [string]$ad.Name
            $desc = [string]$ad.InterfaceDescription
            $guid = [string]$ad.InterfaceGuid
            $hw   = [bool]$ad.HardwareInterface
            $st   = [string]$ad.Status
            $txt  = "$name $desc"
            $isVpn = ($txt -match $script:Z2VpnAdapterRx)
            $isPppoe = ($ad.InterfaceType -eq 23 -and -not $isVpn)
            $defAllow = ($hw -and -not $isVpn) -or $isPppoe
            $kindLbl = if ($hw -and -not $isVpn) { 'Физический' } elseif ($isPppoe) { 'PPPoE' } elseif ($txt -match '(?i)ExitLag') { 'Игровой' } else { 'VPN / Вирт.' }
            $list.Add([PSCustomObject]@{
                Name         = $name
                Desc         = $desc
                IfIndex      = $idx
                Guid         = $guid
                Status       = $st
                IsHardware   = $hw
                IsPppoe      = $isPppoe
                IsVpn        = $isVpn
                DefaultAllow = $defAllow
                KindLabel    = $kindLbl
            })
        }
    } catch {} finally {
        while ($Error.Count -gt $errBefore) { $Error.RemoveAt(0) }
    }

    # Always supplement with .NET NetworkInterface (catches RAS/PPPoE interfaces hidden from Get-NetAdapter; full fallback if Get-NetAdapter failed)
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $name = [string]$ni.Name
            $desc = [string]$ni.Description
            $guid = [string]$ni.Id
            $txt  = "$name $desc"
            $isVpn = ($txt -match $script:Z2VpnAdapterRx)
            $isPppoe = ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp -and -not $isVpn)
            if ($gotNetAdapter -and -not $isPppoe) { continue }
            $idx = 0
            try {
                $ip4 = $ni.GetIPProperties().GetIPv4Properties()
                if ($null -ne $ip4) { $idx = [int]$ip4.Index }
            } catch {}
            if ($idx -le 0 -or -not $seenIdx.Add($idx)) { continue }
            $hw = ($ni.NetworkInterfaceType -in @([System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet, [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211)) -and (-not $isVpn)
            $defAllow = $hw -or $isPppoe
            $kindLbl = if ($isPppoe) { 'PPPoE' } elseif ($hw) { 'Физический' } else { 'VPN / Вирт.' }
            $list.Add([PSCustomObject]@{
                Name         = $name
                Desc         = $desc
                IfIndex      = $idx
                Guid         = $guid
                Status       = [string]$ni.OperationalStatus
                IsHardware   = $hw
                IsPppoe      = $isPppoe
                IsVpn        = $isVpn
                DefaultAllow = $defAllow
                KindLabel    = $kindLbl
            })
        }
    } catch {}

    return @($list | Sort-Object @{Expression='DefaultAllow';Descending=$true}, @{Expression={ $_.Status -eq 'Up' };Descending=$true}, @{Expression='Name';Ascending=$true})
}

function Update-Z2VpnIfIdxFilter([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $flagF   = Join-Path $RootPath 'utils\vpn_ifidx.enabled'
    $customF = Join-Path $RootPath 'utils\vpn_ifidx.custom'
    $namesF  = Join-Path $RootPath 'utils\vpn_ifidx.names'
    $filtF   = Join-Path $RootPath 'bin\filters\vpn_exclude.txt'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $allAds = @(Get-Z2NetAdaptersInfo)
    $selected = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $customF) {
        $wanted = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($cl in (Get-Content -LiteralPath $customF -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = $cl.Trim()
            if ($t -and -not $t.StartsWith('#')) { [void]$wanted.Add($t) }
        }
        foreach ($a in $allAds) {
            if (($a.Guid -and $wanted.Contains($a.Guid)) -or ($a.Name -and $wanted.Contains($a.Name))) {
                $selected.Add($a)
            }
        }
    } else {
        foreach ($a in $allAds) {
            if ($a.DefaultAllow) { $selected.Add($a) }
        }
    }

    # Safety guard: never write an empty filter (would blind winws2.exe)
    if ($selected.Count -eq 0) {
        if (Test-Path -LiteralPath $filtF)  { Remove-Item -LiteralPath $filtF  -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $namesF) { Remove-Item -LiteralPath $namesF -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ Ok = $false; Changed = $false; Expr = ''; Names = '' }
    }

    $ids = @($selected | ForEach-Object { [int]$_.IfIndex } | Sort-Object -Unique)
    $expr = '(' + (($ids | ForEach-Object { "ifIdx = $_" }) -join ' or ') + ')'
    $namesStr = ($selected | ForEach-Object { "$($_.Name) (ifIdx=$($_.IfIndex))" }) -join ', '

    $prevExpr = ''
    if (Test-Path -LiteralPath $filtF) {
        $prevExpr = ([string](Get-Content -LiteralPath $filtF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
    }
    $changed = ($prevExpr -ne $expr)

    $filtDir = Split-Path -Parent $filtF
    if (-not (Test-Path -LiteralPath $filtDir)) { New-Item -ItemType Directory -Path $filtDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($filtF, "$expr`r`n", $utf8NoBom)
    [System.IO.File]::WriteAllText($namesF, "$namesStr`r`n", $utf8NoBom)
    return [PSCustomObject]@{ Ok = $true; Changed = $changed; Expr = $expr; Names = $namesStr }
}

function Clear-Z2VpnIfIdxFilter([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    foreach ($rf in @('utils\vpn_ifidx.enabled', 'utils\vpn_ifidx.custom', 'utils\vpn_ifidx.names', 'bin\filters\vpn_exclude.txt', 'utils\nlm_auto.enabled', 'utils\nlm_filter.enabled', 'utils\nlm_filter.names')) {
        $fp = Join-Path $RootPath $rf
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-WarpState {
    if (Test-Path -LiteralPath $WarpFlag) { return 'ВКЛ (UDP 500, 1701, 2408, 4500 активны)' }
    return 'ВЫКЛ'
}

function Get-VpnFilterState {
    if (Test-Path -LiteralPath $VpnIfIdxFlag) {
        $nm = if (Test-Path -LiteralPath $VpnIfIdxNames) { ([string](Get-Content -LiteralPath $VpnIfIdxNames -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '' }
        if ($nm) { return "ВКЛ (WinDivert: $nm)" }
        return 'ВКЛ (WinDivert: физ. карты + PPPoE)'
    }
    return 'ВЫКЛ (все интерфейсы)'
}

# Only execute CLI actions when run directly (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($Action -eq 'auto') {
        foreach ($lf in $LegacyNlmFiles) {
            $lfp = Join-Path $Root $lf
            if (Test-Path -LiteralPath $lfp) { Remove-Item -LiteralPath $lfp -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $VpnIfIdxCustom) { Remove-Item -LiteralPath $VpnIfIdxCustom -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllText($VpnIfIdxFlag, "1`r`n", $utf8NoBom)
        $r = Update-Z2VpnIfIdxFilter $Root
        if ($r.Ok) {
            Write-Host "[OK] Исключение VPN (WinDivert): $($r.Names)" -ForegroundColor Green
            exit 0
        } else {
            Write-Host '[!] Не найдено физических адаптеров — фильтр WinDivert не применён (активны все интерфейсы).' -ForegroundColor Yellow
            exit 1
        }
    }
    if ($Action -eq 'sync') {
        if (-not (Test-Path -LiteralPath $VpnIfIdxFlag)) { exit 0 }
        $r = Update-Z2VpnIfIdxFilter $Root
        if ($r.Ok -and $r.Changed) { exit 10 }
        exit 0
    }
    if ($Action -eq 'clear') {
        Clear-Z2VpnIfIdxFilter $Root
        Write-Host '[OK] Исключение VPN отключено (активны все интерфейсы)' -ForegroundColor Green
        exit 0
    }
    if ($Action -eq 'reset') {
        [System.IO.File]::WriteAllText($WarpFlag, "1`r`n", $utf8NoBom)
        Clear-Z2VpnIfIdxFilter $Root
        [System.IO.File]::WriteAllText($VpnIfIdxFlag, "1`r`n", $utf8NoBom)
        [void](Update-Z2VpnIfIdxFilter $Root)
        Write-Host '[OK] Сброс выполнен: WARP ВКЛ, WinDivert-исключение VPN (физ. карты + PPPoE) ВКЛ.' -ForegroundColor Green
        exit 0
    }

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host '          РАЗБЛОКИРОВКА CLOUDFLARE WARP И ИСКЛЮЧЕНИЕ VPN        ' -ForegroundColor Cyan
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host "  Обход блокировки Cloudflare WARP : $(Get-WarpState)" -ForegroundColor Green
        Write-Host "  Исключение VPN (WinDivert)       : $(Get-VpnFilterState)" -ForegroundColor Yellow
        Write-Host '  --------------------------------------------------------------'
        Write-Host '  [1] Переключить разблокировку Cloudflare WARP [ВКЛ / ВЫКЛ]' -ForegroundColor Green
        Write-Host '  [2] Включить исключение VPN (физ. карты + PPPoE, без паузы)'
        Write-Host '  [3] Выключить исключение VPN (все интерфейсы)'
        Write-Host '  [4] Сбросить по умолчанию (WARP ВКЛ + физ. карты ВКЛ)'
        Write-Host '  [0] Назад в главное меню'
        Write-Host '  --------------------------------------------------------------'
        $ch = Read-Host '  Выберите пункт (0-4)'
        if ($ch -eq '0' -or $ch -eq '') { exit 0 }
        elseif ($ch -eq '1') {
            if (Test-Path -LiteralPath $WarpFlag) { Remove-Item -LiteralPath $WarpFlag -Force }
            else { [System.IO.File]::WriteAllText($WarpFlag, "1`r`n", $utf8NoBom) }
            exit 10
        }
        elseif ($ch -eq '2') {
            if (Test-Path -LiteralPath $VpnIfIdxCustom) { Remove-Item -LiteralPath $VpnIfIdxCustom -Force -ErrorAction SilentlyContinue }
            [System.IO.File]::WriteAllText($VpnIfIdxFlag, "1`r`n", $utf8NoBom)
            [void](Update-Z2VpnIfIdxFilter $Root)
            exit 10
        }
        elseif ($ch -eq '3') { Clear-Z2VpnIfIdxFilter $Root; exit 10 }
        elseif ($ch -eq '4') {
            [System.IO.File]::WriteAllText($WarpFlag, "1`r`n", $utf8NoBom)
            Clear-Z2VpnIfIdxFilter $Root
            [System.IO.File]::WriteAllText($VpnIfIdxFlag, "1`r`n", $utf8NoBom)
            [void](Update-Z2VpnIfIdxFilter $Root)
            exit 10
        }
    }
}
