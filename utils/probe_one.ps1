param(
    [string]$Root = '',
    [Parameter(Mandatory=$true)][string]$BatPath
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
$Root = Resolve-Z2Root $Root
if (-not (Test-Z2IsAdmin)) {
    Write-Host '[X] Требуются права администратора для тестирования стратегии.'
    exit 1
}

if (-not (Test-Path -LiteralPath $BatPath)) {
    Write-Host "[X] Стратегия не найдена: $BatPath"
    exit 1
}

$TestTargets = @(Get-Z2Targets -Root $Root -Mode 'CORE')
$TestUrls = @($TestTargets | ForEach-Object { $_.Url })
$ytTotal  = @($TestTargets | Where-Object { $_.Cat -eq 'YT' }).Count
$dcTotal  = @($TestTargets | Where-Object { $_.Cat -eq 'DC' }).Count

$batName  = [System.IO.Path]::GetFileName($BatPath)
$confPath = Join-Path $env:TEMP "z2_probe_$PID.conf"
$winwsExe = Join-Path $Root 'bin\winws2.exe'
$curlExe  = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

Write-Host "Подготовка быстрого теста $batName по $($TestUrls.Count) целям..."
$svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$wasRunning = ($null -ne $svc -and $svc.Status -eq 'Running')

Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

$okCount = 0; $ytHits = 0; $dcHits = 0; $totalMs = 0.0; $freezeOk = $false
$exitCode = 0

try {
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $BatPath
    $env:Z2_CONF = $confPath
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

    $global:LASTEXITCODE = 0
    & (Join-Path $Root 'utils\build_service_conf.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $confPath)) {
        Write-Host "[X] Ошибка сборки конфигурации для $batName"
        $exitCode = 1
    } else {
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$confPath`"" -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 650
        if ($null -eq $proc -or $proc.HasExited) {
            Write-Host "[X] winws2.exe завершился сразу после старта для $batName"
            $exitCode = 1
            throw "winws2 exited"
        }

        Write-Host "Тестирую $batName по $($TestUrls.Count) целям..."
        $padHdr = 'X-Pad: ' + ('A' * 3072)

        $curlHasParallel = $false
        try {
            $ch = & $curlExe --help all 2>$null | Out-String
            if ($ch -match '--parallel') { $curlHasParallel = $true }
        } catch {}

        $heavyRx = 'speed\.cloudflare\.com|^https?://www\.youtube\.com/?$|i\.ytimg\.com/.+maxresdefault\.jpg'
        $curlFmt = '%{url_effective}|%{http_code}|%{time_total}|%{size_download}|%{exitcode}|%{speed_download}'
        $rawLines = @()
        if ($curlHasParallel) {
            $cArgs = @('-Z', '--parallel-max', '20')
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
            try { $codesOut = & $curlExe @cArgs 2>$null; $rawLines = ($codesOut -split "`r?`n") } catch {}
        } else {
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

        $invCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $cfFreezeOk = $false; $ytFreezeOk = $false
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
            [void][double]::TryParse($tStr, [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$secVal)
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
                $totalMs += ($secVal * 1000.0)
                if (($uEff -match 'i\.ytimg\.com/.+maxresdefault\.jpg' -or $uEff -match '^https?://www\.youtube\.com/?$') -and $code -eq '200' -and $dlBytes -ge 65536 -and $spdBytes -ge 40000) {
                    $ytFreezeOk = $true
                }
                if ($uEff -match 'youtube\.com|ytimg\.com|ggpht\.com|googleapis\.com|googlevideo\.com') { $ytHits++ }
                if ($uEff -match 'discord\.com|discordapp\.com|discord\.gg') { $dcHits++ }
            }
        }
        $freezeOk = ($cfFreezeOk -and $ytFreezeOk)

        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch {}
        }
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

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
            ytTotal = $ytTotal
            dcHits  = $dcHits
            dcTotal = $dcTotal
            freeze  = $freezeOk
            ytF     = $ytFreezeOk
            cfF     = $cfFreezeOk
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
    $env:Z2_SKIP_NLM_AUTO = $null
    Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
    if (Test-Path -LiteralPath $confPath) {
        Remove-Item -LiteralPath $confPath -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    }
}
exit $exitCode
