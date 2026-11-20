param(
    [string]$Root = '',
    [switch]$SkipUpdateCheck,
    [switch]$NonInteractive
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
try { $Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\' } catch { $Root = $Root.Trim('"', "'", '\', '/') + '\' }
$env:Z2_ROOT = $Root

# Quick silent GitHub release check (1-click auto-update for family/friends)
if (-not $SkipUpdateCheck) {
    try {
        $rcFile = Join-Path $Root 'utils\repo.conf'
        $ghRepo = ''
        if (Test-Path -LiteralPath $rcFile) {
            foreach ($rl in (Get-Content -LiteralPath $rcFile)) {
                if ($rl -match '^\s*repo\s*=\s*(.+)$') { $ghRepo = $matches[1].Trim() }
            }
        }
        if ($ghRepo -and ($ghRepo -notlike 'OWNER/*')) {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghRepo/releases/latest" -Headers @{ 'User-Agent' = 'Zapret2-Kotek-Updater' } -TimeoutSec 4 -ErrorAction Stop
            $latestTag = ([string]$rel.tag_name).Trim().TrimStart('v', 'V')
            $pa = @(([regex]::Matches($latestTag, '\d+') | ForEach-Object { [int]$_.Value })); $verFile = Join-Path $Root 'utils\version.txt'; $curVerStr = if (Test-Path -LiteralPath $verFile) { (Get-Content -LiteralPath $verFile -TotalCount 1).Trim() } else { '1.0.0' }; $pb = @(([regex]::Matches($curVerStr, '\d+') | ForEach-Object { [int]$_.Value })); $isNewer = $false; for ($vi=0; $vi -lt [Math]::Max($pa.Count,$pb.Count); $vi++) { $va = if ($vi -lt $pa.Count){$pa[$vi]}else{0}; $vb = if ($vi -lt $pb.Count){$pb[$vi]}else{0}; if ($va -gt $vb){$isNewer=$true; break}; if ($va -lt $vb){break} }
            if ($latestTag -and $isNewer) {
                Write-Host "  [ОБНОВЛЕНИЕ] (=^o^=) Найдена новая версия v$latestTag на GitHub — обновляюсь..." -ForegroundColor Cyan
                & (Join-Path $Root 'utils\self_update.ps1') -Root $Root -Repo $ghRepo
                if ($LASTEXITCODE -eq 0) {
                    & (Join-Path $Root 'utils\auto_setup.ps1') -Root $Root -SkipUpdateCheck -NonInteractive:$NonInteractive
                    exit $LASTEXITCODE
                }
            }
        }
    } catch {}
}


$ListsDir = Join-Path $Root 'lists'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$curlExe = "$env:SystemRoot\System32\curl.exe"; if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = "curl.exe" }

function Update-IpsetAndHosts([bool]$RestartServiceOnUpdate = $false) {
    $updScript = Join-Path $Root 'utils\update_lists.ps1'
    if (Test-Path -LiteralPath $updScript) {
        $global:LASTEXITCODE = 0
        if ($RestartServiceOnUpdate) {
            & $updScript -Root $Root
        } else {
            & $updScript -Root $Root -NoRestart
        }
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch {} }
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
$verHdr = if (Test-Path -LiteralPath (Join-Path $Root 'utils\version.txt')) { (Get-Content -LiteralPath (Join-Path $Root 'utils\version.txt') -TotalCount 1).Trim() } else { '1.0.0' }
Write-Host "       ZAPRET2 KOTEK v$verHdr — АВТОНАСТРОЙКА (1 КЛИК)      " -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '  Полный автомат: обновление списков IPSet и Hosts, подбор UDP-фейка,' -ForegroundColor Gray
Write-Host '  тест всех базовых стратегий по 16 целям, запуск служб и прокси Telegram' -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------'

$script:KotekTop = -1
try { $script:KotekTop = [Console]::CursorTop } catch {}
$script:KotekFrame = 0
$script:KotekSprites = @(
    @(
        '          /\_____/\      Котек берёт сеть под контроль!     ',
        '         /  o   o  \     Подбираем рабочую стратегию DPI    ',
        '        ( ==  ^  == )    под твоего провайдера...           ',
        '         )         (   ~                                    ',
        '        (  (     )  )                                       '
    ),
    @(
        '          /\_____/\      Котек берёт сеть под контроль!     ',
        '         /  -   -  \     Подбираем рабочую стратегию DPI    ',
        '        ( ==  ^  == )    под твоего провайдера...           ',
        '         )         (  ~                                     ',
        '        (  (     )  )                                       '
    ),
    @(
        '          /\_____/\      Котек тестирует стратегии!         ',
        '         /  ^   ^  \ /   Проверяем обход по 16 целям        ',
        '        ( ==  w  == )    YouTube, Discord и Telegram...     ',
        '         )         (   ~                                    ',
        '        (  (     )  )                                       '
    ),
    @(
        '          /\_____/\      Котек на страже твоего интернета!  ',
        '         /  o   o  \ *   Подбираем лучшую стратегию DPI     ',
        '        ( ==  ^  == )    и настраиваем прокси Telegram...   ',
        '         )         (  ~                                     ',
        '        (  (     )  )                                       '
    )
)
function Update-Kotek([int]$forceFrame = -1) {
    if ($NonInteractive -or $script:KotekTop -lt 0) { return }
    $idx = if ($forceFrame -ge 0) { $forceFrame } else { ($script:KotekFrame++) % $script:KotekSprites.Count }
    $sp = $script:KotekSprites[$idx]
    try {
        $curL = [Console]::CursorLeft
        $curT = [Console]::CursorTop
        for ($r = 0; $r -lt $sp.Count; $r++) {
            [Console]::SetCursorPosition(0, $script:KotekTop + $r)
            Write-Host $sp[$r] -ForegroundColor Cyan -NoNewline
        }
        [Console]::SetCursorPosition($curL, $curT)
    } catch {}
}
foreach ($ln in $script:KotekSprites[0]) { Write-Host $ln -ForegroundColor Cyan }
for ($k = 0; $k -lt 4; $k++) { Update-Kotek $k; Start-Sleep -Milliseconds 160 }

# [0/5] Path Safety Check (Downloads / OneDrive / Spaces / Parens / Cyrillic)
$needsMove = ($Root -notmatch '^(?i)C:\\Zapret2\\?$') -and (
    ($Root -match '(?i)\\(Downloads|Desktop|OneDrive|Temp)\\') -or
    ($Root -match '[\s()]') -or
    ($Root -match '[\u0400-\u04FF]')
)
if ($needsMove -and -not $NonInteractive) {
    Write-Host "`n  [ВНИМАНИЕ] Папка находится в ненадёжном пути:" -ForegroundColor Yellow
    Write-Host "             $Root" -ForegroundColor Gray
    Write-Host "             Пути в Загрузках, с пробелами/скобками или кириллицей часто ломают службы." -ForegroundColor Gray
    $mv = Read-Host '  Перенести и установить в чистую папку C:\Zapret2? [Д/н] (Enter = Да)'
    if ([string]::IsNullOrWhiteSpace($mv) -or $mv -notmatch '^[nNнН]') {
        $targetRoot = 'C:\Zapret2\'
        Write-Host '  [*] Остановка старых служб и копирование в C:\Zapret2...' -ForegroundColor Cyan
        foreach ($s in @('zapret', 'zapret2', 'zapret-tgws', 'WinDivert', 'WinDivert14')) {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $s" -WindowStyle Hidden -Wait | Out-Null
        }
        Get-Process -Name 'winws2','winws','tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path -LiteralPath $targetRoot)) { New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null }
        & "$env:SystemRoot\System32\robocopy.exe" ($Root.TrimEnd("\")) ($targetRoot.TrimEnd("\")) /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        $Root = $targetRoot
        $env:Z2_ROOT = $Root
        $ListsDir = Join-Path $Root 'lists'
        Write-Host '  [OK] Сборка перенесена в C:\Zapret2 (дальнейшая установка идёт оттуда)' -ForegroundColor Green
    }
}

# [1/5] System Prep, Legacy Zapret1/WinDivert Cleanup & Lists Auto-Update
Write-Host "`n  [1/5] Подготовка системы, очистка старых драйверов и обновление списков..." -ForegroundColor Yellow
$legacyFound = @()
foreach ($oldSvc in @('zapret', 'zapret2', 'discordfix_zapret', 'winws1', 'GoodbyeDPI')) {
    if (Get-Service -Name $oldSvc -ErrorAction SilentlyContinue) {
        if ($oldSvc -ne 'zapret') { $legacyFound += $oldSvc }
        Stop-Service -Name $oldSvc -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $oldSvc" -WindowStyle Hidden -Wait | Out-Null
    }
}
Get-Process -Name 'winws2','winws','goodbyedpi' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
foreach ($oldDrv in @('WinDivert', 'WinDivert14')) {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $oldDrv" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $oldDrv" -WindowStyle Hidden -Wait | Out-Null
}
if ($legacyFound.Count -gt 0) {
    Write-Host ("        [OK] Убраны конфликтующие службы Zapret1/DPI: {0}" -f ($legacyFound -join ', ')) -ForegroundColor Green
}
& netsh.exe interface tcp set global timestamps=enabled >$null 2>&1
$rootCleanAcl = $Root.TrimEnd('\')
if ($rootCleanAcl -ieq 'C:\Zapret2') {
    & icacls.exe "$rootCleanAcl" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" /grant:r "*S-1-5-32-544:(OI)(CI)F" /grant:r "*S-1-5-32-545:(OI)(CI)RX" /T /C /Q >$null 2>&1
} else {
    & icacls.exe "$rootCleanAcl" /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q >$null 2>&1
}

if (-not (Test-Path -LiteralPath $ListsDir)) { New-Item -ItemType Directory -Path $ListsDir -Force | Out-Null }
$pIpEx = Join-Path $ListsDir 'ipset-exclude-user.txt'
if (-not (Test-Path -LiteralPath $pIpEx) -or (Get-Item -LiteralPath $pIpEx).Length -eq 0) {
    [System.IO.File]::WriteAllText($pIpEx, "203.0.113.113/32`r`n", $utf8NoBom)
}
$pGenUser = Join-Path $ListsDir 'list-general-user.txt'
if (-not (Test-Path -LiteralPath $pGenUser) -or (Get-Item -LiteralPath $pGenUser).Length -eq 0) {
    [System.IO.File]::WriteAllText($pGenUser, "# Never leave this file empty`r`ndomain.example.abc`r`n", $utf8NoBom)
}
$pExUser = Join-Path $ListsDir 'list-exclude-user.txt'
if (-not (Test-Path -LiteralPath $pExUser) -or (Get-Item -LiteralPath $pExUser).Length -eq 0) {
    [System.IO.File]::WriteAllText($pExUser, "domain.example.abc`r`n", $utf8NoBom)
}
$pAuto = Join-Path $ListsDir 'list-auto.txt'
if (-not (Test-Path -LiteralPath $pAuto)) {
    [System.IO.File]::WriteAllText($pAuto, "", $utf8NoBom)
}
& icacls.exe $pAuto /grant "*S-1-5-18:(M)" /grant "*S-1-5-32-544:(M)" >$null 2>&1

[System.IO.File]::WriteAllText((Join-Path $Root 'utils\autohostlist.enabled'), "1`n")
[System.IO.File]::WriteAllText((Join-Path $Root 'utils\warp_unblock.enabled'), "1`n")

$initialIpsetUpdated = Update-IpsetAndHosts $false


# [2/5] UDP Fake Optimization
Write-Host "`n  [2/5] Подбор оптимального UDP-фейка для голоса Discord и игр..." -ForegroundColor Yellow
& (Join-Path $Root 'utils\fake_selector.ps1') -Action auto -Root $Root

# [3/5] Benchmark All 8 Core Strategies Across 8 Targets
Write-Host "`n  [3/5] (=^.^=) Котек тестирует стратегии на вашем провайдере..." -ForegroundColor Yellow
& sc.exe stop zapret >$null 2>&1
Get-Process -Name winws2,winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

$Candidates = @(
    @{ File = 'general (ALT).bat';            Bonus = 0 },
    @{ File = 'general (ALT7).bat';           Bonus = 0 },
    @{ File = 'custom_wssize_antifreeze.bat'; Bonus = 0 },
    @{ File = 'general (ALT11).bat';  Bonus = 0 },
    @{ File = 'custom_md5_disorder.bat';      Bonus = 0 },
    @{ File = 'general (ALT12).bat';       Bonus = 0 },
    @{ File = 'general (FAKE TLS AUTO).bat';  Bonus = 0 },
    @{ File = 'custom_auto_circular.bat';     Bonus = 2 }
)

# Auto-discover any custom *.bat strategies in strategies\ (and fallback root)
$skipBats = @('1_AUTO_SETUP.bat','2_KOTEK.bat','!_START_KOTEK.bat','KOTEK.bat','AUTO_SETUP.bat','PAUSE_RESUME.bat','UNINSTALL.bat','DEEP_OPTIMIZE.bat','service.bat')
$knownFiles = @($Candidates | ForEach-Object { $_.File.ToLowerInvariant() })
$StratDir = Join-Path $Root 'strategies'
foreach ($searchDir in @($StratDir, $Root)) {
    if (-not (Test-Path -LiteralPath $searchDir)) { continue }
    Get-ChildItem -LiteralPath $searchDir -Filter '*.bat' -File | Sort-Object Name | ForEach-Object {
        if ($skipBats -notcontains $_.Name -and $knownFiles -notcontains $_.Name.ToLowerInvariant()) {
            $Candidates += @{ File = $_.Name; Bonus = 0 }
            $knownFiles += $_.Name.ToLowerInvariant()
        }
    }
}
$PrimaryCount = $Candidates.Count
$ArchDir = Join-Path $Root 'configs_archive'
$archBackups = @('custom_oob_ts.bat', 'custom_delayed_split.bat', 'general (ALT11).bat', 'general (ALT12).bat', 'general (FAKE TLS AUTO ALT2).bat')
if (Test-Path -LiteralPath $ArchDir) {
    foreach ($ab in $archBackups) {
        if ((Test-Path -LiteralPath (Join-Path $ArchDir $ab)) -and ($knownFiles -notcontains $ab.ToLowerInvariant())) {
            $Candidates += @{ File = $ab; Bonus = 0; IsArchive = $true }
            $knownFiles += $ab.ToLowerInvariant()
        }
    }
}

# Load CORE targets from unified utils/targets.txt (fallback to built-in 16 targets)
$TestUrls = New-Object System.Collections.Generic.List[string]
$tFile = Join-Path $Root 'utils\targets.txt'
if (Test-Path -LiteralPath $tFile) {
    foreach ($tl in (Get-Content -LiteralPath $tFile -Encoding UTF8)) {
        $tt = $tl.Trim()
        if (-not $tt -or $tt.StartsWith('#')) { continue }
        $tp = $tt -split '\|'
        if ($tp.Count -ge 3 -and $tp[1].Trim().ToUpperInvariant() -eq 'CORE') {
            $TestUrls.Add($tp[2].Trim())
        }
    }
}
if ($TestUrls.Count -eq 0) {
    foreach ($u in @('https://www.youtube.com','https://i.ytimg.com/favicon.ico','https://yt3.ggpht.com','https://jnn-pa.googleapis.com','https://redirector.googlevideo.com','https://discord.com','https://discord.com/api/v10/gateway','https://cdn.discordapp.com','https://discord.gg','https://web.telegram.org','https://t.me','https://cloudflare-dns.com','https://one.one.one.one','https://speed.cloudflare.com/__down?bytes=65536','https://7tv.io','https://betterttv.net','https://frankerfacez.com','https://raw.githubusercontent.com')) {
        $TestUrls.Add($u)
    }
}
$padHdr = 'X-Pad: ' + ('A' * 3072)

$BestFile = 'general (ALT).bat'
$BestScore = -1
$BestOkCount = 0; $BestYtOk = $false; $BestDcOk = $false; $BestFreezeOk = $false; $BestAvgMs = 9999

# Check if curl supports --parallel (-Z) for fast simultaneous probing
$curlHasParallel = $false
if (Test-Path -LiteralPath $curlExe) {
    $curlHelp = & $curlExe --help all 2>$null | Out-String
    if ($curlHelp -match '--parallel') { $curlHasParallel = $true }
}

$invCulture = [System.Globalization.CultureInfo]::InvariantCulture

$catFrames = @('(=^.^=) .  ', '(=^.^=) .. ', '(=^.^=) ...', '(=-.-=) ...', '(=-.-=)  ~ ', '(=^.^=)    ')
$catStep = 0
foreach ($cand in $Candidates) {
    $catStep++
    $cf = $catFrames[$catStep % $catFrames.Count]
    Write-Host ("`r  {0} [{1}/{2}] Проверяю {3,-34}" -f $cf, $catStep, $Candidates.Count, $cand.File) -NoNewline -ForegroundColor Cyan
    $batPath = Join-Path $StratDir $cand.File
    if (-not (Test-Path -LiteralPath $batPath)) { $batPath = Join-Path $ArchDir $cand.File }
    if (-not (Test-Path -LiteralPath $batPath)) { $batPath = Join-Path $Root $cand.File }
    if (-not (Test-Path -LiteralPath $batPath)) { continue }

    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $batPath
    $env:Z2_CONF = Join-Path $Root 'bin\service.conf'
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
        if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
    } catch {
        Write-Host ("        - {0,-28} : Ошибка сборки конфига" -f $cand.File) -ForegroundColor Red
        continue
    }

    $confPath = Join-Path $Root 'bin\service.conf'
    $winwsExe = Join-Path $Root 'bin\winws2.exe'
    $proc = $null
    try {
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$confPath`"" -WindowStyle Hidden -PassThru
    } catch {}
    if ($NonInteractive) {
        Write-Host ("[{0}/{1}] Тестирую {2}..." -f $catStep, $Candidates.Count, $cand.File)
        Start-Sleep -Milliseconds 650
    } else {
        $animFrames = @('(=^.^=) .  ', '(=^.^=) .. ', '(=^.^=) ...', '(=-.-=) ...', '(=-.-=)  ~ ', '(=^.^=)    ')
        for ($af = 0; $af -lt 6; $af++) {
            $fr = $animFrames[$af % $animFrames.Count]
            Update-Kotek
            Write-Host ("`r  {0} [{1}/{2}] Тестирую {3,-34}" -f $fr, $catStep, $Candidates.Count, $cand.File) -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 280
        }
    }

    $okCount = 0
    $ytHits = 0
    $dcHits = 0
    $totalMs = 0.0
    $rawLines = @()

    if ($curlHasParallel) {
        $cArgs = @('-Z', '--parallel-max', '20')
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

    $padOk = $false; $dl16kOk = $false; $canaryOk = $false
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
            $secVal = 0.0
            if ([double]::TryParse($tStr, [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$secVal)) {
                $totalMs += ($secVal * 1000.0)
            }
            if ($uEff -match 'speed\.cloudflare\.com' -and $dlBytes -ge 32768) { $dl16kOk = $true }
            if ($uEff -match 'one\.one\.one\.one|cloudflare-dns\.com') { $padOk = $true }
            if ($uEff -match 'youtube\.com|ytimg\.com|ggpht\.com|googleapis\.com|googlevideo\.com') { $ytHits++ }
            if ($uEff -match 'discord\.com|discordapp\.com|discord\.gg') { $dcHits++ }
            if ($uEff -match 'githubusercontent\.com|github\.com') { $canaryOk = $true }
        }
    }
    $freezeOk = $dl16kOk

    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name winws2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 280

    $avgMs = if ($okCount -gt 0) { [int][Math]::Round($totalMs / $okCount) } else { 3000 }
    $ytOk = ($ytHits -ge 2)
    $dcOk = ($dcHits -ge 2)
    $speedBonus = [Math]::Max(0, [int][Math]::Round(30.0 - ($avgMs / 50.0)))
    $canaryPen = if (-not $canaryOk -and $okCount -ge 4) { -25 } else { 0 }
    $score = ($okCount * 20) + ($(if ($ytOk) { 45 } else { 0 })) + ($(if ($dcOk) { 35 } else { 0 })) + ($(if ($freezeOk) { 30 } else { 0 })) + $speedBonus + $(if ($okCount -gt 0) { $cand.Bonus } else { 0 }) + $canaryPen

    $ytLbl = if ($ytOk) { 'OK  ' } else { 'FAIL' }
    $dcLbl = if ($dcOk) { 'OK  ' } else { 'FAIL' }
    $frLbl = if ($freezeOk) { 'OK  ' } else { 'SLOW' }
    Write-Host ("`r" + (" " * 78) + "`r") -NoNewline
    Write-Host ("        - {0,-28} : {1,2}/{2} | YT:{3} DC:{4} | 16-20KB:{5} | ~{6,4} мс" -f $cand.File, $okCount, $TestUrls.Count, $ytLbl, $dcLbl, $frLbl, $avgMs) -ForegroundColor Gray

    try {
        $scFile = Join-Path $Root 'utils\strategy_scores.json'
        $scMap = @{}
        if (Test-Path -LiteralPath $scFile) {
            $prevSc = Get-Content -LiteralPath $scFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prevSc) { foreach ($pr in $prevSc.PSObject.Properties) { $scMap[$pr.Name] = $pr.Value } }
        }
        $scMap[$cand.File] = [PSCustomObject]@{ ok=$okCount; total=$TestUrls.Count; ms=$avgMs; yt=$ytOk; dc=$dcOk; ytHits=$ytHits; ytTotal=5; dcHits=$dcHits; dcTotal=4; freeze=$freezeOk; ts=(Get-Date -Format 'yyyy-MM-dd HH:mm') }
        [System.IO.File]::WriteAllText($scFile, ($scMap | ConvertTo-Json -Depth 4), $utf8NoBom)
    } catch {}
    if ($score -gt $BestScore) {
        $BestScore = $score
        $BestFile = $cand.File
        $BestOkCount = $okCount
        $BestYtOk = $ytOk
        $BestDcOk = $dcOk
        $BestFreezeOk = $freezeOk
        $BestAvgMs = $avgMs
    }
    # Smart 2-stage: after top-8 diverse archetypes, stop early if we already found an ideal >=90% match with 64KB OK
    if ($catStep -eq $PrimaryCount -and $Candidates.Count -gt $PrimaryCount) {
        $minIdealOk = [int][Math]::Ceiling($TestUrls.Count * 0.85)
        if ($BestOkCount -ge $minIdealOk -and $BestYtOk -and $BestDcOk -and $BestFreezeOk) {
            Write-Host ("        [БЫСТРО] Найдена отличная стратегия (${BestFile}: $BestOkCount/$($TestUrls.Count), 64KB:OK, ~${BestAvgMs} мс) — архивные стратегии не требуются.") -ForegroundColor Green
            break
        } else {
            Write-Host '        [*] Основные стратегии не дали 85%+ с 64КБ — подключаю резервные из configs_archive\...' -ForegroundColor Yellow
        }
    }
}

$bestPct = if ($TestUrls.Count -gt 0) { [int][Math]::Round(100.0 * $BestOkCount / $TestUrls.Count) } else { 0 }
Write-Host "`n        [ЛУЧШАЯ] Выбрана стратегия: $BestFile ($BestOkCount/$($TestUrls.Count) · $bestPct%)" -ForegroundColor $(if ($bestPct -ge 85) { 'Green' } else { 'Yellow' })
try {
    $resObj = [PSCustomObject]@{ strategy = $BestFile; ok = $BestOkCount; total = $TestUrls.Count; pct = $bestPct }
    [System.IO.File]::WriteAllText((Join-Path $Root 'utils\last_autosetup.json'), ($resObj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
} catch {}

# [4/5] Install & Start zapret Windows Service with Winner Strategy
if (-not (Test-Path -LiteralPath (Join-Path $Root 'utils\nlm_filter.enabled'))) {
    try { & (Join-Path $Root 'utils\nlm_helper.ps1') -Action auto -Root $Root | Out-Null } catch {}
}
Write-Host "`n  [4/5] (=^o^=) Котек ставит службу 'zapret' ($BestFile)..." -ForegroundColor Yellow
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
$env:Z2_BAT = Join-Path $Root $BestFile
$env:Z2_CONF = Join-Path $Root 'bin\service.conf'
$env:Z2_AUTOHOST = '1'
$env:BIN = Join-Path $Root 'bin\'
$env:LISTS = Join-Path $Root 'lists\'
$env:LUA = Join-Path $Root 'lua\'
$env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
$env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'
& (Join-Path $Root 'utils\build_service_conf.ps1')

$winwsExe = Join-Path $Root 'bin\winws2.exe'
$confWin  = Join-Path $Root 'bin\service.conf'
$binEscaped = "\`"$winwsExe\`" @\`"$confWin\`""
$svcZPre = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$svcZExists = ($null -ne $svcZPre)
if ($svcZExists) {
    if ($svcZPre.Status -ne 'Stopped') {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        try { $svcZPre.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5)) } catch { Start-Sleep -Milliseconds 700 }
    }
    try { $svcZPre.Dispose() } catch {}
}
Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 250
if ($svcZExists) {
    $pCfgA = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret binPath= `"$binEscaped`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait -PassThru
    if ($pCfgA.ExitCode -ne 0) {
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEscaped`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait | Out-Null
    }
} else {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create zapret binPath= `"$binEscaped`" DisplayName= `"zapret`" start= auto" -WindowStyle Hidden -Wait | Out-Null
}
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description zapret `"Zapret2 DPI bypass software (winws2)`"" -WindowStyle Hidden -Wait | Out-Null
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure zapret reset= 60 actions= restart/2000/restart/5000/restart/10000" -WindowStyle Hidden -Wait | Out-Null
Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start zapret" -WindowStyle Hidden -Wait | Out-Null
Start-Sleep -Milliseconds 900

$stratShort = [System.IO.Path]::GetFileNameWithoutExtension($BestFile)
& reg.exe add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d $stratShort /f >$null 2>&1

$svcZapret = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$winwsProc = Get-Process -Name 'winws2' -ErrorAction SilentlyContinue
$zapretOk = ($null -ne $svcZapret -and $svcZapret.Status -eq 'Running' -and $null -ne $winwsProc)
if ($zapretOk) {
    Write-Host "        [OK] Служба 'zapret' установлена и ЗАПУЩЕНА (winws2.exe активен)." -ForegroundColor Green
} else {
    $stText = if ($svcZapret) { $svcZapret.Status } else { 'NOT_INSTALLED' }
    Write-Host "        [X] ОШИБКА: Служба 'zapret' не запущена (статус: $stText)!" -ForegroundColor Red
    Write-Host "            Попробуйте перенести папку в C:\Zapret2 и отключить конфликтующий антивирус/VPN." -ForegroundColor Yellow
}

if ($zapretOk -and -not $initialIpsetUpdated) {
    Start-Sleep -Milliseconds 600
    Write-Host "        [*] Докачка свежего списка IPSet и Hosts через активный обход..." -ForegroundColor Cyan
    [void](Update-IpsetAndHosts $true)
}

# [5/5] Install & Start Telegram WS Proxy Service + Live Post-Install Smoke Test
Write-Host "`n  [5/5] (=^-^=) Котек настраивает Telegram Proxy (127.0.0.1:1443) и контрольный тест..." -ForegroundColor Yellow
$tgAction = if ($NonInteractive) { 'ensure-service-silent' } else { 'ensure-service' }
& (Join-Path $Root 'utils\tgws_helper.ps1') $tgAction
$tgDisabled = $false
$tgConfChk = Join-Path $Root 'utils\tgws_proxy.conf'
if (Test-Path -LiteralPath $tgConfChk) {
    $rcChk = [string](Get-Content -LiteralPath $tgConfChk -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($rcChk -match '(?m)^enabled=0\s*$') { $tgDisabled = $true }
}
$svcTgws = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
$tgwsOk = $tgDisabled -or ($null -ne $svcTgws -and $svcTgws.Status -eq 'Running')

# Live Smoke Test through running services
$ytLive = $false; $dcLive = $false; $tgPortLive = $false
if (Test-Path -LiteralPath $curlExe) {
    $ytCode = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 4 'https://www.youtube.com' 2>$null
    if ($ytCode -match '^(200|204|301|302|307|308)$') { $ytLive = $true }
    $dcCode = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 4 'https://discord.com' 2>$null
    if ($dcCode -match '^(200|204|301|302|307|308)$') { $dcLive = $true }
}
$tgHost = '127.0.0.1'; $tgPort = 1443
$tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
if (Test-Path -LiteralPath $tgConf) {
    foreach ($tl in (Get-Content -LiteralPath $tgConf)) {
        if ($tl -match '^(?i)host=(.+)$') { $tgHost = $matches[1].Trim() }
        elseif ($tl -match '^(?i)port=(\d+)$') { $tgPort = [int]$matches[1] }
    }
}
try {
    $tc = New-Object System.Net.Sockets.TcpClient
    $ar = $tc.BeginConnect($tgHost, $tgPort, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(800, $false) -and $tc.Connected) { $tgPortLive = $true }
    $tc.Close()
} catch {}

Write-Host ("        Контроль YouTube  : {0}" -f $(if ($ytLive) { '[OK] Доступен' } else { '[!] Не отвечает (проверьте QUIC/DoH в браузере)' })) -ForegroundColor $(if ($ytLive) { 'Green' } else { 'Yellow' })
Write-Host ("        Контроль Discord  : {0}" -f $(if ($dcLive) { '[OK] Доступен' } else { '[!] Не отвечает' })) -ForegroundColor $(if ($dcLive) { 'Green' } else { 'Yellow' })
Write-Host ("        Контроль TG Proxy : {0}" -f $(if ($tgPortLive) { "[OK] ${tgHost}:${tgPort} слушает" } else { "[X] Порт $tgPort не отвечает" })) -ForegroundColor $(if ($tgPortLive) { 'Green' } else { 'Red' })

if ($zapretOk -and -not $ytLive) {
    if ($NonInteractive) {
        Write-Host '        [*] Контрольный тест YouTube не прошёл — автоматически применяю фикс браузера (QUIC/DoH)...' -ForegroundColor Yellow
        & (Join-Path $Root 'utils\browser_helper.ps1') -Action enable -Root $Root
    } else {
        & (Join-Path $Root 'utils\browser_helper.ps1') -Action prompt -Root $Root
    }
}

Write-Host ''
try { & (Join-Path $Root 'utils\autoupdate_task.ps1') -Action enable -Root $Root | Out-Null } catch {}
try { . (Join-Path $Root 'utils\common.ps1'); Register-Z2UninstallEntry $Root } catch {}
if ($zapretOk -and $tgwsOk) {
    Write-Host '  ==================================================================' -ForegroundColor Green
    Write-Host '          /\_____/\      КОТЕК ВСЁ НАСТРОИЛ! ГОТОВО!' -ForegroundColor Green
    Write-Host '         /  ^   ^  \  *  Обход DPI и Telegram Proxy активны' -ForegroundColor Green
    Write-Host '        ( ==  w  == )    Можно закрывать окно и пользоваться!' -ForegroundColor Green
    Write-Host '         )         (  ~' -ForegroundColor Green
    Write-Host '        (  (     )  )' -ForegroundColor Green
    Write-Host '  ==================================================================' -ForegroundColor Green
    Write-Host "  Папка установки      : $Root"
    Write-Host "  Активная стратегия   : $BestFile"
    Write-Host '  Служба zapret        : ЗАПУЩЕНА (winws2.exe)'
    Write-Host "  Telegram Desktop     : ПРОКСИ АКТИВЕН (${tgHost}:${tgPort})"
    Write-Host '  Управление и удаление: !_START_KOTEK.bat (главное окно GUI)'
    Write-Host '  ==================================================================' -ForegroundColor Green
} else {
    Write-Host '  ==================================================================' -ForegroundColor Red
    Write-Host '              АВТОНАСТРОЙКА ЗАВЕРШЕНА С ОШИБКАМИ!                   ' -ForegroundColor Red
    Write-Host '  ==================================================================' -ForegroundColor Red
    Write-Host ("  Служба zapret        : {0}" -f $(if ($zapretOk) { 'ЗАПУЩЕНА' } else { 'НЕ ЗАПУЩЕНА (ошибка!)' }))
    Write-Host ("  Служба zapret-tgws   : {0}" -f $(if ($tgwsOk) { 'ЗАПУЩЕНА' } else { 'НЕ ЗАПУЩЕНА (ошибка!)' }))
    Write-Host '  Откройте !_START_KOTEK.bat --cli -> 10, чтобы скопировать отчёт диагностики.' -ForegroundColor Yellow
    Write-Host '  ==================================================================' -ForegroundColor Red
    exit 1
}
Write-Host ''

exit 0
