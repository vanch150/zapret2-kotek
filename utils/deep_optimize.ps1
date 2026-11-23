param(
    [string]$Root = '',
    [switch]$NonInteractive
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
$Root = Resolve-Z2Root $Root
if (-not (Test-Z2IsAdmin)) {
    Write-Host '  [X] Требуются права администратора — запустите от имени администратора.' -ForegroundColor Red
    exit 1
}

$TestTargets = @(Get-Z2Targets -Root $Root -Mode 'ALL')
$TestUrls = @($TestTargets | ForEach-Object { $_.Url })
$ytTotal  = @($TestTargets | Where-Object { $_.Cat -eq 'YT' }).Count
$dcTotal  = @($TestTargets | Where-Object { $_.Cat -eq 'DC' }).Count
$webTotal = @($TestTargets | Where-Object { $_.Cat -eq 'WEB' }).Count

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
$verHdr = Get-Z2Version $Root
Write-Host "     ZAPRET2 KOTEK v$verHdr — ГЛУБОКИЙ ТЕСТ И СИНТЕЗ СТРАТЕГИИ     " -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "  Прогоняет ВСЕ стратегии (strategies + configs_archive) по $($TestUrls.Count) целям," -ForegroundColor Gray
Write-Host '  находит чемпионов отдельно для YouTube, Discord и Web, и собирает' -ForegroundColor Gray
Write-Host '  гибридный конфиг custom_auto_synthesized.bat под твоего провайдера' -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray

$curlExe = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

$curlHasParallel = $false
try {
    $curlHelp = & $curlExe --help all 2>$null | Out-String
    if ($curlHelp -match '--parallel') { $curlHasParallel = $true }
} catch {}

# Collect all candidate .bat files from strategies\ + configs_archive\ (deduplicated via $seenBats)
$skipBats = @('1_AUTO_SETUP.bat','2_KOTEK.bat','!_START_KOTEK.bat','KOTEK.bat','AUTO_SETUP.bat','PAUSE_RESUME.bat','UNINSTALL.bat','DEEP_OPTIMIZE.bat','service.bat','custom_auto_synthesized.bat')
$allBats = @()
$seenBats = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
foreach ($d in @((Join-Path $Root 'strategies'), $Root)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    Get-ChildItem -LiteralPath $d -Filter '*.bat' -File | Sort-Object Name | ForEach-Object {
        if ($skipBats -notcontains $_.Name -and $seenBats.Add($_.Name)) { $allBats += $_ }
    }
}
$archDir = Join-Path $Root 'configs_archive'
if (Test-Path -LiteralPath $archDir) {
    Get-ChildItem -LiteralPath $archDir -Filter '*.bat' -File | Sort-Object Name | ForEach-Object {
        if ($skipBats -notcontains $_.Name -and $seenBats.Add($_.Name)) { $allBats += $_ }
    }
}

Write-Host "`n  [*] Найдено стратегий для глубокого теста: $($allBats.Count)" -ForegroundColor Yellow
Write-Host '  [*] Останавливаю текущую службу zapret на время бенчмарка...' -ForegroundColor Gray
$preSvc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$wasRunning = ($null -ne $preSvc -and $preSvc.Status -eq 'Running')
Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

$padHdr = 'X-Pad: ' + ('A' * 3072)
$invCulture = [System.Globalization.CultureInfo]::InvariantCulture
$liveConfPath = Join-Path $Root 'bin\service.conf'
$probeConfPath = Join-Path $env:TEMP "z2_deep_$PID.conf"
$winwsExe = Join-Path $Root 'bin\winws2.exe'

function Invoke-StrategyProbe([string]$batFullPath, [string]$displayName) {
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $batFullPath
    $env:Z2_CONF = $probeConfPath
    $env:Z2_AUTOHOST = '0'
    $env:Z2_SKIP_NLM_AUTO = '1'
    $env:BIN = Join-Path $Root 'bin\'
    $env:LISTS = Join-Path $Root 'lists\'
    $env:LUA = Join-Path $Root 'lua\'
    $env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
    $env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'
    $env:GameFilter = '12'
    $env:GameFilterTCP = '12'
    $env:GameFilterUDP = '12'

    try {
        $global:LASTEXITCODE = 0
        & (Join-Path $Root 'utils\build_service_conf.ps1')
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeConfPath)) { return $null }
    } catch { return $null }

    $proc = $null
    try {
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$probeConfPath`"" -WindowStyle Hidden -PassThru
    } catch { return $null }
    Start-Sleep -Milliseconds 650
    if ($null -eq $proc -or $proc.HasExited) {
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
        return $null
    }

    $okCount = 0; $totalMs = 0.0
    $ytHits = 0; $ytMs = 0.0
    $dcHits = 0; $dcMs = 0.0
    $webHits = 0; $webMs = 0.0
    $rawLines = @()

    if ($curlHasParallel) {
        $cArgs = @('-Z', '--parallel-max', '28')
        $heavyRx = 'speed\.cloudflare\.com|^https?://www\.youtube\.com/?$|i\.ytimg\.com/.+maxresdefault\.jpg'
        $curlFmt = '%{url_effective}|%{http_code}|%{time_total}|%{size_download}|%{exitcode}|%{speed_download}'
        for ($ui = 0; $ui -lt $TestUrls.Count; $ui++) {
            if ($ui -gt 0) { $cArgs += '-:' }
            $u = $TestUrls[$ui]
            $tLim = if ($u -match $heavyRx) { '6' } else { '4' }
            $cArgs += @('-4', '-s', '--max-time', $tLim, '-w', ($curlFmt + '\n'), '-o', 'NUL')
            if ($u -eq 'https://one.one.one.one' -or $u -eq 'https://cloudflare-dns.com') {
                $cArgs += @('-H', $padHdr)
            }
            $cArgs += $u
        }
        try {
            $codesOut = & $curlExe @cArgs 2>$null
            $rawLines = ($codesOut -split "`r?`n")
        } catch {}
    } else {
        $heavyRx = 'speed\.cloudflare\.com|^https?://www\.youtube\.com/?$|i\.ytimg\.com/.+maxresdefault\.jpg'
        $curlFmt = '%{url_effective}|%{http_code}|%{time_total}|%{size_download}|%{exitcode}|%{speed_download}'
        foreach ($u in $TestUrls) {
            try {
                $tLim = if ($u -match $heavyRx) { '6' } else { '4' }
                $one = if ($u -eq 'https://one.one.one.one' -or $u -eq 'https://cloudflare-dns.com') {
                    & $curlExe -4 -s -H $padHdr -o NUL -w $curlFmt --max-time $tLim $u 2>$null
                } else {
                    & $curlExe -4 -s -o NUL -w $curlFmt --max-time $tLim $u 2>$null
                }
                if ($one) { $rawLines += $one }
            } catch {}
        }
    }

    $cfFreezeOk = $false; $ytFreezeOk = $false; $canaryHits = 0
    foreach ($line in $rawLines) {
        $tr = $line.Trim()
        if (-not $tr) { continue }
        $parts = $tr -split '\|'
        if ($parts.Count -lt 3) { continue }
        $uEff = $parts[0].ToLowerInvariant()
        $code = $parts[1].Trim()
        $tStr = $parts[2].Trim().Replace(',', '.')
        $dlBytes = 0L
        if ($parts.Count -ge 4) { [void][long]::TryParse($parts[3].Trim(), [ref]$dlBytes) }
        $secVal = 0.0
        $ms = 500.0
        if ([double]::TryParse($tStr, [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$secVal)) {
            $ms = $secVal * 1000.0
        }
        $isHeavy = ($uEff -match $heavyRx)
        $targetMax = if ($isHeavy) { 6.0 } else { 4.0 }
        $exitOk = $true
        if ($parts.Count -ge 5 -and $parts[4].Trim() -match '^\d+$') {
            $exitOk = ($parts[4].Trim() -eq '0')
        } elseif ($secVal -ge ($targetMax - 0.15)) {
            $exitOk = $false
        }
        $spdBytes = 0.0
        if ($parts.Count -ge 6) { [void][double]::TryParse($parts[5].Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$spdBytes) }
        if (-not $exitOk) { continue }
        if ($code -match '^(200|204|301|302|307|308|400|403|404)$') {
            if ($uEff -match '^https?://www\.youtube\.com/?$' -and $code -eq '200' -and $dlBytes -lt 65536) { continue }
            if ($uEff -match 'speed\.cloudflare\.com') {
                $cfMin = if ($uEff -match '262144') { 200000L } else { 50000L }
                if ($dlBytes -lt $cfMin) { continue }
                $cfFreezeOk = $true
            }
            $okCount++
            $totalMs += $ms
            if (($uEff -match 'i\.ytimg\.com/.+maxresdefault\.jpg' -or $uEff -match '^https?://www\.youtube\.com/?$') -and $code -eq '200' -and $dlBytes -ge 65536 -and $spdBytes -ge 40000) {
                $ytFreezeOk = $true
            }
            if ($uEff -match 'github\.com|githubusercontent\.com' -and $ms -le 2000.0) { $canaryHits++ }
            if ($uEff -match 'youtube\.com|ytimg\.com|ggpht\.com|googleapis\.com|googlevideo\.com|play\.google\.com') {
                $ytHits++; $ytMs += $ms
            } elseif ($uEff -match 'discord\.com|discordapp\.com|discordapp\.net|discord\.gg') {
                $dcHits++; $dcMs += $ms
            } elseif ($uEff -notmatch 'telegram\.org|t\.me') {
                $webHits++; $webMs += $ms
            }
        }
    }
    $freezeOk = ($cfFreezeOk -and $ytFreezeOk)

    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch {}
    }
    Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

    $avgMs = if ($okCount -gt 0) { [int][Math]::Round($totalMs / $okCount) } else { 3000 }
    $ytAvg = if ($ytHits -gt 0) { [int][Math]::Round($ytMs / $ytHits) } else { 3000 }
    $dcAvg = if ($dcHits -gt 0) { [int][Math]::Round($dcMs / $dcHits) } else { 3000 }
    $webAvg = if ($webHits -gt 0) { [int][Math]::Round($webMs / $webHits) } else { 3000 }

    $ytScore  = ($ytHits * 100) + ($(if ($ytFreezeOk) { 120 } else { 0 })) + [Math]::Max(0, [int](50 - ($ytAvg / 40.0)))
    $dcScore  = ($dcHits * 100) + [Math]::Max(0, [int](50 - ($dcAvg / 40.0)))
    $webScore = ($webHits * 100) + ($(if ($cfFreezeOk) { 80 } else { 0 })) + [Math]::Max(0, [int](50 - ($webAvg / 40.0)))
    $canaryPen = if ($canaryHits -eq 0 -and $okCount -ge 6) { -30 } else { 0 }
    $totScore = ($okCount * 20) + ($(if ($ytHits -ge 2 -and $ytFreezeOk) { 45 } else { 0 })) + ($(if ($ytFreezeOk) { 35 } else { 0 })) + ($(if ($dcHits -ge 2) { 35 } else { 0 })) + ($(if ($cfFreezeOk) { 30 } else { 0 })) + [Math]::Max(0, [int](30 - ($avgMs / 50.0))) + $canaryPen

    $frLbl = if ($freezeOk) { 'OK  ' } else { 'SLOW' }
    Write-Host ("`r" + (" " * 86) + "`r") -NoNewline
    Write-Host ("  - {0,-34} : {1,2}/$($TestUrls.Count) | YT:{2}/$ytTotal DC:{3}/$dcTotal WEB:{4}/$webTotal | 16-20KB:{5} | ~{6,4} мс" -f $displayName, $okCount, $ytHits, $dcHits, $webHits, $frLbl, $avgMs) -ForegroundColor Gray

    try {
        $scFile = Join-Path $Root 'utils\strategy_scores.json'
        $scMap = @{}
        if (Test-Path -LiteralPath $scFile) {
            $prevSc = Get-Content -LiteralPath $scFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prevSc) { foreach ($pr in $prevSc.PSObject.Properties) { $scMap[$pr.Name] = $pr.Value } }
        }
        $leafKey = [System.IO.Path]::GetFileName($batFullPath)
        $scMap[$leafKey] = [PSCustomObject]@{ ok=$okCount; total=$TestUrls.Count; ms=$avgMs; yt=($ytHits -ge 2); dc=($dcHits -ge 2); ytHits=$ytHits; ytTotal=$ytTotal; dcHits=$dcHits; dcTotal=$dcTotal; freeze=$freezeOk; ytF=$ytFreezeOk; cfF=$cfFreezeOk; ts=(Get-Date -Format 'yyyy-MM-dd HH:mm') }
        [System.IO.File]::WriteAllText($scFile, ($scMap | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    return [PSCustomObject]@{
        Name      = $displayName
        Path      = $batFullPath
        OkCount   = $okCount
        AvgMs     = $avgMs
        FreezeOk  = $freezeOk
        YtFreezeOk = $ytFreezeOk
        CfFreezeOk = $cfFreezeOk
        YtHits    = $ytHits
        YtAvg     = $ytAvg
        YtScore   = $ytScore
        DcHits    = $dcHits
        DcAvg     = $dcAvg
        DcScore   = $dcScore
        WebHits   = $webHits
        WebAvg    = $webAvg
        WebScore  = $webScore
        TotScore  = $totScore
    }
}

# Helper: extract --blob, --lua-init, and profile lines from a strategy .bat
function Parse-BatStrategy([string]$batFile) {
    $raw = Get-Content -LiteralPath $batFile -Encoding UTF8
    $joined = ''
    foreach ($l in $raw) {
        $t = $l.TrimEnd()
        if ($t.EndsWith('^')) { $joined += $t.Substring(0, $t.Length - 1) + ' ' }
        else { $joined += $t + "`n" }
    }
    $cmdLine = ($joined -split "`n" | Where-Object { $_ -notmatch '^\s*(::|REM\b)' -and $_ -match '(?i)^\s*(?:start\s+.*?\s+)?"?[^"]*winws2\.exe"?\s+--' } | Select-Object -First 1)
    if (-not $cmdLine) { return $null }
    $idx = $cmdLine.ToLowerInvariant().IndexOf('winws2.exe')
    $rest = $cmdLine.Substring($idx + 10).TrimStart()
    if ($rest.StartsWith('"')) { $rest = $rest.Substring(1).TrimStart() }

    $blobs = [ordered]@{}
    foreach ($m in [regex]::Matches($rest, '--blob=([A-Za-z0-9_]+):(@(?:"[^"]+"|\S+)|\S+)')) {
        $blobs[$m.Groups[1].Value] = $m.Value
    }
    $luas = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($rest, '--lua-init=@(?:"[^"]+"|\S+)')) {
        if (-not $luas.Contains($m.Value)) { $luas.Add($m.Value) }
    }

    $fIdx = $rest.IndexOf('--filter-')
    if ($fIdx -lt 0) { return $null }
    $profText = $rest.Substring($fIdx)
    $profs = @($profText -split '\s+--new\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    return [PSCustomObject]@{
        Blobs    = $blobs
        Luas     = $luas
        Profiles = $profs
    }
}

