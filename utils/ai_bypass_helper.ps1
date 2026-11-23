param(
    [string]$Action = 'status',
    [string]$Root = '',
    [string]$Provider = '',
    [string]$Services = ''
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'SilentlyContinue'
$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if ((Test-Path -LiteralPath $commonPath) -and -not (Get-Command Resolve-Z2Root -ErrorAction SilentlyContinue)) {
    . $commonPath
}
if (-not (Get-Command Test-Z2IsAdmin -ErrorAction SilentlyContinue)) {
    function Test-Z2IsAdmin {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $pr = New-Object Security.Principal.WindowsPrincipal($id)
            return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { return $false }
    }
}
$Root = if (Get-Command Resolve-Z2Root -ErrorAction SilentlyContinue) {
    Resolve-Z2Root $Root
} else {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $env:Z2_ROOT }
    $cleanR = if ($null -ne $Root) { $Root.Trim().Trim('"').Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($cleanR)) { $cleanR = Split-Path -Parent $PSScriptRoot }
    if ($cleanR -match '^[A-Za-z]:$') { $cleanR += '\' }
    try { [System.IO.Path]::GetFullPath($cleanR).TrimEnd('\', '/') + '\' } catch { $cleanR.TrimEnd('\', '/') + '\' }
}

$script:Z2AiNrptTag = 'Zapret2KotekAI'
$script:Z2AiCatalog = @(
    [PSCustomObject]@{
        Id        = 'gemini'
        Name      = 'Google Gemini'
        ProbeHost = 'gemini.google.com'
        Domains   = @(
            '.gemini.google.com',
            '.aistudio.google.com',
            '.generativelanguage.googleapis.com',
            '.alkalimakersuite-pa.clients6.google.com',
            '.proactivebackend-pa.googleapis.com',
            '.notebooklm.google.com',
            '.labs.google',
            '.ai.google.dev',
            '.makersuite.google.com'
        )
    },
    [PSCustomObject]@{
        Id        = 'chatgpt'
        Name      = 'ChatGPT / OpenAI'
        ProbeHost = 'chatgpt.com'
        Domains   = @(
            '.chatgpt.com',
            '.openai.com',
            '.oaistatic.com',
            '.oaiusercontent.com'
        )
    },
    [PSCustomObject]@{
        Id        = 'claude'
        Name      = 'Claude'
        ProbeHost = 'claude.ai'
        Domains   = @(
            '.claude.ai',
            '.claude.com',
            '.anthropic.com',
            '.claudeusercontent.com'
        )
    },
    [PSCustomObject]@{
        Id        = 'copilot'
        Name      = 'Copilot'
        ProbeHost = 'copilot.microsoft.com'
        Domains   = @(
            '.copilot.microsoft.com',
            '.sydney.bing.com'
        )
    },
    [PSCustomObject]@{
        Id        = 'grok'
        Name      = 'Grok (xAI)'
        ProbeHost = 'grok.com'
        Domains   = @(
            '.grok.com',
            '.x.ai'
        )
    },
    [PSCustomObject]@{
        Id        = 'perplexity'
        Name      = 'Perplexity'
        ProbeHost = 'perplexity.ai'
        Domains   = @(
            '.perplexity.ai'
        )
    },
    [PSCustomObject]@{
        Id        = 'ide_ai'
        Name      = 'Cursor / Windsurf'
        ProbeHost = 'cursor.com'
        Domains   = @(
            '.cursor.com',
            '.cursor.sh',
            '.windsurf.com',
            '.codeium.com'
        )
    },
    [PSCustomObject]@{
        Id        = 'antigravity'
        Name      = 'Google Antigravity'
        ProbeHost = 'daily-cloudcode-pa.googleapis.com'
        Domains   = @(
            '.antigravity.google',
            '.antigravity.google.com',
            '.antigravity-unleash.goog',
            '.cloudcode-pa.googleapis.com',
            '.daily-cloudcode-pa.googleapis.com',
            '.aicode.googleapis.com',
            '.businessaicode.googleapis.com',
            '.cloudaicompanion.googleapis.com',
            '.jetski-webchannel.googleapis.com',
            '.antigravity-cli-auto-updater-974169037036.us-central1.run.app',
            '.antigravity-hub-auto-updater-974169037036.us-central1.run.app'
        )
    }
)

function Get-Z2AiCustomDomains([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $customFile = Join-Path $RootPath 'lists\ai-custom-domains.txt'
    $out = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $customFile)) { return @() }
    $seen = @{}
    $domRx = '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'
    foreach ($rawLine in (Get-Content -LiteralPath $customFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($null -eq $rawLine) { continue }
        $t = ($rawLine -replace '#.*$', '').Trim().ToLowerInvariant()
        if (-not $t) { continue }
        $t = $t -replace '^https?://', ''
        $t = $t -replace '/.*$', ''
        $t = $t -replace ':\d+$', ''
        $t = $t.Trim()
        while ($t.StartsWith('*.')) { $t = $t.Substring(2) }
        $t = $t.TrimStart('.').TrimEnd('.')
        if ($t -match $domRx) {
            $norm = '.' + $t
            if (-not $seen.ContainsKey($norm)) { $seen[$norm] = $true; $out.Add($norm) }
        }
    }
    return $out.ToArray()
}

function Resolve-Z2AiServiceIds([string]$RawServices) {
    $validSet = @{}
    if (-not [string]::IsNullOrWhiteSpace($RawServices)) {
        foreach ($tok in ($RawServices -split '[,;\s]+')) {
            $id = $tok.Trim().ToLowerInvariant()
            if ($id) { $validSet[$id] = $true }
        }
    }
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($item in $script:Z2AiCatalog) {
        if ($validSet.ContainsKey($item.Id)) {
            $ordered.Add($item.Id)
        }
    }
    return $ordered.ToArray()
}

function Get-Z2AiSelectionInfo([string]$RootPath = '', [string]$RawServices = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $ids = @(Resolve-Z2AiServiceIds $RawServices)
    $entries = New-Object System.Collections.Generic.List[object]
    $domains = New-Object System.Collections.Generic.List[string]
    $seenDom = @{}
    $names   = New-Object System.Collections.Generic.List[string]
    $probes  = New-Object System.Collections.Generic.List[object]

    foreach ($item in $script:Z2AiCatalog) {
        if ($ids -contains $item.Id) {
            $entries.Add($item)
            $names.Add($item.Name)
            $probes.Add((New-Object PSObject -Property @{ Id = $item.Id; Name = $item.Name; Host = $item.ProbeHost }))
            foreach ($d in $item.Domains) {
                if (-not $seenDom.ContainsKey($d)) { $seenDom[$d] = $true; $domains.Add($d) }
            }
        }
    }

    $customDoms = @(Get-Z2AiCustomDomains $RootPath)
    foreach ($cd in $customDoms) {
        if (-not $seenDom.ContainsKey($cd)) { $seenDom[$cd] = $true; $domains.Add($cd) }
    }
    if ($probes.Count -eq 0 -and $customDoms.Count -gt 0) {
        $firstCustomHost = $customDoms[0].TrimStart('.')
        $probes.Add([PSCustomObject]@{ Id = 'custom'; Name = 'Свои домены'; Host = $firstCustomHost })
    }

    if ($customDoms.Count -gt 0) {
        $names.Add("Свои ($($customDoms.Count))")
    }
    $label = if ($names.Count -gt 0) { $names -join ', ' } else { 'не выбрано' }

    return (New-Object PSObject -Property @{
        ServiceIds     = [string[]]@($ids)
        ServiceEntries = [object[]]$entries.ToArray()
        CustomDomains  = [string[]]@($customDoms)
        Domains        = [string[]]$domains.ToArray()
        Label          = [string]$label
        ProbeHosts     = [object[]]$probes.ToArray()
    })
}

function Test-Z2PublicIpv4([string]$IpStr) {
    if ([string]::IsNullOrWhiteSpace($IpStr)) { return $false }
    $t = $IpStr.Trim()
    if ($t -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    $pIp = $null
    if (-not [System.Net.IPAddress]::TryParse($t, [ref]$pIp)) { return $false }
    if ($pIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    if ($t -match '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)') { return $false }
    return $true
}

function Get-Z2AiDnsPool([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $pool = New-Object System.Collections.Generic.List[object]
    $poolFile = Join-Path $RootPath 'lists\ai-dns-pool.txt'
    if (Test-Path -LiteralPath $poolFile) {
        foreach ($l in (Get-Content -LiteralPath $poolFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = ([string]$l).Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $parts = $t -split '\|', 2
            if ($parts.Count -eq 2) {
                $name = $parts[0].Trim()
                $ips  = @($parts[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { Test-Z2PublicIpv4 $_ })
                if ($name -and $ips.Count -gt 0) {
                    $pool.Add((New-Object PSObject -Property @{ Name = [string]$name; Ips = [string[]]@($ips) }))
                }
            }
        }
    }
    if ($pool.Count -eq 0) {
        $pool.Add((New-Object PSObject -Property @{ Name = 'Pereval';    Ips = @('153.80.200.170') }))
        $pool.Add((New-Object PSObject -Property @{ Name = 'GeoHide EU'; Ips = @('37.230.192.51') }))
        $pool.Add((New-Object PSObject -Property @{ Name = 'Malw.link';  Ips = @('179.254.166.171', '164.5.224.81') }))
    }
    return $pool
}

function Get-Z2AiBypassConf([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $allDefaultSvc = 'gemini,chatgpt,copilot,grok,perplexity,ide_ai'
    $cfg = [PSCustomObject]@{ Mode = 'auto'; ActiveName = ''; ActiveIps = ''; CustomDns = ''; Services = $allDefaultSvc }
    $cf = Join-Path $RootPath 'utils\ai_bypass.conf'
    $hasServicesKey = $false
    $confExists = (Test-Path -LiteralPath $cf)
    if ($confExists) {
        foreach ($l in (Get-Content -LiteralPath $cf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($l -match '^(?i)mode=(.*)$')            { $cfg.Mode       = $matches[1].Trim() }
            elseif ($l -match '^(?i)active_name=(.*)$') { $cfg.ActiveName = $matches[1].Trim() }
            elseif ($l -match '^(?i)active_ips=(.*)$')  { $cfg.ActiveIps  = $matches[1].Trim() }
            elseif ($l -match '^(?i)custom_dns=(.*)$')  { $cfg.CustomDns  = $matches[1].Trim() }
            elseif ($l -match '^(?i)services=(.*)$')    { $cfg.Services   = $matches[1].Trim(); $hasServicesKey = $true }
        }
        if (-not $hasServicesKey) {
            $cfg.Services = if (-not [string]::IsNullOrWhiteSpace($cfg.ActiveName)) { 'gemini' } else { $allDefaultSvc }
        }
    }
    return $cfg
}

function Save-Z2AiBypassConf([string]$RootPath, $Cfg) {
    $cf = Join-Path $RootPath 'utils\ai_bypass.conf'
    $svcVal = ''
    if ($null -ne $Cfg.PSObject.Properties['Services'] -and $null -ne $Cfg.Services) {
        $svcVal = [string]$Cfg.Services
    }
    $lines = @(
        "mode=$($Cfg.Mode)",
        "active_name=$($Cfg.ActiveName)",
        "active_ips=$($Cfg.ActiveIps)",
        "custom_dns=$($Cfg.CustomDns)",
        "services=$svcVal"
    )
    [System.IO.File]::WriteAllLines($cf, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

$script:Z2AiNrptRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig'
$script:Z2AiVpnRx = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|\b(TAP|TUN)\b|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'
$script:Z2AiVpnExcludeRx = 'ExitLag|Hyper-V|vEthernet|VMware|VirtualBox|Bluetooth|Loopback|Pseudo'

function Invoke-Z2FlushDnsFast {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\ipconfig.exe"
        $psi.Arguments = '/flushdns'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $p) {
            try {
                if (-not $p.WaitForExit(3000)) {
                    try { $p.Kill() } catch {}
                }
            } finally {
                try { $p.Dispose() } catch {}
            }
        }
    } catch {}
}

function Get-Z2AiNrptRegistryRules {
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $script:Z2AiNrptRegPath) {
        try {
            foreach ($sub in @(Get-ChildItem -LiteralPath $script:Z2AiNrptRegPath -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
                if ($null -ne $props -and [string]$props.Comment -eq $script:Z2AiNrptTag) {
                    $nsRaw = [string]$props.GenericDNSServers
                    $nsArr = @($nsRaw -split '[;,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $domArr = @($props.Name | ForEach-Object { [string]$_ } | Where-Object { $_ })
                    $list.Add([PSCustomObject]@{
                        KeyPath     = $sub.PSPath
                        KeyName     = $sub.PSChildName
                        Domains     = [string[]]$domArr
                        NameServers = [string[]]$nsArr
                    })
                }
            }
            return $list.ToArray()
        } catch {}
    }
    try {
        foreach ($r in @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:Z2AiNrptTag })) {
            $list.Add([PSCustomObject]@{
                KeyPath     = ''
                KeyName     = [string]$r.Name
                Domains     = [string[]]@($r.Namespace)
                NameServers = [string[]]@($r.NameServers)
            })
        }
    } catch {}
    return $list.ToArray()
}

function Get-Z2ActiveVpnInfo {
    $names = New-Object System.Collections.Generic.List[string]
    $seen  = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $nName = [string]$ni.Name
            $nDesc = [string]$ni.Description
            if ($nName -match $script:Z2AiVpnExcludeRx -or $nDesc -match $script:Z2AiVpnExcludeRx) { continue }
            $isVpn = ($nName -match $script:Z2AiVpnRx) -or
                     ($nDesc -match $script:Z2AiVpnRx)
            if ($isVpn) {
                $disp = if ($nName) { $nName } else { $nDesc }
                if ($disp -and $seen.Add($disp)) { $names.Add($disp) }
            }
        }
    } catch {}
    try {
        $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($null -ne $inet -and [int]$inet.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$inet.ProxyServer)) {
            $psrv = ([string]$inet.ProxyServer).Trim()
            if ($psrv -notmatch '^(?:socks=)?127\.0\.0\.1:1443$') {
                $lbl = "Системный прокси ($psrv)"
                if ($seen.Add($lbl)) { $names.Add($lbl) }
            }
        }
    } catch {}
    return [PSCustomObject]@{
        Active = ($names.Count -gt 0)
        Names  = [string[]]$names.ToArray()
        Label  = ($names -join ', ')
    }
}

function Restore-Z2AiBypassFast([string]$RootPath = '', [string[]]$Domains = @(), [string[]]$NameServers = @()) {
    if (-not (Test-Z2IsAdmin)) { return $false }
    if (-not $RootPath) { $RootPath = $Root }
    if ($Domains.Count -eq 0 -or $NameServers.Count -eq 0) { return $false }
    [void](Disable-Z2AiBypass $RootPath)
    try {
        if (-not (Test-Path -LiteralPath $script:Z2AiNrptRegPath)) {
            New-Item -Path $script:Z2AiNrptRegPath -Force -ErrorAction Stop | Out-Null
        }
        $nsStr = ($NameServers -join ';')
        foreach ($dom in $Domains) {
            if ([string]::IsNullOrWhiteSpace($dom)) { continue }
            $guidKey = Join-Path $script:Z2AiNrptRegPath ('{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}')
            New-Item -Path $guidKey -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $guidKey -Name 'Version' -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $guidKey -Name 'ConfigOptions' -PropertyType DWord -Value 8 -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $guidKey -Name 'Name' -PropertyType MultiString -Value ([string[]]@([string]$dom)) -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $guidKey -Name 'GenericDNSServers' -PropertyType String -Value $nsStr -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $guidKey -Name 'Comment' -PropertyType String -Value $script:Z2AiNrptTag -Force -ErrorAction Stop | Out-Null
        }
        Invoke-Z2FlushDnsFast
        return $true
    } catch {
        return $false
    }
}

function Get-Z2AiBypassState([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $rules = @(Get-Z2AiNrptRegistryRules)
    $cfg = Get-Z2AiBypassConf $RootPath
    $ipList  = New-Object System.Collections.Generic.List[string]
    $seenIp  = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $domList = New-Object System.Collections.Generic.List[string]
    $seenDom = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if ($rules.Count -gt 0) {
        foreach ($r in $rules) {
            foreach ($ns in @($r.NameServers)) {
                $nsT = ([string]$ns).Trim()
                if ($nsT -and $seenIp.Add($nsT)) { $ipList.Add($nsT) }
            }
            foreach ($d in @($r.Domains)) {
                $dT = ([string]$d).Trim()
                if ($dT -and $seenDom.Add($dT)) { $domList.Add($dT) }
            }
        }
    }
    $ips = $ipList.ToArray()

    $svcIds = @()
    $svcLabel = ''
    $customCount = 0
    $activeName = ''

    if ($rules.Count -gt 0) {
        $activeDomSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($d in $domList) {
            $normD = '.' + $d.Trim().TrimStart('.').ToLowerInvariant()
            [void]$activeDomSet.Add($normD)
        }
        $matchedSvcIds = New-Object System.Collections.Generic.List[string]
        $matchedNames  = New-Object System.Collections.Generic.List[string]
        $allCatDomSet  = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $script:Z2AiCatalog) {
            $itemMatched = $false
            foreach ($cd in @($item.Domains)) {
                $normCd = '.' + ([string]$cd).Trim().TrimStart('.').ToLowerInvariant()
                [void]$allCatDomSet.Add($normCd)
                if ($activeDomSet.Contains($normCd)) { $itemMatched = $true }
            }
            if ($itemMatched) {
                $matchedSvcIds.Add([string]$item.Id)
                $matchedNames.Add([string]$item.Name)
            }
        }
        foreach ($ad in $activeDomSet) {
            if (-not $allCatDomSet.Contains($ad)) { $customCount++ }
        }
        if ($customCount -gt 0) {
            $matchedNames.Add("Свои ($customCount)")
        }
        $svcIds = $matchedSvcIds.ToArray()
        $svcLabel = if ($matchedNames.Count -gt 0) { $matchedNames -join ', ' } else { 'не выбрано' }

        $pool = Get-Z2AiDnsPool $RootPath
        $matchedNodeName = ''
        if ($ips.Count -gt 0) {
            foreach ($p in $pool) {
                if ($p.Ips -contains $ips[0]) { $matchedNodeName = [string]$p.Name; break }
            }
        }
        if ($cfg.ActiveName -and $ips.Count -gt 0 -and (@($cfg.ActiveIps -split ',\s*') -contains $ips[0])) {
            $activeName = $cfg.ActiveName
        } elseif ($matchedNodeName) {
            $activeName = $matchedNodeName
        } elseif ($cfg.ActiveName) {
            $activeName = $cfg.ActiveName
        } elseif ($ips.Count -gt 0) {
            $activeName = $ips[0]
        }
    } else {
        $sel = Get-Z2AiSelectionInfo $RootPath $cfg.Services
        $svcIds = @($sel.ServiceIds)
        $svcLabel = [string]$sel.Label
        $customCount = $sel.CustomDomains.Count
        $activeName = $cfg.ActiveName
    }

    return (New-Object PSObject -Property @{
        Active        = ($rules.Count -gt 0)
        RuleCount     = $rules.Count
        Domains       = [string[]]$domList.ToArray()
        IpsList       = [string[]]@($ips)
        Mode          = $cfg.Mode
        ActiveName    = $activeName
        ActiveIps     = if ($ips.Count -gt 0) { ($ips -join ', ') } else { $cfg.ActiveIps }
        Services      = [string[]]@($svcIds)
        ServicesLabel = [string]$svcLabel
        CustomCount   = $customCount
    })
}

function Resolve-Z2DnsRawUdp([string]$HostName, [string]$DnsIp, [int]$TimeoutMs = 2200) {
    $ips = New-Object System.Collections.Generic.List[string]
    $udp = $null
    try {
        if ($TimeoutMs -lt 100) { $TimeoutMs = 100 }
        $targetIp = [System.Net.IPAddress]::Parse($DnsIp.Trim())
        $targetIpStr = $targetIp.ToString()
        $txId = Get-Random -Minimum 1000 -Maximum 65000
        $pkt = New-Object System.Collections.Generic.List[byte]
        # DNS header: ID(2), Flags=0x0100(RD), QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
        $pkt.Add([byte](($txId -shr 8) -band 0xFF)); $pkt.Add([byte]($txId -band 0xFF))
        $pkt.Add(0x01); $pkt.Add(0x00)
        $pkt.Add(0x00); $pkt.Add(0x01)
        $pkt.Add(0x00); $pkt.Add(0x00)
        $pkt.Add(0x00); $pkt.Add(0x00)
        $pkt.Add(0x00); $pkt.Add(0x00)
        foreach ($lbl in ($HostName.Trim('.').Split('.'))) {
            if (-not $lbl) { continue }
            $lb = [System.Text.Encoding]::ASCII.GetBytes($lbl)
            $pkt.Add([byte]$lb.Length)
            foreach ($b in $lb) { $pkt.Add($b) }
        }
        $pkt.Add(0x00)
        $pkt.Add(0x00); $pkt.Add(0x01) # QTYPE = A
        $pkt.Add(0x00); $pkt.Add(0x01) # QCLASS = IN

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SendTimeout = $TimeoutMs
        $ep = New-Object System.Net.IPEndPoint($targetIp, 53)
        $qBytes = $pkt.ToArray()
        [void]$udp.Send($qBytes, $qBytes.Length, $ep)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $null
        while ($true) {
            $remMs = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($remMs -le 0) { break }
            $udp.Client.ReceiveTimeout = $remMs
            $remEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $pktIn = $null
            try {
                $pktIn = $udp.Receive([ref]$remEp)
            } catch {
                break
            }
            if ($null -eq $pktIn -or $pktIn.Length -lt 12) { continue }
            if ($null -eq $remEp -or $remEp.Address.ToString() -ne $targetIpStr) { continue }
            if (((([int]$pktIn[0] -shl 8) -bor [int]$pktIn[1]) -ne $txId)) { continue }
            if (([int]$pktIn[2] -band 0x80) -eq 0) { continue }
            if (([int]$pktIn[3] -band 0x0F) -ne 0) { break }
            $resp = $pktIn
            break
        }
        if ($null -eq $resp) { return @() }

        $qdCount = ([int]$resp[4] -shl 8) -bor [int]$resp[5]
        $anCount = ([int]$resp[6] -shl 8) -bor [int]$resp[7]
        $pos = 12

        # Skip Question section
        for ($q = 0; $q -lt $qdCount -and $pos -lt $resp.Length; $q++) {
            while ($pos -lt $resp.Length) {
                $len = [int]$resp[$pos]
                if ($len -eq 0) { $pos++; break }
                if (($len -band 0xC0) -eq 0xC0) { $pos += 2; break }
                $pos += (1 + $len)
            }
            $pos += 4 # QTYPE + QCLASS
        }

        # Parse Answer section for A records (Type=1, Class=1, RDLength=4)
        for ($a = 0; $a -lt $anCount -and ($pos + 12) -le $resp.Length; $a++) {
            if (($resp[$pos] -band 0xC0) -eq 0xC0) {
                $pos += 2
            } else {
                while ($pos -lt $resp.Length) {
                    $len = [int]$resp[$pos]
                    if ($len -eq 0) { $pos++; break }
                    if (($len -band 0xC0) -eq 0xC0) { $pos += 2; break }
                    $pos += (1 + $len)
                }
            }
            if (($pos + 10) -gt $resp.Length) { break }
            $rType  = ([int]$resp[$pos] -shl 8) -bor [int]$resp[$pos + 1]
            $rClass = ([int]$resp[$pos + 2] -shl 8) -bor [int]$resp[$pos + 3]
            $rdLen  = ([int]$resp[$pos + 8] -shl 8) -bor [int]$resp[$pos + 9]
            $pos += 10
            if ($rType -eq 1 -and $rClass -eq 1 -and $rdLen -eq 4 -and ($pos + 4) -le $resp.Length) {
                $ipStr = "$($resp[$pos]).$($resp[$pos + 1]).$($resp[$pos + 2]).$($resp[$pos + 3])"
                if (-not ($ips -contains $ipStr)) { $ips.Add($ipStr) }
            }
            $pos += $rdLen
        }
    } catch {} finally {
        if ($null -ne $udp) { try { $udp.Close() } catch {}; try { $udp.Dispose() } catch {} }
    }
    return $ips.ToArray()
}

function Test-Z2AiSmartDns([string]$DnsIp, [string]$TestHost = 'gemini.google.com') {
    if ([string]::IsNullOrWhiteSpace($TestHost)) { $TestHost = 'gemini.google.com' }
    $TestHost = $TestHost.Trim().TrimStart('.')
    $res = [PSCustomObject]@{ Ok = $false; ResolvedIp = ''; HttpCode = '000'; Reason = ''; Host = $TestHost }
    $bogonRx = '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)'

    # Direct UDP/53 query bypasses active Windows NRPT rules so switching away from a dead node always works
    $resolvedIps = @(Resolve-Z2DnsRawUdp -HostName $TestHost -DnsIp $DnsIp -TimeoutMs 2200)
    if ($resolvedIps.Count -eq 0) {
        $res.Reason = 'DNS не ответил'
        return $res
    }

    $validIps = @($resolvedIps | Where-Object { $_ -notmatch $bogonRx })
    if ($validIps.Count -eq 0) {
        $res.ResolvedIp = $resolvedIps[0]
        $res.Reason = "Заглушка ($($resolvedIps[0]))"
        return $res
    }

    $curlExe = "$env:SystemRoot\System32\curl.exe"
    if (-not (Test-Path -LiteralPath $curlExe)) {
        $res.Ok = $true
        $res.ResolvedIp = $validIps[0]
        $res.Reason = "DNS -> $($validIps[0])"
        return $res
    }

    $probeUrl = if ($TestHost -ieq 'gemini.google.com') { 'https://gemini.google.com/app' } else { "https://$TestHost" }
    $okCodeRx = if ($TestHost -match '(?i)googleapis\.com$') { '^([23]\d\d|401|403|404|405|429)$' } else { '^([23]\d\d|401|403|405|429)$' }
    $geoBlockRx = '(?i)(app-unavailable-in-region|/unsupported|/not-available|/region|/unavailable)'
    $googleHostRx = '(?i)(^|\.)(google|googleapis)\.com$'
    $lastReason = ''
    $maxTry = [Math]::Min($validIps.Count, 3)

    for ($k = 0; $k -lt $maxTry; $k++) {
        $candIp = $validIps[$k]
        $res.ResolvedIp = $candIp
        $rawProbe = [string](& $curlExe --noproxy '*' -4 -s -o NUL -w '%{http_code}|%{redirect_url}' --max-time 4 --resolve "${TestHost}:443:$candIp" $probeUrl 2>$null)
        $pParts = $rawProbe.Trim() -split '\|', 2
        $httpCode = if ($pParts.Count -ge 1 -and $pParts[0]) { $pParts[0].Trim() } else { '000' }
        $redirUrl = if ($pParts.Count -ge 2) { $pParts[1].Trim() } else { '' }
        $res.HttpCode = $httpCode

        if ($redirUrl -match '(?i)/sorry\b' -or ($httpCode -eq '429' -and $TestHost -match $googleHostRx)) {
            $lastReason = "Google антибот ($httpCode) на $candIp — переключаюсь на другой узел"
            continue
        }
        if ($redirUrl -match $geoBlockRx) {
            $lastReason = "Геоблок (HTTP $httpCode -> $redirUrl) на $candIp — узел не обходит регион"
            continue
        }
        if ($httpCode -match $okCodeRx) {
            $res.Ok = $true
            $res.Reason = "HTTP $httpCode через $candIp"
            return $res
        }
        $lastReason = "Прокси $candIp не ответил (HTTP $httpCode)"
    }
    $res.Reason = $lastReason
    return $res
}

function Disable-Z2AiBypass([string]$RootPath = '') {
    if (-not (Test-Z2IsAdmin)) { return -1 }
    if (-not $RootPath) { $RootPath = $Root }
    $removed = 0
    $hadErr = $false
    # Instant registry removal avoids CIM/WMI hangs inside background GUI runspaces
    if (Test-Path -LiteralPath $script:Z2AiNrptRegPath) {
        try {
            foreach ($sub in @(Get-ChildItem -LiteralPath $script:Z2AiNrptRegPath -ErrorAction Stop)) {
                try {
                    $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
                    if ($null -ne $props -and [string]$props.Comment -eq $script:Z2AiNrptTag) {
                        Remove-Item -LiteralPath $sub.PSPath -Recurse -Force -ErrorAction Stop
                        $removed++
                    }
                } catch {
                    $hadErr = $true
                }
            }
        } catch {
            $hadErr = $true
        }
    } else {
        try {
            $rules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:Z2AiNrptTag })
            foreach ($r in $rules) {
                try {
                    Remove-DnsClientNrptRule -Name $r.Name -Force -Confirm:$false -ErrorAction Stop
                    $removed++
                } catch {
                    $hadErr = $true
                }
            }
        } catch {
            $hadErr = $true
        }
    }
    Invoke-Z2FlushDnsFast
    if ($hadErr -and $removed -eq 0) { return -1 }
    return $removed
}

function Get-Z2AiProbePlan($SelInfo) {
    $proxiedIds = @('gemini', 'chatgpt', 'claude', 'copilot', 'grok', 'antigravity')
    $proxiedHost = ''
    foreach ($ph in @($SelInfo.ProbeHosts)) {
        if ($proxiedIds -contains ([string]$ph.Id)) {
            $proxiedHost = [string]$ph.Host
            break
        }
    }
    if ($proxiedHost) {
        return [PSCustomObject]@{
            PrimaryHost      = $proxiedHost
            HasProxiedSelect = $true
        }
    }
    $fbHost = 'gemini.google.com'
    if ($SelInfo.ProbeHosts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$SelInfo.ProbeHosts[0].Host)) {
        $fbHost = [string]$SelInfo.ProbeHosts[0].Host
    }
    return [PSCustomObject]@{
        PrimaryHost      = $fbHost
        HasProxiedSelect = $false
    }
}

function Enable-Z2AiBypass(
    [string]$RootPath = '',
    [string]$SelectedMode = '',
    [string]$Services = '',
    [bool]$ServicesSpecified = $false,
    [bool]$PreserveMode = $false
) {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host '  [X] Требуются права администратора для настройки обхода ИИ (NRPT).' -ForegroundColor Red
        return $false
    }
    if (-not $RootPath) { $RootPath = $Root }
    $cfg = Get-Z2AiBypassConf $RootPath
    $searchMode = $cfg.Mode
    if (-not [string]::IsNullOrWhiteSpace($SelectedMode)) {
        $searchMode = $SelectedMode
        if (-not $PreserveMode) { $cfg.Mode = $SelectedMode }
    }
    $hasSvcParam = $ServicesSpecified -or ($PSBoundParameters.ContainsKey('Services') -and -not $PSBoundParameters.ContainsKey('ServicesSpecified'))
    if ($hasSvcParam) {
        if ([string]::IsNullOrWhiteSpace($Services)) {
            $cfg.Services = ''
        } else {
            $resolvedSvc = @(Resolve-Z2AiServiceIds $Services)
            $cfg.Services = ($resolvedSvc -join ',')
        }
    }

    $sel = Get-Z2AiSelectionInfo $RootPath $cfg.Services
    if ($sel.Domains.Count -eq 0) {
        Write-Host '  [!] Не выбран ни один ИИ-сервис — правила NRPT не добавлены.' -ForegroundColor Yellow
        return $false
    }
    $vpnCheck = Get-Z2ActiveVpnInfo
    if ($vpnCheck.Active) {
        Write-Host ("  [!] Обнаружен активный VPN/прокси ({0}): при одновременной работе со SmartDNS возможен двойной прокси и тормоза." -f $vpnCheck.Label) -ForegroundColor DarkYellow
    }

    $probePlan = Get-Z2AiProbePlan $sel
    $primaryProbeHost = $probePlan.PrimaryHost
    $needProxyVerify  = (-not $probePlan.HasProxiedSelect)
    $pool = Get-Z2AiDnsPool $RootPath

    $candidates = New-Object System.Collections.Generic.List[object]
    if ($searchMode -ieq 'auto' -or [string]::IsNullOrWhiteSpace($searchMode)) {
        foreach ($p in $pool) { $candidates.Add($p) }
    } elseif ($searchMode -ieq 'custom') {
        $custIps = @($cfg.CustomDns -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { Test-Z2PublicIpv4 $_ })
        if ($custIps.Count -gt 0) {
            $candidates.Add([PSCustomObject]@{ Name = "Свой ($($custIps[0]))"; Ips = [string[]]$custIps })
        }
        if ($candidates.Count -eq 0) {
            foreach ($p in $pool) { $candidates.Add($p) }
        }
    } else {
        foreach ($p in $pool) { if ($p.Name -ieq $searchMode) { $candidates.Add($p) } }
        if ($candidates.Count -eq 0 -and (Test-Z2PublicIpv4 $searchMode)) {
            $ipClean = $searchMode.Trim()
            $candidates.Add([PSCustomObject]@{ Name = "Свой ($ipClean)"; Ips = @($ipClean) })
        }
        if ($candidates.Count -eq 0) {
            foreach ($p in $pool) { $candidates.Add($p) }
        }
    }

    $chosen = $null
    foreach ($cand in $candidates) {
        Write-Host ("  [*] Проверка SmartDNS {0} ({1}) по {2}..." -f $cand.Name, ($cand.Ips -join ', '), $primaryProbeHost) -ForegroundColor Yellow
        $liveIps = New-Object System.Collections.Generic.List[string]
        foreach ($ip in $cand.Ips) {
            $t = Test-Z2AiSmartDns $ip $primaryProbeHost
            if (-not $t.Ok) {
                Write-Host ("      [!] {0} -> {1}" -f $ip, $t.Reason) -ForegroundColor DarkYellow
                continue
            }
            if ($needProxyVerify) {
                $tp1 = Test-Z2AiSmartDns $ip 'gemini.google.com'
                if ($tp1.Ok) {
                    $liveIps.Add($ip)
                    Write-Host ("      [OK] {0} -> {1} (прокси gemini.google.com: {2})" -f $ip, $t.Reason, $tp1.Reason) -ForegroundColor Green
                } else {
                    $tp2 = Test-Z2AiSmartDns $ip 'chatgpt.com'
                    if ($tp2.Ok) {
                        $liveIps.Add($ip)
                        Write-Host ("      [OK] {0} -> {1} (прокси chatgpt.com: {2})" -f $ip, $t.Reason, $tp2.Reason) -ForegroundColor Green
                    } else {
                        Write-Host ("      [!] {0} -> {1}, но прокси ИИ не работает (gemini: {2}; chatgpt: {3})" -f $ip, $t.Reason, $tp1.Reason, $tp2.Reason) -ForegroundColor DarkYellow
                    }
                }
            } else {
                $liveIps.Add($ip)
                Write-Host ("      [OK] {0} -> {1}" -f $ip, $t.Reason) -ForegroundColor Green
            }
        }
        if ($liveIps.Count -gt 0) {
            $chosen = New-Object PSObject -Property @{ Name = [string]$cand.Name; Ips = [string[]]$liveIps.ToArray() }
            break
        }
    }

    if ($null -eq $chosen) {
        Write-Host '  [X] Ни один SmartDNS из пула не ответил для выбранных ИИ-сервисов (возможно, провайдер режет UDP/53 или прокси временно недоступен).' -ForegroundColor Red
        return $false
    }

    [void](Disable-Z2AiBypass $RootPath)
    $added = 0
    $nsIps = [string[]]@($chosen.Ips)
    foreach ($dom in @($sel.Domains)) {
        try {
            Add-DnsClientNrptRule -Namespace ([string]$dom) -NameServers $nsIps -Comment $script:Z2AiNrptTag -ErrorAction Stop | Out-Null
            $added++
        } catch {
            Write-Host ("      [!] NRPT ({0}): {1}" -f $dom, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    Invoke-Z2FlushDnsFast

    if ($added -lt $sel.Domains.Count) {
        [void](Disable-Z2AiBypass $RootPath)
        Write-Host "  [X] Не удалось добавить все правила NRPT ($added/$($sel.Domains.Count)) — выполнен откат (проверь права администратора)." -ForegroundColor Red
        return $false
    }

    $cfg.ActiveName = $chosen.Name
    $cfg.ActiveIps  = ($chosen.Ips -join ', ')
    $cfg.Services   = ($sel.ServiceIds -join ',')
    Save-Z2AiBypassConf $RootPath $cfg
    Write-Host ("  [OK] Обход ИИ включён: {0} ({1}) · {2} ({3} доменов)" -f $chosen.Name, $cfg.ActiveIps, $sel.Label, $added) -ForegroundColor Green
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    $svcSpecified = $PSBoundParameters.ContainsKey('Services')
    if ($Action -eq 'enable') {
        if ($svcSpecified) {
            $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode $Provider -Services $Services -ServicesSpecified $true
        } else {
            $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode $Provider -ServicesSpecified $false
        }
        if ($ok) { exit 0 } else { exit 1 }
    } elseif ($Action -eq 'disable') {
        if (-not (Test-Z2IsAdmin)) {
            Write-Host '  [X] Требуются права администратора для отключения обхода ИИ (NRPT).' -ForegroundColor Red
            exit 1
        }
        $remRes = Disable-Z2AiBypass $Root
        if ($remRes -lt 0 -or (Get-Z2AiBypassState $Root).Active) {
            Write-Host '  [X] Не удалось удалить все правила NRPT обхода ИИ (проверь права администратора).' -ForegroundColor Red
            exit 1
        }
        Write-Host '  [OK] Обход ИИ выключен, правила NRPT удалены.' -ForegroundColor Green
        exit 0
    } elseif ($Action -eq 'probe') {
        $st = Get-Z2AiBypassState $Root
        if (-not $st.Active) {
            if (-not (Test-Z2IsAdmin)) {
                Write-Host '  [X] Требуются права администратора для включения обхода ИИ (NRPT).' -ForegroundColor Red
                exit 1
            }
            Write-Host '  [!] Обход ИИ выключен — запускаю подбор живого SmartDNS...' -ForegroundColor Yellow
            if ($svcSpecified) {
                $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -Services $Services -ServicesSpecified $true -PreserveMode $true
            } else {
                $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -ServicesSpecified $false -PreserveMode $true
            }
            if ($ok) { exit 0 } else { exit 1 }
        }
        $cfg = Get-Z2AiBypassConf $Root
        $svcRaw = if ($svcSpecified) { $Services } elseif ($st.Services.Count -gt 0 -or $st.CustomCount -gt 0) { ($st.Services -join ',') } else { $cfg.Services }
        $sel = Get-Z2AiSelectionInfo $Root $svcRaw
        if ($sel.Domains.Count -eq 0) {
            Write-Host '  [!] Не выбран ни один ИИ-сервис.' -ForegroundColor Yellow
            exit 1
        }
        $probePlan = Get-Z2AiProbePlan $sel
        $proxiedIds = @('gemini', 'chatgpt', 'claude', 'copilot', 'grok', 'antigravity')
        $activeIpList = @($st.ActiveIps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($curIp in $activeIpList) {
            Write-Host ("  [*] Проверка активного SmartDNS {0} ({1})..." -f $st.ActiveName, $curIp) -ForegroundColor Yellow
            $okCount = 0
            $proxiedOk = $false
            $firstOk = $false
            $idxP = 0
            foreach ($ph in $sel.ProbeHosts) {
                $t = Test-Z2AiSmartDns $curIp $ph.Host
                if ($t.Ok) {
                    $okCount++
                    if ($idxP -eq 0) { $firstOk = $true }
                    if ($proxiedIds -contains ([string]$ph.Id)) { $proxiedOk = $true }
                    Write-Host ("      [OK] {0} ({1}) -> {2}" -f $ph.Name, $ph.Host, $t.Reason) -ForegroundColor Green
                } else {
                    Write-Host ("      [!] {0} ({1}) -> {2}" -f $ph.Name, $ph.Host, $t.Reason) -ForegroundColor DarkYellow
                }
                $idxP++
            }
            $nodeLive = if ($probePlan.HasProxiedSelect) {
                $proxiedOk
            } elseif ($okCount -gt 0 -and $firstOk) {
                ((Test-Z2AiSmartDns $curIp 'gemini.google.com').Ok -or (Test-Z2AiSmartDns $curIp 'chatgpt.com').Ok)
            } else {
                $false
            }
            if ($nodeLive) {
                Write-Host ("  [OK] Обход ИИ работает через {0} ({1}): доступно {2}/{3} сервисов." -f $st.ActiveName, $curIp, $okCount, $sel.ProbeHosts.Count) -ForegroundColor Green
                exit 0
            }
        }
        Write-Host ("  [!] Активный узел {0} ({1}) не отвечает — пробую переключиться на запасной из пула..." -f $st.ActiveName, ($activeIpList -join ', ')) -ForegroundColor Yellow
        if ($svcSpecified) {
            $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -Services $Services -ServicesSpecified $true -PreserveMode $true
        } else {
            $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -ServicesSpecified $false -PreserveMode $true
        }
        if ($ok) { exit 0 } else { exit 1 }
    } else {
        $st = Get-Z2AiBypassState $Root
        if ($st.Active) {
            Write-Host ("  [OK] Обход ИИ активен: {0} ({1}) · {2} ({3} доменов)" -f $st.ActiveName, $st.ActiveIps, $st.ServicesLabel, $st.RuleCount) -ForegroundColor Green
        } else {
            Write-Host ("  [ИНФО] Обход ИИ выключен · выбрано: {0}" -f $st.ServicesLabel) -ForegroundColor Gray
        }
        exit 0
    }
}
