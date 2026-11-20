param(
    [string]$Action = 'menu',
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'
$MarkerFile = Join-Path $Root 'utils\browser_policy.applied'

$Browsers = @(
    @{ Name = 'Google Chrome';  Reg = 'HKLM:\SOFTWARE\Policies\Google\Chrome';       Exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") },
    @{ Name = 'Microsoft Edge'; Reg = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';      Exe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") },
    @{ Name = 'Yandex Browser'; Reg = 'HKLM:\SOFTWARE\Policies\YandexBrowser';       Exe = @("$env:LOCALAPPDATA\Yandex\YandexBrowser\Application\browser.exe", "${env:ProgramFiles(x86)}\Yandex\YandexBrowser\Application\browser.exe") },
    @{ Name = 'Brave';          Reg = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Exe = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe") }
)

function Get-DetectedBrowsers {
    $found = @()
    foreach ($b in $Browsers) {
        $installed = $false
        foreach ($p in $b.Exe) {
            if ($p -and (Test-Path -LiteralPath $p)) { $installed = $true; break }
        }
        if ($installed -or (Test-Path -LiteralPath $b.Reg)) {
            $found += $b
        }
    }
    return $found
}

function Get-SystemDohEnabled {
    try {
        $cnt = (Get-ChildItem -Recurse -Path 'HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DohFlags -gt 0 } | Measure-Object).Count
        return ($cnt -gt 0)
    } catch { return $false }
}

function Show-BrowserStatus {
    $sysDoh = Get-SystemDohEnabled
    Write-Host ("  Системный DoH (Windows) : {0}" -f $(if ($sysDoh) { 'ВКЛ' } else { 'ВЫКЛ / не настроен' })) -ForegroundColor $(if ($sysDoh) { 'Green' } else { 'Yellow' })
    $det = Get-DetectedBrowsers
    if ($det.Count -eq 0) {
        Write-Host '  Браузеры Chromium       : не обнаружены' -ForegroundColor Gray
        return
    }
    foreach ($b in $det) {
        $qVal = $null; $dVal = $null
        if (Test-Path -LiteralPath $b.Reg) {
            $props = Get-ItemProperty -Path $b.Reg -ErrorAction SilentlyContinue
            $qVal = $props.QuicAllowed
            $dVal = $props.DnsOverHttpsMode
        }
        $qStr = if ($qVal -eq 0) { 'QUIC:ВЫКЛ' } else { 'QUIC:по умолч.' }
        $dStr = if ($dVal) { "DoH:$dVal" } else { 'DoH:по умолч.' }
        Write-Host ("  - {0,-16} : {1}, {2}" -f $b.Name, $qStr, $dStr) -ForegroundColor Gray
    }
}

function Enable-BrowserFix {
    $det = Get-DetectedBrowsers
    if ($det.Count -eq 0) {
        Write-Host '  [ИНФО] Поддерживаемые Chromium-браузеры (Chrome/Edge/Яндекс/Brave) не найдены.' -ForegroundColor Yellow
        return
    }
    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($b in $det) {
        try {
            if (-not (Test-Path -LiteralPath $b.Reg)) {
                New-Item -Path $b.Reg -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -Path $b.Reg -Name 'QuicAllowed' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $b.Reg -Name 'DnsOverHttpsMode' -Value 'automatic' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $b.Reg -Name 'DnsOverHttpsTemplates' -Value 'https://dns.google/dns-query{?dns} https://cloudflare-dns.com/dns-query' -PropertyType String -Force | Out-Null
            $applied.Add($b.Name)
        } catch {}
    }
    if ($applied.Count -gt 0) {
        [System.IO.File]::WriteAllText($MarkerFile, ($applied -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        try { if (-not (Test-Path 'HKLM:\SOFTWARE\Zapret2')) { New-Item -Path 'HKLM:\SOFTWARE\Zapret2' -Force | Out-Null }; New-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null } catch {}
        Write-Host ("  [OK] Применено для: {0}" -f ($applied -join ', ')) -ForegroundColor Green
        Write-Host '       Перезапустите браузер, чтобы отключение QUIC и DoH вступили в силу.' -ForegroundColor Cyan
    }
}

function Disable-BrowserFix([bool]$Quiet = $false) {
    $removed = 0
    foreach ($b in $Browsers) {
        if (Test-Path -LiteralPath $b.Reg) {
            foreach ($prop in @('QuicAllowed', 'DnsOverHttpsMode', 'DnsOverHttpsTemplates')) {
                try {
                    if ($null -ne (Get-ItemProperty -Path $b.Reg -Name $prop -ErrorAction SilentlyContinue)) {
                        Remove-ItemProperty -Path $b.Reg -Name $prop -Force -ErrorAction SilentlyContinue
                        $removed++
                    }
                } catch {}
            }
        }
    }
    if (Test-Path -LiteralPath $MarkerFile) {
        Remove-Item -LiteralPath $MarkerFile -Force -ErrorAction SilentlyContinue
    }
    try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -Force -ErrorAction SilentlyContinue } catch {}
    if (-not $Quiet) {
        if ($removed -gt 0) {
            Write-Host '  [OK] Политики QUIC/DoH удалены. Перезапустите браузер для возврата к стандарту.' -ForegroundColor Green
        } else {
            Write-Host '  [ИНФО] Политики Zapret2 в браузерах не найдены.' -ForegroundColor Gray
        }
    }
}

if ($Action -eq 'enable') {
    Enable-BrowserFix
    exit 0
}
if ($Action -eq 'revert') {
    Disable-BrowserFix $true
    exit 0
}

if ($Action -eq 'prompt') {
    Write-Host ''
    Write-Host '  [СОВЕТ] Контрольный тест YouTube не прошёл — частая причина: QUIC (HTTP/3) или DNS в браузере.' -ForegroundColor Yellow
    Show-BrowserStatus
    Write-Host '  Примечание: после применения Chrome/Edge покажет в меню безобидную надпись' -ForegroundColor DarkGray
    Write-Host '  «Управляется вашей организацией» (полностью откатывается через UNINSTALL.bat).' -ForegroundColor DarkGray
    $ans = Read-Host '  Отключить QUIC и включить DoH для найденных браузеров? [y/N]'
    if ($ans -match '^[yYдД]') {
        Enable-BrowserFix
    }
    exit 0
}

# Interactive menu (service.bat -> 4 -> 4)
while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '             ФИКС БРАУЗЕРА: ОТКЛЮЧЕНИЕ QUIC И DoH               ' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Show-BrowserStatus
    Write-Host '  --------------------------------------------------------------'
    Write-Host '  Примечание: политики реестра добавляют в меню Chrome/Edge' -ForegroundColor DarkGray
    Write-Host '  безобидную надпись «Управляется вашей организацией».' -ForegroundColor DarkGray
    Write-Host '  --------------------------------------------------------------'
    Write-Host '  [1] Применить фикс (отключить QUIC + включить DoH)' -ForegroundColor Green
    Write-Host '  [2] Откатить политики браузера (вернуть по умолчанию)' -ForegroundColor Yellow
    Write-Host '  [0] Назад'
    Write-Host '  --------------------------------------------------------------'
    $ch = Read-Host '  Выберите пункт (0-2)'
    if ($ch -eq '0' -or $ch -eq '') { break }
    elseif ($ch -eq '1') {
        Enable-BrowserFix
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '2') {
        Disable-BrowserFix $false
        Read-Host "`n  Нажмите Enter для продолжения"
    }
}
