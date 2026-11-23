$ErrorActionPreference = 'Stop'
$q = [char]34

function ConvertTo-NormPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    $s = $p.Trim().Trim('"').Trim()
    $hadTrail = $s.EndsWith('\') -or $s.EndsWith('/')
    if ($s -match '^[A-Za-z]:[/\\]' -or $s.Contains('..')) {
        try {
            $full = [System.IO.Path]::GetFullPath($s.Replace('/', '\'))
            $s = $full.Replace('\', '/')
            if ($hadTrail -and -not $s.EndsWith('/')) { $s += '/' }
            return $s
        } catch {}
    }
    return $s.Replace('\', '/')
}

$vars = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($k in @('BIN','LISTS','LUA','GameFilterTCP','GameFilterUDP','GameFilter','DISCORD_FAKE','GAME_FAKE')) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($null -ne $v) {
        if (($k -eq 'DISCORD_FAKE' -or $k -eq 'GAME_FAKE') -and ($v -match '(?i)ACTIVE_.*_UDP\.bin$') -and -not (Test-Path -LiteralPath $v)) {
            continue
        }
        $vars[$k] = ConvertTo-NormPath $v
    }
}
if ($env:Z2_ROOT) {
    $z2RootClean = $env:Z2_ROOT.Trim().Trim('"').Trim().TrimEnd('\', '/') + '\'
    $normR = ConvertTo-NormPath $z2RootClean
    $vars['ROOT'] = $normR
    $vars['~dp0'] = $normR
}

$batTarget = $env:Z2_BAT
if (-not (Test-Path -LiteralPath $batTarget) -and $env:Z2_ROOT) {
    $leaf = Split-Path -Leaf $batTarget
    foreach ($sub in @('strategies', 'configs_archive', '')) {
        $alt = if ($sub) { Join-Path (Join-Path $env:Z2_ROOT $sub) $leaf } else { Join-Path $env:Z2_ROOT $leaf }
        if (Test-Path -LiteralPath $alt) { $batTarget = $alt; break }
    }
}
try {
    $batDir = (Split-Path -Parent ([System.IO.Path]::GetFullPath($batTarget))).TrimEnd('\', '/') + '/'
    $vars['~dp0'] = $batDir.Replace('\', '/')
} catch {}
$raw = Get-Content -LiteralPath $batTarget -Encoding UTF8
$lines = @()
$buf = ''
foreach ($l in $raw) {
    $t = $l.TrimEnd()
    if ($t.EndsWith('^')) {
        $buf += $t.Substring(0, $t.Length - 1) + ' '
    } else {
        $buf += $t
        $lines += $buf
        $buf = ''
    }
}
if ($buf) { $lines += $buf }

function Exp([string]$s) {
    return [regex]::Replace($s, '(?i)%~dp0|%([A-Za-z0-9_~]+)%', {
        param($m)
        if ($m.Value -ieq '%~dp0') {
            if ($vars.ContainsKey('~dp0')) { return $vars['~dp0'] }
            return $m.Value
        }
        $k = $m.Groups[1].Value
        if ($vars.ContainsKey($k)) { return $vars[$k] }
        $ev = [Environment]::GetEnvironmentVariable($k)
        if ($null -ne $ev) { return $ev.Replace('\', '/') }
        return $m.Value
    })
}

$cmdLine = $null
foreach ($l in $lines) {
    $tr = $l.Trim()
    if (-not $tr -or $tr.StartsWith('::') -or $tr -match '(?i)^rem(\s|$)') { continue }
    if ($tr -match '(?i)^(?:start\s+.*?\s+)?\x22?[^\x22]*winws2\.exe\x22?\s+--') {
        $cmdLine = $tr
        break
    }
    if ($tr -match '(?i)^set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        $vars[$matches[1]] = ConvertTo-NormPath (Exp $matches[2])
        continue
    }
    if ($tr -match '(?i)^if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        $neg1 = [bool]$matches[1]; $p1 = (ConvertTo-NormPath (Exp $matches[2])).Replace('/', '\'); $ex1 = Test-Path -LiteralPath $p1
        $neg2 = [bool]$matches[3]; $p2 = (ConvertTo-NormPath (Exp $matches[4])).Replace('/', '\'); $ex2 = Test-Path -LiteralPath $p2
        if ((($neg1 -and -not $ex1) -or (-not $neg1 -and $ex1)) -and (($neg2 -and -not $ex2) -or (-not $neg2 -and $ex2))) {
            $vars[$matches[5]] = ConvertTo-NormPath (Exp $matches[6])
        }
        continue
    }
    if ($tr -match '(?i)^if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        $neg = [bool]$matches[1]
        $p = (ConvertTo-NormPath (Exp $matches[2])).Replace('/', '\')
        $ex = Test-Path -LiteralPath $p
        if (($neg -and -not $ex) -or (-not $neg -and $ex)) {
            $vars[$matches[3]] = ConvertTo-NormPath (Exp $matches[4])
        }
        continue
    }
    if ($tr -match '(?i)^if\s+not\s+defined\s+([A-Za-z0-9_]+)\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        if (-not $vars.ContainsKey($matches[1]) -or [string]::IsNullOrEmpty($vars[$matches[1]])) {
            $vars[$matches[2]] = ConvertTo-NormPath (Exp $matches[3])
        }
        continue
    }
}

if (-not $cmdLine) {
    if (($lines -join ' ') -match '(?i)winws\.exe') { exit 2 } else { exit 3 }
}

foreach ($fk in @('DISCORD_FAKE', 'GAME_FAKE')) {
    if ($vars.ContainsKey($fk) -and ($vars[$fk] -match '(?i)ACTIVE_.*_UDP\.bin$')) {
        $fkWin = $vars[$fk].Replace('/', '\')
        if (-not (Test-Path -LiteralPath $fkWin)) {
            if ($vars.ContainsKey('BIN') -and -not [string]::IsNullOrWhiteSpace($vars['BIN'])) {
                $binBase = $vars['BIN']
                if (-not $binBase.EndsWith('/')) { $binBase += '/' }
                $fallbackFake = $binBase + 'quic_initial_www_google_com.bin'
                if (Test-Path -LiteralPath ($fallbackFake.Replace('/', '\'))) {
                    $vars[$fk] = $fallbackFake
                }
            }
        }
    }
}

$idx = $cmdLine.ToLowerInvariant().IndexOf('winws2.exe')
$rest = $cmdLine.Substring($idx + 10).TrimStart()
if ($rest.StartsWith($q)) { $rest = $rest.Substring(1).TrimStart() }
$rest = Exp $rest

$tokens = New-Object System.Collections.Generic.List[string]
$cur = New-Object System.Text.StringBuilder
$inQ = $false
$hasTok = $false
for ($i = 0; $i -lt $rest.Length; $i++) {
    $c = $rest[$i]
    if ($c -eq $q) {
        $inQ = -not $inQ
        $hasTok = $true
        continue
    }
    if (-not $inQ -and [char]::IsWhiteSpace($c)) {
        if ($hasTok) {
            $tokens.Add($cur.ToString())
            [void]$cur.Clear()
            $hasTok = $false
        }
        continue
    }
    [void]$cur.Append($c)
    $hasTok = $true
}
if ($hasTok) { $tokens.Add($cur.ToString()) }
if ($tokens.Count -eq 0) { exit 4 }

$header = New-Object System.Collections.Generic.List[string]
$profiles = New-Object System.Collections.Generic.List[System.Collections.Generic.List[string]]
$curProf = New-Object System.Collections.Generic.List[string]
$inProfiles = $false

foreach ($tk in $tokens) {
    if (-not $inProfiles) {
        if ($tk -match '^(?i)--filter-') {
            $inProfiles = $true
            $curProf.Add($tk)
        } else {
            $header.Add($tk)
        }
    } else {
        if ($tk -ieq '--new') {
            if ($curProf.Count -gt 0) {
                $profiles.Add($curProf)
                $curProf = New-Object System.Collections.Generic.List[string]
            }
        } else {
            $curProf.Add($tk)
        }
    }
}
if ($curProf.Count -gt 0) { $profiles.Add($curProf) }

$rootWin = if ($env:Z2_ROOT) {
    $rwClean = $env:Z2_ROOT.Trim().Trim('"').Trim()
    if ($rwClean -match '^[A-Za-z]:$') { $rwClean += '\' }
    if ($rwClean) {
        try { [System.IO.Path]::GetFullPath($rwClean).TrimEnd('\', '/') + '\' } catch { $rwClean.TrimEnd('\', '/') + '\' }
    } else { '' }
} else { '' }

# 0. WARP Unblock toggle check
$warpOn = $true
if ($rootWin) {
    $warpFlag = Join-Path $rootWin 'utils\warp_unblock.enabled'
    if (-not (Test-Path -LiteralPath $warpFlag)) { $warpOn = $false }
}
# 1. WinDivert per-interface VPN exclusion (--wf-raw-filter=@bin/filters/vpn_exclude.txt)
$vpnIfIdxActive = $false
if ($rootWin) {
    $vpnIfFlag = Join-Path $rootWin 'utils\vpn_ifidx.enabled'
    $nlmHelperPs = Join-Path $rootWin 'utils\nlm_helper.ps1'
    if ($env:Z2_SKIP_NLM_AUTO -ne '1' -and (Test-Path -LiteralPath $vpnIfFlag)) {
        if (Test-Path -LiteralPath $nlmHelperPs) {
            $prevEap = $ErrorActionPreference
            try {
                . $nlmHelperPs -Root $rootWin
                if (Get-Command Update-Z2VpnIfIdxFilter -ErrorAction SilentlyContinue) {
                    $uRes = Update-Z2VpnIfIdxFilter $rootWin
                    if ($null -ne $uRes -and $uRes.Ok) { $vpnIfIdxActive = $true }
                }
            } catch {} finally {
                $ErrorActionPreference = $prevEap
            }
        }
        $vpnFiltPath = Join-Path $rootWin 'bin\filters\vpn_exclude.txt'
        if ($vpnIfIdxActive -and (Test-Path -LiteralPath $vpnFiltPath)) {
            $hasRawF = $false
            foreach ($h in $header) { if ($h -match '^(?i)--wf-raw-filter=') { $hasRawF = $true; break } }
            if (-not $hasRawF) {
                $filtArgPath = $vpnFiltPath.Replace('\', '/')
                $header.Add('--wf-raw-filter=@' + $filtArgPath)
            }
        }
    }
}

# 2. Strip disabled GameFilter (port 12) and apply Kernel Filters
$gfTcpOff = (-not $vars.ContainsKey('GameFilterTCP')) -or ($vars['GameFilterTCP'] -eq '12')
$gfUdpOff = (-not $vars.ContainsKey('GameFilterUDP')) -or ($vars['GameFilterUDP'] -eq '12')

$kernelFilterOn = ($rootWin -and (Test-Path -LiteralPath (Join-Path $rootWin 'utils\kernel_filter.enabled')))
if ($kernelFilterOn) {
    if (-not $vars.ContainsKey('BIN') -or [string]::IsNullOrWhiteSpace($vars['BIN'])) {
        $kernelFilterOn = $false
    } else {
        $kfBin = $vars['BIN'].Replace('/', '\')
        $kfRequired = @('windivert_part.quic_initial_ietf.txt','windivert_part.discord_media.txt','windivert_part.stun.txt')
        if ($warpOn) { $kfRequired += 'windivert_part.wireguard.txt' }
        foreach ($kfReq in $kfRequired) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $kfBin 'filters') $kfReq))) { $kernelFilterOn = $false; break }
        }
    }
}
$removeHeaderIdx = New-Object System.Collections.Generic.List[int]
# Keep WARP/IKEv2/L2TP ports (500,1701,2408,4500) in --wf-udp-out when warp_unblock is active
$wideUdpPorts = if ($warpOn) {
    @('443','19294-19344','50000-50100')
} else {
    @('443','500','1701','2408','4500','19294-19344','50000-50100')
}
$hasWfUdpOut = $false

for ($i = 0; $i -lt $header.Count; $i++) {
    if ($gfTcpOff -and $header[$i] -match '^(?i)(--wf-tcp-(?:out|in)=)(.+)$') {
        $pts = @($matches[2] -split ',' | Where-Object { $_ -ne '12' -and $_ -ne '' })
        if ($pts.Count -gt 0) {
            $header[$i] = $matches[1] + ($pts -join ',')
        } else {
            $removeHeaderIdx.Add($i)
        }
    }
    if ($header[$i] -match '^(?i)(--wf-udp-(?:out|in)=)(.+)$') {
        $isWfUdpOut = ($matches[1] -ieq '--wf-udp-out=')
        if ($isWfUdpOut) { $hasWfUdpOut = $true }
        $pts = @($matches[2] -split ',' | Where-Object { $_ -ne '' })
        if ($gfUdpOff) { $pts = @($pts | Where-Object { $_ -ne '12' }) }
        if (-not $warpOn) { $pts = @($pts | Where-Object { $_ -notin @('500','1701','2408','4500') }) }
        if ($kernelFilterOn -and $isWfUdpOut) {
            # Keep only GameFilterUDP, WARP (if enabled), or custom ports; wide UDP ports move to --wf-raw-part
            $pts = @($pts | Where-Object { $_ -notin $wideUdpPorts })
        }
        if ($pts.Count -gt 0) {
            $header[$i] = $matches[1] + ($pts -join ',')
        } else {
            $removeHeaderIdx.Add($i)
        }
    }
}
for ($ri = $removeHeaderIdx.Count - 1; $ri -ge 0; $ri--) {
    $header.RemoveAt($removeHeaderIdx[$ri])
}
if ($kernelFilterOn -and $hasWfUdpOut -and $vars.ContainsKey('BIN')) {
    $binSlash = $vars['BIN']
    if (-not $binSlash.EndsWith('/')) { $binSlash += '/' }
    $partNames = @('windivert_part.quic_initial_ietf.txt', 'windivert_part.discord_media.txt', 'windivert_part.stun.txt')
    if ($warpOn) { $partNames += 'windivert_part.wireguard.txt' }
    foreach ($pn in $partNames) {
        $winP = ($binSlash + 'filters/' + $pn).Replace('/', '\')
        if (Test-Path -LiteralPath $winP) {
            $header.Add('--wf-raw-part=@' + $binSlash + 'filters/' + $pn)
        }
    }
}

# 2b. Optional WinDivert Priority (--wf-priority=<int>, -30000..30000) via utils\wf_priority.conf
if ($rootWin) {
    $wfPrioFile = Join-Path $rootWin 'utils\wf_priority.conf'
    if (Test-Path -LiteralPath $wfPrioFile) {
        $pRaw = (Get-Content -LiteralPath $wfPrioFile -TotalCount 1 -ErrorAction SilentlyContinue)
        $pInt = 0
        if ($null -ne $pRaw -and [int]::TryParse($pRaw.Trim(), [ref]$pInt) -and $pInt -ne 0 -and $pInt -ge -30000 -and $pInt -le 30000) {
            $header.Add('--wf-priority=' + $pInt)
        }
    }
}

if ([string]::IsNullOrEmpty($env:Z2_AUTOHOST)) {
    $autoHostOn = ($rootWin -and (Test-Path -LiteralPath (Join-Path $rootWin 'utils\autohostlist.enabled')))
} else {
    $autoHostOn = ($env:Z2_AUTOHOST -eq '1')
}

$listsDir = ''
if ($vars.ContainsKey('LISTS')) {
    $listsDir = $vars['LISTS']
    if (-not $listsDir.EndsWith('/')) { $listsDir += '/' }
    $autoFileWin = ($listsDir + 'list-auto.txt').Replace('/', '\')
    if (-not (Test-Path -LiteralPath $autoFileWin)) {
        [IO.File]::WriteAllText($autoFileWin, '', (New-Object System.Text.UTF8Encoding $false))
    }
}

$activeProfiles = New-Object System.Collections.Generic.List[System.Collections.Generic.List[string]]
$usesCircular = $false
foreach ($p in $profiles) {
    $skip = $false
    $isPureAutoHost = $false
    $hasRegularHostlist = $false
    foreach ($tk in $p) {
        if ($gfTcpOff -and $tk -ieq '--filter-tcp=12') { $skip = $true; break }
        if ($gfUdpOff -and $tk -ieq '--filter-udp=12') { $skip = $true; break }
        if ((-not $warpOn) -and $tk -ieq '--filter-udp=500,1701,2408,4500') { $skip = $true; break }
        if ($tk -match '^(?i)--hostlist=') { $hasRegularHostlist = $true }
        if ($tk -match '^(?i)--hostlist-auto=') { $isPureAutoHost = $true }
        if ($tk -match '^(?i)--lua-desync=circular\b') { $usesCircular = $true }
    }
    if ($isPureAutoHost -and -not $hasRegularHostlist) {
        $skip = $true
    }
    if (-not $skip) {
        if (-not $autoHostOn) {
            # When Z2_AUTOHOST=0, drop all --hostlist-auto* flags cleanly without converting to --hostlist
            $cleaned = New-Object System.Collections.Generic.List[string]
            foreach ($tk in $p) {
                if ($tk -match '^(?i)--hostlist-auto(=|-|$)') { continue }
                $cleaned.Add($tk)
            }
            $activeProfiles.Add($cleaned)
        } else {
            $activeProfiles.Add($p)
        }
    }
}

# 3. Auto-Hostlist (--hostlist-auto) attached directly to the main list-general.txt TCP 80/443 profile (BEFORE ipset-all.txt)
if ($autoHostOn -and $listsDir) {
    $autoHostArg = '--hostlist=' + $listsDir + 'list-auto.txt'
    $autoHostAutoArg = '--hostlist-auto=' + $listsDir + 'list-auto.txt'

    foreach ($p in $activeProfiles) {
        $hasGenList = $false
        $hasAutoList = $false
        $hasAutoHostFlag = $false
        $isTcp80_443 = $false
        $isUdp = $false
        foreach ($tk in $p) {
            if ($tk -match '(?i)^--hostlist=.*list-general\.txt$') { $hasGenList = $true }
            if ($tk -match '(?i)^--hostlist=.*list-auto\.txt$') { $hasAutoList = $true }
            if ($tk -match '(?i)^--hostlist-auto=') { $hasAutoHostFlag = $true }
            if ($tk -match '(?i)^--filter-tcp=.*443') { $isTcp80_443 = $true }
            if ($tk -match '(?i)^--filter-udp=') { $isUdp = $true }
        }
        if ($hasGenList -and $isUdp -and -not $hasAutoList) {
            $insIdx = 0
            for ($j = 0; $j -lt $p.Count; $j++) {
                if ($p[$j] -match '(?i)^--hostlist=.*list-general\.txt$') { $insIdx = $j + 1; break }
            }
            $p.Insert($insIdx, $autoHostArg)
        }
        if ($hasGenList -and $isTcp80_443) {
            for ($j = $p.Count - 1; $j -ge 0; $j--) {
                if ($p[$j] -match '(?i)^--hostlist=.*list-auto\.txt$') {
                    $p.RemoveAt($j)
                }
            }
            if (-not $hasAutoHostFlag) {
                $insIdx = 0
                for ($j = 0; $j -lt $p.Count; $j++) {
                    if ($p[$j] -match '(?i)^--hostlist=.*list-general(-user)?\.txt$') { $insIdx = $j + 1 }
                }
                $p.Insert($insIdx, '--hostlist-auto-retrans-reset=1')
                $p.Insert($insIdx, '--hostlist-auto-retrans-threshold=4')
                $p.Insert($insIdx, '--hostlist-auto-fail-time=60')
                $p.Insert($insIdx, '--hostlist-auto-fail-threshold=3')
                $p.Insert($insIdx, $autoHostAutoArg)
            }
            $hasInRange = $false
            $outRangeIdx = -1
            for ($j = 0; $j -lt $p.Count; $j++) {
                if ($p[$j] -match '^(?i)--in-range=') { $hasInRange = $true }
                if ($p[$j] -match '^(?i)--out-range=') { $outRangeIdx = $j }
            }
            if (-not $hasInRange -and $outRangeIdx -ge 0) {
                $p.Insert($outRangeIdx, '--in-range=-s4096')
            }
        }
    }
}

# 3a. Ensure QUIC UDP 443 covers list-google.txt without duplicating/shadowing existing QUIC google profiles
if ($listsDir) {
    $googleListArg = '--hostlist=' + $listsDir + 'list-google.txt'
    $anyQuicHasGoogle = $false
    foreach ($p in $activeProfiles) {
        $isQ443 = $false; $isQL7 = $false; $hasG = $false
        for ($j = 0; $j -lt $p.Count; $j++) {
            if ($p[$j] -match '(?i)^--filter-udp=.*\b443\b') { $isQ443 = $true }
            if ($p[$j] -match '(?i)^--filter-l7=.*\bquic\b') { $isQL7 = $true }
            if ($p[$j] -match '(?i)^--hostlist=.*list-google\.txt$') { $hasG = $true }
        }
        if ($isQ443 -and $isQL7 -and $hasG) { $anyQuicHasGoogle = $true; break }
    }
    if (-not $anyQuicHasGoogle) {
        foreach ($p in $activeProfiles) {
            $isQuic443 = $false
            $isQuicL7 = $false
            $hasGenList = $false
            $genIdx = -1
            for ($j = 0; $j -lt $p.Count; $j++) {
                if ($p[$j] -match '(?i)^--filter-udp=.*\b443\b') { $isQuic443 = $true }
                if ($p[$j] -match '(?i)^--filter-l7=.*\bquic\b') { $isQuicL7 = $true }
                if ($p[$j] -match '(?i)^--hostlist=.*list-general\.txt$') { $hasGenList = $true; $genIdx = $j }
            }
            if ($isQuic443 -and $isQuicL7 -and $hasGenList -and $genIdx -ge 0) {
                $p.Insert($genIdx + 1, $googleListArg)
                break
            }
        }
    }
}

# 3b. Ensure Discord UDP profile has --out-range=-d4 and list-general TCP includes port 8443
$needsTcp8443 = $false
$needsTcpEmpty = $false
foreach ($p in $activeProfiles) {
    $isDiscordUdp = $false
    $hasOutRange = $false
    $hasGenList = $false
    $tcpFilterIdx = -1
    $insertRangeIdx = -1
    for ($j = 0; $j -lt $p.Count; $j++) {
        if ($p[$j] -match '^(?i)--filter-udp=.*19294-19344') { $isDiscordUdp = $true }
        if ($p[$j] -match '^(?i)--out-range=') { $hasOutRange = $true }
        if ($p[$j] -match '(?i)^--hostlist=.*list-general\.txt$') { $hasGenList = $true }
        if ($p[$j] -match '^(?i)--filter-tcp=(.+)$') { $tcpFilterIdx = $j }
        if ($insertRangeIdx -lt 0 -and ($p[$j] -match '^(?i)--payload=' -or $p[$j] -match '^(?i)--lua-desync=')) {
            $insertRangeIdx = $j
        }
        if ($p[$j] -match '^(?i)--payload=.*\bempty\b' -or $p[$j] -match '^(?i)--lua-desync=(syndata|wssize|oob)\b') {
            $needsTcpEmpty = $true
        }
    }
    if ($isDiscordUdp -and -not $hasOutRange) {
        if ($insertRangeIdx -ge 0) { $p.Insert($insertRangeIdx, '--out-range=-d4') }
        else { $p.Add('--out-range=-d4') }
    }
    if ($hasGenList -and $tcpFilterIdx -ge 0) {
        if ($p[$tcpFilterIdx] -match '^(?i)(--filter-tcp=)(.+)$') {
            $tpts = @($matches[2] -split ',')
            if ($tpts -contains '443' -and $tpts -notcontains '8443') {
                $tpts += '8443'
                $p[$tcpFilterIdx] = $matches[1] + ($tpts -join ',')
            }
        }
    }
    if ($tcpFilterIdx -ge 0 -and $p[$tcpFilterIdx] -match '^(?i)--filter-tcp=(.+)$') {
        $allTpts = @($matches[1] -split ',')
        if ($allTpts -contains '8443') { $needsTcp8443 = $true }
    }
}

# 3c. Auto-inject --wf-tcp-empty=1 when profiles use --payload=empty, syndata, wssize, or oob
if ($needsTcpEmpty) {
    $hasTcpEmpty = $false
    foreach ($h in $header) { if ($h -match '^(?i)--wf-tcp-empty=') { $hasTcpEmpty = $true; break } }
    if (-not $hasTcpEmpty) {
        $header.Insert(0, '--wf-tcp-empty=1')
    }
}

# 3d. Ensure port 8443 is present in --wf-tcp-out unconditionally when used by any --filter-tcp
if ($needsTcp8443) {
    for ($i = 0; $i -lt $header.Count; $i++) {
        if ($header[$i] -match '^(?i)(--wf-tcp-out=)(.+)$') {
            $pts = @($matches[2] -split ',')
            if ($pts -notcontains '8443') {
                $pts += '8443'
                $header[$i] = $matches[1] + ($pts -join ',')
            }
        }
    }
}

# 4. Ensure --wf-tcp-in is present when Auto-Hostlist or circular orchestrator is active
if ($autoHostOn -or $usesCircular) {
    $hasWfTcpIn = $false
    $wfTcpOutIdx = -1
    for ($i = 0; $i -lt $header.Count; $i++) {
        if ($header[$i] -match '^(?i)(--wf-tcp-out=)(.+)$') {
            $wfTcpOutIdx = $i
            $pts = @($matches[2] -split ',')
            if ($pts -notcontains '8443') {
                $pts += '8443'
                $header[$i] = $matches[1] + ($pts -join ',')
            }
        }
        if ($header[$i] -match '^(?i)(--wf-tcp-in=)(.+)$') {
            $hasWfTcpIn = $true
            $pts = @($matches[2] -split ',')
            foreach ($reqP in @('80','443','8443')) {
                if ($pts -notcontains $reqP) { $pts += $reqP }
            }
            $header[$i] = $matches[1] + ($pts -join ',')
        }
    }
    if (-not $hasWfTcpIn) {
        $inPorts = '80,443,2053,2083,2087,2096,8443'
        if ($wfTcpOutIdx -ge 0) {
            $header.Insert($wfTcpOutIdx, '--wf-tcp-in=' + $inPorts)
        } else {
            $header.Insert(0, '--wf-tcp-in=' + $inPorts)
        }
    }
}

# 4b. Ensure --in-range=-s4096 is present on all TCP profiles when --wf-tcp-in is active
$hasAnyWfTcpIn = $false
foreach ($h in $header) {
    if ($h -match '^(?i)--wf-tcp-in=') { $hasAnyWfTcpIn = $true; break }
}
if ($hasAnyWfTcpIn) {
    foreach ($p in $activeProfiles) {
        $isTcp = $false
        $hasInRange = $false
        $insAt = -1
        for ($j = 0; $j -lt $p.Count; $j++) {
            if ($p[$j] -match '^(?i)--filter-tcp=') { $isTcp = $true }
            if ($p[$j] -match '^(?i)--in-range=') { $hasInRange = $true }
            if ($insAt -lt 0 -and ($p[$j] -match '^(?i)--out-range=' -or $p[$j] -match '^(?i)--payload=' -or $p[$j] -match '^(?i)--lua-desync=')) {
                $insAt = $j
            }
        }
        if ($isTcp -and -not $hasInRange) {
            if ($insAt -ge 0) { $p.Insert($insAt, '--in-range=-s4096') }
            else { $p.Add('--in-range=-s4096') }
        }
    }
}

# 5. Sync effective exclude list (user list-general-user.txt overrides system list-exclude.txt) and prune list-auto.txt
if ($listsDir) {
    $syncScript = Join-Path $PSScriptRoot 'sync_lists.ps1'
    if (Test-Path -LiteralPath $syncScript) {
        $syncRoot = if ($rootWin) { $rootWin } else { Split-Path -Parent $PSScriptRoot }
        & $syncScript -Root $syncRoot
    }
    $effExWin = ($listsDir + 'list-exclude.effective.txt').Replace('/', '\')
    if (Test-Path -LiteralPath $effExWin) {
        $effExArg = '--hostlist-exclude=' + $listsDir + 'list-exclude.effective.txt'
        foreach ($p in $activeProfiles) {
            for ($j = 0; $j -lt $p.Count; $j++) {
                if ($p[$j] -match '(?i)^--hostlist-exclude=.*[/\\]list-exclude\.txt$') {
                    $p[$j] = $effExArg
                }
            }
        }
    }
}

$finalTokens = New-Object System.Collections.Generic.List[string]
foreach ($h in $header) { $finalTokens.Add($h) }
for ($i = 0; $i -lt $activeProfiles.Count; $i++) {
    if ($i -gt 0) { $finalTokens.Add('--new') }
    foreach ($tk in $activeProfiles[$i]) { $finalTokens.Add($tk) }
}

$out = foreach ($tk in $finalTokens) {
    if ($tk -match '[\s\x27\x22(){}\[\]*?~]') {
        $q + ($tk -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + $q
    } else {
        $tk
    }
}
[IO.File]::WriteAllText($env:Z2_CONF, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
exit 0
