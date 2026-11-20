param(
    [string]$Root = '',
    [switch]$NonInteractive
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
try { $Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\' } catch { $Root = $Root.Trim('"', "'", '\', '/') + '\' }

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
$verHdr = if (Test-Path -LiteralPath (Join-Path $Root 'utils\version.txt')) { (Get-Content -LiteralPath (Join-Path $Root 'utils\version.txt') -TotalCount 1).Trim() } else { '1.0.0' }
Write-Host "     ZAPRET2 KOTEK v$verHdr — ГЛУБОКИЙ ТЕСТ И СИНТЕЗ СТРАТЕГИИ     " -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '  Прогоняет ВСЕ стратегии (корень + configs_archive), находит' -ForegroundColor Gray
Write-Host '  чемпионов отдельно для YouTube, Discord и Web, и собирает' -ForegroundColor Gray
Write-Host '  гибридный конфиг custom_auto_synthesized.bat под твоего провайдера' -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray

$curlExe = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

$curlHasParallel = $false
try {
    $curlHelp = & $curlExe --help all 2>$null | Out-String
    if ($curlHelp -match '--parallel') { $curlHasParallel = $true }
} catch {}

# Collect all candidate .bat files from strategies\ + configs_archive\ (plus any custom root .bat)
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
        $allBats += $_
    }
}

Write-Host "`n  [*] Найдено стратегий для глубокого теста: $($allBats.Count)" -ForegroundColor Yellow
Write-Host '  [*] Останавливаю текущую службу zapret на время бенчмарка...' -ForegroundColor Gray
& sc.exe stop zapret >$null 2>&1
Get-Process -Name winws2,winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

# Load all CORE + EXT targets from unified utils/targets.txt (fallback to built-in 28 targets)
$TestUrls = New-Object System.Collections.Generic.List[string]
$tFile = Join-Path $Root 'utils\targets.txt'
if (Test-Path -LiteralPath $tFile) {
    foreach ($tl in (Get-Content -LiteralPath $tFile -Encoding UTF8)) {
        $tt = $tl.Trim()
        if (-not $tt -or $tt.StartsWith('#')) { continue }
        $tp = $tt -split '\|'
        if ($tp.Count -ge 3) { $TestUrls.Add($tp[2].Trim()) }
    }
}
if ($TestUrls.Count -eq 0) {
    foreach ($u in @('https://www.youtube.com','https://m.youtube.com','https://i.ytimg.com/favicon.ico','https://yt3.ggpht.com','https://jnn-pa.googleapis.com','https://play.google.com','https://discord.com','https://discord.com/api/v10/gateway','https://cdn.discordapp.com','https://media.discordapp.net','https://discord.gg','https://status.discord.com','https://web.telegram.org','https://t.me','https://cloudflare-dns.com','https://one.one.one.one','https://7tv.io','https://betterttv.net','https://frankerfacez.com','https://raw.githubusercontent.com','https://github.com','https://store.steampowered.com','https://steamcommunity.com','https://www.twitch.tv','https://gql.twitch.tv','https://soundcloud.com','https://rutracker.org','https://ntc.party')) {
        $TestUrls.Add($u)
    }
}
$padHdr = 'X-Pad: ' + ('A' * 3072)
$invCulture = [System.Globalization.CultureInfo]::InvariantCulture
$confPath = Join-Path $Root 'bin\service.conf'
$confBakPath = Join-Path $Root 'bin\service.conf.deepbak'
if (Test-Path -LiteralPath $confPath) { Copy-Item -LiteralPath $confPath -Destination $confBakPath -Force -ErrorAction SilentlyContinue }
$winwsExe = Join-Path $Root 'bin\winws2.exe'

