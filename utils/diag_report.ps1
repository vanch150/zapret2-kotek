param(
    [string]$Root = ''
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$commonPs1 = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPs1) { . $commonPs1 }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$verHdr = if (Get-Command Get-Z2Version -ErrorAction SilentlyContinue) { Get-Z2Version $Root } elseif (Test-Path -LiteralPath (Join-Path $Root 'utils\version.txt')) { ([string](Get-Content -LiteralPath (Join-Path $Root 'utils\version.txt') -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '1.0.9' }
$nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$safeRoot = if ($env:USERPROFILE) { $Root -ireplace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' } else { $Root }

$checks = New-Object System.Collections.Generic.List[object]
function Add-DiagCheck([string]$Id, [string]$Title, [string]$Status, [string]$Detail, [string]$Fix = '') {
    $checks.Add([PSCustomObject]@{
        id     = $Id
        title  = $Title
        status = $Status
        detail = $Detail
        fix    = $Fix
    })
}

# 1. Core files integrity (antivirus quarantine check)
$reqFiles = @(
    'bin\winws2.exe',
    'bin\WinDivert64.sys',
    'bin\WinDivert.dll',
    'bin\cygwin1.dll',
    'lua\zapret-lib.lua',
    'lua\zapret-antidpi.lua',
    'bin\quic_initial_www_google_com.bin'
)
$missingFiles = New-Object System.Collections.Generic.List[string]
foreach ($rf in $reqFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $rf))) { $missingFiles.Add($rf) }
}
if ($missingFiles.Count -eq 0) {
    Add-DiagCheck 'files' 'Целостность файлов' 'OK' 'Все ключевые файлы bin\ и lua\ на месте' ''
} else {
    Add-DiagCheck 'files' 'Целостность файлов' 'FAIL' ("Отсутствуют: " + ($missingFiles -join ', ')) 'Антивирус мог удалить файлы в карантин. Добавь папку Zapret2 Kotek в исключения Защитника Windows и распакуй архив заново.'
}

# 2. Path check
$pathWarn = New-Object System.Collections.Generic.List[string]
if ($Root -match '\s') { $pathWarn.Add('пробелы') }
if ($Root -match '[()]') { $pathWarn.Add('скобки') }
if ($Root -match '[\u0400-\u04FF]') { $pathWarn.Add('кириллица') }
if ($Root -match '(?i)\\(Downloads|OneDrive|Desktop|Temp)\\') { $pathWarn.Add('временная/облачная папка') }
if ($pathWarn.Count -eq 0) {
    Add-DiagCheck 'path' 'Путь к папке' 'OK' $safeRoot ''
} else {
    Add-DiagCheck 'path' 'Путь к папке' 'WARN' ("$safeRoot (" + ($pathWarn -join ', ') + ')') 'Если возникают сбои запуска или обновлений, перенеси папку в короткий путь на латинице, например: C:\zapret2-kotek'
}

# 2b. Service path match check (detects running from a sibling folder)
try {
    $imgP = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
    if (-not [string]::IsNullOrWhiteSpace($imgP)) {
        $em = [regex]::Match($imgP, '"?([A-Za-z]:\\[^"]+?\\bin\\winws2\.exe)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($em.Success) {
            $svcDir = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $em.Groups[1].Value))).TrimEnd('\') + '\'
            $curDir = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
            if ($svcDir -ine $curDir) {
                $safeSvc = if ($env:USERPROFILE) { $svcDir -ireplace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' } else { $svcDir }
                Add-DiagCheck 'svc_path' 'Путь службы zapret' 'WARN' "Служба работает из другой папки: $safeSvc" 'Перезапусти окно Котека и подтверди перенос служб в текущую папку (или переустанови стратегию на вкладке «Стратегии»), затем удали старую папку.'
            } else {
                Add-DiagCheck 'svc_path' 'Путь службы zapret' 'OK' 'Совпадает с текущей папкой' ''
            }
        }
    }
} catch {}

