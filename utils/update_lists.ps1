param(
    [string]$Root = '',
    [switch]$NoRestart
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$ListsDir = Join-Path $Root 'lists'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$curlExe = "$env:SystemRoot\System32\curl.exe"

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '     (=^.^=) ZAPRET2 KOTEK — ОБНОВЛЕНИЕ СПИСКОВ IPSET И HOSTS' -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan

$ipsetFile = Join-Path $ListsDir 'ipset-all.txt'
$ipsetBak  = Join-Path $ListsDir 'ipset-all.txt.backup'
$ipsetUrl  = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
$z2Repo = 'vanch150/zapret2-kotek'
$repoConfFile = Join-Path $Root 'utils\repo.conf'
if (Test-Path -LiteralPath $repoConfFile) {
    foreach ($rl in (Get-Content -LiteralPath $repoConfFile -ErrorAction SilentlyContinue)) {
        if ($rl -match '^\s*repo\s*=\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*$') { $z2Repo = $matches[1]; break }
    }
}
$hostsCustomUrl   = "https://raw.githubusercontent.com/$z2Repo/main/lists/hosts-extra.txt"
$hostsFlowsealUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
$localHostsExtra  = Join-Path $ListsDir 'hosts-extra.txt'
$tmpIpset  = Join-Path $env:TEMP 'z2_ipset_dl.txt'
$tmpHosts  = Join-Path $env:TEMP 'z2_hosts_dl.txt'

function Download-Z2TextFile([string]$Url, [string]$OutFile, [int]$MinBytes = 10, [int]$TimeoutSec = 8) {
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $curlExe) {
        & $curlExe --proto =https --proto-redir =https --ssl-no-revoke -L -s -f --max-time $TimeoutSec -o $OutFile $Url 2>$null
        if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -ge $MinBytes) { return $true }
    }
    try {
        $res = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        if ($res.StatusCode -eq 200 -and $res.Content.Length -ge $MinBytes) {
            [System.IO.File]::WriteAllText($OutFile, $res.Content, $utf8NoBom)
            return $true
        }
    } catch {}
    return $false
}

$extraSubnets = @(
    '104.16.0.0/12',
    '172.64.0.0/13',
    '162.158.0.0/15',
    '198.41.128.0/17',
    '108.162.192.0/18',
    '162.159.192.0/24',
    '162.159.193.0/24',
    '162.159.195.0/24',
    '162.159.196.0/24',
    '162.159.197.0/24',
    '162.159.198.0/24',
    '162.159.199.0/24',
    '162.159.200.0/24',
    '188.114.96.0/20',
    '66.22.192.0/18',
    '35.190.0.0/17',
    '130.211.0.0/16',
    '151.101.0.0/16',
    '199.232.0.0/16'
)

Write-Host '  [1/2] Загрузка свежего списка IPSet...' -ForegroundColor Yellow
$dlOk = Download-Z2TextFile $ipsetUrl $tmpIpset 500 8
$ipsetUpdated = $false
$ipsetSummary = 'не обновлён'

if ($dlOk) {
    $cidrRx = '^(\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?|[0-9a-fA-F:]+/[0-9]{1,3})$'
    $lines = New-Object System.Collections.Generic.HashSet[string]
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($l in (Get-Content -LiteralPath $tmpIpset)) {
        $t = ($l -replace '\s*#.*$', '').Trim()
        if ($t -match $cidrRx -and $lines.Add($t)) { $ordered.Add($t) }
    }
    if ($ordered.Count -ge 50) {
        foreach ($s in $extraSubnets) {
            if ($lines.Add($s)) { $ordered.Add($s) }
        }
        $curIpsetRaw = if (Test-Path -LiteralPath $ipsetFile) { ([string](Get-Content -LiteralPath $ipsetFile -Raw -ErrorAction SilentlyContinue)).Trim() } else { 'loaded' }
        $isSpecialMode = ($curIpsetRaw -eq '' -or $curIpsetRaw -eq '203.0.113.113/32')
        if ($isSpecialMode) {
            [System.IO.File]::WriteAllLines(($ipsetFile + '.backup'), $ordered, $utf8NoBom)
        } else {
            [System.IO.File]::WriteAllLines($ipsetFile, $ordered, $utf8NoBom)
        }
        $ip2net = Join-Path $Root 'bin\ip2net.exe'
        if (Test-Path -LiteralPath $ip2net) {
            try {
                $aggOut = @($ordered | & $ip2net 2>$null | Where-Object { $_ -match $cidrRx })
                if ($aggOut.Count -ge 50) {
                    [System.IO.File]::WriteAllLines($ipsetFile, $aggOut, $utf8NoBom)
                    $ordered = $aggOut
                }
            } catch {}
        }
        Copy-Item -LiteralPath $ipsetFile -Destination $ipsetBak -Force -ErrorAction SilentlyContinue
        $ipsetUpdated = $true
        $ipsetSummary = "$($ordered.Count) подсетей"
        Write-Host ("        [OK] IPSet обновлён ({0} подсетей)" -f $ordered.Count) -ForegroundColor Green
    } else {
        $dlOk = $false
        $ipsetSummary = 'ошибка формата'
        Write-Host '        [!] Скачанный IPSet не прошёл проверку CIDR — оставлен текущий локальный список' -ForegroundColor Yellow
    }
} else {
    $ipsetSummary = 'ошибка загрузки'
    Write-Host '        [!] Не удалось скачать IPSet — оставлен текущий локальный список' -ForegroundColor Yellow
}