function Invoke-StrategyProbe([string]$batFullPath, [string]$displayName) {
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $batFullPath
    $env:Z2_CONF = $confPath
    $env:Z2_AUTOHOST = '0'
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
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $confPath)) { return $null }
    } catch { return $null }

    $proc = $null
    try {
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$confPath`"" -WindowStyle Hidden -PassThru
    } catch { return $null }
    Start-Sleep -Milliseconds 650
    if ($null -eq $proc -or $proc.HasExited) { return $null }

    $okCount = 0; $totalMs = 0.0
    $ytHits = 0; $ytMs = 0.0
    $dcHits = 0; $dcMs = 0.0
    $webHits = 0; $webMs = 0.0
    $rawLines = @()

    if ($curlHasParallel) {
        $cArgs = @('-Z', '--parallel-max', '28')
        for ($ui = 0; $ui -lt $TestUrls.Count; $ui++) {
            if ($ui -gt 0) { $cArgs += '-:' }
            $u = $TestUrls[$ui]
            $cArgs += @('-4', '-s', '--max-time', '4', '-w', '%{url_effective}|%{http_code}|%{time_total}|%{size_download}\n', '-o', 'NUL')
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
        foreach ($u in $TestUrls) {
            try {
                $one = if ($u -eq 'https://one.one.one.one' -or $u -eq 'https://cloudflare-dns.com') {
                    & $curlExe -4 -s -H $padHdr -o NUL -w '%{url_effective}|%{http_code}|%{time_total}|%{size_download}' --max-time 4 $u 2>$null
                } else {
                    & $curlExe -4 -s -o NUL -w '%{url_effective}|%{http_code}|%{time_total}|%{size_download}' --max-time 4 $u 2>$null
                }
                if ($one) { $rawLines += $one }
            } catch {}
        }
    }

    $padOk = $false; $dl16kOk = $false; $canaryHits = 0
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
        if ($code -match '^(200|204|301|302|307|308|400|403|404)$') {
            $okCount++
            $ms = 500.0
            $secVal = 0.0
            if ([double]::TryParse($tStr, [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$secVal)) {
                $ms = $secVal * 1000.0
            }
            $totalMs += $ms
            if ($uEff -match 'speed\.cloudflare\.com' -and $dlBytes -ge 32768) { $dl16kOk = $true }
            if ($uEff -match 'one\.one\.one\.one|cloudflare-dns\.com') { $padOk = $true }
            if ($uEff -match 'github\.com|githubusercontent\.com|steampowered\.com' -and $ms -le 2000.0) { $canaryHits++ }
            if ($uEff -match 'youtube\.com|ytimg\.com|ggpht\.com|googleapis\.com|googlevideo\.com|play\.google\.com') {
                $ytHits++; $ytMs += $ms
            } elseif ($uEff -match 'discord\.com|discordapp\.com|discordapp\.net|discord\.gg') {
                $dcHits++; $dcMs += $ms
            } else {
                $webHits++; $webMs += $ms
            }
        }
    }
    $freezeOk = $dl16kOk

    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Get-Process -Name winws2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 180

    $avgMs = if ($okCount -gt 0) { [int][Math]::Round($totalMs / $okCount) } else { 3000 }
    $ytAvg = if ($ytHits -gt 0) { [int][Math]::Round($ytMs / $ytHits) } else { 3000 }
    $dcAvg = if ($dcHits -gt 0) { [int][Math]::Round($dcMs / $dcHits) } else { 3000 }
    $webAvg = if ($webHits -gt 0) { [int][Math]::Round($webMs / $webHits) } else { 3000 }

    $ytScore  = ($ytHits * 100) + [Math]::Max(0, [int](50 - ($ytAvg / 40.0)))
    $dcScore  = ($dcHits * 100) + [Math]::Max(0, [int](50 - ($dcAvg / 40.0)))
    $webScore = ($webHits * 100) + ($(if ($freezeOk) { 80 } else { 0 })) + [Math]::Max(0, [int](50 - ($webAvg / 40.0)))
    $canaryPen = if ($canaryHits -eq 0 -and $okCount -ge 6) { -30 } else { 0 }
    $totScore = ($okCount * 20) + ($(if ($ytHits -ge 2) { 45 } else { 0 })) + ($(if ($dcHits -ge 2) { 35 } else { 0 })) + ($(if ($freezeOk) { 30 } else { 0 })) + [Math]::Max(0, [int](30 - ($avgMs / 50.0))) + $canaryPen

    $frLbl = if ($freezeOk) { 'OK  ' } else { 'SLOW' }
    Write-Host ("`r" + (" " * 86) + "`r") -NoNewline
    Write-Host ("  - {0,-34} : {1,2}/$($TestUrls.Count) | YT:{2}/7 DC:{3}/6 WEB:{4}/17 | 16-20KB:{5} | ~{6,4} мс" -f $displayName, $okCount, $ytHits, $dcHits, $webHits, $frLbl, $avgMs) -ForegroundColor Gray

    try {
        $scFile = Join-Path $Root 'utils\strategy_scores.json'
        $scMap = @{}
        if (Test-Path -LiteralPath $scFile) {
            $prevSc = Get-Content -LiteralPath $scFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prevSc) { foreach ($pr in $prevSc.PSObject.Properties) { $scMap[$pr.Name] = $pr.Value } }
        }
        $leafKey = [System.IO.Path]::GetFileName($batFullPath)
        $scMap[$leafKey] = [PSCustomObject]@{ ok=$okCount; total=$TestUrls.Count; ms=$avgMs; yt=($ytHits -ge 3); dc=($dcHits -ge 3); ytHits=$ytHits; ytTotal=7; dcHits=$dcHits; dcTotal=6; freeze=$freezeOk; ts=(Get-Date -Format 'yyyy-MM-dd HH:mm') }
        [System.IO.File]::WriteAllText($scFile, ($scMap | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    return [PSCustomObject]@{
        Name      = $displayName
        Path      = $batFullPath
        OkCount   = $okCount
        AvgMs     = $avgMs
        FreezeOk  = $freezeOk
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
    if (Test-Path -LiteralPath $confBakPath) { Copy-Item -LiteralPath $confBakPath -Destination $confPath -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $confBakPath -Force -ErrorAction SilentlyContinue }
    & sc.exe start zapret >$null 2>&1
    Write-Host "`n  [X] Не удалось протестировать ни одной стратегии (прежняя служба восстановлена)." -ForegroundColor Red
    exit 1
}