# 3. Base Filtering Engine (BFE)
$svcBfe = $null
try {
    $svcBfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
    if ($null -ne $svcBfe -and $svcBfe.Status -eq 'Running') {
        Add-DiagCheck 'bfe' 'Служба BFE (WinDivert)' 'OK' 'Запущена (Running)' ''
    } else {
        $bfeSt = if ($svcBfe) { [string]$svcBfe.Status } else { 'НЕ НАЙДЕНА' }
        Add-DiagCheck 'bfe' 'Служба BFE (WinDivert)' 'FAIL' "Статус: $bfeSt" 'Без службы базовой фильтрации (BFE) WinDivert не работает. Открой Win+R -> services.msc, найди «Служба базовой фильтрации» и запусти её.'
    }
} finally {
    if ($null -ne $svcBfe) { try { $svcBfe.Dispose() } catch {} }
}

# 4. Main zapret service & strategy
$strat = ''
try { $strat = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube' } catch {}
$stratDisp = if ($strat) { $strat } else { 'не выбрана' }
$svcZ = $null
$svcWd = $null
try {
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $svcWd = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
    $zSt = if ($svcZ) { [string]$svcZ.Status } else { 'NOT_INSTALLED' }
    $wdSt = if ($svcWd) { [string]$svcWd.Status } else { 'NOT_INSTALLED' }
} finally {
    if ($null -ne $svcZ) { try { $svcZ.Dispose() } catch {} }
    if ($null -ne $svcWd) { try { $svcWd.Dispose() } catch {} }
}
$pWinws2 = @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue)

if ($zSt -eq 'Running' -and $pWinws2.Count -gt 0) {
    Add-DiagCheck 'zapret' 'Служба обхода (zapret)' 'OK' "Работает · стратегия: $stratDisp · WinDivert: $wdSt" ''
} elseif ($zSt -eq 'Stopped') {
    Add-DiagCheck 'zapret' 'Служба обхода (zapret)' 'WARN' "Остановлена (на паузе) · стратегия: $stratDisp" 'Нажми «Возобновить» на главной или выбери стратегию.'
} else {
    Add-DiagCheck 'zapret' 'Служба обхода (zapret)' 'FAIL' "Служба: $zSt · winws2: $($pWinws2.Count) · WinDivert: $wdSt" 'Нажми «Автонастройка» на главной или установи стратегию на вкладке «Стратегии».'
}

# 5. Conflicting DPI bypasses / filters
$hardConflicts = New-Object System.Collections.Generic.List[string]
$softConflicts = New-Object System.Collections.Generic.List[string]
foreach ($cs in @('GoodbyeDPI', 'discordfix_zapret')) {
    $csv = $null
    try {
        $csv = Get-Service -Name $cs -ErrorAction SilentlyContinue
        if ($null -ne $csv -and $csv.Status -eq 'Running') { $hardConflicts.Add("служба $cs") }
    } finally {
        if ($null -ne $csv) { try { $csv.Dispose() } catch {} }
    }
}
foreach ($cp in @('goodbyedpi', 'winws')) {
    if (Get-Process -Name $cp -ErrorAction SilentlyContinue) { $hardConflicts.Add("процесс $cp.exe") }
}
if (Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue) { $softConflicts.Add('AdGuard (AdguardSvc)') }

if ($hardConflicts.Count -gt 0) {
    Add-DiagCheck 'conflicts' 'Конфликтующие обходы' 'FAIL' ("Обнаружены: " + ($hardConflicts -join ', ')) 'Два DPI-обхода на WinDivert конфликтуют друг с другом. Удали или останови сторонний обход (GoodbyeDPI / старый Zapret) и перезапусти службу.'
} elseif ($softConflicts.Count -gt 0) {
    Add-DiagCheck 'conflicts' 'Конфликтующие программы' 'WARN' ("Активен: " + ($softConflicts -join ', ')) 'AdGuard фильтрует HTTPS-трафик и иногда мешает обходу. Если сайты не грузятся — отключи HTTPS-фильтрацию для браузера в AdGuard.'
} else {
    Add-DiagCheck 'conflicts' 'Конфликтующие обходы' 'OK' 'GoodbyeDPI и сторонние обходы не обнаружены' ''
}

