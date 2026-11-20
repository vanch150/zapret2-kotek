# Zapret2 Clean Release Packager (for author use)
# Produces a clean .zip without logs, service.conf, personal secrets, list-auto.txt, or dev/
param(
    [string]$Version = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    $vf = Join-Path $Root 'utils\version.txt'
    $Version = if (Test-Path -LiteralPath $vf) { (Get-Content -LiteralPath $vf -TotalCount 1).Trim() } else { '1.0.0' }
}
$StageParent = Join-Path $env:TEMP "z2_release_stage_$([Guid]::NewGuid().ToString('N').Substring(0,6))"
$FolderName = "zapret2-kotek-v$($Version.TrimStart('v', 'V'))"
$StageDir = Join-Path $StageParent $FolderName
$OutZip = Join-Path (Split-Path -Parent $Root) "$FolderName.zip"

New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
Get-ChildItem -LiteralPath $Root -Force | Copy-Item -Destination $StageDir -Recurse -Force

# Strip runtime artifacts, caches, dev scripts, and personal files
$stripPaths = @(
    'dev',
    'docs',
    '.git',
    '.gitignore',
    'bin\service.conf',
    'bin\tg-ws-proxy.log',
    'bin\tg-ws-proxy.exe',
    'bin\tg-ws-proxy.sha256',
    'utils\.tgws_connected',
    'utils\diag_report.txt',
    'utils\strategy_scores.json',
    'utils\browser_policy.applied',
    'utils\tgws_py',
    'utils\test results',
    'lists\ipset-all.txt.backup',
    'utils\nlm_filter.enabled',
    'utils\nlm_filter.names',
    'utils\autoupdate.log',
    'utils\autoupdate.mode',
    'utils\tray_mode.enabled',
    'utils\wf_priority.conf',
    'desktop.ini',
    'utils\game_filter.enabled',
    'custom_auto_synthesized.bat',
    'strategies\custom_auto_synthesized.bat'
)
foreach ($rel in $stripPaths) {
    $p = Join-Path $StageDir $rel
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Recurse -Force
    }
}

# Ensure default ACTIVE_*_UDP.bin and clean defaults exist so manual service install binds to ACTIVE_*.bin
$defFake = Join-Path $StageDir 'bin\quic_initial_www_google_com.bin'
if (Test-Path -LiteralPath $defFake) {
    Copy-Item -LiteralPath $defFake -Destination (Join-Path $StageDir 'bin\ACTIVE_DISCORD_UDP.bin') -Force
    Copy-Item -LiteralPath $defFake -Destination (Join-Path $StageDir 'bin\ACTIVE_GAME_UDP.bin') -Force
}
Get-ChildItem -LiteralPath (Join-Path $StageDir 'utils') -Filter '*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
$utf8NoBomInit = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $StageDir 'utils\active_udp_fake.txt'), 'quic_initial_www_google_com.bin', $utf8NoBomInit)

# Reset list-auto.txt and tgws_proxy.conf secret
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $StageDir 'lists\list-auto.txt'), '', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $StageDir 'utils\version.txt'), "$Version`r`n", $utf8NoBom)

# Aggregate lists\ipset-all.txt via bin\ip2net.exe (preserving both IPv4 and IPv6 subnets)
$stageIp2Net = Join-Path $StageDir 'bin\ip2net.exe'
$stageIpset  = Join-Path $StageDir 'lists\ipset-all.txt'
if ((Test-Path -LiteralPath $stageIp2Net) -and (Test-Path -LiteralPath $stageIpset)) {
    try {
        $allRaw = @(Get-Content -LiteralPath $stageIpset -Encoding UTF8 | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object { $_ })
        $rawV4  = @($allRaw | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$' })
        $rawV6  = @($allRaw | Where-Object { $_ -match ':' })
        $aggV4  = @($rawV4 | & $stageIp2Net 2>$null | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$' })
        $aggV6  = $rawV6
        if ($rawV6.Count -gt 0) {
            $tryV6 = @($rawV6 | & $stageIp2Net -6 2>$null | Where-Object { $_ -match ':' })
            if ($tryV6.Count -gt 0) { $aggV6 = $tryV6 }
        }
        if ($aggV4.Count -ge 50) {
            $combined = @($aggV4) + @($aggV6)
            [System.IO.File]::WriteAllLines($stageIpset, $combined, $utf8NoBom)
            Write-Host "[OK] Aggregated ipset-all.txt via ip2net.exe (IPv4: $($rawV4.Count)->$($aggV4.Count), IPv6: $($rawV6.Count)->$($aggV6.Count))" -ForegroundColor Green
        }
    } catch {}
}

# Precompile bin\tg-ws-proxy.exe via system .NET 4.x csc.exe (zero-delay launch; tgws_helper keeps fallback)
$stageCs  = Join-Path $StageDir 'utils\TgWsProxyService.cs'
$stageExe = Join-Path $StageDir 'bin\tg-ws-proxy.exe'
$cscPath  = @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($cscPath -and (Test-Path -LiteralPath $stageCs)) {
    & $cscPath /nologo /target:exe /optimize+ /platform:anycpu /out:$stageExe /reference:System.dll,System.Core.dll,System.ServiceProcess.dll $stageCs
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $stageExe)) {
        $csHash = (Get-FileHash -LiteralPath $stageCs -Algorithm SHA256).Hash.ToUpperInvariant()
        [System.IO.File]::WriteAllText((Join-Path $StageDir 'bin\tg-ws-proxy.sha256'), $csHash, $utf8NoBom)
        Write-Host "[OK] Precompiled bin\tg-ws-proxy.exe (SHA256 saved)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] csc.exe failed — bin\tg-ws-proxy.exe will compile on client" -ForegroundColor Yellow
    }
}

$confPath = Join-Path $StageDir 'utils\tgws_proxy.conf'
if (Test-Path -LiteralPath $confPath) {
    $c = Get-Content -LiteralPath $confPath -Raw
    # Keep cfproxy_worker_domain / cfproxy_domain for family & friends pool; strip only personal secret
    $c = [regex]::Replace($c, '(?m)^secret=.*$', 'secret=')
    [System.IO.File]::WriteAllText($confPath, $c, $utf8NoBom)
}

# Scan for accidental user-path leaks
$leaks = Select-String -Path (Join-Path $StageDir '*.bat'), (Join-Path $StageDir 'strategies\*.bat'), (Join-Path $StageDir 'configs_archive\*.bat'), (Join-Path $StageDir 'utils\*.ps1'), (Join-Path $StageDir 'utils\*.conf'), (Join-Path $StageDir 'bin\*.conf'), (Join-Path $StageDir 'lists\*.txt') -Pattern '[A-Za-z]:[/\\]Users[/\\]' -ErrorAction SilentlyContinue
if ($leaks) {
    Write-Host '[WARN] Обнаружены упоминания C:\Users\:' -ForegroundColor Yellow
    $leaks | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Yellow }
}

if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }
Compress-Archive -Path $StageDir -DestinationPath $OutZip -CompressionLevel Optimal
Remove-Item -LiteralPath $StageParent -Recurse -Force

$zipHash = (Get-FileHash -LiteralPath $OutZip -Algorithm SHA256).Hash.ToLowerInvariant()
$sumsPath = Join-Path (Split-Path -Parent $Root) 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($sumsPath, "$zipHash  $FolderName.zip`r`n", $utf8NoBom)
Write-Host "`n[OK] Чистый релиз собран: $OutZip" -ForegroundColor Green
Write-Host "[OK] SHA-256 записан в:   $sumsPath" -ForegroundColor Cyan
