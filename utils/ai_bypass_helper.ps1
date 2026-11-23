param(
    [string]$Action = 'status',
    [string]$Root = '',
    [string]$Provider = '',
    [string]$Services = ''
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

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
        ProbeHost = 'antigravity.google'
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
                $ips  = @($parts[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $pIp = $null; [System.Net.IPAddress]::TryParse($_, [ref]$pIp) -and $pIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_ -notmatch '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' })
                if ($name -and $ips.Count -gt 0) {
                    $pool.Add((New-Object PSObject -Property @{ Name = [string]$name; Ips = [string[]]@($ips) }))
                }
            }
        }
    }
    if ($pool.Count -eq 0) {
        $pool.Add((New-Object PSObject -Property @{ Name = 'MagicDNS';   Ips = @('217.144.190.216', '109.120.187.249') }))
        $pool.Add((New-Object PSObject -Property @{ Name = 'GeoHide EU'; Ips = @('5.175.161.40', '143.20.64.192') }))
        $pool.Add((New-Object PSObject -Property @{ Name = 'Pereval';    Ips = @('153.80.200.170') }))
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
    $sel = Get-Z2AiSelectionInfo $RootPath $cfg.Services
    $ips = @()
    $domList = New-Object System.Collections.Generic.List[string]
    if ($rules.Count -gt 0) {
        if ($rules[0].NameServers) { $ips = @($rules[0].NameServers) }
        foreach ($r in $rules) {
            foreach ($d in @($r.Domains)) {
                if ($d -and -not $domList.Contains($d)) { $domList.Add($d) }
            }
        }
    }
    return (New-Object PSObject -Property @{
        Active        = ($rules.Count -gt 0)
        RuleCount     = $rules.Count
        Domains       = [string[]]$domList.ToArray()
        IpsList       = [string[]]@($ips)
        Mode          = $cfg.Mode
        ActiveName    = if ($cfg.ActiveName) { $cfg.ActiveName } elseif ($ips.Count -gt 0) { $ips[0] } else { '' }
        ActiveIps     = if ($ips.Count -gt 0) { ($ips -join ', ') } else { $cfg.ActiveIps }
        Services      = [string[]]@($sel.ServiceIds)
        ServicesLabel = [string]$sel.Label
        CustomCount   = $sel.CustomDomains.Count
    })
}

function Test-Z2AiSmartDns([string]$DnsIp, [string]$TestHost = 'gemini.google.com') {
    if ([string]::IsNullOrWhiteSpace($TestHost)) { $TestHost = 'gemini.google.com' }
    $TestHost = $TestHost.Trim().TrimStart('.')
    $res = [PSCustomObject]@{ Ok = $false; ResolvedIp = ''; HttpCode = '000'; Reason = ''; Host = $TestHost }
    $resolvedIp = ''
    try {
        $ans = @(Resolve-DnsName -Name $TestHost -Type A -Server $DnsIp -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($ans.Count -gt 0) { $resolvedIp = [string]$ans[0].IPAddress }
    } catch {}
    if (-not $resolvedIp) {
        $res.Reason = 'DNS не ответил'
        return $res
    }
    if ($resolvedIp -match '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)') {
        $res.ResolvedIp = $resolvedIp
        $res.Reason = "Заглушка ($resolvedIp)"
        return $res
    }
    $res.ResolvedIp = $resolvedIp
    $curlExe = "$env:SystemRoot\System32\curl.exe"
    if (Test-Path -LiteralPath $curlExe) {
        $probeUrl = if ($TestHost -ieq 'gemini.google.com') { 'https://gemini.google.com/app' } else { "https://$TestHost" }
        $rawProbe = [string](& $curlExe -4 -s -o NUL -w '%{http_code}|%{redirect_url}' --max-time 4 --resolve "${TestHost}:443:$resolvedIp" $probeUrl 2>$null)
        $pParts = $rawProbe.Trim() -split '\|', 2
        if ($pParts.Count -ge 1 -and $pParts[0]) { $res.HttpCode = $pParts[0].Trim() }
        $redirUrl = if ($pParts.Count -ge 2) { $pParts[1].Trim() } else { '' }
        if ($redirUrl -match '(?i)/sorry\b' -or ($res.HttpCode -eq '429' -and $TestHost -match '(?i)google\.com$')) {
            $res.Ok = $false
            $res.Reason = "Google антибот (/sorry) на $resolvedIp — переключаюсь на другой узел"
            return $res
        }
        if ($res.HttpCode -match '^([23]\d\d|401|403|405|429)$') {
            $res.Ok = $true
            $res.Reason = "HTTP $($res.HttpCode) через $resolvedIp"
            return $res
        }
        $res.Reason = "Прокси $resolvedIp не ответил (HTTP $($res.HttpCode))"
        return $res
    }
    $res.Ok = $true
    $res.Reason = "DNS -> $resolvedIp"
    return $res
}

function Disable-Z2AiBypass([string]$RootPath = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $removed = 0
    # Instant registry removal avoids CIM/WMI hangs inside background GUI runspaces
    if (Test-Path -LiteralPath $script:Z2AiNrptRegPath) {
        try {
            foreach ($sub in @(Get-ChildItem -LiteralPath $script:Z2AiNrptRegPath -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
                if ($null -ne $props -and [string]$props.Comment -eq $script:Z2AiNrptTag) {
                    try {
                        Remove-Item -LiteralPath $sub.PSPath -Recurse -Force -ErrorAction Stop
                        $removed++
                    } catch {}
                }
            }
        } catch {}
    } else {
        try {
            $rules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:Z2AiNrptTag })
            foreach ($r in $rules) {
                Remove-DnsClientNrptRule -Name $r.Name -Force -Confirm:$false -ErrorAction SilentlyContinue
                $removed++
            }
        } catch {}
    }
    Invoke-Z2FlushDnsFast
    return $removed
}