# 6. VPN & NLM auto-exclude check (reusing nlm_helper.ps1 regex)
$vpnRx = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|\b(TAP|TUN)\b|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'
$nlmAutoOn = Test-Path -LiteralPath (Join-Path $Root 'utils\nlm_auto.enabled')
$nlmFilterRaw = ''
$nlmFile = Join-Path $Root 'utils\nlm_filter.enabled'
if (Test-Path -LiteralPath $nlmFile) { $nlmFilterRaw = ([string](Get-Content -LiteralPath $nlmFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() }
$nlmManualGuids = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
if ($nlmFilterRaw -match '^(?i)(?:NEG:|!)(.+)$') {
    foreach ($g in ($matches[1] -split ',')) {
        $gt = $g.Trim()
        if ($gt) { [void]$nlmManualGuids.Add($gt) }
    }
}

$detectedVpns = New-Object System.Collections.Generic.List[string]
$detectedVpnIds = New-Object System.Collections.Generic.List[string]
$winwsExe = Join-Path $Root 'bin\winws2.exe'
if (Test-Path -LiteralPath $winwsExe) {
    $nlmRawText = ''
    $nlmProc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $winwsExe
        $psi.Arguments              = '--nlm-list=all'
        $psi.WorkingDirectory       = $Root
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $nlmProc = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $nlmProc) {
            $outTask = $nlmProc.StandardOutput.ReadToEndAsync()
            $errTask = $nlmProc.StandardError.ReadToEndAsync()
            if (-not $nlmProc.WaitForExit(10000)) {
                try { $nlmProc.Kill() } catch {}
            }
            try { if ($outTask.Wait(1000)) { $nlmRawText = [string]$outTask.Result } } catch {}
            try { [void]$errTask.Wait(1000) } catch {}
        }
    } catch {
        $nlmRawText = ''
    } finally {
        if ($null -ne $nlmProc) {
            try { $nlmProc.Dispose() } catch {}
        }
    }
    $nlmOut = $nlmRawText -split '\r?\n'
    $curN = ''
    foreach ($nl in $nlmOut) {
        if ($nl -match '^Name\s*:\s*(.+)$') { $curN = $matches[1].Trim() }
        elseif ($nl -match '^NetID\s*:\s*(\{?[0-9A-Fa-f\-]+\}?)') {
            $curId = $matches[1].Trim()
            if ($curN -and ($curN -match $vpnRx)) {
                if (-not $detectedVpns.Contains($curN)) { $detectedVpns.Add($curN) }
                if ($curId -and -not $detectedVpnIds.Contains($curId)) { $detectedVpnIds.Add($curId) }
            }
            $curN = ''
        }
    }
}
if ($detectedVpns.Count -eq 0) {
    try {
        foreach ($ad in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
            $adText = "$($ad.Name) $($ad.InterfaceDescription)"
            if ($adText -match $vpnRx -and -not $detectedVpns.Contains($ad.Name)) { $detectedVpns.Add($ad.Name) }
        }
    } catch {}
}

if ($detectedVpns.Count -gt 0) {
    $vpnListStr = if ($detectedVpns.Count -eq 1) { '<VPN_PROFILE>' } else { "<VPN_PROFILE> ($($detectedVpns.Count) шт.)" }
    if ($nlmAutoOn) {
        Add-DiagCheck 'vpn_nlm' 'VPN и защита NLM' 'OK' "Обнаружен VPN ($vpnListStr) — защищён через Авто-исключение (NLM)" ''
    } elseif ($nlmManualGuids.Count -gt 0) {
        $allManualCovered = $false
        if ($detectedVpnIds.Count -gt 0) {
            $allManualCovered = $true
            foreach ($vid in $detectedVpnIds) {
                if (-not $nlmManualGuids.Contains($vid)) {
                    $allManualCovered = $false
                    break
                }
            }
        }
        if ($allManualCovered) {
            Add-DiagCheck 'vpn_nlm' 'VPN и защита NLM' 'OK' "Обнаружен VPN ($vpnListStr) — исключён в ручном списке NLM" ''
        } else {
            Add-DiagCheck 'vpn_nlm' 'VPN и защита NLM' 'WARN' "Обнаружен VPN ($vpnListStr), но он не входит в ручной список NLM" 'Открой «Настроить VPN» в Настройках Котека и отметь нужный VPN, либо включи Авто-исключение (NLM).'
        }
    } else {
        Add-DiagCheck 'vpn_nlm' 'VPN и защита NLM' 'WARN' "Обнаружен VPN ($vpnListStr), а защита NLM выключена" 'Включи «Авто-исключение VPN (NLM)» в Настройках Котека или добавь VPN в ручной список NLM.'
    }
} else {
    $nlmTxt = if ($nlmAutoOn) { 'Авто-исключение NLM активно' } elseif ($nlmManualGuids.Count -gt 0) { "Ручной список NLM активен ($($nlmManualGuids.Count))" } else { 'NLM выключен' }
    Add-DiagCheck 'vpn_nlm' 'VPN и защита NLM' 'OK' "Активных VPN не обнаружено · $nlmTxt" ''
}

