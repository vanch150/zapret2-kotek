# Zapret2 Kotek — Lightweight AI Code Packager (dev/pack_for_ai.ps1)
# Packs all code/configs as-is and replaces heavy binaries/media/ipset with tiny .stub.txt phantoms + _AI_MANIFEST.txt
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$vf   = Join-Path $Root 'utils\version.txt'
$ver  = if (Test-Path -LiteralPath $vf) { (Get-Content -LiteralPath $vf -TotalCount 1).Trim() } else { 'dev' }
$tmp  = Join-Path $env:TEMP ("z2_ai_" + [Guid]::NewGuid().ToString('N').Substring(0,6))
# Clean old AI code packs in dev\ and root before creating a fresh one
Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'zapret2-kotek-*-code.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $Root -Filter 'zapret2-kotek-*-code.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
$out  = Join-Path $PSScriptRoot "zapret2-kotek-v$ver-code.zip"

if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Directories skipped completely (repo internals / docs)
$skipDirs  = @('.git', 'docs')
# Directories where all files become phantom .stub.txt
$stubDirs  = @('lua')
# File patterns replaced by phantom .stub.txt
$stubPats  = @('ipset-all.txt', 'ipset-all.txt.backup', '*.png', '*.ico', '*.exe', '*.dll', '*.sys', '*.bin', '*.log')
# File patterns skipped completely (don't even stub)
$skipPats  = @('*.zip', '*.log.*', 'ai_bypass.conf', 'diag_report.txt', 'diag_report.json')
# Exact relative paths skipped completely (runtime/personal artifacts)
$skipRelPaths = @(
    'bin/service.conf',
    'utils/last_autosetup.json',
    'utils/strategy_scores.json',
    'utils/.tgws_connected',
    'utils/ai_bypass.conf',
    'utils/telemetry.enabled',
    'utils/telemetry.id',
    'utils/telemetry.state.json',
    'utils/telemetry.prompted',
    'utils/browser_policy.backup.json',
    'utils/nlm_filter.enabled',
    'utils/nlm_filter.names',
    'lists/ai-custom-domains.txt'
)

$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("# Zapret2 Kotek v$ver — AI Code Snapshot Manifest")
$manifest.Add("# IMPORTANT FOR AI: Read dev/AI_CONTEXT.md FIRST (intentional design decisions, invariants, and 'do not touch' notes).")
$manifest.Add("# Heavy files below were replaced by <name>.stub.txt phantoms so AI sees exact project layout.")
$manifest.Add("")

$realCount = 0
$stubCount = 0

Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
    $relNorm = ($rel -replace '\\', '/').ToLowerInvariant()
    $top = ($rel -split '[\\/]')[0]
    if ($skipDirs -contains $top) { return }
    if ($skipRelPaths -contains $relNorm) { return }
    foreach ($sp in $skipPats) { if ($_.Name -like $sp) { return } }

    $isStub = ($stubDirs -contains $top)
    if (-not $isStub) {
        foreach ($pat in $stubPats) {
            if ($_.Name -like $pat) { $isStub = $true; break }
        }
    }

    $dst = Join-Path $tmp $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

    if ($isStub) {
        $szBytes = $_.Length
        $extra = ''
        if ($_.Name -ieq 'ipset-all.txt') {
            try { $lc = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count; $extra = " | Lines: $lc" } catch {}
        }
        $stubText = "[PHANTOM STUB] Original: $rel | Size: $szBytes bytes$extra`r`nExcluded from lightweight AI archive to save space; real file exists in project.`r`n"
        [System.IO.File]::WriteAllText(($dst + '.stub.txt'), $stubText, $utf8NoBom)
        $manifest.Add("[STUB] $rel ($szBytes bytes$extra)")
        $stubCount++
    } elseif ($relNorm -eq 'utils/tgws_proxy.conf') {
        # Sanitize personal secrets and custom proxy domains before packing
        $cfg = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $cfg = [regex]::Replace($cfg, '(?m)^secret=[^\r\n]*', 'secret=')
        $cfg = [regex]::Replace($cfg, '(?m)^cfproxy_domain=[^\r\n]*', 'cfproxy_domain=')
        $cfg = [regex]::Replace($cfg, '(?m)^cfproxy_worker_domain=[^\r\n]*', 'cfproxy_worker_domain=')
        [System.IO.File]::WriteAllText($dst, $cfg, $utf8NoBom)
        $realCount++
    } else {
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        $realCount++
    }
}

[System.IO.File]::WriteAllLines((Join-Path $tmp '_AI_MANIFEST.txt'), $manifest, $utf8NoBom)
Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $out -CompressionLevel Optimal
Remove-Item -LiteralPath $tmp -Recurse -Force

$kb = [Math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1)
Write-Host "[OK] Собран облегчённый архив для AI: $out ($kb KB)" -ForegroundColor Green
Write-Host "     Реальных файлов: $realCount | Фантомных заглушек (.stub.txt): $stubCount" -ForegroundColor Cyan
