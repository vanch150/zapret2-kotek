param(
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$sb = New-Object System.Text.StringBuilder
$verHdr = if (Test-Path -LiteralPath (Join-Path $Root 'utils\version.txt')) { (Get-Content -LiteralPath (Join-Path $Root 'utils\version.txt') -TotalCount 1).Trim() } else { '1.0.0' }
[void]$sb.AppendLine("=== ZAPRET2 KOTEK DIAGNOSTIC REPORT (v$verHdr) ===")
[void]$sb.AppendLine("Date      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$safeRoot = if ($env:USERPROFILE) { $Root -ireplace [regex]::Escape($env:USERPROFILE), "%USERPROFILE%" } else { $Root }
[void]$sb.AppendLine("Path      : $safeRoot")
$pathWarn = @()
if ($Root -match '\s') { $pathWarn += 'SPACES' }
if ($Root -match '[()]') { $pathWarn += 'PARENS' }
if ($Root -match '[\u0400-\u04FF]') { $pathWarn += 'CYRILLIC' }
if ($Root -match '(?i)\\(Downloads|OneDrive|Desktop|Temp)\\') { $pathWarn += 'USER_TMP_DIR' }
[void]$sb.AppendLine("PathFlags : $(if ($pathWarn.Count -gt 0) { $pathWarn -join ', ' } else { 'CLEAN' })")

$strat = ''
try { $strat = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube').'zapret-discord-youtube' } catch {}
[void]$sb.AppendLine("Strategy  : $(if ($strat) { $strat } else { 'none' })")

foreach ($s in @('zapret', 'zapret-tgws', 'WinDivert', 'WinDivert14', 'BFE', 'GoodbyeDPI', 'discordfix_zapret')) {
    $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($sv -or $s -in @('zapret','zapret-tgws','WinDivert','BFE')) {
        [void]$sb.AppendLine(("Service {0,-17}: {1}" -f $s, $(if ($sv) { $sv.Status } else { 'NOT_INSTALLED' })))
    }
}

$procs = (Get-Process -Name 'winws2','winws','tg-ws-proxy','AdguardSvc' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique) -join ', '
[void]$sb.AppendLine("Processes : $(if ($procs) { $procs } else { 'none' })")

$prevEnc = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch {}
$tcpTs = (& netsh.exe interface tcp show global 2>$null | Select-String -Pattern 'Timestamps|Метки' | Select-Object -First 1)
try { [Console]::OutputEncoding = $prevEnc } catch {}
[void]$sb.AppendLine("TCP_TS    : $(if ($tcpTs) { $tcpTs.ToString().Trim() } else { 'unknown' })")

$curlExe = "$env:SystemRoot\System32\curl.exe"
if (Test-Path -LiteralPath $curlExe) {
    foreach ($u in @('https://www.youtube.com', 'https://discord.com')) {
        $code = & $curlExe -4 -s -o NUL -w '%{http_code}' --max-time 3 $u 2>$null
        [void]$sb.AppendLine(("Probe {0,-24}: HTTP {1}" -f $u, $(if ($code) { $code } else { '000' })))
    }
}

$tgHost = '127.0.0.1'; $tgPort = 1443
$tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
if (Test-Path -LiteralPath $tgConf) {
    foreach ($tl in (Get-Content -LiteralPath $tgConf)) {
        if ($tl -match '^(?i)host=(.+)$') { $tgHost = $matches[1].Trim() }
        elseif ($tl -match '^(?i)port=(\d+)$') { $tgPort = [int]$matches[1] }
    }
}
$tgPortOk = $false
try {
    $tc = New-Object System.Net.Sockets.TcpClient
    $ar = $tc.BeginConnect($tgHost, $tgPort, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(800, $false) -and $tc.Connected) { $tgPortOk = $true }
    $tc.Close()
} catch {}
[void]$sb.AppendLine("TG_Proxy  : $(if ($tgPortOk) { "${tgHost}:${tgPort} OPEN" } else { "${tgHost}:${tgPort} CLOSED" })")

$logPath = Join-Path $Root 'bin\tg-ws-proxy.log'
if (Test-Path -LiteralPath $logPath) {
    [void]$sb.AppendLine('--- Last 6 lines of tg-ws-proxy.log (redacted) ---')
    $tail = Get-Content -LiteralPath $logPath -Tail 6
    foreach ($tl in $tail) {
        $redacted = $tl -replace '[0-9a-fA-F]{32,}', '<REDACTED_SECRET>'
        [void]$sb.AppendLine($redacted)
    }
}

$report = $sb.ToString()
$outFile = Join-Path $Root 'utils\diag_report.txt'
[System.IO.File]::WriteAllText($outFile, $report, (New-Object System.Text.UTF8Encoding($false)))
$clipOk = $false
try { Set-Clipboard -Value $report; $clipOk = $true } catch {}

if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch {} }
Write-Host $report -ForegroundColor Gray
if ($clipOk) {
    Write-Host '  [OK] Отчёт скопирован в буфер обмена и сохранён в utils\diag_report.txt' -ForegroundColor Green
} else {
    Write-Host '  [OK] Отчёт сохранён в utils\diag_report.txt (буфер обмена недоступен)' -ForegroundColor Yellow
}
Write-Host '  Просто нажмите Ctrl+V в Telegram, чтобы отправить его для помощи.' -ForegroundColor Cyan
Write-Host ''
exit 0
