param(
    [string]$Action = 'menu',
    [string]$Root = '',
    [string]$BrowsersCsv = ''
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'
$script:Z2BrowserMarkerFile = Join-Path $Root 'utils\browser_policy.applied'
$script:Z2BrowserBackupFile = Join-Path $Root 'utils\browser_policy.backup.json'

$script:Z2BrowserCatalog = @(
    @{ Id = 'chrome';  Kind = 'chromium'; Name = 'Google Chrome';   Reg = 'HKLM:\SOFTWARE\Policies\Google\Chrome';       Exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") },
    @{ Id = 'edge';    Kind = 'chromium'; Name = 'Microsoft Edge';  Reg = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';      Exe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") },
    @{ Id = 'yandex';  Kind = 'chromium'; Name = 'Yandex Browser';  Reg = 'HKLM:\SOFTWARE\Policies\YandexBrowser';       Exe = @("$env:LOCALAPPDATA\Yandex\YandexBrowser\Application\browser.exe", "${env:ProgramFiles(x86)}\Yandex\YandexBrowser\Application\browser.exe") },
    @{ Id = 'brave';   Kind = 'chromium'; Name = 'Brave';           Reg = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Exe = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe") },
    @{ Id = 'vivaldi'; Kind = 'chromium'; Name = 'Vivaldi';         Reg = 'HKLM:\SOFTWARE\Policies\Vivaldi';             Exe = @("$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe", "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe") },
    @{ Id = 'firefox'; Kind = 'firefox';  Name = 'Mozilla Firefox'; Reg = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox';     Exe = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe", "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe") },
    @{ Id = 'opera';   Kind = 'manual';   Name = 'Opera / Opera GX'; Reg = ''; ManualTip = 'opera://flags/#enable-quic'; Exe = @("$env:LOCALAPPDATA\Programs\Opera\opera.exe", "$env:LOCALAPPDATA\Programs\Opera GX\opera.exe", "$env:ProgramFiles\Opera\opera.exe", "$env:ProgramFiles\Opera GX\opera.exe") }
)

function Get-Z2ObjProp($Obj, [string]$PropName) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$PropName]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Get-Z2RegValueSnapshot([string]$RegPath, [string]$Name) {
    $entry = [ordered]@{ Exists = $false; Value = $null; Kind = '' }
    try {
        if ($RegPath -and (Test-Path -LiteralPath $RegPath)) {
            $rk = Get-Item -LiteralPath $RegPath -ErrorAction Stop
            try {
                $val = $rk.GetValue($Name, $null)
                if ($null -ne $val) {
                    $entry.Exists = $true
                    $entry.Value = $val
                    $entry.Kind = [string]$rk.GetValueKind($Name)
                }
            } finally {
                if ($null -ne $rk) { $rk.Close() }
            }
        }
    } catch {}
    return $entry
}

$script:Z2LastRegOpFailed = $false

function Restore-Z2RegValue([string]$RegPath, [string]$Name, $Snap) {
    $script:Z2LastRegOpFailed = $false
    if (-not $RegPath) { return $false }
    $snapExists = $false
    if ($null -ne $Snap) {
        $snapExists = [bool](Get-Z2ObjProp $Snap 'Exists')
    }
    if ($snapExists) {
        try {
            if (-not (Test-Path -LiteralPath $RegPath)) {
                New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
            }
            $kindStr = [string](Get-Z2ObjProp $Snap 'Kind')
            $pType = 'String'
            switch ($kindStr) {
                'DWord'        { $pType = 'DWord' }
                'QWord'        { $pType = 'QWord' }
                'ExpandString' { $pType = 'ExpandString' }
                'MultiString'  { $pType = 'MultiString' }
                'Binary'       { $pType = 'Binary' }
                default        { $pType = 'String' }
            }
            $origVal = Get-Z2ObjProp $Snap 'Value'
            if ($pType -eq 'DWord') { $origVal = [int]$origVal }
            elseif ($pType -eq 'QWord') { $origVal = [long]$origVal }
            New-ItemProperty -Path $RegPath -Name $Name -Value $origVal -PropertyType $pType -Force -ErrorAction Stop | Out-Null
            return $true
        } catch {
            $script:Z2LastRegOpFailed = $true
            return $false
        }
    } else {
        try {
            if ((Test-Path -LiteralPath $RegPath) -and ($null -ne (Get-ItemProperty -Path $RegPath -Name $Name -ErrorAction SilentlyContinue))) {
                Remove-ItemProperty -Path $RegPath -Name $Name -Force -ErrorAction Stop
                return $true
            }
        } catch {
            $script:Z2LastRegOpFailed = $true
        }
        return $false
    }
}

function Save-Z2BrowserPolicyBackup([string]$RootPath) {
    $backupPath = Join-Path $RootPath 'utils\browser_policy.backup.json'
    $browsersMap = [ordered]@{}
    $existingExists = Test-Path -LiteralPath $backupPath
    $savedAt = (Get-Date -Format 'o')
    if ($existingExists) {
        $existingObj = Load-Z2BrowserPolicyBackup $RootPath
        if ($null -ne $existingObj) {
            $origSavedAt = Get-Z2ObjProp $existingObj 'SavedAt'
            if (-not [string]::IsNullOrWhiteSpace([string]$origSavedAt)) { $savedAt = [string]$origSavedAt }
            $existingBrowsers = Get-Z2ObjProp $existingObj 'Browsers'
            if ($null -ne $existingBrowsers) {
                foreach ($ep in $existingBrowsers.PSObject.Properties) {
                    $browsersMap[$ep.Name] = $ep.Value
                }
            }
        }
    }
    $addedAny = $false
    foreach ($b in $script:Z2BrowserCatalog) {
        if ($b.Kind -eq 'manual' -or -not $b.Reg) { continue }
        if ($browsersMap.Contains($b.Id)) { continue }
        if ($b.Kind -eq 'chromium') {
            $browsersMap[$b.Id] = [ordered]@{
                QuicAllowed           = Get-Z2RegValueSnapshot $b.Reg 'QuicAllowed'
                DnsOverHttpsMode      = Get-Z2RegValueSnapshot $b.Reg 'DnsOverHttpsMode'
                DnsOverHttpsTemplates = Get-Z2RegValueSnapshot $b.Reg 'DnsOverHttpsTemplates'
            }
            $addedAny = $true
        } elseif ($b.Kind -eq 'firefox') {
            $dohKey = Join-Path $b.Reg 'DNSOverHTTPS'
            $prefSnap = Get-Z2RegValueSnapshot $b.Reg 'Preferences'
            $hasHttp3 = $false
            $http3Val = $null
            if ($prefSnap.Exists -and -not [string]::IsNullOrWhiteSpace([string]$prefSnap.Value)) {
                try {
                    $curObj = ([string]$prefSnap.Value) | ConvertFrom-Json -ErrorAction Stop
                    $h3Prop = $curObj.PSObject.Properties['network.http.http3.enable']
                    if ($null -ne $h3Prop) {
                        $hasHttp3 = $true
                        $http3Val = $h3Prop.Value
                    }
                } catch {}
            }
            $browsersMap[$b.Id] = [ordered]@{
                DNSOverHTTPS = [ordered]@{
                    Enabled     = Get-Z2RegValueSnapshot $dohKey 'Enabled'
                    ProviderURL = Get-Z2RegValueSnapshot $dohKey 'ProviderURL'
                    Locked      = Get-Z2RegValueSnapshot $dohKey 'Locked'
                }
                Preferences = [ordered]@{
                    Exists     = $prefSnap.Exists
                    HasHttp3   = $hasHttp3
                    Http3Value = $http3Val
                }
            }
            $addedAny = $true
        }
    }
    if (-not $existingExists -or $addedAny) {
        $payload = [ordered]@{
            Version  = 1
            SavedAt  = $savedAt
            Browsers = $browsersMap
        }
        try {
            $json = $payload | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($backupPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
}

function Load-Z2BrowserPolicyBackup([string]$RootPath) {
    $backupPath = Join-Path $RootPath 'utils\browser_policy.backup.json'
    if (-not (Test-Path -LiteralPath $backupPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($backupPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Get-Z2BrowserStates {
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($b in $script:Z2BrowserCatalog) {
        $installed = $false
        foreach ($p in $b.Exe) {
            if ($p -and (Test-Path -LiteralPath $p)) { $installed = $true; break }
        }
        $hasPolicy = $false
        $quicOff = $false
        $dohOn = $false
        $statusText = 'по умолч.'

        if ($b.Kind -eq 'chromium' -and $b.Reg -and (Test-Path -LiteralPath $b.Reg)) {
            $props = Get-ItemProperty -Path $b.Reg -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                if ($null -ne $props.QuicAllowed -and [int]$props.QuicAllowed -eq 0) { $quicOff = $true; $hasPolicy = $true }
                $dohModeVal = ([string]$props.DnsOverHttpsMode).Trim().ToLowerInvariant()
                if ($dohModeVal -in @('automatic', 'secure')) { $dohOn = $true; $hasPolicy = $true }
            }
        } elseif ($b.Kind -eq 'firefox' -and $b.Reg -and (Test-Path -LiteralPath $b.Reg)) {
            $props = Get-ItemProperty -Path $b.Reg -ErrorAction SilentlyContinue
            if ($null -ne $props -and -not [string]::IsNullOrWhiteSpace([string]$props.Preferences)) {
                try {
                    $ffJson = ([string]$props.Preferences) | ConvertFrom-Json -ErrorAction Stop
                    $h3Prop = $ffJson.PSObject.Properties['network.http.http3.enable']
                    if ($null -ne $h3Prop -and $null -ne $h3Prop.Value -and ($h3Prop.Value.Value -eq $false)) {
                        $quicOff = $true; $hasPolicy = $true
                    }
                } catch {}
            }
            $dohKey = Join-Path $b.Reg 'DNSOverHTTPS'
            if (Test-Path -LiteralPath $dohKey) {
                $dp = Get-ItemProperty -Path $dohKey -ErrorAction SilentlyContinue
                if ($null -ne $dp -and $null -ne $dp.Enabled -and [int]$dp.Enabled -eq 1) { $dohOn = $true; $hasPolicy = $true }
            }
        }

        if ($installed -or $hasPolicy) {
            if ($b.Kind -eq 'manual') {
                $statusText = "вручную ($($b.ManualTip))"
            } else {
                $qS = if ($quicOff) { 'QUIC выкл' } else { 'QUIC по умолч.' }
                $statusText = if ($dohOn) { "$qS · DoH вкл (устар.)" } else { $qS }
            }
            $res.Add([PSCustomObject]@{
                Id         = $b.Id
                Kind       = $b.Kind
                Name       = $b.Name
                Reg        = $b.Reg
                ManualTip  = if ($b.ContainsKey('ManualTip')) { $b.ManualTip } else { '' }
                Applied    = ($quicOff -or $dohOn)
                QuicOff    = $quicOff
                DohOn      = $dohOn
                StatusText = $statusText
            })
        }
    }
    return $res
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
    $det = Get-Z2BrowserStates
    if ($det.Count -eq 0) {
        Write-Host '  Браузеры                : не обнаружены' -ForegroundColor Gray
        return
    }
    foreach ($b in $det) {
        Write-Host ("  - {0,-16} : {1}" -f $b.Name, $b.StatusText) -ForegroundColor Gray
    }
}

function Update-Z2BrowserMarker([string]$RootPath) {
    $marker = Join-Path $RootPath 'utils\browser_policy.applied'
    $active = @(Get-Z2BrowserStates | Where-Object { $_.Applied } | ForEach-Object { $_.Name })
    if ($active.Count -gt 0) {
        [System.IO.File]::WriteAllText($marker, ($active -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        try {
            if (-not (Test-Path 'HKLM:\SOFTWARE\Zapret2')) { New-Item -Path 'HKLM:\SOFTWARE\Zapret2' -Force | Out-Null }
            New-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        } catch {}
    } else {
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
        try { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Enable-BrowserFix([string[]]$FilterIds = @(), [string]$RootPath = '', [bool]$SetQuic = $true, [bool]$SetDoh = $false) {
    if (-not $SetQuic -and -not $SetDoh) { return @() }
    if (-not $RootPath) { $RootPath = $Root }
    $det = Get-Z2BrowserStates
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($b in $det) {
        if ($b.Kind -eq 'manual') { continue }
        if ($FilterIds.Count -gt 0 -and ($FilterIds -notcontains $b.Id)) { continue }
        $targets.Add($b)
    }
    if ($targets.Count -eq 0) {
        Write-Host '  [ИНФО] Подходящие браузеры для автоматической настройки не найдены.' -ForegroundColor Yellow
        return @()
    }
    Save-Z2BrowserPolicyBackup $RootPath
    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($b in $targets) {
        try {
            if ($b.Kind -eq 'chromium') {
                if (-not (Test-Path -LiteralPath $b.Reg)) { New-Item -Path $b.Reg -Force -ErrorAction Stop | Out-Null }
                if ($SetQuic) {
                    New-ItemProperty -Path $b.Reg -Name 'QuicAllowed' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                }
                if ($SetDoh) {
                    New-ItemProperty -Path $b.Reg -Name 'DnsOverHttpsMode' -Value 'automatic' -PropertyType String -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -Path $b.Reg -Name 'DnsOverHttpsTemplates' -Value 'https://dns.google/dns-query{?dns} https://cloudflare-dns.com/dns-query' -PropertyType String -Force -ErrorAction Stop | Out-Null
                }
                $applied.Add($b.Name)
            } elseif ($b.Kind -eq 'firefox') {
                if (-not (Test-Path -LiteralPath $b.Reg)) { New-Item -Path $b.Reg -Force -ErrorAction Stop | Out-Null }
                $ffApplied = $false
                if ($SetDoh) {
                    $dohKey = Join-Path $b.Reg 'DNSOverHTTPS'
                    if (-not (Test-Path -LiteralPath $dohKey)) { New-Item -Path $dohKey -Force -ErrorAction Stop | Out-Null }
                    New-ItemProperty -Path $dohKey -Name 'Enabled' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -Path $dohKey -Name 'ProviderURL' -Value 'https://dns.google/dns-query' -PropertyType String -Force -ErrorAction Stop | Out-Null
                    New-ItemProperty -Path $dohKey -Name 'Locked' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    $ffApplied = $true
                }
                if ($SetQuic) {
                    $prefMap = @{}
                    $jsonBroken = $false
                    $curPrefRaw = (Get-ItemProperty -Path $b.Reg -Name 'Preferences' -ErrorAction SilentlyContinue).Preferences
                    if (-not [string]::IsNullOrWhiteSpace([string]$curPrefRaw)) {
                        try {
                            $curObj = ([string]$curPrefRaw) | ConvertFrom-Json -ErrorAction Stop
                            if ($null -eq $curObj) {
                                $jsonBroken = $true
                            } else {
                                foreach ($p in $curObj.PSObject.Properties) { $prefMap[$p.Name] = $p.Value }
                            }
                        } catch {
                            $jsonBroken = $true
                        }
                    }
                    if ($jsonBroken) {
                        Write-Host '  [!] Firefox Preferences содержит повреждённый JSON — запись пропущена, чтобы не затереть настройки.' -ForegroundColor Yellow
                    } else {
                        $prefMap['network.http.http3.enable'] = [PSCustomObject]@{ Value = $false; Status = 'default' }
                        $prefJson = ($prefMap | ConvertTo-Json -Depth 10 -Compress)
                        New-ItemProperty -Path $b.Reg -Name 'Preferences' -Value $prefJson -PropertyType String -Force -ErrorAction Stop | Out-Null
                        $ffApplied = $true
                    }
                }
                if ($ffApplied) { $applied.Add($b.Name) }
            }
        } catch {}
    }
    Update-Z2BrowserMarker $RootPath
    if ($applied.Count -gt 0) {
        Write-Host ("  [OK] Применено для: {0}" -f ($applied -join ', ')) -ForegroundColor Green
        Write-Host '       Перезапустите браузер, чтобы отключение QUIC и DoH вступили в силу.' -ForegroundColor Cyan
    }
    return $applied.ToArray()
}

function Disable-BrowserFix([bool]$Quiet = $false, [string[]]$FilterIds = @(), [string]$RootPath = '', [bool]$ClearQuic = $true, [bool]$ClearDoh = $true) {
    if (-not $RootPath) { $RootPath = $Root }
    $backupObj = Load-Z2BrowserPolicyBackup $RootPath
    $backupBrowsers = Get-Z2ObjProp $backupObj 'Browsers'
    $removed = 0
    $failedOps = 0
    foreach ($b in $script:Z2BrowserCatalog) {
        if ($b.Kind -eq 'manual' -or -not $b.Reg) { continue }
        if ($FilterIds.Count -gt 0 -and ($FilterIds -notcontains $b.Id)) { continue }
        $bSnap = Get-Z2ObjProp $backupBrowsers $b.Id
        if ((Test-Path -LiteralPath $b.Reg) -or ($null -ne $bSnap)) {
            if ($b.Kind -eq 'chromium') {
                $propsToRestore = New-Object System.Collections.Generic.List[string]
                if ($ClearQuic) { $propsToRestore.Add('QuicAllowed') }
                if ($ClearDoh)  { $propsToRestore.Add('DnsOverHttpsMode'); $propsToRestore.Add('DnsOverHttpsTemplates') }
                foreach ($prop in $propsToRestore) {
                    $pSnap = Get-Z2ObjProp $bSnap $prop
                    if (Restore-Z2RegValue $b.Reg $prop $pSnap) {
                        $removed++
                    } elseif ($script:Z2LastRegOpFailed) {
                        $failedOps++
                    }
                }
            } elseif ($b.Kind -eq 'firefox') {
                if ($ClearDoh) {
                    $dohKey = Join-Path $b.Reg 'DNSOverHTTPS'
                    $dohSnap = Get-Z2ObjProp $bSnap 'DNSOverHTTPS'
                    if ((Test-Path -LiteralPath $dohKey) -or ($null -ne $dohSnap)) {
                        foreach ($dkProp in @('Enabled', 'ProviderURL', 'Locked')) {
                            $dkSnap = Get-Z2ObjProp $dohSnap $dkProp
                            if (Restore-Z2RegValue $dohKey $dkProp $dkSnap) {
                                $removed++
                            } elseif ($script:Z2LastRegOpFailed) {
                                $failedOps++
                            }
                        }
                        if (Test-Path -LiteralPath $dohKey) {
                            try {
                                $rk = Get-Item -LiteralPath $dohKey -ErrorAction Stop
                                $remVals = $rk.ValueCount
                                $remSubs = $rk.SubKeyCount
                                $rk.Close()
                                if ($remVals -eq 0 -and $remSubs -eq 0) {
                                    Remove-Item -LiteralPath $dohKey -Force -ErrorAction SilentlyContinue
                                }
                            } catch {}
                        }
                    }
                }
                if ($ClearQuic) {
                    try {
                        $prefSnap = Get-Z2ObjProp $bSnap 'Preferences'
                        $curPrefRaw = $null
                        if (Test-Path -LiteralPath $b.Reg) {
                            $curPrefRaw = (Get-ItemProperty -Path $b.Reg -Name 'Preferences' -ErrorAction SilentlyContinue).Preferences
                        }
                        $prefMap = @{}
                        $jsonBroken = $false
                        if (-not [string]::IsNullOrWhiteSpace([string]$curPrefRaw)) {
                            try {
                                $curObj = ([string]$curPrefRaw) | ConvertFrom-Json -ErrorAction Stop
                                if ($null -eq $curObj) {
                                    $jsonBroken = $true
                                } else {
                                    foreach ($p in $curObj.PSObject.Properties) { $prefMap[$p.Name] = $p.Value }
                                }
                            } catch {
                                $jsonBroken = $true
                            }
                        }
                        if ($jsonBroken) {
                            $failedOps++
                            if (-not $Quiet) {
                                Write-Host '  [!] Firefox Preferences содержит повреждённый JSON — откат Preferences пропущен.' -ForegroundColor Yellow
                            }
                        } else {
                            $hadOrigHttp3 = [bool](Get-Z2ObjProp $prefSnap 'HasHttp3')
                            if ($hadOrigHttp3) {
                                if (-not (Test-Path -LiteralPath $b.Reg)) { New-Item -Path $b.Reg -Force -ErrorAction Stop | Out-Null }
                                $prefMap['network.http.http3.enable'] = Get-Z2ObjProp $prefSnap 'Http3Value'
                                New-ItemProperty -Path $b.Reg -Name 'Preferences' -Value ($prefMap | ConvertTo-Json -Depth 10 -Compress) -PropertyType String -Force -ErrorAction Stop | Out-Null
                                $removed++
                            } elseif ($prefMap.ContainsKey('network.http.http3.enable')) {
                                $prefMap.Remove('network.http.http3.enable')
                                if ($prefMap.Count -gt 0) {
                                    New-ItemProperty -Path $b.Reg -Name 'Preferences' -Value ($prefMap | ConvertTo-Json -Depth 10 -Compress) -PropertyType String -Force -ErrorAction Stop | Out-Null
                                } else {
                                    Remove-ItemProperty -Path $b.Reg -Name 'Preferences' -Force -ErrorAction Stop
                                }
                                $removed++
                            }
                        }
                    } catch {
                        $failedOps++
                    }
                }
            }
        }
    }
    if ($FilterIds.Count -eq 0 -and $ClearQuic -and $ClearDoh -and $failedOps -eq 0) {
        $backupPath = Join-Path $RootPath 'utils\browser_policy.backup.json'
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    Update-Z2BrowserMarker $RootPath
    if (-not $Quiet) {
        if ($removed -gt 0) {
            Write-Host '  [OK] Политики QUIC/DoH восстановлены к исходному состоянию. Перезапустите браузер.' -ForegroundColor Green
        } else {
            Write-Host '  [ИНФО] Политики Zapret2 в выбранных браузерах не найдены.' -ForegroundColor Gray
        }
    }
    return $removed
}

if ($MyInvocation.InvocationName -ne '.') {
    $idFilter = @()
    if (-not [string]::IsNullOrWhiteSpace($BrowsersCsv)) {
        $idFilter = @($BrowsersCsv -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    if ($Action -eq 'enable') {
        [void](Enable-BrowserFix $idFilter $Root)
        exit 0
    }
    if ($Action -eq 'revert') {
        [void](Disable-BrowserFix $false $idFilter $Root)
        exit 0
    }
    if ($Action -eq 'revert-quiet') {
        [void](Disable-BrowserFix $true $idFilter $Root)
        exit 0
    }
    if ($Action -eq 'status') {
        Show-BrowserStatus
        exit 0
    }
    if ($Action -eq 'prompt') {
        Write-Host ''
        Write-Host '  [?] Применить фикс браузеров (отключить QUIC)?' -ForegroundColor Yellow
        Show-BrowserStatus
        $ans = Read-Host '      Применить для обнаруженных браузеров? [y/N]'
        if ($ans -match '^[yYдД]') { [void](Enable-BrowserFix @() $Root) }
        exit 0
    }
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host '          НАСТРОЙКА БРАУЗЕРОВ (QUIC) — ZAPRET2 KOTEK          ' -ForegroundColor Cyan
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Show-BrowserStatus
        Write-Host '  --------------------------------------------------------------'
        Write-Host '  [1] Применить фикс (отключить QUIC) для всех найденных' -ForegroundColor Green
        Write-Host '  [2] Вернуть стандартные настройки браузеров' -ForegroundColor Yellow
        Write-Host '  [0] Назад'
        Write-Host '  --------------------------------------------------------------'
        $ch = Read-Host '  Выберите пункт (0-2)'
        if ($ch -eq '0' -or $ch -eq '') { exit 0 }
        elseif ($ch -eq '1') { [void](Enable-BrowserFix @() $Root); Read-Host '  Enter для продолжения...' | Out-Null }
        elseif ($ch -eq '2') { [void](Disable-BrowserFix $false @() $Root); Read-Host '  Enter для продолжения...' | Out-Null }
    }
}
