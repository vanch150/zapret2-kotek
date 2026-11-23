param(
    [string]$Root = ''
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$ListsDir = Join-Path $Root 'lists'
if (-not (Test-Path -LiteralPath $ListsDir)) { exit 0 }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sysExPath   = Join-Path $ListsDir 'list-exclude.txt'
$effExPath   = Join-Path $ListsDir 'list-exclude.effective.txt'
$usrExPath   = Join-Path $ListsDir 'list-exclude-user.txt'
$sysIpExPath = Join-Path $ListsDir 'ipset-exclude.txt'
$usrIpExPath = Join-Path $ListsDir 'ipset-exclude-user.txt'
$usrGenPath  = Join-Path $ListsDir 'list-general-user.txt'
$autoPath    = Join-Path $ListsDir 'list-auto.txt'

function Read-Z2Domains([string]$Path) {
    $res = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = ($line -replace '\s*#.*$', '').Trim()
        if ($t) { $res.Add($t) }
    }
    return $res
}

function Normalize-Z2ListEntry([string]$Dom) {
    if ([string]::IsNullOrWhiteSpace($Dom)) { return '' }
    $s = $Dom.Trim().TrimStart('!').Trim()
    $exact = ''
    if ($s.StartsWith('^')) {
        $exact = '^'
        $s = $s.Substring(1).TrimStart('!')
    }
    $s = $s.Trim().Trim('.').ToLowerInvariant()
    if (-not $s) { return '' }
    return ($exact + $s)
}

function Test-Z2DomainCovered([string]$Candidate, [string[]]$RuleList) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $c = (Normalize-Z2ListEntry $Candidate).TrimStart('^').Trim('.')
    if (-not $c) { return $false }
    foreach ($r in $RuleList) {
        if ([string]::IsNullOrEmpty($r)) { continue }
        if ($r.StartsWith('^')) {
            $rBare = $r.Substring(1)
            if ($rBare -and $c -eq $rBare) { return $true }
        } else {
            if ($c -eq $r -or $c.EndsWith('.' + $r)) { return $true }
        }
    }
    return $false
}

function Get-Z2DedupKey([string]$Entry) {
    if ([string]::IsNullOrWhiteSpace($Entry)) { return '' }
    $s = ($Entry -replace '\s*#.*$', '').Trim()
    if (-not $s) { return '' }
    $prefix = ''
    if ($s -match '^([!^]+)(.*)$') {
        $prefix = $matches[1]
        $s = $matches[2]
    }
    $s = $s.Trim().Trim('.').ToLowerInvariant()
    if (-not $s) { return '' }
    return ($prefix + $s)
}

function Deduplicate-Z2UserFile([string]$UserPath, [string]$SysPath, [string]$DefaultHeader) {
    if (-not (Test-Path -LiteralPath $UserPath) -or -not (Test-Path -LiteralPath $SysPath)) { return }
    $sysSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in (Read-Z2Domains $SysPath)) {
        $k = Get-Z2DedupKey $s
        if ($k) { [void]$sysSet.Add($k) }
    }
    if ($sysSet.Count -eq 0) { return }

    $rawLines = @(Get-Content -LiteralPath $UserPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $changed = $false
    foreach ($line in $rawLines) {
        if ($null -eq $line) { continue }
        $tr = $line.Trim()
        if (-not $tr) { continue }
        if ($tr.StartsWith('#')) { $out.Add($tr); continue }
        # Strip inline comments and normalize dot/case for comparison while preserving original trimmed line
        $key = Get-Z2DedupKey $tr
        if (-not $key) { continue }
        if ($sysSet.Contains($key)) { $changed = $true; continue }
        if ($seen.Add($key)) { $out.Add($tr) } else { $changed = $true }
    }
    if ($changed) {
        if ($out.Count -eq 0 -and $DefaultHeader) { $out.Add($DefaultHeader) }
        [System.IO.File]::WriteAllLines($UserPath, $out, $utf8NoBom)
    }
}

# 0. Safe migration: drop only exact duplicates already covered by system excludes (keeps all custom user entries)
Deduplicate-Z2UserFile $usrExPath   $sysExPath   '# Свои домены-исключения (по одному в строке)'
Deduplicate-Z2UserFile $usrIpExPath $sysIpExPath '# Свои IP/подсети-исключения (CIDR, по одной в строке)'

# 1. Build list-exclude.effective.txt = list-exclude.txt MINUS user overrides from list-general-user.txt
# Only exact matches or subdomains of user-added domain are removed (never strip parent domains like yandex.ru!)
$usrGenRaw = Read-Z2Domains $usrGenPath
$usrGenNorm = @($usrGenRaw | Where-Object { -not $_.StartsWith('!') } | ForEach-Object { Normalize-Z2ListEntry $_ } | Where-Object { $_ } | Select-Object -Unique)

$sysExRaw = Read-Z2Domains $sysExPath
$effLines = New-Object System.Collections.Generic.List[string]
foreach ($d in $sysExRaw) {
    if (-not (Test-Z2DomainCovered $d $usrGenNorm)) { $effLines.Add($d) }
}
if ($sysExRaw.Count -gt 0) { [System.IO.File]::WriteAllLines($effExPath, $effLines, $utf8NoBom) }

# 2. Prune list-auto.txt: remove any domain covered by effective system excludes or user excludes
if (Test-Path -LiteralPath $autoPath) {
    $autoRaw = Read-Z2Domains $autoPath
    if ($autoRaw.Count -gt 0) {
        $usrExRaw = Read-Z2Domains $usrExPath
        $allExNorm = @(($effLines.ToArray() + @($usrExRaw)) | Where-Object { -not $_.StartsWith('!') } | ForEach-Object { Normalize-Z2ListEntry $_ } | Where-Object { $_ } | Select-Object -Unique)
        $cleanAuto = New-Object System.Collections.Generic.List[string]
        $seenAuto = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $changed = $false
        foreach ($ad in $autoRaw) {
            if (Test-Z2DomainCovered $ad $allExNorm) {
                $changed = $true
                continue
            }
            if ($seenAuto.Add($ad)) { $cleanAuto.Add($ad) } else { $changed = $true }
        }
        if ($changed) {
            [System.IO.File]::WriteAllLines($autoPath, $cleanAuto, $utf8NoBom)
        }
    }
}