$bestOverall = $results | Sort-Object -Property TotScore -Descending | Select-Object -First 1
$bestYt      = $results | Sort-Object -Property YtScore, TotScore -Descending | Select-Object -First 1
$bestDc      = $results | Sort-Object -Property DcScore, TotScore -Descending | Select-Object -First 1
$bestWeb     = $results | Sort-Object -Property WebScore, TotScore -Descending | Select-Object -First 1

Write-Host "`n  ==================================================================" -ForegroundColor Cyan
Write-Host "  [ЧЕМПИОНЫ ПО КАТЕГОРИЯМ]" -ForegroundColor Cyan
Write-Host ("    YouTube (list-google) : {0} ({1}/6, ~{2} мс)" -f $bestYt.Name, $bestYt.YtHits, $bestYt.YtAvg) -ForegroundColor Green
Write-Host ("    Discord (TCP/Media)   : {0} ({1}/6, ~{2} мс)" -f $bestDc.Name, $bestDc.DcHits, $bestDc.DcAvg) -ForegroundColor Green
Write-Host ("    Web + 16-20KB         : {0} ({1}/16, ~{2} мс)" -f $bestWeb.Name, $bestWeb.WebHits, $bestWeb.WebAvg) -ForegroundColor Green
Write-Host ("    Лучшая целиком        : {0} ({1}/$($TestUrls.Count), ~{2} мс)" -f $bestOverall.Name, $bestOverall.OkCount, $bestOverall.AvgMs) -ForegroundColor Yellow
Write-Host '  ==================================================================' -ForegroundColor Cyan

