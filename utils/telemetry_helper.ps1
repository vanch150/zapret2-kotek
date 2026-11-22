# Zapret2 Kotek — Anonymous Opt-In Telemetry Helper (utils/telemetry_helper.ps1)
# Strictly opt-in (requires utils\telemetry.enabled unless explicitly triggered by user in Diagnostics).

function Get-Z2TelemetryEndpoint([string]$RootPath) {
    $cf = Join-Path $RootPath 'utils\telemetry.conf'
    if (-not (Test-Path -LiteralPath $cf)) { return '' }
    foreach ($l in (Get-Content -LiteralPath $cf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*endpoint\s*=\s*(https://\S+)\s*$') {
            return $matches[1].Trim()
        }
    }
    return ''
}

function Test-Z2TelemetryEnabled([string]$RootPath) {
    return (Test-Path -LiteralPath (Join-Path $RootPath 'utils\telemetry.enabled'))
}

function Get-Z2TelemetryAnonId([string]$RootPath) {
    $idFile = Join-Path $RootPath 'utils\telemetry.id'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $idFile) {
        $cur = ([string](Get-Content -LiteralPath $idFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($cur -match '^[0-9a-f]{12}$') { return $cur }
    }
    $newId = [Guid]::NewGuid().ToString('N').Substring(0, 12).ToLowerInvariant()
    try { [System.IO.File]::WriteAllText($idFile, "$newId`r`n", $utf8NoBom) } catch {}
    return $newId
}

function Remove-Z2SensitiveText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $r = $Text
    $r = [regex]::Replace($r, '[A-Za-z]:[/\\]Users[/\\][^/\\\r\n"'']+', '<USER_DIR>')
    $r = [regex]::Replace($r, '[0-9a-fA-F]{32,}', '<REDACTED>')
    $r = [regex]::Replace($r, '(?i)(secret\s*[:=]\s*)\S+', '$1<REDACTED>')
    $r = [regex]::Replace($r, '(?i)(cfproxy_(?:worker_)?domain\s*[:=]\s*)\S+', '$1<REDACTED>')
    $r = [regex]::Replace($r, '://[^@\s]+@', '://<REDACTED>@')
    if ($r.Length -gt 7200) { $r = $r.Substring(0, 7200) + "`n...[truncated]" }
    return $r
}

function Get-Z2TelemetrySnapshot([string]$RootPath) {
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        # Services & dependencies
        $zSt = 'NONE'; $zDep = ''
        $sZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $sZ) { $zSt = [string]$sZ.Status; try { $sZ.Dispose() } catch {} }
        try {
            $depArr = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -Name 'DependOnService' -ErrorAction SilentlyContinue).DependOnService
            if ($depArr) { $zDep = ($depArr -join ',') }
        } catch {}
        $tSt = 'NONE'
        $sT = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
        if ($null -ne $sT) { $tSt = [string]$sT.Status; try { $sT.Dispose() } catch {} }
        $wProc = if (Get-Process -Name 'winws2' -ErrorAction SilentlyContinue) { 'up' } else { 'down' }
        $lines.Add("Services: zapret=$zSt(winws2=$wProc,dep=$(if ($zDep) { $zDep } else { 'none' })) | tgws=$tSt")

        # service.conf summary (no paths or secrets)
        $confP = Join-Path $RootPath 'bin\service.conf'
        if (Test-Path -LiteralPath $confP) {
            $cRaw = [string](Get-Content -LiteralPath $confP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            $hasNlm = ($cRaw -match '(?m)^--nlm-filter=')
            $hasNlmNeg = ($cRaw -match '(?m)^--nlm-filter-neg=1')
            $hasCirc = ($cRaw -match '--lua-desync=circular')
            $hasMd5 = ($cRaw -match 'tcp_md5')
            $hasQuicG = ($cRaw -match '(?i)list-google\.txt')
            $hasKf = ($cRaw -match '(?m)^--wf-raw-part=')
            $nlmNames = ''
            $nfP = Join-Path $RootPath 'utils\nlm_filter.names'
            if (Test-Path -LiteralPath $nfP) {
                $nlmNames = ([string](Get-Content -LiteralPath $nfP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
            }
            $hasRawVpn = ($cRaw -match '(?m)^--wf-raw-filter=')
            $vpnIfNm = ''
            $vIfP = Join-Path $RootPath 'utils\vpn_ifidx.names'
            if (Test-Path -LiteralPath $vIfP) { $vpnIfNm = ([string](Get-Content -LiteralPath $vIfP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() }
            $vpnFiltSummary = if ($hasRawVpn) { "WinDivert($vpnIfNm)" } elseif ($hasNlm) { "LegacyNLM($nlmNames)" } else { 'OFF' }
            $lines.Add("Conf: VpnFilter=$vpnFiltSummary | circular=$hasCirc | tcp_md5=$hasMd5 | quic_google=$hasQuicG | kf=$hasKf")
        } else {
            $lines.Add("Conf: missing")
        }

        # Flags & last autosetup
        $ahOn = Test-Path -LiteralPath (Join-Path $RootPath 'utils\autohostlist.enabled')
        $ahCnt = 0
        $ahFile = Join-Path $RootPath 'lists\list-auto.txt'
        if (Test-Path -LiteralPath $ahFile) {
            $ahCnt = @(Get-Content -LiteralPath $ahFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' }).Count
        }
        $wOn = Test-Path -LiteralPath (Join-Path $RootPath 'utils\warp_unblock.enabled')
        $gfOn = Test-Path -LiteralPath (Join-Path $RootPath 'utils\game_filter.enabled')
        $nlmAutoOn = Test-Path -LiteralPath (Join-Path $RootPath 'utils\nlm_auto.enabled')
        $lines.Add("Flags: autohost=$ahOn($ahCnt) | warp=$wOn | gamefilter=$gfOn | nlm_auto=$nlmAutoOn")

        # Default browser (from HTTPS UserChoice ProgId)
        try {
            $progId = [string](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -Name 'ProgId' -ErrorAction SilentlyContinue).ProgId
            if ($progId) {
                $defBr = if ($progId -match '(?i)Chrome') { 'Chrome' }
                         elseif ($progId -match '(?i)Firefox') { 'Firefox' }
                         elseif ($progId -match '(?i)MSEdge') { 'Edge' }
                         elseif ($progId -match '(?i)Yandex') { 'Yandex' }
                         elseif ($progId -match '(?i)Brave') { 'Brave' }
                         elseif ($progId -match '(?i)Opera') { 'Opera' }
                         elseif ($progId -match '(?i)Vivaldi') { 'Vivaldi' }
                         else { $progId }
                $lines.Add("DefaultBrowser: $defBr")
            }
        } catch {}

        # Network profile without private IPs: transport, PPPoE, IPv6, DNS class, active VPN classes
        $vpnClassSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $hasEth = $false; $hasWifi = $false; $hasPpp = $false; $hasIpv6 = $false
        $pubDnsSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $pubDnsMap = @{ '8.8.8.8'='8.8.8.8'; '8.8.4.4'='8.8.4.4'; '1.1.1.1'='1.1.1.1'; '1.0.0.1'='1.0.0.1'; '9.9.9.9'='9.9.9.9'; '77.88.8.8'='77.88.8.8'; '94.140.14.14'='AdGuard' }
        try {
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
                if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
                $nType = $ni.NetworkInterfaceType
                $nInfo = "$($ni.Name) $($ni.Description)"
                if ($nType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) { $hasEth = $true }
                elseif ($nType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { $hasWifi = $true }
                elseif ($nType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp) { $hasPpp = $true }
                try {
                    $ipProps = $ni.GetIPProperties()
                    foreach ($ua in $ipProps.UnicastAddresses) {
                        if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $ua.Address.IsIPv6LinkLocal -and -not $ua.Address.IsIPv6SiteLocal) {
                            $hasIpv6 = $true
                        }
                    }
                    foreach ($da in $ipProps.DnsAddresses) {
                        $ds = $da.ToString()
                        if ($pubDnsMap.ContainsKey($ds)) { [void]$pubDnsSet.Add($pubDnsMap[$ds]) }
                    }
                } catch {}
                if ($nInfo -match '(?i)WARP|Cloudflare') { [void]$vpnClassSet.Add('WARP') }
                elseif ($nInfo -match '(?i)WireGuard|Amnezia') { [void]$vpnClassSet.Add('WireGuard') }
                elseif ($nInfo -match '(?i)Happ|Sing-box|Hiddify|Nekoray|v2ray|Outline') { [void]$vpnClassSet.Add('TUN/Proxy') }
                elseif ($nInfo -match '(?i)OpenVPN|\bTAP\b') { [void]$vpnClassSet.Add('OpenVPN/TAP') }
                elseif ($nInfo -match '(?i)Radmin|Hamachi|ZeroTier|Tailscale') { [void]$vpnClassSet.Add('MeshLAN') }
                elseif ($nInfo -match '(?i)Wintun|\bTUN\b|Proton|Nord|Mullvad|Cisco|Fortinet|VPN') { [void]$vpnClassSet.Add('VPN/TUN') }
            }
        } catch {}
        $netKind = if ($hasWifi -and $hasEth) { 'Eth+WiFi' } elseif ($hasWifi) { 'Wi-Fi' } elseif ($hasEth) { 'Ethernet' } else { 'Other' }
        $dnsLbl = if ($pubDnsSet.Count -gt 0) { ($pubDnsSet -join '/') } else { 'ISP' }
        $netLine = "Net: $netKind | PPPoE=$(if ($hasPpp) { 'yes' } else { 'no' }) | IPv6=$(if ($hasIpv6) { 'yes' } else { 'no' }) | DNS=$dnsLbl"
        if ($vpnClassSet.Count -gt 0) { $netLine += " | UpVPN=" + ($vpnClassSet -join ',') }
        $lines.Add($netLine)

        # Top-3 strategies from utils\strategy_scores.json
        $scFile = Join-Path $RootPath 'utils\strategy_scores.json'
        if (Test-Path -LiteralPath $scFile) {
            try {
                $scObj = Get-Content -LiteralPath $scFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($null -ne $scObj) {
                    $scList = New-Object System.Collections.Generic.List[object]
                    foreach ($pr in $scObj.PSObject.Properties) {
                        $v = $pr.Value
                        if ($null -ne $v -and $null -ne $v.total -and [int]$v.total -gt 0) {
                            $scList.Add([PSCustomObject]@{
                                Name   = [System.IO.Path]::GetFileNameWithoutExtension($pr.Name)
                                Ok     = [int]$v.ok
                                Total  = [int]$v.total
                                Freeze = [bool]$v.freeze
                                YtF    = if ($null -ne $v.PSObject.Properties['ytF']) { [bool]$v.ytF } else { $null }
                                CfF    = if ($null -ne $v.PSObject.Properties['cfF']) { [bool]$v.cfF } else { $null }
                                Ms     = if ($null -ne $v.ms) { [int]$v.ms } else { 9999 }
                            })
                        }
                    }
                    $top3 = @($scList | Sort-Object @{Expression='Ok';Descending=$true}, @{Expression='Freeze';Descending=$true}, @{Expression='Ms';Ascending=$true} | Select-Object -First 3)
                    if ($top3.Count -gt 0) {
                        $topStrs = @($top3 | ForEach-Object {
                            $fTag = if ($null -ne $_.YtF -or $null -ne $_.CfF) {
                                "ytF=$(if ($_.YtF) { 1 } else { 0 }),cfF=$(if ($_.CfF) { 1 } else { 0 })"
                            } else {
                                "f=$(if ($_.Freeze) { 1 } else { 0 })"
                            }
                            "$($_.Name)($($_.Ok)/$($_.Total),$fTag,$($_.Ms)ms)"
                        })
                        $lines.Add("Top3: " + ($topStrs -join ', '))
                    }
                }
            } catch {}
        }

        # Synthesized hybrid recipe from utils\last_hybrid.json (for regional strategy stats)
        $hybFile = Join-Path $RootPath 'utils\last_hybrid.json'
        if (Test-Path -LiteralPath $hybFile) {
            try {
                $hj = Get-Content -LiteralPath $hybFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($null -ne $hj) {
                    $hYt  = if ($hj.yt)  { [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.yt) }  else { '-' }
                    $hDc  = if ($hj.dc)  { [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.dc) }  else { '-' }
                    $hWeb = if ($hj.web) { [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.web) } else { '-' }
                    $hUdp = if ($hj.udp) { [string]$hj.udp } else { '-' }
                    $hWin = if ($hj.winner) { [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.winner) } else { 'custom_auto_synthesized' }
                    $hOk  = if ($null -ne $hj.ok) { [int]$hj.ok } else { 0 }
                    $hTot = if ($null -ne $hj.total) { [int]$hj.total } else { 0 }
                    $hYtF = if ($hj.ytF) { 1 } else { 0 }
                    $hCfF = if ($hj.cfF) { 1 } else { 0 }
                    $hMs  = if ($null -ne $hj.ms) { [int]$hj.ms } else { 0 }
                    $lines.Add("Hybrid: YT=$hYt + DC=$hDc + WEB=$hWeb | UDP=$hUdp | Winner=$hWin($hOk/$hTot,ytF=$hYtF,cfF=$hCfF,${hMs}ms)")
                }
            } catch {}
        }
    } catch {}
    return ($lines -join "`n")
}

function Get-Z2TelemetryPreview([string]$RootPath) {
    $ver = '1.1.1'
    $vf = Join-Path $RootPath 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = ([string](Get-Content -LiteralPath $vf -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($v) { $ver = $v }
    }
    $osBuild = ''
    try { $osBuild = [string][System.Environment]::OSVersion.Version.Build } catch {}
    $obj = [ordered]@{
        app      = 'zapret2-kotek'
        ver      = $ver
        id       = (Get-Z2TelemetryAnonId $RootPath)
        os       = "Win-$osBuild"
        event    = 'autosetup'
        strategy = 'general (ALT11).bat'
        score    = '15/17 (88%)'
        code     = 0
        detail   = 'Services: zapret=Running | Top3: ALT12(17/17,ytF=1,cfF=1,240ms) | Hybrid: YT=ALT12 + DC=ALT11 + WEB=wssize'
    }
    return ($obj | ConvertTo-Json -Depth 3)
}

function Send-Z2TelemetryEvent {
    param(
        [string]$RootPath,
        [string]$Event,
        [string]$Strategy = '',
        [string]$Score = '',
        [string]$Code = '',
        [string]$Detail = '',
        [switch]$ManualDiag
    )
    if (-not $ManualDiag -and -not (Test-Z2TelemetryEnabled $RootPath)) { return $false }
    $endpoint = Get-Z2TelemetryEndpoint $RootPath
    if (-not $endpoint) { return $false }

    # Anti-flood rate-limiting via utils\telemetry.state.json (no 24h cap: 15s per error/crash, 30s manual diag, 60s per event)
    $stateFile = Join-Path $RootPath 'utils\telemetry.state.json'
    $nowUnix = [int64]([DateTime]::UtcNow - (New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc))).TotalSeconds
    $stateMap = @{}
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $loaded = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($null -ne $loaded) {
                foreach ($p in $loaded.PSObject.Properties) { $stateMap[$p.Name] = [int64]$p.Value }
            }
        } catch {}
    }

    $rateKey = if ($ManualDiag) { 'diag' } elseif ($Event -in @('crash', 'error')) { "err_${Event}_${Code}" } else { "ev_$Event" }
    $minInterval = if ($ManualDiag) { 30 } elseif ($Event -in @('crash', 'error')) { 15 } else { 60 }
    if ($stateMap.ContainsKey($rateKey) -and (($nowUnix - $stateMap[$rateKey]) -lt $minInterval)) {
        return $false
    }

    $ver = '1.1.1'
    $vf = Join-Path $RootPath 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = ([string](Get-Content -LiteralPath $vf -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($v) { $ver = $v }
    }
    $osBuild = ''
    try { $osBuild = [string][System.Environment]::OSVersion.Version.Build } catch {}

    $payload = [ordered]@{
        app      = 'zapret2-kotek'
        ver      = $ver
        id       = (Get-Z2TelemetryAnonId $RootPath)
        os       = "Win-$osBuild"
        event    = $Event
        strategy = (Remove-Z2SensitiveText $Strategy)
        score    = (Remove-Z2SensitiveText $Score)
        code     = (Remove-Z2SensitiveText $Code)
        detail   = (Remove-Z2SensitiveText $Detail)
    }
    $jsonBody = $payload | ConvertTo-Json -Compress -Depth 3
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tmpBody = Join-Path $env:TEMP ("z2_tel_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
    $sentOk = $false
    try {
        [System.IO.File]::WriteAllText($tmpBody, $jsonBody, $utf8NoBom)
        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (Test-Path -LiteralPath $curlExe) {
            $httpCode = & $curlExe --proto =https --proto-redir =https -s -o NUL -w '%{http_code}' --max-time 3 -X POST -H 'Content-Type: application/json' --data-binary "@$tmpBody" $endpoint 2>$null
            if ($httpCode -match '^2\d\d$') { $sentOk = $true }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $r = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { $sentOk = $true }
        }
    } catch {
        $sentOk = $false
    } finally {
        if (Test-Path -LiteralPath $tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    }

    if ($sentOk) {
        $stateMap[$rateKey] = $nowUnix
        try {
            $stateJson = ([PSCustomObject]$stateMap) | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($stateFile, $stateJson, $utf8NoBom)
        } catch {}
    }
    return $sentOk
}
