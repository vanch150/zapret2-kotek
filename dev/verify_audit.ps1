#Requires -Version 5.1
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$fail = 0
function Pass($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }

$ps1Files = Get-ChildItem -Path $Root -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' }
$parseErrors = 0
foreach ($f in $ps1Files) {
    $tokens = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $parseErrors++
        foreach ($e in $errs) { Fail "PS5.1 syntax: $($f.Name):$($e.Extent.StartLineNumber) — $($e.Message)" }
    }
}
if ($parseErrors -eq 0) { Pass "PS 5.1 AST синтаксис: $($ps1Files.Count) файлов без ошибок" }

$bomErrs = 0
foreach ($f in $ps1Files) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
        $bomErrs++; Fail "Отсутствует UTF-8 BOM в $($f.FullName)"
    }
}
$noBomFiles = Get-ChildItem -Path $Root -Include '*.bat','*.conf','*.json' -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($f in $noBomFiles) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        $bomErrs++; Fail "Лишний UTF-8 BOM в $($f.FullName)"
    }
}
if ($bomErrs -eq 0) { Pass "Кодировки и BOM проверены" }

$tabPathErrs = 0
foreach ($f in $ps1Files) {
    $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "['`"](utils|lists|bin|strategies|configs_archive|dev)`t") {
            $tabPathErrs++; Fail "Буквальный символ TAB в пути: $($f.Name):$($i + 1)"
        }
    }
}
if ($tabPathErrs -eq 0) { Pass "Символы табуляции внутри путей отсутствуют" }

$csPath = Join-Path $Root 'utils\TgWsProxyService.cs'
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if ((Test-Path $csPath) -and (Test-Path $csc)) {
    $tmpExe = Join-Path $env:TEMP "z2_verify_tgws_$PID.exe"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $out = & $csc /nologo /target:exe /optimize+ /warn:4 "/out:$tmpExe" /reference:System.dll,System.Core.dll,System.ServiceProcess.dll $csPath 2>&1
    $ErrorActionPreference = $prevEap
    if ($LASTEXITCODE -eq 0) { Pass "Компиляция TgWsProxyService.cs: 0 ошибок" }
    else { Fail "Ошибка компиляции TgWsProxyService.cs:`n$($out -join "`n")" }
    if (Test-Path $tmpExe) { Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue }
}

$xamlPath = Join-Path $Root 'utils\gui_layout.xaml'
$guiPath  = Join-Path $Root 'utils\gui_app.ps1'
if ((Test-Path $xamlPath) -and (Test-Path $guiPath)) {
    $xamlTxt = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $guiTxt  = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
    $xNames  = [regex]::Matches($xamlTxt, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $fNames  = [regex]::Matches($guiTxt, "FindName\(['`"]([^'`"]+)['`"]\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $missing = @($fNames | Where-Object { $xNames -notcontains $_ })
    if ($missing.Count -eq 0) { Pass "XAML <-> FindName: все $($fNames.Count) ссылок валидны" }
    else { Fail "Битые FindName в gui_app.ps1: $($missing -join ', ')" }
}

$listGen = Join-Path $Root 'lists\list-general.txt'
if (Test-Path $listGen) {
    $lg = Get-Content -LiteralPath $listGen -Raw -Encoding UTF8
    if ($lg -match 'exitlag\.com' -and $lg -match 'exitlag\.io') { Pass "Инвариант: exitlag.com/io на месте" }
    else { Fail "Потеряны exitlag.com / exitlag.io в lists\list-general.txt" }
}

$aiPool = Join-Path $Root 'lists\ai-dns-pool.txt'
if (Test-Path $aiPool) {
    $badPool = 0
    foreach ($l in (Get-Content -LiteralPath $aiPool -Encoding UTF8)) {
        $t = $l.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
        $p = $t -split '\|', 2
        if ($p.Count -ne 2) { $badPool++; continue }
        foreach ($ipStr in ($p[1] -split ',')) {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($ipStr.Trim(), [ref]$parsed)) { $badPool++ }
        }
    }
    if ($badPool -eq 0) { Pass "Формат lists\ai-dns-pool.txt валиден" }
    else { Fail "Невалидные строки/IP в lists\ai-dns-pool.txt ($badPool)" }
}

$stratFiles = @(Get-ChildItem -Path (Join-Path $Root 'strategies'), (Join-Path $Root 'configs_archive') -Filter '*.bat' -ErrorAction SilentlyContinue)
$stratErrs = 0
foreach ($sf in $stratFiles) {
    $txt = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8
    if ($txt -match '--lua-desync=syndata' -and $txt -notmatch '--wf-tcp-empty=1') {
        $stratErrs++; Fail "Нет --wf-tcp-empty=1 при syndata в $($sf.Name)"
    }
    $idxCall = $txt.IndexOf('call "%ROOT%')
    $idxSet  = $txt.IndexOf('set "ROOT=')
    if ($idxCall -ge 0 -and $idxSet -ge 0 -and $idxCall -lt $idxSet) {
        $stratErrs++; Fail "%ROOT% используется до объявления в $($sf.Name)"
    }
}
if ($stratErrs -eq 0) { Pass "Базовая проверка $($stratFiles.Count) стратегий пройдена" }

if ($fail -gt 0) { Write-Host "`nИТОГ: $fail ошибок." -ForegroundColor Red; exit 1 }
Write-Host "`nИТОГ: все автоматические проверки пройдены." -ForegroundColor Green; exit 0