# Helper: extract --blob, --lua-init, and profile lines from a strategy .bat
function Parse-BatStrategy([string]$batFile) {
    $raw = Get-Content -LiteralPath $batFile -Encoding UTF8
    $joined = ''
    foreach ($l in $raw) {
        $t = $l.TrimEnd()
        if ($t.EndsWith('^')) { $joined += $t.Substring(0, $t.Length - 1) + ' ' }
        else {
            $joined += $t + "`n"
        }
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

    # Split profiles by --new
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

Write-Host "`n  [*] Синтезирую гибридный конфиг custom_auto_synthesized.bat..." -ForegroundColor Yellow
$pYt  = Parse-BatStrategy $bestYt.Path
$pDc  = Parse-BatStrategy $bestDc.Path
$pWeb = Parse-BatStrategy $bestWeb.Path

$mergedBlobs = [ordered]@{}
$mergedLuas  = New-Object System.Collections.Generic.List[string]
$srcEntries = @(
    @{ Obj = $pWeb; Tag = '' },
    @{ Obj = $pYt;  Tag = '_yt' },
    @{ Obj = $pDc;  Tag = '_dc' }
)
foreach ($se in $srcEntries) {
    $src = $se.Obj
    if (-not $src) { continue }
    foreach ($k in @($src.Blobs.Keys)) {
        $def = $src.Blobs[$k]
        if (-not $mergedBlobs.Contains($k)) {
            $mergedBlobs[$k] = $def
        } elseif ($mergedBlobs[$k] -ine $def -and $se.Tag) {
            $newK = $k + $se.Tag
            $mergedBlobs[$newK] = $def -replace ("^--blob=" + [regex]::Escape($k) + ":"), ("--blob=" + $newK + ":")
            for ($pi = 0; $pi -lt $src.Profiles.Count; $pi++) {
                $src.Profiles[$pi] = $src.Profiles[$pi] -replace ("(blob=|seqovl_pattern=)" + [regex]::Escape($k) + "(?=[:\s]|$)"), ("`$1" + $newK)
            }
        }
    }
    foreach ($lu in $src.Luas) {
        if (-not $mergedLuas.Contains($lu)) { $mergedLuas.Add($lu) }
    }
}

# Pick winning profiles (keep ALL matching profiles per category, e.g. wssize + tls_client_hello, without mutating --in-range)
$profQuicGen   = @($pWeb.Profiles | Where-Object { $_ -match '--filter-udp=443' -and $_ -match 'list-general\.txt' })
$profWarp      = @($pWeb.Profiles | Where-Object { $_ -match '--filter-udp=500,1701,2408,4500' })
$profDiscUdp   = @($pDc.Profiles  | Where-Object { $_ -match '19294-19344' })
if ($profDiscUdp.Count -eq 0) { $profDiscUdp = @($pWeb.Profiles | Where-Object { $_ -match '19294-19344' }) }
$profDiscTcp   = @($pDc.Profiles  | Where-Object { $_ -match 'discord\.media' })
$profDiscWeb   = @()
if ($bestDc.Path -ne $bestWeb.Path -and $pDc) {
    $dcGens = @($pDc.Profiles | Where-Object { $_ -match '--filter-tcp=' -and $_ -match 'list-general\.txt' })
    foreach ($dcGen in $dcGens) {
        $dcCustom = [regex]::Replace($dcGen, '--hostlist=(?:"[^"]+"|\S+)\s*', '')
        $dcCustom = [regex]::Replace($dcCustom, '--hostlist-auto(?:-[a-z-]+)?=(?:"[^"]+"|\S+)\s*', '')
        $dcCustom = [regex]::Replace($dcCustom, '(--filter-tcp=\S+)', '$1 --hostlist-domains=discord.com,discordapp.com,discordapp.net,discord.gg', 1)
        $profDiscWeb += $dcCustom.Trim()
    }
}
$profYtTcp     = @($pYt.Profiles  | Where-Object { $_ -match '--filter-tcp=' -and $_ -match 'list-google\.txt' })
$profGenTcp    = @($pWeb.Profiles | Where-Object { $_ -match '--filter-tcp=' -and $_ -match 'list-general\.txt' })
$profQuicIpset = @($pWeb.Profiles | Where-Object { $_ -match '--filter-udp=443' -and $_ -match 'ipset-all\.txt' })
$profIpsetTcp  = @($pWeb.Profiles | Where-Object { $_ -match '--filter-tcp=' -and $_ -match 'ipset-all\.txt' -and $_ -notmatch '%GameFilterTCP%' })
$profGameTcp   = @($pWeb.Profiles | Where-Object { $_ -match '%GameFilterTCP%' })
$profGameUdp   = @($pWeb.Profiles | Where-Object { $_ -match '%GameFilterUDP%' })

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
$batLines.Add('cd /d "%~dp0..\"')
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
$needTcpEmpty = ($chosenProfiles -join ' ') -match '(?i)(--payload=empty|wssize|oob)'
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
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $installBat
    $env:Z2_CONF = $confPath
    $env:Z2_AUTOHOST = if (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')) { '1' } else { '0' }
    $env:BIN = Join-Path $Root 'bin\'
    $env:LISTS = Join-Path $Root 'lists\'
    $env:LUA = Join-Path $Root 'lua\'
    $env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
    $env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'
    & (Join-Path $Root 'utils\build_service_conf.ps1')
    $binEsc = "\`"$winwsExe\`" @\`"$confPath\`""
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $svcExists = ($null -ne $svcZ)
    if ($svcExists) {
        if ($svcZ.Status -ne 'Stopped') {
            Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
            try { $svcZ.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5)) } catch { Start-Sleep -Milliseconds 700 }
        }
        try { $svcZ.Dispose() } catch {}
    }
    Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 250
    if ($svcExists) {
        $pCfg = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait -PassThru
        if ($pCfg.ExitCode -ne 0) {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait | Out-Null
        }
    } else {
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEsc`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait | Out-Null
    }
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description zapret `"Zapret2 DPI bypass software (winws2)`"" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure zapret reset= 60 actions= restart/2000/restart/5000/restart/10000" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start zapret" -WindowStyle Hidden -Wait | Out-Null
    $startedOk = $false
    for ($w = 0; $w -lt 10; $w++) {
        Start-Sleep -Milliseconds 300
        $chkS = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $chkS -and $chkS.Status -eq 'Running') { $startedOk = $true; try { $chkS.Dispose() } catch {}; break }
        if ($null -ne $chkS) { try { $chkS.Dispose() } catch {} }
    }
    $stratShort = [System.IO.Path]::GetFileNameWithoutExtension($installBat)
    & reg.exe add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d $stratShort /f >$null 2>&1
    if (Test-Path -LiteralPath $confBakPath) { Remove-Item -LiteralPath $confBakPath -Force -ErrorAction SilentlyContinue }
    if ($startedOk) {
        Write-Host "  [OK] Служба zapret переведена на $installName и запущена!" -ForegroundColor Green
    } else {
        Write-Host "  [X] ОШИБКА: Служба zapret не смогла запуститься на $installName!" -ForegroundColor Red
        exit 1
    }
} else {
    if (Test-Path -LiteralPath $confBakPath) { Copy-Item -LiteralPath $confBakPath -Destination $confPath -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $confBakPath -Force -ErrorAction SilentlyContinue }
    Write-Host '  [*] Восстановлен прежний service.conf — перезапускаю службу zapret...' -ForegroundColor Gray
    & sc.exe start zapret >$null 2>&1
}
