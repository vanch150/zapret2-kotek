param(
    [string]$Root = '',
    [switch]$NoRestart
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
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

# Unique GUID temp directory (mitigates predictable %TEMP% symlink/TOCTOU)
$tmpDir = Join-Path $env:TEMP ('z2_lists_' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$tmpIpset = Join-Path $tmpDir 'ipset_dl.txt'
$tmpHosts = Join-Path $tmpDir 'hosts_dl.txt'

function Write-Z2FileAtomic([string]$TargetPath, [string]$Content) {
    $parentDir = Split-Path -Parent $TargetPath
    $tmpWrite = Join-Path $parentDir (([System.IO.Path]::GetFileName($TargetPath)) + '.z2tmp_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
        [System.IO.File]::WriteAllText($tmpWrite, $Content, $utf8NoBom)
        if (Test-Path -LiteralPath $TargetPath) {
            try {
                [System.IO.File]::Replace($tmpWrite, $TargetPath, $null, $true)
            } catch {
                Move-Item -LiteralPath $tmpWrite -Destination $TargetPath -Force -ErrorAction Stop
            }
        } else {
            Move-Item -LiteralPath $tmpWrite -Destination $TargetPath -Force -ErrorAction Stop
        }
    } finally {
        if (Test-Path -LiteralPath $tmpWrite) { Remove-Item -LiteralPath $tmpWrite -Force -ErrorAction SilentlyContinue }
    }
}

function Test-Z2PublicIp([System.Net.IPAddress]$Ip) {
    if ($null -eq $Ip) { return $false }
    if ($Ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($Ip.IsIPv4MappedToIPv6) {
            return (Test-Z2PublicIp $Ip.MapToIPv4())
        }
        if ($Ip.Equals([System.Net.IPAddress]::IPv6Loopback) -or $Ip.Equals([System.Net.IPAddress]::IPv6None) -or $Ip.Equals([System.Net.IPAddress]::IPv6Any)) { return $false }
        if ($Ip.IsIPv6LinkLocal -or $Ip.IsIPv6SiteLocal -or $Ip.IsIPv6Multicast -or $Ip.IsIPv6Teredo) { return $false }
        $b6 = $Ip.GetAddressBytes()
        if (($b6[0] -band 0xFE) -eq 0xFC) { return $false } # fc00::/7 ULA
        return $true
    }
    if ($Ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Ip.GetAddressBytes()
        if ($b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
        if ($b[0] -ge 224) { return $false }
        return $true
    }
    return $false
}

function Write-Z2LinesAtomic([string]$TargetPath, [string[]]$Lines) {
    $content = ($Lines -join "`r`n") + "`r`n"
    Write-Z2FileAtomic $TargetPath $content
}

function Download-Z2TextFile([string]$Url, [string]$OutFile, [int]$MinBytes = 10, [int]$TimeoutSec = 8) {
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $curlExe) {
        & $curlExe --proto =https --proto-redir =https -L -s -f --max-time $TimeoutSec -o $OutFile $Url 2>$null
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

$dlOk = $false
$ipsetUpdated = $false
$sysListsUpdated = 0
$hostsDlOk = $false
$ipsetSummary = 'не обновлён'
$sysListsSummary = 'без изменений'
$hostsSummary = 'не обновлён'

try {
    Write-Host '  [1/3] Загрузка свежего списка IPSet...' -ForegroundColor Yellow
    $dlOk = Download-Z2TextFile $ipsetUrl $tmpIpset 500 8

    if ($dlOk) {
        function Test-Z2ValidCidr([string]$Entry, [bool]$RequirePrefixForV6 = $true) {
            if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
            $parts = $Entry -split '/', 2
            $ipObj = $null
            if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ipObj)) { return $false }
            $isV6 = ($ipObj.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6)
            if ($parts.Count -eq 1) { return (-not $isV6) -or (-not $RequirePrefixForV6) }
            $pfx = -1
            if (-not [int]::TryParse($parts[1], [ref]$pfx)) { return $false }
            if ($isV6) { return ($pfx -ge 0 -and $pfx -le 128) }
            return ($pfx -ge 0 -and $pfx -le 32)
        }
        $cidrV4Rx = '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'
        $cidrV6Rx = '^[0-9a-fA-F]*:[0-9a-fA-F:]+/[0-9]{1,3}$'
        $lines = @{}
        $ordered = New-Object System.Collections.Generic.List[string]
        foreach ($l in (Get-Content -LiteralPath $tmpIpset -Encoding UTF8)) {
            $t = ($l -replace '\s*#.*$', '').Trim()
            if ((Test-Z2ValidCidr $t $true) -and (-not $lines.ContainsKey($t))) { $lines[$t] = $true; $ordered.Add($t) }
        }
        if ($ordered.Count -ge 50) {
            foreach ($s in $extraSubnets) {
                if (-not $lines.ContainsKey($s)) { $lines[$s] = $true; $ordered.Add($s) }
            }
            $curIpsetRaw = if (Test-Path -LiteralPath $ipsetFile) { ([string](Get-Content -LiteralPath $ipsetFile -Raw -ErrorAction SilentlyContinue)).Trim() } else { 'loaded' }
            $isSpecialMode = ($curIpsetRaw -eq '' -or $curIpsetRaw -eq '203.0.113.113/32')
            $ip2net = Join-Path $Root 'bin\ip2net.exe'
            $finalSubnets = $ordered.ToArray()
            if (Test-Path -LiteralPath $ip2net) {
                try {
                    # Separate IPv4 and IPv6 aggregation so IPv6 subnets are preserved (ID 4.11)
                    $rawV4 = @($ordered | Where-Object { $_ -match $cidrV4Rx })
                    $rawV6 = @($ordered | Where-Object { $_ -match $cidrV6Rx })
                    $aggV4 = @($rawV4 | & $ip2net 2>$null | Where-Object { $_ -match $cidrV4Rx })
                    $aggV6 = $rawV6
                    if ($rawV6.Count -gt 0) {
                        $tryV6 = @($rawV6 | & $ip2net -6 2>$null | Where-Object { $_ -match $cidrV6Rx })
                        if ($tryV6.Count -gt 0) { $aggV6 = $tryV6 }
                    }
                    if ($aggV4.Count -ge 50) {
                        $finalSubnets = @($aggV4) + @($aggV6)
                    }
                } catch {}
            }
            if ($isSpecialMode) {
                Write-Z2LinesAtomic $ipsetBak $finalSubnets
            } else {
                Write-Z2LinesAtomic $ipsetFile $finalSubnets
                Copy-Item -LiteralPath $ipsetFile -Destination $ipsetBak -Force -ErrorAction SilentlyContinue
            }
            $ipsetUpdated = $true
            $ipsetSummary = "$($finalSubnets.Count) подсетей"
            Write-Host ("        [OK] IPSet обновлён ({0} подсетей)" -f $finalSubnets.Count) -ForegroundColor Green
        } else {
            $dlOk = $false
            $ipsetSummary = 'ошибка формата'
            Write-Host '        [!] Скачанный IPSet не прошёл проверку CIDR — оставлен текущий локальный список' -ForegroundColor Yellow
        }
    } else {
        $ipsetSummary = 'ошибка загрузки'
        Write-Host '        [!] Не удалось скачать IPSet — оставлен текущий локальный список' -ForegroundColor Yellow
    }

    Write-Host '  [2/3] Обновление системных списков (пользовательские не трогаются)...' -ForegroundColor Yellow
    $sysListSpecs = @(
        @{ Name = 'list-general.txt';  Kind = 'domain'; MinCount = 10 },
        @{ Name = 'list-google.txt';   Kind = 'domain'; MinCount = 5  },
        @{ Name = 'list-exclude.txt';  Kind = 'domain'; MinCount = 20 },
        @{ Name = 'ipset-exclude.txt'; Kind = 'cidr';   MinCount = 5  },
        @{ Name = 'ai-dns-pool.txt';   Kind = 'pool';   MinCount = 1  }
    )
    $domLineRx  = '^[\^!]?[A-Za-z0-9._-]+$'
    $cidrLineRx = '^(\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?|[0-9a-fA-F]*:[0-9a-fA-F:]+(/\d{1,3})?)$'
    $privPoolIpRx = '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|22[4-9]\.|23\d\.|24\d\.|25[0-5]\.)'

    foreach ($spec in $sysListSpecs) {
        $tmpSys = Join-Path $tmpDir ("sys_" + $spec.Name)
        $urlSys = "https://raw.githubusercontent.com/$z2Repo/main/lists/$($spec.Name)"
        if (Download-Z2TextFile $urlSys $tmpSys 30 6) {
            if ($spec.Kind -eq 'pool') {
                $valid = @(Get-Content -LiteralPath $tmpSys -Encoding UTF8 | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object {
                    if ($_ -notmatch '^[A-Za-z0-9 _.-]{1,40}\|[0-9., ]+$') { return $false }
                    $pp = $_ -split '\|', 2
                    $ipParts = @($pp[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($ipParts.Count -eq 0) { return $false }
                    foreach ($ipItem in $ipParts) {
                        $parsedIp = $null
                        if (-not [System.Net.IPAddress]::TryParse($ipItem, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
                        $normIp = $parsedIp.IPAddressToString
                        if ($normIp -match $privPoolIpRx) { return $false }
                    }
                    return $true
                })
            } else {
                $rx = if ($spec.Kind -eq 'cidr') { $cidrLineRx } else { $domLineRx }
                $valid = @(Get-Content -LiteralPath $tmpSys -Encoding UTF8 | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object { $_ -match $rx })
            }
            if ($valid.Count -ge $spec.MinCount) {
                Write-Z2LinesAtomic (Join-Path $ListsDir $spec.Name) $valid
                $sysListsUpdated++
            }
        }
        if (Test-Path -LiteralPath $tmpSys) { Remove-Item -LiteralPath $tmpSys -Force -ErrorAction SilentlyContinue }
    }
    $sysListsSummary = if ($sysListsUpdated -gt 0) { "обновлено $sysListsUpdated/$($sysListSpecs.Count)" } else { 'без изменений' }
    if ($sysListsUpdated -gt 0) {
        Write-Host ("        [OK] Системные списки обновлены ({0}/{1})" -f $sysListsUpdated, $sysListSpecs.Count) -ForegroundColor Green
    } else {
        Write-Host '        [!] Системные списки не удалось скачать — оставлены локальные' -ForegroundColor Yellow
    }

    $syncScript = Join-Path $PSScriptRoot 'sync_lists.ps1'
    if (Test-Path -LiteralPath $syncScript) { & $syncScript -Root $Root }

    Write-Host '  [3/3] Проверка обновлений системного файла hosts...' -ForegroundColor Yellow
    $hostsSource = ''
    $hostsFromNet = $false

    # Priority 1: User's own repo lists/hosts-extra.txt
    if (Download-Z2TextFile $hostsCustomUrl $tmpHosts 10 6) {
        $hostsDlOk = $true
        $hostsFromNet = $true
        $hostsSource = $z2Repo
    }
    # Priority 2: Official Flowseal .service/hosts (network)
    if (-not $hostsDlOk -and (Download-Z2TextFile $hostsFlowsealUrl $tmpHosts 10 8)) {
        $hostsDlOk = $true
        $hostsFromNet = $true
        $hostsSource = 'Flowseal'
    }
    # Priority 3: Local lists\hosts-extra.txt (offline fallback — does not mask network failure)
    if (-not $hostsDlOk -and (Test-Path -LiteralPath $localHostsExtra) -and (Get-Item -LiteralPath $localHostsExtra).Length -ge 10) {
        Copy-Item -LiteralPath $localHostsExtra -Destination $tmpHosts -Force -ErrorAction SilentlyContinue
        $hostsDlOk = $true
        $hostsSource = 'локальный hosts-extra.txt'
    }

    if ($hostsDlOk) {
        try {
            $sysHosts = "$env:SystemRoot\System32\drivers\etc\hosts"
            $hostsBak = "$sysHosts.zapret2.bak"
            # Strict read with -ErrorAction Stop so locked/unreadable hosts is NEVER wiped clean (ID 4.3)
            $rawCur = ''
            if (Test-Path -LiteralPath $sysHosts) {
                $hostsLen = (Get-Item -LiteralPath $sysHosts -ErrorAction Stop).Length
                $rawCur = Get-Content -LiteralPath $sysHosts -Raw -Encoding UTF8 -ErrorAction Stop
                if ($hostsLen -gt 0 -and $null -eq $rawCur) { throw "Не удалось прочитать системный файл hosts" }
                if ($null -eq $rawCur) { $rawCur = '' }
            }
            $hostLineRx = '^((\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]*:[0-9a-fA-F:]+)\s+[A-Za-z0-9._-]+(\s+[A-Za-z0-9._-]+)*$'
            # Strict domain allowlist (prevents DNS-hijacking of banking/mail/gov/google/steam/yandex)
            $allowedDomRx = if ($hostsSource -eq 'Flowseal') {
                '(?i)(^|\.)(telegram\.org|t\.me|telegram\.me|telegram\.dog|telegram\.space|telesco\.pe|tg\.dev|discord\.com|discordapp\.com|discordapp\.net|discord\.gg|discord\.media)$'
            } else {
                '(?i)(^|\.)(telegram\.org|t\.me|telegram\.me|telegram\.dog|telegram\.space|telesco\.pe|tg\.dev|discord\.com|discordapp\.com|discordapp\.net|discord\.gg|discord\.media|github\.com|githubusercontent\.com)$'
            }
            $newLines = @(Get-Content -LiteralPath $tmpHosts -Encoding UTF8 | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object {
                if ($_ -notmatch $hostLineRx) { return $false }
                $toks = $_ -split '\s+'
                $parsedH = $null
                if (-not [System.Net.IPAddress]::TryParse($toks[0], [ref]$parsedH)) { return $false }
                if (-not (Test-Z2PublicIp $parsedH)) { return $false }
                for ($ti = 1; $ti -lt $toks.Count; $ti++) {
                    if ($toks[$ti] -notmatch $allowedDomRx) { return $false }
                }
                return $true
            })
            if ($newLines.Count -gt 0) {
                if ((Test-Path -LiteralPath $sysHosts) -and -not (Test-Path -LiteralPath $hostsBak)) {
                    Copy-Item -LiteralPath $sysHosts -Destination $hostsBak -Force -ErrorAction SilentlyContinue
                }
                $cleaned = [regex]::Replace($rawCur, "(?ms)\r?\n?# --- Zapret2 Auto-Updated Hosts ---.*?# --- End Zapret2 Hosts ---\r?\n?", "")
                $block = "`r`n# --- Zapret2 Auto-Updated Hosts ---`r`n" + ($newLines -join "`r`n") + "`r`n# --- End Zapret2 Hosts ---`r`n"
                $finalHosts = $cleaned.TrimEnd() + $block
                try { Write-Z2FileAtomic $sysHosts $finalHosts } catch { [System.IO.File]::WriteAllText($sysHosts, $finalHosts, $utf8NoBom) }
                & "$env:SystemRoot\System32\ipconfig.exe" /flushdns >$null 2>&1
                $hostsSummary = "обновлён ($($newLines.Count) зап., $hostsSource)"
                Write-Host ("        [OK] Системный файл hosts обновлён ({0} записей, источник: {1})" -f $newLines.Count, $hostsSource) -ForegroundColor Green
            } else {
                $hostsSummary = 'актуален'
                Write-Host '        [OK] Системный файл hosts уже актуален' -ForegroundColor Green
            }
        } catch {
            $hostsSummary = 'нет прав записи'
            Write-Host ("        [!] Не удалось обновить hosts: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        $hostsSummary = 'не удалось скачать'
        Write-Host '        [!] Не удалось скачать список hosts' -ForegroundColor Yellow
    }
} finally {
    if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $NoRestart -and ($ipsetUpdated -or $sysListsUpdated -gt 0)) {
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $svcZ) {
        try {
            if ($svcZ.Status -eq 'Running') {
                Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
                Write-Host '        [OK] Служба zapret перезапущена с новыми списками' -ForegroundColor Green
            }
        } finally {
            try { $svcZ.Dispose() } catch {}
        }
    }
}

Write-Host ("  [OK] IPSet: {0} · Списки: {1} · Hosts: {2}" -f $ipsetSummary, $sysListsSummary, $hostsSummary) -ForegroundColor Green
Write-Host ''
if ($dlOk -or $sysListsUpdated -gt 0 -or $hostsFromNet) { exit 0 } else { exit 2 }