function Enable-Z2AiBypass([string]$RootPath = '', [string]$SelectedMode = '', [string]$Services = '') {
    if (-not $RootPath) { $RootPath = $Root }
    $cfg = Get-Z2AiBypassConf $RootPath
    if (-not [string]::IsNullOrWhiteSpace($SelectedMode)) { $cfg.Mode = $SelectedMode }
    if (-not [string]::IsNullOrWhiteSpace($Services)) {
        $resolvedSvc = @(Resolve-Z2AiServiceIds $Services)
        $cfg.Services = ($resolvedSvc -join ',')
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

    $primaryProbeHost = 'gemini.google.com'
    if ($sel.ProbeHosts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$sel.ProbeHosts[0].Host)) { $primaryProbeHost = [string]$sel.ProbeHosts[0].Host }
    $pool = Get-Z2AiDnsPool $RootPath

    $candidates = New-Object System.Collections.Generic.List[object]
    if ($cfg.Mode -ieq 'auto' -or [string]::IsNullOrWhiteSpace($cfg.Mode)) {
        foreach ($p in $pool) { $candidates.Add($p) }
    } else {
        foreach ($p in $pool) { if ($p.Name -ieq $cfg.Mode) { $candidates.Add($p) } }
        $pCust = $null; if ($candidates.Count -eq 0 -and [System.Net.IPAddress]::TryParse($cfg.Mode, [ref]$pCust) -and $pCust.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $cfg.Mode -notmatch '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)') {
            $candidates.Add([PSCustomObject]@{ Name = "Свой ($($cfg.Mode))"; Ips = @($cfg.Mode) })
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
            if ($t.Ok) {
                $liveIps.Add($ip)
                Write-Host ("      [OK] {0} -> {1}" -f $ip, $t.Reason) -ForegroundColor Green
            } else {
                Write-Host ("      [!] {0} -> {1}" -f $ip, $t.Reason) -ForegroundColor DarkYellow
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
    if ($Action -eq 'enable') {
        $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode $Provider -Services $Services
        if ($ok) { exit 0 } else { exit 1 }
    } elseif ($Action -eq 'disable') {
        [void](Disable-Z2AiBypass $Root)
        Write-Host '  [OK] Обход ИИ выключен, правила NRPT удалены.' -ForegroundColor Green
        exit 0
    } elseif ($Action -eq 'probe') {
        $st = Get-Z2AiBypassState $Root
        if (-not $st.Active) {
            Write-Host '  [!] Обход ИИ выключен — запускаю подбор живого SmartDNS...' -ForegroundColor Yellow
            $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -Services $Services
            if ($ok) { exit 0 } else { exit 1 }
        }
        $cfg = Get-Z2AiBypassConf $Root
        $svcRaw = if ($Services) { $Services } else { $cfg.Services }
        $sel = Get-Z2AiSelectionInfo $Root $svcRaw
        if ($sel.Domains.Count -eq 0) {
            Write-Host '  [!] Не выбран ни один ИИ-сервис.' -ForegroundColor Yellow
            exit 1
        }
        $firstIp = ($st.ActiveIps -split ',')[0].Trim()
        Write-Host ("  [*] Проверка активного SmartDNS {0} ({1})..." -f $st.ActiveName, $firstIp) -ForegroundColor Yellow
        $okCount = 0
        $primaryOk = $false
        $idxP = 0
        foreach ($ph in $sel.ProbeHosts) {
            $t = Test-Z2AiSmartDns $firstIp $ph.Host
            if ($t.Ok) {
                $okCount++
                if ($idxP -eq 0) { $primaryOk = $true }
                Write-Host ("      [OK] {0} ({1}) -> {2}" -f $ph.Name, $ph.Host, $t.Reason) -ForegroundColor Green
            } else {
                Write-Host ("      [!] {0} ({1}) -> {2}" -f $ph.Name, $ph.Host, $t.Reason) -ForegroundColor DarkYellow
            }
            $idxP++
        }
        if ($okCount -gt 0 -and $primaryOk) {
            Write-Host ("  [OK] Обход ИИ работает через {0} ({1}): доступно {2}/{3} сервисов." -f $st.ActiveName, $firstIp, $okCount, $sel.ProbeHosts.Count) -ForegroundColor Green
            exit 0
        }
        Write-Host ("  [!] Базовый узел {0} ({1}) не отвечает — пробую переключиться на запасной из пула..." -f $st.ActiveName, $firstIp) -ForegroundColor Yellow
        $ok = Enable-Z2AiBypass -RootPath $Root -SelectedMode 'auto' -Services $Services
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