Write-Host '  [2/2] Проверка обновлений системного файла hosts...' -ForegroundColor Yellow
$hostsDlOk = $false
$hostsSource = ''
$hostsSummary = 'не обновлён'

# Priority 1: User's own repo lists/hosts-extra.txt
if (Download-Z2TextFile $hostsCustomUrl $tmpHosts 10 6) {
    $hostsDlOk = $true
    $hostsSource = $z2Repo
}
# Priority 2: Local lists\hosts-extra.txt
if (-not $hostsDlOk -and (Test-Path -LiteralPath $localHostsExtra) -and (Get-Item -LiteralPath $localHostsExtra).Length -ge 10) {
    Copy-Item -LiteralPath $localHostsExtra -Destination $tmpHosts -Force -ErrorAction SilentlyContinue
    $hostsDlOk = $true
    $hostsSource = 'локальный hosts-extra.txt'
}
# Priority 3: Official Flowseal .service/hosts (filtered by security allow/block rules)
if (-not $hostsDlOk -and (Download-Z2TextFile $hostsFlowsealUrl $tmpHosts 10 8)) {
    $hostsDlOk = $true
    $hostsSource = 'Flowseal'
}

if ($hostsDlOk) {
    try {
        $sysHosts = "$env:SystemRoot\System32\drivers\etc\hosts"
        $hostsBak = "$sysHosts.zapret2.bak"
        $rawCur = if (Test-Path -LiteralPath $sysHosts) { Get-Content -LiteralPath $sysHosts -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($null -eq $rawCur) { $rawCur = '' }
        $hostLineRx = '^(\d{1,3}\.){3}\d{1,3}\s+[A-Za-z0-9._-]+(\s+[A-Za-z0-9._-]+)*$'
        $privIpRx = '^(0\.|127\.|10\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)'
        $blockedDomRx = '(?i)(^|\.)(github\.com|githubusercontent\.com|google\.com|windowsupdate\.com|microsoft\.com|gosuslugi\.ru|sberbank\.ru|tbank\.ru|tinkoff\.ru|vtb\.ru|alfabank\.ru|nalog\.ru|cbr\.ru)$'
        $newLines = @(Get-Content -LiteralPath $tmpHosts | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object {
            if ($_ -notmatch $hostLineRx) { return $false }
            $toks = $_ -split '\s+'
            if ($toks[0] -match $privIpRx) { return $false }
            for ($ti = 1; $ti -lt $toks.Count; $ti++) { if ($toks[$ti] -match $blockedDomRx) { return $false } }
            return $true
        })
        if ($newLines.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $hostsBak)) { Copy-Item -LiteralPath $sysHosts -Destination $hostsBak -Force -ErrorAction SilentlyContinue }
            # Strip previous managed Zapret2 block so updated IPs replace old ones cleanly without duplicates
            $cleaned = [regex]::Replace($rawCur, "(?ms)\r?\n?# --- Zapret2 Auto-Updated Hosts ---.*?# --- End Zapret2 Hosts ---\r?\n?", "")
            $block = "`r`n# --- Zapret2 Auto-Updated Hosts ---`r`n" + ($newLines -join "`r`n") + "`r`n# --- End Zapret2 Hosts ---`r`n"
            $finalHosts = $cleaned.TrimEnd() + $block
            [System.IO.File]::WriteAllText($sysHosts, $finalHosts, $utf8NoBom)
            & ipconfig.exe /flushdns >$null 2>&1
            $hostsSummary = "обновлён ($($newLines.Count) зап., $hostsSource)"
            Write-Host ("        [OK] Системный файл hosts обновлён ({0} записей, источник: {1})" -f $newLines.Count, $hostsSource) -ForegroundColor Green
        } else {
            $hostsSummary = 'актуален'
            Write-Host '        [OK] Системный файл hosts уже актуален' -ForegroundColor Green
        }
    } catch {
        $hostsSummary = 'нет прав записи'
        Write-Host '        [!] Не удалось обновить hosts (проверь права администратора)' -ForegroundColor Yellow
    }
} else {
    $hostsSummary = 'не удалось скачать'
    Write-Host '        [!] Не удалось скачать список hosts' -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $tmpIpset) { Remove-Item -LiteralPath $tmpIpset -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $tmpHosts) { Remove-Item -LiteralPath $tmpHosts -Force -ErrorAction SilentlyContinue }

if (-not $NoRestart -and ($ipsetUpdated -or $hostsDlOk)) {
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $svcZ -and $svcZ.Status -eq 'Running') {
        Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        Write-Host '        [OK] Служба zapret перезапущена с новыми списками' -ForegroundColor Green
    }
}

Write-Host ("  [OK] IPSet: {0} · Hosts: {1}" -f $ipsetSummary, $hostsSummary) -ForegroundColor Green
Write-Host ''
if ($dlOk -or $hostsDlOk) { exit 0 } else { exit 2 }