$installedNewService = $false
$exitCode = 0

try {
    $results = @()
    $catFrames = @('(=^.^=) .  ', '(=^.^=) .. ', '(=^.^=) ...', '(=-.-=) ...', '(=-.-=)  ~ ', '(=^.^=)    ')
    $catStep = 0
    foreach ($bf in $allBats) {
        $catStep++
        $cf = $catFrames[$catStep % $catFrames.Count]
        Write-Host ("`r  {0}  [{1}/{2}] Тестирую {3,-32} ..." -f $cf, $catStep, $allBats.Count, $bf.Name) -NoNewline -ForegroundColor Cyan
        $relName = if ($bf.DirectoryName -match 'configs_archive$') { "archive\$($bf.Name)" } else { $bf.Name }
        $r = Invoke-StrategyProbe -batFullPath $bf.FullName -displayName $relName
        if ($r) { $results += $r }
    }

    if ($results.Count -eq 0) {
        Write-Host "`n  [X] Не удалось протестировать ни одной стратегии (прежняя служба будет восстановлена)." -ForegroundColor Red
        $exitCode = 1
        throw "Z2_ABORT"
    }

    $rankedOverall = @($results | Sort-Object -Property TotScore -Descending)
    $rankedYt      = @($results | Sort-Object -Property YtScore, TotScore -Descending)
    $rankedDc      = @($results | Sort-Object -Property DcScore, TotScore -Descending)
    $rankedWeb     = @($results | Sort-Object -Property WebScore, TotScore -Descending)

    $bestOverall = $rankedOverall[0]
    if ($bestOverall.OkCount -le 0) {
        Write-Host "`n  [X] Все стратегии показали 0/$($TestUrls.Count) (проверь интернет/VPN — прежняя служба будет восстановлена)." -ForegroundColor Red
        $exitCode = 1
        throw "Z2_ABORT"
    }
    $bestYt      = $rankedYt[0]
    $bestDc      = $rankedDc[0]
    $bestWeb     = $rankedWeb[0]

    Write-Host "`n  ==================================================================" -ForegroundColor Cyan
    Write-Host "  [ЧЕМПИОНЫ ПО КАТЕГОРИЯМ]" -ForegroundColor Cyan
    Write-Host ("    YouTube (list-google) : {0} ({1}/$ytTotal, ~{2} мс)" -f $bestYt.Name, $bestYt.YtHits, $bestYt.YtAvg) -ForegroundColor Green
    Write-Host ("    Discord (TCP/Media)   : {0} ({1}/$dcTotal, ~{2} мс)" -f $bestDc.Name, $bestDc.DcHits, $bestDc.DcAvg) -ForegroundColor Green
    Write-Host ("    Web + 16-20KB         : {0} ({1}/$webTotal, ~{2} мс)" -f $bestWeb.Name, $bestWeb.WebHits, $bestWeb.WebAvg) -ForegroundColor Green
    Write-Host ("    Лучшая целиком        : {0} ({1}/$($TestUrls.Count), ~{2} мс)" -f $bestOverall.Name, $bestOverall.OkCount, $bestOverall.AvgMs) -ForegroundColor Yellow
    Write-Host '  ==================================================================' -ForegroundColor Cyan

    Write-Host "`n  [*] Синтезирую гибридный конфиг custom_auto_synthesized.bat..." -ForegroundColor Yellow

    # Cache parsed strategies and support fallback to next-best candidate when champion lacks a section (2.6)
    $parsedCache = @{}
    function Get-ParsedCached([string]$p) {
        if (-not $parsedCache.ContainsKey($p)) { $parsedCache[$p] = Parse-BatStrategy $p }
        return $parsedCache[$p]
    }

    $mergedBlobs = [ordered]@{}
    $mergedLuas  = New-Object System.Collections.Generic.List[string]
    $mergedPaths = @{}
    $tagSeq = 0

    function Merge-StrategyAssets([object]$parsed, [string]$pathKey) {
        if (-not $parsed) { return }
        if ($mergedPaths.ContainsKey($pathKey)) { return }
        $mergedPaths[$pathKey] = $true
        $script:tagSeq++
        $tag = if ($script:tagSeq -eq 1) { '' } else { "_s$($script:tagSeq)" }
        foreach ($k in @($parsed.Blobs.Keys)) {
            $def = $parsed.Blobs[$k]
            if (-not $mergedBlobs.Contains($k)) {
                $mergedBlobs[$k] = $def
            } elseif ($mergedBlobs[$k] -ine $def -and $tag) {
                $newK = $k + $tag
                $mergedBlobs[$newK] = $def -replace ("^--blob=" + [regex]::Escape($k) + ":"), ("--blob=" + $newK + ":")
                for ($pi = 0; $pi -lt $parsed.Profiles.Count; $pi++) {
                    $parsed.Profiles[$pi] = $parsed.Profiles[$pi] -replace ("(blob=|seqovl_pattern=)" + [regex]::Escape($k) + "(?=[:\s]|$)"), ("`$1" + $newK)
                }
            }
        }
        foreach ($lu in $parsed.Luas) {
            if (-not $mergedLuas.Contains($lu)) { $mergedLuas.Add($lu) }
        }
    }

    function Pick-ProfilesWithFallback([object[]]$rankedList, [scriptblock]$predicate) {
        foreach ($cand in $rankedList) {
            $parsed = Get-ParsedCached $cand.Path
            if (-not $parsed) { continue }
            $hits = @($parsed.Profiles | Where-Object $predicate)
            if ($hits.Count -gt 0) {
                Merge-StrategyAssets $parsed $cand.Path
                # Re-query after potential blob rename during merge
                return @($parsed.Profiles | Where-Object $predicate)
            }
        }
        return @()
    }

    $profQuicGen   = Pick-ProfilesWithFallback $rankedWeb { $_ -match '--filter-udp=443' -and $_ -match 'list-general\.txt' }
    $profWarp      = Pick-ProfilesWithFallback $rankedWeb { $_ -match '--filter-udp=500,1701,2408,4500' }
    $profDiscUdp   = Pick-ProfilesWithFallback $rankedDc  { $_ -match '19294-19344' }
    $profDiscTcp   = Pick-ProfilesWithFallback $rankedDc  { $_ -match 'discord\.media' }
    $profDiscWeb   = @()
    if ($bestDc.Path -ne $bestWeb.Path) {
        $dcGens = Pick-ProfilesWithFallback $rankedDc { $_ -match '--filter-tcp=' -and $_ -match 'list-general\.txt' }
        foreach ($dcGen in $dcGens) {
            $dcCustom = [regex]::Replace($dcGen, '--hostlist=(?:"[^"]+"|\S+)\s*', '')
            $dcCustom = [regex]::Replace($dcCustom, '--hostlist-auto(?:-[a-z-]+)?=(?:"[^"]+"|\S+)\s*', '')
            $dcCustom = [regex]::Replace($dcCustom, '(--filter-tcp=\S+)', '$1 --hostlist-domains=discord.com,discordapp.com,discordapp.net,discord.gg', 1)
            $profDiscWeb += $dcCustom.Trim()
        }
    }
    $profYtTcp     = Pick-ProfilesWithFallback $rankedYt  { $_ -match '--filter-tcp=' -and $_ -match 'list-google\.txt' }
    $profGenTcp    = Pick-ProfilesWithFallback $rankedWeb { $_ -match '--filter-tcp=' -and $_ -match 'list-general\.txt' }
    $profQuicIpset = Pick-ProfilesWithFallback $rankedWeb { $_ -match '--filter-udp=443' -and $_ -match 'ipset-all\.txt' }
    $profIpsetTcp  = Pick-ProfilesWithFallback $rankedWeb { $_ -match '--filter-tcp=' -and $_ -match 'ipset-all\.txt' -and $_ -notmatch '%GameFilterTCP%' }
    $profGameTcp   = Pick-ProfilesWithFallback $rankedWeb { $_ -match '%GameFilterTCP%' }
    $profGameUdp   = Pick-ProfilesWithFallback $rankedWeb { $_ -match '%GameFilterUDP%' }

    $chosenProfiles = @()
    foreach ($grp in @($profQuicGen, $profWarp, $profDiscUdp, $profDiscTcp, $profDiscWeb, $profYtTcp, $profGenTcp, $profQuicIpset, $profIpsetTcp, $profGameTcp, $profGameUdp)) {
        foreach ($pr in $grp) {
            if (-not [string]::IsNullOrWhiteSpace($pr)) { $chosenProfiles += $pr }
        }
    }

    $synthPath = Join-Path $Root 'strategies\custom_auto_synthesized.bat'
    $batLines = New-Object System.Collections.Generic.List[string]
    $batLines.Add('@echo off')
    $batLines.Add('chcp 65001 > nul')
    $batLines.Add(":: Auto-Synthesized Strategy by DEEP_OPTIMIZE.bat")
    $batLines.Add(":: YouTube: $($bestYt.Name) | Discord: $($bestDc.Name) | Web: $($bestWeb.Name)")
    $batLines.Add('')
    $batLines.Add('set "ROOT=%~dp0"')
    $batLines.Add('if exist "%~dp0..\utils\service.bat" set "ROOT=%~dp0..\"')
    $batLines.Add('cd /d "%ROOT%"')
    $batLines.Add('call "%ROOT%utils\service.bat" status_zapret')
    $batLines.Add('call "%ROOT%utils\service.bat" check_updates')
    $batLines.Add('call "%ROOT%utils\service.bat" load_game_filter')
    $batLines.Add('call "%ROOT%utils\service.bat" load_user_lists')
    $batLines.Add('call "%ROOT%utils\service.bat" load_autohost')
    $batLines.Add('call "%ROOT%utils\service.bat" load_nlm_filter')
    $batLines.Add('echo:')
    $batLines.Add('')
    $batLines.Add('chcp 65001 > nul')
    $batLines.Add('if not defined GameFilterTCP set "GameFilterTCP=12"')
    $batLines.Add('if not defined GameFilterUDP set "GameFilterUDP=12"')
    $batLines.Add('set "BIN=%ROOT%bin\"')
    $batLines.Add('set "LISTS=%ROOT%lists\"')
    $batLines.Add('set "LUA=%ROOT%lua\"')
    $batLines.Add('if not exist "%LUA%zapret-lib.lua" if exist "%BIN%lua\zapret-lib.lua" set "LUA=%BIN%lua\"')
    $batLines.Add('if not exist "%LUA%zapret-lib.lua" if exist "%BIN%zapret-lib.lua" set "LUA=%BIN%"')
    $batLines.Add('set "DISCORD_FAKE=%BIN%ACTIVE_DISCORD_UDP.bin"')
    $batLines.Add('if not exist "%DISCORD_FAKE%" set "DISCORD_FAKE=%BIN%quic_initial_www_google_com.bin"')
    $batLines.Add('set "GAME_FAKE=%BIN%ACTIVE_GAME_UDP.bin"')
    $batLines.Add('if not exist "%GAME_FAKE%" set "GAME_FAKE=%BIN%quic_initial_www_google_com.bin"')
    $batLines.Add('cd /d "%BIN%"')
    $batLines.Add('')
    $needTcpEmpty = ($chosenProfiles -join ' ') -match '(?i)(--payload=empty|syndata|wssize|oob)'
    $tcpEmptyFlag = if ($needTcpEmpty) { '--wf-tcp-empty=1 ' } else { '' }
    $batLines.Add(('start "zapret2: %~n0" /min "%BIN%winws2.exe" ' + $tcpEmptyFlag + '--wf-tcp-in=80,443,2053,2083,2087,2096,8443 --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,500,1701,2408,4500,19294-19344,50000-50100,%GameFilterUDP% ^'))
    $batLines.Add(($mergedLuas -join ' ') + ' ^')
    $batLines.Add((@($mergedBlobs.Values) -join ' ') + ' ^')
    for ($i = 0; $i -lt $chosenProfiles.Count; $i++) {
        if ($i -lt ($chosenProfiles.Count - 1)) {
            $batLines.Add($chosenProfiles[$i] + ' --new ^')
        } else {
            $batLines.Add($chosenProfiles[$i])
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($synthPath, ($batLines -join "`r`n") + "`r`n", $utf8NoBom)

    Write-Host "`n  [*] Контрольный тест синтезированного custom_auto_synthesized.bat..." -ForegroundColor Yellow
    $synthRes = Invoke-StrategyProbe -batFullPath $synthPath -displayName 'custom_auto_synthesized.bat'

    if (-not $synthRes -or $synthRes.TotScore -lt $bestOverall.TotScore) {
        $installBat = $bestOverall.Path
        $installName = $bestOverall.Name
        $synthInfo = if ($synthRes) { "$($synthRes.OkCount)/$($TestUrls.Count)" } else { "ошибка" }
        Write-Host "`n  [ПОБЕДИТЕЛЬ] Лучшая стратегия: $installName ($($bestOverall.OkCount)/$($TestUrls.Count), ~$($bestOverall.AvgMs) мс — лучше гибрида $synthInfo)." -ForegroundColor Green
    } else {
        $installBat = $synthPath
        $installName = 'custom_auto_synthesized.bat'
        Write-Host "`n  [ПОБЕДИТЕЛЬ] Гибрид $installName стал лучшим ($($synthRes.OkCount)/$($TestUrls.Count), ~$($synthRes.AvgMs) мс)!" -ForegroundColor Green
    }

    # Save anonymized hybrid recipe for GUI & opt-in telemetry statistics
    try {
        $winResObj = if ($installName -eq 'custom_auto_synthesized.bat' -and $null -ne $synthRes) { $synthRes } else { $bestOverall }
        $udpFakeNow = ''
        $ufFile = Join-Path $Root 'utils\active_udp_fake.txt'
        if (Test-Path -LiteralPath $ufFile) { $udpFakeNow = ([string](Get-Content -LiteralPath $ufFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() }
        $hybObj = [PSCustomObject]@{
            yt     = Split-Path -Leaf $bestYt.Path
            dc     = Split-Path -Leaf $bestDc.Path
            web    = Split-Path -Leaf $bestWeb.Path
            udp    = $udpFakeNow
            winner = Split-Path -Leaf $installBat
            ok     = [int]$winResObj.OkCount
            total  = [int]$TestUrls.Count
            pct    = if ($TestUrls.Count -gt 0) { [int][Math]::Round(100.0 * $winResObj.OkCount / $TestUrls.Count) } else { 0 }
            ytF    = [bool]$winResObj.YtFreezeOk
            cfF    = [bool]$winResObj.CfFreezeOk
            ms     = [int]$winResObj.AvgMs
            ts     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        [System.IO.File]::WriteAllText((Join-Path $Root 'utils\last_hybrid.json'), ($hybObj | ConvertTo-Json -Compress), $utf8NoBom)
    } catch {}

    $ans = if ($NonInteractive) { "y" } else { Read-Host "`n  Установить победителя ($installName) в службу zapret прямо сейчас? [Д/н] (Enter = Да)" }
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans -notmatch '^[nNнН]') {
        $gfFile = Join-Path $Root 'utils\game_filter.enabled'
        $gfTcp = '12'; $gfUdp = '12'; $gfMode = 'disabled'; $tcpR = '1024-65535'; $udpR = '1024-65535'
        if (Test-Path -LiteralPath $gfFile) {
            foreach ($gl in (Get-Content -LiteralPath $gfFile)) {
                if ($gl -match '^(?i)mode=(.+)$') { $gfMode = $matches[1].Trim() }
                elseif ($gl -match '^(?i)tcp=(.+)$') { $tcpR = $matches[1].Trim() }
                elseif ($gl -match '^(?i)udp=(.+)$') { $udpR = $matches[1].Trim() }
            }
            if ($gfMode -ieq 'all') { $gfTcp = $tcpR; $gfUdp = $udpR }
            elseif ($gfMode -ieq 'tcp') { $gfTcp = $tcpR }
            elseif ($gfMode -ieq 'udp') { $gfUdp = $udpR }
        }
        $env:GameFilterTCP = $gfTcp
        $env:GameFilterUDP = $gfUdp
        $env:GameFilter = if ($gfTcp -ne '12') { $gfTcp } else { $gfUdp }
        $tmpLiveConf = Join-Path $Root "bin\service.conf.tmp_$PID"
        $bakLiveConf = Join-Path $Root "bin\service.conf.bak_$PID"
        $env:Z2_ROOT = $Root
        $env:Z2_BAT = $installBat
        $env:Z2_CONF = $tmpLiveConf
        $env:Z2_AUTOHOST = if (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')) { '1' } else { '0' }
        $env:Z2_SKIP_NLM_AUTO = $null
        $env:BIN = Join-Path $Root 'bin\'
        $env:LISTS = Join-Path $Root 'lists\'
        $env:LUA = Join-Path $Root 'lua\'
        $env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
        $env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'

        $global:LASTEXITCODE = 0
        & (Join-Path $Root 'utils\build_service_conf.ps1')
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpLiveConf)) {
            if (Test-Path -LiteralPath $tmpLiveConf) { Remove-Item -LiteralPath $tmpLiveConf -Force -ErrorAction SilentlyContinue }
            Write-Host "  [X] ОШИБКА сборки bin\service.conf для $installName (код $LASTEXITCODE)!" -ForegroundColor Red
            $exitCode = 1
            throw "Z2_ABORT"
        }

        $binEsc = "\`"$winwsExe\`" @\`"$liveConfPath\`""
        $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        $svcExists = ($null -ne $svcZ)
        if ($svcZ) { try { $svcZ.Dispose() } catch {} }
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

        $hadOldConf = Test-Path -LiteralPath $liveConfPath
        if ($hadOldConf) {
            Copy-Item -LiteralPath $liveConfPath -Destination $bakLiveConf -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $tmpLiveConf -Destination $liveConfPath -Force -ErrorAction Stop

        $zDepend = if (Get-Command Get-Z2ZapretDepend -ErrorAction SilentlyContinue) { Get-Z2ZapretDepend } else { 'BFE/nlasvc' }
        if ($svcExists) {
            $pCfg = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto depend= $zDepend" -WindowStyle Hidden -Wait -PassThru
            if ($pCfg.ExitCode -ne 0) {
                Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto depend= $zDepend" -WindowStyle Hidden -Wait | Out-Null
            }
        } else {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto depend= $zDepend" -WindowStyle Hidden -Wait | Out-Null
        }
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description zapret `"Zapret2 DPI bypass software (winws2)`"" -WindowStyle Hidden -Wait | Out-Null
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure zapret reset= 60 actions= restart/2000/restart/5000/restart/10000" -WindowStyle Hidden -Wait | Out-Null
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failureflag zapret 1" -WindowStyle Hidden -Wait | Out-Null
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start zapret" -WindowStyle Hidden -Wait | Out-Null
        $startedOk = $false
        for ($w = 0; $w -lt 10; $w++) {
            Start-Sleep -Milliseconds 300
            $chkS = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
            if ($null -ne $chkS -and $chkS.Status -eq 'Running') { $startedOk = $true; try { $chkS.Dispose() } catch {}; break }
            if ($null -ne $chkS) { try { $chkS.Dispose() } catch {} }
        }
        $installedNewService = $startedOk
        if ($startedOk) {
            $stratShort = [System.IO.Path]::GetFileNameWithoutExtension($installBat)
            & "$env:SystemRoot\System32\reg.exe" add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d $stratShort /f >$null 2>&1
            if (Test-Path -LiteralPath $bakLiveConf) { Remove-Item -LiteralPath $bakLiveConf -Force -ErrorAction SilentlyContinue }
            Write-Host "  [OK] Служба zapret переведена на $installName и запущена!" -ForegroundColor Green
        } else {
            Write-Host "  [X] ОШИБКА: Служба zapret не смогла запуститься на $installName — откатываю прежнюю конфигурацию..." -ForegroundColor Red
            Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
            if ($hadOldConf -and (Test-Path -LiteralPath $bakLiveConf)) {
                Move-Item -LiteralPath $bakLiveConf -Destination $liveConfPath -Force -ErrorAction SilentlyContinue
            }
            $exitCode = 1
        }
    } else {
        Write-Host '  [*] Прежний service.conf не тронут — перезапускаю службу zapret...' -ForegroundColor Gray
    }
} catch {
    if ($_.Exception.Message -ne 'Z2_ABORT') { Write-Host "  [X] Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
    if ($exitCode -eq 0) { $exitCode = 1 }
} finally {
    $env:Z2_SKIP_NLM_AUTO = $null
    if (Test-Path -LiteralPath $probeConfPath) { Remove-Item -LiteralPath $probeConfPath -Force -ErrorAction SilentlyContinue }
    $tmpClean = Join-Path $Root "bin\service.conf.tmp_$PID"
    $bakClean = Join-Path $Root "bin\service.conf.bak_$PID"
    if (Test-Path -LiteralPath $tmpClean) { Remove-Item -LiteralPath $tmpClean -Force -ErrorAction SilentlyContinue }
    if (-not $installedNewService -and (Test-Path -LiteralPath $bakClean)) {
        Move-Item -LiteralPath $bakClean -Destination $liveConfPath -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $bakClean) {
        Remove-Item -LiteralPath $bakClean -Force -ErrorAction SilentlyContinue
    }
    if (-not $installedNewService) {
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
        if ($wasRunning) {
            Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
        }
    }
}
exit $exitCode
