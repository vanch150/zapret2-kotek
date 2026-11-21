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

function Normalize-Z2Domain([string]$Dom) {
    return ($Dom.Trim().TrimStart('^', '!', '.')).ToLowerInvariant()
}

function Test-Z2DomainCovered([string]$Candidate, [string[]]$RuleList) {
    $c = Normalize-Z2Domain $Candidate
    if (-not $c) { return $false }
    foreach ($r in $RuleList) {
        if ($c -eq $r -or $c.EndsWith('.' + $r)) { return $true }
    }
    return $false
}

function Deduplicate-Z2UserFile([string]$UserPath, [string]$SysPath, [string]$DefaultHeader) {
    if (-not (Test-Path -LiteralPath $UserPath) -or -not (Test-Path -LiteralPath $SysPath)) { return }
    $sysSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in (Read-Z2Domains $SysPath)) { [void]$sysSet.Add($s) }
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
        # Strip inline comments when checking duplicates so "domain.com # note" deduplicates properly
        $cleanVal = ($tr -replace '\s*#.*$', '').Trim()
        if (-not $cleanVal) { continue }
        if ($sysSet.Contains($cleanVal)) { $changed = $true; continue }
        if ($seen.Add($cleanVal)) { $out.Add($tr) } else { $changed = $true }
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
$usrGenNorm = @($usrGenRaw | Where-Object { -not $_.StartsWith('!') } | ForEach-Object { Normalize-Z2Domain $_ } | Where-Object { $_ } | Select-Object -Unique)

$sysExRaw = Read-Z2Domains $sysExPath
$effLines = New-Object System.Collections.Generic.List[string]
foreach ($d in $sysExRaw) {
    $dn = Normalize-Z2Domain $d
    $overridden = $false
    foreach ($ug in $usrGenNorm) {
        if ($dn -eq $ug -or $dn.EndsWith('.' + $ug)) {
            $overridden = $true
            break
        }
    }
    if (-not $overridden) { $effLines.Add($d) }
}
if ($sysExRaw.Count -gt 0) { [System.IO.File]::WriteAllLines($effExPath, $effLines, $utf8NoBom) }

# 2. Prune list-auto.txt: remove any domain covered by effective system excludes or user excludes
if (Test-Path -LiteralPath $autoPath) {
    $autoRaw = Read-Z2Domains $autoPath
    if ($autoRaw.Count -gt 0) {
        $usrExRaw = Read-Z2Domains $usrExPath
        $allExNorm = @(($effLines.ToArray() + @($usrExRaw)) | ForEach-Object { Normalize-Z2Domain $_ } | Where-Object { $_ } | Select-Object -Unique)
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
