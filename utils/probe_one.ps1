param(
    [string]$Root = '',
    [Parameter(Mandatory=$true)][string]$BatPath
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

if (-not (Test-Path -LiteralPath $BatPath)) {
    Write-Host "[X] Стратегия не найдена: $BatPath"
    exit 1
}

$batName  = [System.IO.Path]::GetFileName($BatPath)
$confPath = Join-Path $env:TEMP "z2_probe_$PID.conf"
$winwsExe = Join-Path $Root 'bin\winws2.exe'
$curlExe  = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

Write-Host "Подготовка быстрого теста $batName..."
$svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$wasRunning = ($null -ne $svc -and $svc.Status -eq 'Running')


if ($wasRunning) {
    Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}
Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 200

$okCount = 0; $ytHits = 0; $dcHits = 0; $totalMs = 0.0; $freezeOk = $false
$exitCode = 0

try {
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $BatPath
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

    $global:LASTEXITCODE = 0
    & (Join-Path $Root 'utils\build_service_conf.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $confPath)) {
        Write-Host "[X] Ошибка сборки конфигурации для $batName"
        $exitCode = 1
    } else {
        Write-Host "Тестирую $batName по 16 целям..."
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$confPath`"" -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 650
        if ($null -eq $proc -or $proc.HasExited) {
            Write-Host "[X] winws2.exe завершился сразу после старта для $batName"
            $exitCode = 1
            throw "winws2 exited"
        }

        $TestItems = New-Object System.Collections.Generic.List[object]
        $tFile = Join-Path $Root 'utils\targets.txt'
        if (Test-Path -LiteralPath $tFile) {
            foreach ($tl in (Get-Content -LiteralPath $tFile -Encoding UTF8)) {
                $tt = $tl.Trim()
                if (-not $tt -or $tt.StartsWith('#')) { continue }
                $tp = $tt -split '\|'
                if ($tp.Count -ge 3 -and $tp[1].Trim().ToUpperInvariant() -eq 'CORE') {
                    $TestItems.Add(@{ Tag = $tp[0].Trim().ToUpperInvariant(); Url = $tp[2].Trim() })
                }
            }
        }
        if ($TestItems.Count -eq 0) {
            foreach ($u in @('https://www.youtube.com','https://i.ytimg.com/favicon.ico','https://yt3.ggpht.com','https://jnn-pa.googleapis.com','https://discord.com','https://discord.com/api/v10/gateway','https://cdn.discordapp.com','https://discord.gg','https://web.telegram.org','https://t.me','https://cloudflare-dns.com','https://one.one.one.one','https://7tv.io','https://betterttv.net','https://frankerfacez.com','https://raw.githubusercontent.com')) {
                $tg = if ($u -match 'youtube|ytimg|ggpht|googleapis') { 'YT' } elseif ($u -match 'discord') { 'DC' } else { 'WEB' }
                $TestItems.Add(@{ Tag = $tg; Url = $u })
            }
        }
        $TestUrls = @($TestItems | ForEach-Object { $_.Url })
        $padHdr = 'X-Pad: ' + ('A' * 3072)

        $curlHasParallel = $false
        try {
            $ch = & $curlExe --help all 2>$null | Out-String
            if ($ch -match '--parallel') { $curlHasParallel = $true }
        } catch {}

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
            try { $codesOut = & $curlExe @cArgs 2>$null; $rawLines = ($codesOut -split "`r?`n") } catch {}
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

        $invCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $padOk = $false; $dl16kOk = $false
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
            }
        }
        $freezeOk = $dl16kOk

        if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 180

        $avgMs = if ($okCount -gt 0) { [int][Math]::Round($totalMs / $okCount) } else { 3000 }
        $scoreFile = Join-Path $Root 'utils\strategy_scores.json'
        $map = @{}
        if (Test-Path -LiteralPath $scoreFile) {
            try {
                $prev = Get-Content -LiteralPath $scoreFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($prev) {
                    foreach ($prop in $prev.PSObject.Properties) {
                        $map[$prop.Name] = $prop.Value
                    }
                }
            } catch {}
        }
        $map[$batName] = [PSCustomObject]@{
            ok      = $okCount
            total   = $TestUrls.Count
            ms      = $avgMs
            yt      = ($ytHits -ge 2)
            dc      = ($dcHits -ge 2)
            ytHits  = $ytHits
            ytTotal = 5
            dcHits  = $dcHits
            dcTotal = 4
            freeze  = $freezeOk
            ts      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        $json = $map | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($scoreFile, $json, (New-Object System.Text.UTF8Encoding($false)))

        $ytLbl = if ($ytHits -ge 2) { 'OK' } else { 'FAIL' }
        $dcLbl = if ($dcHits -ge 2) { 'OK' } else { 'FAIL' }
        Write-Host "[OK] ${batName}: ${okCount}/$($TestUrls.Count) · ~${avgMs} мс (YT:${ytLbl} DC:${dcLbl})"
    }
} catch {
    if ($exitCode -eq 0) { $exitCode = 1 }
} finally {
    Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $confPath) {
        Remove-Item -LiteralPath $confPath -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    }
}
exit $exitCode
