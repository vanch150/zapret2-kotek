# Zapret2 Kotek — Shared Utility Library (utils/common.ps1)

function Resolve-Z2Root([string]$Root = '') {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $env:Z2_ROOT }
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
    try { return ([System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\') } catch { return ($Root.Trim('"', "'", '\', '/') + '\') }
}

function Get-Z2Version([string]$Root) {
    $vf = Join-Path $Root 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = (Get-Content -LiteralPath $vf -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($v) { return $v.Trim() }
    }
    return '1.0.0'
}

function Get-Z2Repo([string]$Root) {
    $repo = 'vanch150/zapret2-kotek'
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc -ErrorAction SilentlyContinue)) {
            if ($l -match '^\s*repo\s*=\s*(.+)$') {
                $r = $matches[1].Trim()
                if ($r -and $r -notlike 'OWNER/*') { $repo = $r; break }
            }
        }
    }
    return $repo
}

function Get-Z2StrategyScores([string]$Root) {
    $map = @{}
    $sf = Join-Path $Root 'utils\strategy_scores.json'
    if (Test-Path -LiteralPath $sf) {
        try {
            $obj = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj) {
                foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
            }
        } catch {}
    }
    return $map
}

function Get-Z2Strategies([string]$Root, [string]$Group = 'core') {
    $skip = @('1_AUTO_SETUP.bat','2_KOTEK.bat','!_START_KOTEK.bat','KOTEK.bat','AUTO_SETUP.bat','PAUSE_RESUME.bat','UNINSTALL.bat','DEEP_OPTIMIZE.bat','service.bat')
    if ($Group -eq 'arch') {
        $archDir = Join-Path $Root 'configs_archive'
        if (Test-Path -LiteralPath $archDir) {
            return @(Get-ChildItem -LiteralPath $archDir -Filter '*.bat' -File | Sort-Object Name)
        }
        return @()
    }
    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @((Join-Path $Root 'strategies'), $Root)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Filter '*.bat' -File | Sort-Object Name | ForEach-Object {
            if ($skip -notcontains $_.Name -and $seen.Add($_.Name)) { $list.Add($_) }
        }
    }
    return @($list | Sort-Object Name)
}

function Get-Z2IpsetMode([string]$Root) {
    $ipFile = Join-Path $Root 'lists\ipset-all.txt'
    if (-not (Test-Path -LiteralPath $ipFile)) { return 'none' }
    $len = (Get-Item -LiteralPath $ipFile).Length
    if ($len -eq 0) { return 'any' }
    if ($len -lt 64) {
        $raw = (Get-Content -LiteralPath $ipFile -Raw -ErrorAction SilentlyContinue)
        if ($raw -and $raw.Trim() -eq '203.0.113.113/32') { return 'none' }
    }
    return 'loaded'
}

function Set-Z2IpsetMode([string]$Root, [string]$Mode) {
    $ipFile = Join-Path $Root 'lists\ipset-all.txt'
    $bakFile = Join-Path $Root 'lists\ipset-all.txt.backup'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $curMode = Get-Z2IpsetMode $Root
    if ($curMode -eq 'loaded' -and $Mode -ne 'loaded') {
        Copy-Item -LiteralPath $ipFile -Destination $bakFile -Force -ErrorAction SilentlyContinue
    }
    if ($Mode -eq 'none') {
        [System.IO.File]::WriteAllText($ipFile, "203.0.113.113/32`r`n", $utf8NoBom)
    } elseif ($Mode -eq 'any') {
        [System.IO.File]::WriteAllText($ipFile, '', $utf8NoBom)
    } elseif ($Mode -eq 'loaded') {
        if (Test-Path -LiteralPath $bakFile) {
            Copy-Item -LiteralPath $bakFile -Destination $ipFile -Force -ErrorAction SilentlyContinue
        } elseif ($curMode -ne 'loaded') {
            return $false
        }
    }
    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -eq 'Running') {
        Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Get-Z2AutoUpdateTask {
    try {
        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        $task = $folder.GetTask('Zapret2KotekAutoUpdate')
        if ($null -ne $task) { return $task }
    } catch {}
    try {
        return (Get-ScheduledTask -TaskName 'Zapret2KotekAutoUpdate' -ErrorAction SilentlyContinue)
    } catch { return $null }
}

function Set-Z2DesktopAndFolderIcons([string]$Root) {
    $icoPath = Join-Path $Root 'utils\kotek.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) { return }
    # 1. Create Desktop & Start Menu shortcuts "Zapret2 Kotek.lnk" pointing to 2_KOTEK.bat
    try {
        $targetBat = Join-Path $Root '!_START_KOTEK.bat'
        if (-not (Test-Path -LiteralPath $targetBat)) { $targetBat = Join-Path $Root 'utils\service.bat' }
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($lnkDir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            if ($lnkDir -and (Test-Path -LiteralPath $lnkDir)) {
                $lnkPath = Join-Path $lnkDir 'Zapret2 Kotek.lnk'
                $sc = $wsh.CreateShortcut($lnkPath)
                $sc.TargetPath = $targetBat
                $sc.WorkingDirectory = $Root.TrimEnd('\')
                $sc.IconLocation = "$icoPath,0"
                $sc.WindowStyle = 7
                $sc.Description = 'Zapret2 Kotek — обход DPI и Telegram Proxy'
                $sc.Save()
            }
        }
    } catch {}
    # 2. Apply kotek.ico to the Zapret2 folder via desktop.ini
    try {
        $rootClean = $Root.TrimEnd('\')
        $iniPath = Join-Path $rootClean 'desktop.ini'
        $iniText = "[.ShellClassInfo]`r`nIconResource=utils\kotek.ico,0`r`nInfoTip=Zapret2 Kotek`r`n"
        if (Test-Path -LiteralPath $iniPath) {
            & attrib.exe -h -s "$iniPath" 2>$null | Out-Null
        }
        [System.IO.File]::WriteAllText($iniPath, $iniText, (New-Object System.Text.UTF8Encoding($false)))
        & attrib.exe +h +s "$iniPath" 2>$null | Out-Null
        & attrib.exe +s "$rootClean" 2>$null | Out-Null
    } catch {}
}

function Register-Z2UninstallEntry([string]$Root) {
    try {
        $rootClean = $Root.TrimEnd('\')
        $uninstBat = Join-Path $rootClean 'utils\UNINSTALL.bat'
        if (-not (Test-Path -LiteralPath $uninstBat)) { return }
        $ver = Get-Z2Version $Root
        $ico = Join-Path $rootClean 'utils\kotek.ico'
        $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Zapret2Kotek'
        if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        $uninstCmd = "`"$env:SystemRoot\System32\cmd.exe`" /d /c `"`"$uninstBat`"`""
        New-ItemProperty -Path $regKey -Name 'DisplayName'     -Value 'Zapret2 Kotek' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'DisplayVersion'  -Value $ver -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'Publisher'       -Value 'vanch150' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'InstallLocation' -Value $rootClean -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'UninstallString' -Value $uninstCmd -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'URLInfoAbout'    -Value ('https://github.com/' + (Get-Z2Repo $Root)) -PropertyType String -Force | Out-Null
        if (Test-Path -LiteralPath $ico) {
            New-ItemProperty -Path $regKey -Name 'DisplayIcon' -Value "$ico,0" -PropertyType String -Force | Out-Null
        }
        New-ItemProperty -Path $regKey -Name 'NoModify'      -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'NoRepair'      -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'EstimatedSize' -Value 12288 -PropertyType DWord -Force | Out-Null
    } catch {}
}
