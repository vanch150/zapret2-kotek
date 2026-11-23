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
$verHdr = if (Get-Command Get-Z2Version -ErrorAction SilentlyContinue) { Get-Z2Version $Root } elseif (Test-Path -LiteralPath (Join-Path $Root 'utils\version.txt')) { ([string](Get-Content -LiteralPath (Join-Path $Root 'utils\version.txt') -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '1.1.1' }
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
$svcRootDir = ''
$svcConfFromImg = ''
try {
    $imgP = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
    if (-not [string]::IsNullOrWhiteSpace($imgP)) {
        $em = [regex]::Match($imgP, '"?([A-Za-z]:\\(?:[^"]+\\)?bin\\winws2\.exe)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($em.Success) {
            $svcDir = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $em.Groups[1].Value))).TrimEnd('\') + '\'
            $svcRootDir = $svcDir
            $curDir = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
            if ($svcDir -ine $curDir) {
                $safeSvc = if ($env:USERPROFILE) { $svcDir -ireplace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' } else { $svcDir }
                Add-DiagCheck 'svc_path' 'Путь службы zapret' 'WARN' "Служба работает из другой папки: $safeSvc" 'Перезапусти окно Котека и подтверди перенос служб в текущую папку (или переустанови стратегию на вкладке «Стратегии»), затем удали старую папку.'
            } else {
                Add-DiagCheck 'svc_path' 'Путь службы zapret' 'OK' 'Совпадает с текущей папкой' ''
            }
        }
        $cm = [regex]::Match($imgP, '@"?([A-Za-z]:\\[^"]+?\.conf)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($cm.Success) { $svcConfFromImg = $cm.Groups[1].Value }
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
$vpnRx = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|\b(TAP|TUN)\b|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Happ|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'
$unidNetRx = '^(?i)(Unidentified network|Неопознанная сеть)(\s*\(.*\))?$'
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
    $curId = ''
    foreach ($nl in $nlmOut) {
        if ($nl -match '^Name\s*:\s*(.+)$') {
            $curN = $matches[1].Trim()
            $curId = ''
        } elseif ($nl -match '^NetID\s*:\s*(\{?[0-9A-Fa-f\-]+\}?)') {
            $curId = $matches[1].Trim()
            if ($curN -and ($curN -match $vpnRx)) {
                if (-not $detectedVpns.Contains($curN)) { $detectedVpns.Add($curN) }
                if ($curId -and -not $detectedVpnIds.Contains($curId)) { $detectedVpnIds.Add($curId) }
            }
        } elseif ($nl -match '^Adapter\s*:\s*(.+)$') {
            $curAd = $matches[1].Trim()
            if ($curId -and ($curAd -match $vpnRx) -and (-not ($curN -match $unidNetRx))) {
                $dispAd = if ($curN) { "$curN ($curAd)" } else { $curAd }
                if (-not $detectedVpns.Contains($dispAd)) { $detectedVpns.Add($dispAd) }
                if (-not $detectedVpnIds.Contains($curId)) { $detectedVpnIds.Add($curId) }
            }
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
    $vpnIfOnDiag = Test-Path -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.enabled')
    $vpnIfNmDiag = if (Test-Path -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.names')) { ([string](Get-Content -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.names') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '' }
    if ($vpnIfOnDiag) {
        Add-DiagCheck 'vpn_nlm' 'Исключение VPN (WinDivert)' 'OK' "Обнаружен VPN ($vpnListStr) — исключён через WinDivert (обход на: $(if ($vpnIfNmDiag) { $vpnIfNmDiag } else { 'физ. карты' }))" ''
    } elseif ($nlmAutoOn) {
        Add-DiagCheck 'vpn_nlm' 'Исключение VPN' 'WARN' "Обнаружен VPN ($vpnListStr) — активен устаревший NLM (обход засыпает при подключении VPN)" 'Включи «Исключение VPN (WinDivert)» в Настройках Котека.'
    } else {
        Add-DiagCheck 'vpn_nlm' 'Исключение VPN (WinDivert)' 'INFO' "Обнаружен VPN ($vpnListStr) · фильтр интерфейсов выключен" ''
    }
} else {
    $vpnIfOnDiag = Test-Path -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.enabled')
    $vpnIfNmDiag = if (Test-Path -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.names')) { ([string](Get-Content -LiteralPath (Join-Path $Root 'utils\vpn_ifidx.names') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '' }
    $vfTxt = if ($vpnIfOnDiag) { "WinDivert-фильтр активен ($(if ($vpnIfNmDiag) { $vpnIfNmDiag } else { 'физ. карты' }))" } else { 'фильтр интерфейсов выключен' }
    Add-DiagCheck 'vpn_nlm' 'Исключение VPN (WinDivert)' 'OK' "Активных VPN не обнаружено · $vfTxt" ''
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
    Add-DiagCheck 'proxy' 'Системный прокси Windows' 'WARN' "Включён системный прокси: $safeProxySrv" 'WinDivert-фильтр VPN не перехватывает HTTP/SOCKS-прокси. Если ты не пользуешься сейчас V2RayN/Nekoray/Clash, выключи прокси в Параметрах Windows -> Сеть и Интернет -> Прокси.'
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
$svcConfPath = ''
if ($svcConfFromImg -and (Test-Path -LiteralPath $svcConfFromImg)) {
    $svcConfPath = $svcConfFromImg
} elseif ($svcRootDir) {
    $candConf = Join-Path $svcRootDir 'bin\service.conf'
    if (Test-Path -LiteralPath $candConf) { $svcConfPath = $candConf }
}
if (-not $svcConfPath) { $svcConfPath = Join-Path $Root 'bin\service.conf' }
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

# 10. Network probes (YouTube, YT HD 120KB, Discord, 7TV CDN, CF 256KB) with exitcode & speed
$curlExe = "$env:SystemRoot\System32\curl.exe"
$invC = [System.Globalization.CultureInfo]::InvariantCulture
function Invoke-Z2DiagProbe([string]$Url, [int]$MaxSec = 5, [int]$Retries = 0) {
    $res = [PSCustomObject]@{ Code='000'; Bytes=0L; Speed=0.0; Exit=99; Ok=$false; Label='000' }
    if (-not (Test-Path -LiteralPath $curlExe)) { return $res }
    for ($attempt = 0; $attempt -le $Retries; $attempt++) {
        $res = [PSCustomObject]@{ Code='000'; Bytes=0L; Speed=0.0; Exit=99; Ok=$false; Label='000' }
        try {
            $raw = [string](& $curlExe -4 -s -o NUL -w '%{http_code}|%{size_download}|%{speed_download}|%{exitcode}' --max-time $MaxSec $Url 2>$null)
            $p = $raw.Trim() -split '\|'
            if ($p.Count -ge 1 -and $p[0]) { $res.Code = $p[0].Trim() }
            $tmpBytes = 0L
            $tmpSpeed = 0.0
            if ($p.Count -ge 2 -and [long]::TryParse($p[1].Trim(), [ref]$tmpBytes)) { $res.Bytes = $tmpBytes }
            if ($p.Count -ge 3 -and [double]::TryParse($p[2].Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $invC, [ref]$tmpSpeed)) { $res.Speed = $tmpSpeed }
            if ($p.Count -ge 4 -and $p[3].Trim() -match '^\d+$') { $res.Exit = [int]$p[3].Trim() } else { $res.Exit = $LASTEXITCODE }
            $kb = [int][Math]::Round($res.Bytes / 1024.0)
            $kbs = [int][Math]::Round($res.Speed / 1024.0)
            $res.Label = if ($res.Exit -eq 0) { "$($res.Code) (${kb}KB, ${kbs}KB/s)" } else { "$($res.Code) (e=$($res.Exit), ${kb}KB)" }
        } catch {}
        if ($res.Exit -eq 0) { break }
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds 300 }
    }
    return $res
}
$pYt  = Invoke-Z2DiagProbe 'https://www.youtube.com' 6 1
$pYtH = Invoke-Z2DiagProbe 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg' 6
$pDc  = Invoke-Z2DiagProbe 'https://discord.com' 4 1
$p7tv = Invoke-Z2DiagProbe 'https://cdn.7tv.app' 4
$pCf  = Invoke-Z2DiagProbe 'https://speed.cloudflare.com/__down?bytes=262144' 6

$ytOk   = ($pYt.Exit -eq 0 -and $pYt.Code -match '^[23]\d\d$' -and ($pYt.Code -ne '200' -or $pYt.Bytes -ge 65536))
$ytHdOk = ($pYtH.Exit -eq 0 -and $pYtH.Code -eq '200' -and $pYtH.Bytes -ge 40960 -and $pYtH.Speed -ge 20000)
$dcOk   = ($pDc.Exit -eq 0 -and $pDc.Code -match '^[23]\d\d$')
$tv7Ok  = ($p7tv.Exit -eq 0 -and $p7tv.Code -match '^[234]\d\d$')
$cfOk   = ($pCf.Exit -eq 0 -and $pCf.Code -eq '200' -and $pCf.Bytes -ge 200000)

$probeLine = "YouTube: $($pYt.Label) · YT-HD: $($pYtH.Label) · Discord: $($pDc.Label) · 7TV: $($p7tv.Label) · CF256: $($pCf.Label)"
if ($ytOk -and $ytHdOk -and $dcOk -and $tv7Ok -and $cfOk) {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord, 7TV и скорость' 'OK' $probeLine ''
} elseif ((-not $ytOk -and -not $ytHdOk) -or (-not $ytOk -and -not $dcOk)) {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord, 7TV и скорость' 'FAIL' $probeLine 'Текущая стратегия не пробивает блокировку провайдера. Нажми «Автонастройка» или «Глубокая оптимизация» на главной.'
} else {
    Add-DiagCheck 'probes' 'Доступ к YouTube, Discord, 7TV и скорость' 'WARN' $probeLine 'Часть целей работает, но одна или несколько просели (возможен разовый таймаут или ограничение на тяжёлых ресурсах). Если в браузере всё открывается — это нормально; иначе попробуй другую стратегию (ALT12 / custom_wssize_antifreeze) или отключи QUIC в «Фиксе браузера».'
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
            Add-DiagCheck 'browsers' 'Браузеры (QUIC)' 'INFO' ($parts -join '  |  ') ''
        } else {
            Add-DiagCheck 'browsers' 'Браузеры (QUIC)' 'INFO' 'Установленные браузеры не обнаружены' ''
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
$telHelperDiag = Join-Path $PSScriptRoot 'telemetry_helper.ps1'
if (Test-Path -LiteralPath $telHelperDiag) {
    try {
        . $telHelperDiag
        if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) {
            $diagSnap = Get-Z2TelemetrySnapshot $Root
            if ($diagSnap) {
                [void]$sb.AppendLine("--- Tech Snapshot ---")
                [void]$sb.AppendLine($diagSnap)
            }
        }
    } catch {}
}

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
        $redacted = $redacted -replace '(?i)([A-Z]:\\Users\\)[^\\\s"'']+', '$1<USER>'
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
