$ErrorActionPreference = 'Stop'
$q = [char]34
$vars = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($k in @('BIN','LISTS','LUA','GameFilterTCP','GameFilterUDP','GameFilter','DISCORD_FAKE','GAME_FAKE')) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($null -ne $v) { $vars[$k] = $v.Replace('\', '/') }
}
if ($env:Z2_ROOT) {
    $normR = try { [System.IO.Path]::GetFullPath($env:Z2_ROOT.Trim('"', "'")).TrimEnd('\', '/') + '/' } catch { $env:Z2_ROOT.Replace('\', '/').TrimEnd('/') + '/' }
    $vars['ROOT'] = $normR.Replace('\', '/')
    $vars['~dp0'] = $vars['ROOT']
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
    if ($vars.ContainsKey('~dp0')) {
        $s = [regex]::Replace($s, '(?i)%~dp0', { param($m) $vars['~dp0'] })
    }
    return [regex]::Replace($s, '%([A-Za-z0-9_~]+)%', {
        param($m)
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
        $vars[$matches[1]] = (Exp $matches[2]).Replace('\', '/')
        continue
    }
    if ($tr -match '(?i)^if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        $neg1 = [bool]$matches[1]; $p1 = (Exp $matches[2]).Replace('/', '\'); $ex1 = Test-Path -LiteralPath $p1
        $neg2 = [bool]$matches[3]; $p2 = (Exp $matches[4]).Replace('/', '\'); $ex2 = Test-Path -LiteralPath $p2
        if ((($neg1 -and -not $ex1) -or (-not $neg1 -and $ex1)) -and (($neg2 -and -not $ex2) -or (-not $neg2 -and $ex2))) {
            $vars[$matches[5]] = (Exp $matches[6]).Replace('\', '/')
        }
        continue
    }
    if ($tr -match '(?i)^if\s+(not\s+)?exist\s+\x22([^\x22]+)\x22\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        $neg = [bool]$matches[1]
        $p = (Exp $matches[2]).Replace('/', '\')
        $ex = Test-Path -LiteralPath $p
        if (($neg -and -not $ex) -or (-not $neg -and $ex)) {
            $vars[$matches[3]] = (Exp $matches[4]).Replace('\', '/')
        }
        continue
    }
    if ($tr -match '(?i)^if\s+not\s+defined\s+([A-Za-z0-9_]+)\s+set\s+\x22?([A-Za-z0-9_]+)=(.*?)\x22?$') {
        if (-not $vars.ContainsKey($matches[1]) -or [string]::IsNullOrEmpty($vars[$matches[1]])) {
            $vars[$matches[2]] = (Exp $matches[3]).Replace('\', '/')
        }
        continue
    }
}

if (-not $cmdLine) {
    if (($lines -join ' ') -match '(?i)winws\.exe') { exit 2 } else { exit 3 }
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

# 0. WARP Unblock toggle check
$warpOn = $true
if ($env:Z2_ROOT) {
    $warpFlag = Join-Path $env:Z2_ROOT 'utils\warp_unblock.enabled'
    if (-not (Test-Path -LiteralPath $warpFlag)) { $warpOn = $false }
}
# 1. NLM Filter (--nlm-filter) injection
$nlmVal = $env:Z2_NLM
if ([string]::IsNullOrWhiteSpace($nlmVal) -and $env:Z2_ROOT) {
    $nlmAutoFlag = Join-Path $env:Z2_ROOT 'utils\nlm_auto.enabled'
    $nlmHelperPs = Join-Path $env:Z2_ROOT 'utils\nlm_helper.ps1'
    if ((Test-Path -LiteralPath $nlmAutoFlag) -and (Test-Path -LiteralPath $nlmHelperPs)) {
        try { & $nlmHelperPs -Action auto -Root $env:Z2_ROOT | Out-Null } catch {}
    }
    $nlmFile = Join-Path $env:Z2_ROOT 'utils\nlm_filter.enabled'
    if (Test-Path -LiteralPath $nlmFile) {
        $nlmFirst = Get-Content -LiteralPath $nlmFile -Encoding UTF8 | Select-Object -First 1; if ($null -ne $nlmFirst) { $nlmVal = $nlmFirst.Trim() }
    }
}
if (-not [string]::IsNullOrWhiteSpace($nlmVal) -and $nlmVal -match '^(?i)(NEG:|!)?[0-9A-Fa-f{}\-,]+$') {
    $hasNlm = $false
    foreach ($h in $header) { if ($h -match '^(?i)--nlm-filter=') { $hasNlm = $true; break } }
    if (-not $hasNlm) {
        if ($nlmVal -match '^(?i)NEG:(.+)$') {
            $cleanNlm = $matches[1].Trim()
            if ($cleanNlm) {
                $header.Add('--nlm-filter=' + $cleanNlm)
                $header.Add('--nlm-filter-neg=1')
            }
        } elseif ($nlmVal.StartsWith('!')) {
            $cleanNlm = $nlmVal.Substring(1).Trim()
            if ($cleanNlm) {
                $header.Add('--nlm-filter=' + $cleanNlm)
                $header.Add('--nlm-filter-neg=1')
            }
        } else {
            $header.Add('--nlm-filter=' + $nlmVal)
        }
    }
}

# 2. Strip disabled GameFilter (port 12)
$gfTcpOff = (-not $vars.ContainsKey('GameFilterTCP')) -or ($vars['GameFilterTCP'] -eq '12')
$gfUdpOff = (-not $vars.ContainsKey('GameFilterUDP')) -or ($vars['GameFilterUDP'] -eq '12')

$kernelFilterOn = ($env:Z2_ROOT -and (Test-Path -LiteralPath (Join-Path $env:Z2_ROOT 'utils\kernel_filter.enabled')))
$removeHeaderIdx = New-Object System.Collections.Generic.List[int]
$wideUdpPorts = @('443','500','1701','2408','4500','19294-19344','50000-50100')

for ($i = 0; $i -lt $header.Count; $i++) {
    if ($gfTcpOff -and $header[$i] -match '^(?i)(--wf-tcp-(?:out|in)=)(.+)$') {
        $pts = ($matches[2] -split ',') | Where-Object { $_ -ne '12' -and $_ -ne '' }
        $header[$i] = $matches[1] + ($pts -join ',')
    }
    if ($header[$i] -match '^(?i)(--wf-udp-(?:out|in)=)(.+)$') {
        $pts = @($matches[2] -split ',' | Where-Object { $_ -ne '' })
        if ($gfUdpOff) { $pts = @($pts | Where-Object { $_ -ne '12' }) }
        if (-not $warpOn) { $pts = @($pts | Where-Object { $_ -notin @('500','1701','2408','4500') }) }
        if ($kernelFilterOn -and $vars.ContainsKey('BIN')) {
            $kfBin = $vars['BIN'].Replace('/', '\')
            foreach ($kfReq in @('windivert_part.quic_initial_ietf.txt','windivert_part.discord_media.txt','windivert_part.stun.txt','windivert_part.wireguard.txt')) {
                if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $kfBin 'filters') $kfReq))) { $kernelFilterOn = $false; break }
            }
        }
        if ($kernelFilterOn) {
            # Keep only GameFilterUDP (or custom ports); wide UDP ports move to --wf-raw-part
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
if ($kernelFilterOn -and $vars.ContainsKey('BIN')) {
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
if ($env:Z2_ROOT) {
    $wfPrioFile = Join-Path $env:Z2_ROOT 'utils\wf_priority.conf'
    if (Test-Path -LiteralPath $wfPrioFile) {
        $pRaw = (Get-Content -LiteralPath $wfPrioFile -TotalCount 1 -ErrorAction SilentlyContinue)
        $pInt = 0
        if ($null -ne $pRaw -and [int]::TryParse($pRaw.Trim(), [ref]$pInt) -and $pInt -ne 0 -and $pInt -ge -30000 -and $pInt -le 30000) {
            $header.Add('--wf-priority=' + $pInt)
        }
    }
}

if ([string]::IsNullOrEmpty($env:Z2_AUTOHOST)) {
    $autoHostOn = ($env:Z2_ROOT -and (Test-Path -LiteralPath (Join-Path $env:Z2_ROOT 'utils\autohostlist.enabled')))
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
            $cleaned = New-Object System.Collections.Generic.List[string]
            foreach ($tk in $p) {
                if ($tk -match '^(?i)--hostlist-auto(-|$)') {
                    if ($tk -match '^(?i)--hostlist-auto=(.+)$') {
                        $cleaned.Add('--hostlist=' + $matches[1])
                    }
                    continue
                }
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
            # Remove plain --hostlist=list-auto.txt if present and replace/ensure --hostlist-auto=list-auto.txt
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
                $p.Insert($insIdx, '--hostlist-auto-retrans-threshold=3')
                $p.Insert($insIdx, '--hostlist-auto-fail-time=60')
                $p.Insert($insIdx, '--hostlist-auto-fail-threshold=2')
                $p.Insert($insIdx, $autoHostAutoArg)
            }
            # Ensure --in-range=-s4096 is present so incoming RST/redirect detection works
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

# 3b. Ensure Discord UDP profile has --out-range=-d4 and list-general TCP includes port 8443
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

$finalTokens = New-Object System.Collections.Generic.List[string]
foreach ($h in $header) { $finalTokens.Add($h) }
for ($i = 0; $i -lt $activeProfiles.Count; $i++) {
    if ($i -gt 0) { $finalTokens.Add('--new') }
    foreach ($tk in $activeProfiles[$i]) { $finalTokens.Add($tk) }
}

$out = foreach ($tk in $finalTokens) {
    if ($tk -match '[\s\x27\x22(){}\[\]*?~]') {
        $q + $tk + $q
    } else {
        $tk
    }
}
[IO.File]::WriteAllText($env:Z2_CONF, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