# 7. Windows system proxy (ProxyEnable)
$proxyOn = $false
$proxySrv = ''
try {
    $inetKey = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($null -ne $inetKey -and [int]$inetKey.ProxyEnable -eq 1) {
        $proxyOn = $true
        $proxySrv = [string]$inetKey.ProxyServer
    }
} catch {}
if ($proxyOn) {
    $safeProxySrv = ($proxySrv -replace '://[^@\s]+@', '://<REDACTED>@') -replace '([=;]|^)[^=;\s/]+:[^@\s]+@', '$1<REDACTED>@'
    Add-DiagCheck 'proxy' 'Системный прокси Windows' 'WARN' "Включён системный прокси: $safeProxySrv" 'NLM не перехватывает HTTP/SOCKS-прокси. Если ты не пользуешься сейчас V2RayN/Nekoray/Clash, выключи прокси в Параметрах Windows -> Сеть и Интернет -> Прокси.'
} else {
    Add-DiagCheck 'proxy' 'Системный прокси Windows' 'OK' 'Выключен' ''
}

# 8. TCP Timestamps (locale-independent via Get-NetTCPSetting)
$tcpTsState = 'unknown'
try {
    $tsObj = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $tsObj -and $null -ne $tsObj.Timestamps) {
        $tcpTsState = [string]$tsObj.Timestamps
    }
} catch {}
if ($tcpTsState -eq 'unknown') {
    try {
        $rawNetsh = (& "$env:SystemRoot\System32\netsh.exe" interface tcp show global 2>$null) -join "`n"
        if ($rawNetsh -match '(?im)(Timestamps|RFC 1323|Отметки времени|Метки времени)[^:\r\n]*:\s*(\S+)') {
            $vTs = $matches[2].Trim().ToLowerInvariant()
            if ($vTs -in @('enabled', 'включено', 'вкл')) { $tcpTsState = 'Enabled' }
            elseif ($vTs -in @('disabled', 'отключено', 'выкл')) { $tcpTsState = 'Disabled' }
            else { $tcpTsState = $matches[2].Trim() }
        }
    } catch {}
}
$usesTcpTs = $false
$svcConfPath = Join-Path $Root 'bin\service.conf'
if (Test-Path -LiteralPath $svcConfPath) {
    $confRaw = [string](Get-Content -LiteralPath $svcConfPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($confRaw -match 'tcp_ts') { $usesTcpTs = $true }
}
if ($tcpTsState -ieq 'Enabled') {
    Add-DiagCheck 'tcp_ts' 'TCP Timestamps (RFC 1323)' 'OK' 'Включены (Enabled)' ''
} elseif ($tcpTsState -ieq 'Disabled' -and $usesTcpTs) {
    Add-DiagCheck 'tcp_ts' 'TCP Timestamps (RFC 1323)' 'WARN' 'Отключены, но текущая стратегия использует tcp_ts' 'Открой командную строку (cmd) от имени администратора и выполни: netsh interface tcp set global timestamps=enabled'
} elseif ($tcpTsState -ieq 'Disabled') {
    Add-DiagCheck 'tcp_ts' 'TCP Timestamps (RFC 1323)' 'OK' 'Отключены (текущей стратегии не требуются)' ''
} else {
    Add-DiagCheck 'tcp_ts' 'TCP Timestamps (RFC 1323)' 'WARN' "Не удалось определить ($tcpTsState)" 'Если стратегии с tcp_ts не работают, выполни в cmd от админа: netsh interface tcp set global timestamps=enabled'
}

# 9. Filter modes (IPSet, GameFilter, AutoHost)
$ipMode = if (Get-Command Get-Z2IpsetMode -ErrorAction SilentlyContinue) { Get-Z2IpsetMode $Root } else { 'unknown' }
$gfMode = 'disabled'
$gfFile = Join-Path $Root 'utils\game_filter.enabled'
if (Test-Path -LiteralPath $gfFile) {
    foreach ($gl in (Get-Content -LiteralPath $gfFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($gl -match '^(?i)mode=(.+)$') { $gfMode = $matches[1].Trim().ToLowerInvariant() }
    }
}
$ahOn = Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')
$autoCnt = 0
$autoPath = Join-Path $Root 'lists\list-auto.txt'
if (Test-Path -LiteralPath $autoPath) {
    $autoCnt = @(Get-Content -LiteralPath $autoPath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
}
$filterDesc = "IPSet: $ipMode · GameFilter: $gfMode · AutoHost: $(if ($ahOn) { "ВКЛ ($autoCnt)" } else { 'ВЫКЛ' })"
if ($gfMode -in @('tcp', 'all')) {
    Add-DiagCheck 'filters' 'Режимы фильтров' 'WARN' $filterDesc 'GameFilter в режиме TCP/ALL может рвать авторизацию в играх (Battle.net и др.). Если игра не пускает — переключи GameFilter на UDP/Выкл или добавь домен в Исключения.'
} else {
    Add-DiagCheck 'filters' 'Режимы фильтров' 'OK' $filterDesc ''
}

# 10. Network probes (YouTube, Discord, 7TV CDN)
$curlExe = "$env:SystemRoot\System32\curl.exe"
$ytCode = '000'; $dcCode = '000'; $tv7Code = '000'
if (Test-Path -LiteralPath $curlExe) {
    $c1 = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 4 'https://www.youtube.com' 2>$null
    $c2 = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 4 'https://discord.com' 2>$null
    $c3 = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 4 'https://cdn.7tv.app' 2>$null
    if ($c1) { $ytCode = [string]$c1 }
    if ($c2) { $dcCode = [string]$c2 }
    if ($c3) { $tv7Code = [string]$c3 }
}
$ytOk = ($ytCode -match '^[23]\d\d$')
$dcOk = ($dcCode -match '^[23]\d\d$')
$tv7Ok = ($tv7Code -match '^[234]\d\d$')
if ($ytOk -and $dcOk -and $tv7Ok) {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord и 7TV' 'OK' "YouTube: HTTP $ytCode · Discord: HTTP $dcCode · 7TV CDN: HTTP $tv7Code" ''
} elseif ($ytOk -and $dcOk -and -not $tv7Ok) {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord и 7TV' 'WARN' "YouTube: HTTP $ytCode · Discord: HTTP $dcCode · 7TV CDN: HTTP $tv7Code" 'YouTube и Discord работают, но 7TV CDN не отвечает. Попробуй другую стратегию или опциональный фикс браузера (QUIC/DoH) в Настройках.'
} else {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord и 7TV' 'FAIL' "YouTube: HTTP $ytCode · Discord: HTTP $dcCode · 7TV CDN: HTTP $tv7Code" 'Текущая стратегия не пробивает блокировку провайдера. Нажми «Автонастройка» или «Глубокая оптимизация» на главной.'
}

# 10b. Browsers QUIC/DoH current status (neutral INFO, never alarms)
$brList = @()
$bhPs1 = Join-Path $PSScriptRoot 'browser_helper.ps1'
if (Test-Path -LiteralPath $bhPs1) {
    try {
        . $bhPs1 -Root $Root
        $brList = @(Get-Z2BrowserStates)
        if ($brList.Count -gt 0) {
            $parts = @($brList | ForEach-Object { "$($_.Name): $($_.StatusText)" })
            Add-DiagCheck 'browsers' 'Браузеры (QUIC / DoH)' 'INFO' ($parts -join '  |  ') ''
        } else {
            Add-DiagCheck 'browsers' 'Браузеры (QUIC / DoH)' 'INFO' 'Установленные браузеры не обнаружены' ''
        }
    } catch {}
}

# 11. Telegram WS Proxy
$tgHost = '127.0.0.1'; $tgPort = 1443
$tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
if (Test-Path -LiteralPath $tgConf) {
    foreach ($tl in (Get-Content -LiteralPath $tgConf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($tl -match '^(?i)host=(.+)$') { $tgHost = $matches[1].Trim() }
        elseif ($tl -match '^(?i)port=(\d+)$') { $pTmp = 0; if ([int]::TryParse($matches[1], [ref]$pTmp) -and $pTmp -ge 1 -and $pTmp -le 65535) { $tgPort = $pTmp } }
    }
}
$svcTg = $null
try {
    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    $tgSvcSt = if ($svcTg) { [string]$svcTg.Status } else { 'NOT_INSTALLED' }
} finally {
    if ($null -ne $svcTg) { try { $svcTg.Dispose() } catch {} }
}
$tgProbeHost = $tgHost.Trim('[', ']')
if ($tgProbeHost -eq '0.0.0.0') { $tgProbeHost = '127.0.0.1' }
elseif ($tgProbeHost -eq '::') { $tgProbeHost = '::1' }
$tgPortOk = $false
$tc = $null
$ar = $null
try {
    if ($tgProbeHost -like '*:*') {
        $tc = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6)
    } else {
        $tc = New-Object System.Net.Sockets.TcpClient
    }
    $ar = $tc.BeginConnect($tgProbeHost, $tgPort, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(800, $false) -and $tc.Connected) { $tgPortOk = $true }
} catch {} finally {
    if ($null -ne $ar -and $null -ne $ar.AsyncWaitHandle) { try { $ar.AsyncWaitHandle.Dispose() } catch {} }
    if ($null -ne $tc) { try { $tc.Close() } catch {}; try { $tc.Dispose() } catch {} }
}

if ($tgSvcSt -eq 'Running' -and $tgPortOk) {
    Add-DiagCheck 'tg_proxy' 'Telegram WS Proxy' 'OK' "Работает · ${tgHost}:${tgPort} OPEN" ''
} elseif ($tgSvcSt -eq 'Running' -and -not $tgPortOk) {
    Add-DiagCheck 'tg_proxy' 'Telegram WS Proxy' 'FAIL' "Служба запущена, но порт ${tgHost}:${tgPort} закрыт" "Перезапусти TG-прокси на главной или проверь, не занят ли порт $tgPort другой программой."
} else {
    Add-DiagCheck 'tg_proxy' 'Telegram WS Proxy' 'WARN' "Выключен ($tgSvcSt)" 'Если нужен обход для Telegram Desktop — включи TG-прокси на главной.'
}

# 12. Gemini bypass (NRPT) + DoH conflict check
$aiHelperDiag = Join-Path $PSScriptRoot 'ai_bypass_helper.ps1'
if (Test-Path -LiteralPath $aiHelperDiag) {
    try {
        . $aiHelperDiag -Root $Root
        $aiSt = Get-Z2AiBypassState $Root
        if ($aiSt.Active) {
            $brDohConflict = (@($brList | Where-Object { $_.DohOn }).Count -gt 0)
            if ($brDohConflict) {
                Add-DiagCheck 'ai_bypass' 'Обход ИИ (NRPT)' 'WARN' "Активен ($($aiSt.ActiveName): $($aiSt.ServicesLabel)), но в браузере включён DoH" 'DoH в браузере идёт мимо системного DNS Windows и ломает обход ИИ. Отключи DoH в карточке «Фикс браузера» и перезапусти браузер.'
            } else {
                Add-DiagCheck 'ai_bypass' 'Обход ИИ (NRPT)' 'OK' "Активен · $($aiSt.ActiveName) · $($aiSt.ServicesLabel) ($($aiSt.RuleCount) доменов)" ''
            }
        } else {
            Add-DiagCheck 'ai_bypass' 'Обход ИИ (NRPT)' 'INFO' "Выключен · выбрано: $($aiSt.ServicesLabel)" ''
        }
    } catch {}
}

# Tally summary
$okCount = 0; $warnCount = 0; $failCount = 0
foreach ($c in $checks) {
    if ($c.status -eq 'OK') { $okCount++ }
    elseif ($c.status -eq 'WARN') { $warnCount++ }
    elseif ($c.status -eq 'FAIL') { $failCount++ }
}

# Build human-readable report for clipboard & diag_report.txt
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("=== ZAPRET2 KOTEK DIAGNOSTIC REPORT (v$verHdr) ===")
[void]$sb.AppendLine("Date      : $nowStr")
[void]$sb.AppendLine("Summary   : OK=$okCount, WARN=$warnCount, FAIL=$failCount")
[void]$sb.AppendLine("Path      : $safeRoot")
[void]$sb.AppendLine("Strategy  : $stratDisp")
[void]$sb.AppendLine("")
foreach ($c in $checks) {
    $tag = ("[{0,-4}]" -f $c.status)
    [void]$sb.AppendLine("$tag $($c.title): $($c.detail)")
    if ($c.fix) { [void]$sb.AppendLine("       -> $($c.fix)") }
}

$procs = (Get-Process -Name 'winws2','winws','tg-ws-proxy','AdguardSvc','goodbyedpi' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique) -join ', '
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Processes : $(if ($procs) { $procs } else { 'none' })")

$logPath = Join-Path $Root 'bin\logs\tg-ws-proxy.log'
if (-not (Test-Path -LiteralPath $logPath)) { $logPath = Join-Path $Root 'bin\tg-ws-proxy.log' }
if (Test-Path -LiteralPath $logPath) {
    [void]$sb.AppendLine('--- Last 6 lines of tg-ws-proxy.log (redacted) ---')
    $tail = Get-Content -LiteralPath $logPath -Tail 6 -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($tl in $tail) {
        $redacted = $tl -replace '[0-9a-fA-F]{32,}', '<REDACTED_SECRET>'
        $redacted = $redacted -replace '(?i)(secret\s*[:=]\s*)\S+', '$1<REDACTED_SECRET>'
        $redacted = $redacted -replace '(?i)(cfproxy_domain\s*[:=]\s*)\S+', '$1<REDACTED_DOMAIN>'
        $redacted = $redacted -replace '(?i)(cfproxy_worker_domain\s*[:=]\s*)\S+', '$1<REDACTED_DOMAIN>'
        $redacted = $redacted -replace '://[^@]+@', '://<REDACTED>@'
        [void]$sb.AppendLine($redacted)
    }
}

$report = $sb.ToString()
$outTxt  = Join-Path $Root 'utils\diag_report.txt'
$outJson = Join-Path $Root 'utils\diag_report.json'
try {
    [System.IO.File]::WriteAllText($outTxt, $report, $utf8NoBom)
} catch {}

$jsonObj = [PSCustomObject]@{
    version = $verHdr
    date    = $nowStr
    ok      = $okCount
    warn    = $warnCount
    fail    = $failCount
    checks  = $checks.ToArray()
}
try {
    [System.IO.File]::WriteAllText($outJson, ($jsonObj | ConvertTo-Json -Depth 4), $utf8NoBom)
} catch {}

$clipOk = $false
try { Set-Clipboard -Value $report; $clipOk = $true } catch {}

if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch {} }
Write-Host $report -ForegroundColor Gray
$clipNote = if ($clipOk) { 'скопировано в буфер' } else { 'сохранено в diag_report.txt' }
Write-Host ("  [OK] Диагностика: OK={0}, WARN={1}, FAIL={2} ({3})" -f $okCount, $warnCount, $failCount, $clipNote) -ForegroundColor Green
Write-Host ''
exit 0
