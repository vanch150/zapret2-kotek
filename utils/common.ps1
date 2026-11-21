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
    return '1.0.9'
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
        if ($curMode -ne 'loaded') {
            if (Test-Path -LiteralPath $bakFile) {
                Copy-Item -LiteralPath $bakFile -Destination $ipFile -Force -ErrorAction SilentlyContinue
            } else {
                return $false
            }
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

function Register-Z2TrayStartupTask([string]$Root) {
    try {
        $rootClean = $Root.Trim('"', "'").TrimEnd('\', '/') + '\'
        $guiScript = Join-Path $rootClean 'utils\gui_app.ps1'
        if (-not (Test-Path -LiteralPath $guiScript)) { return $false }
        $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $rootNoSlash = $rootClean.TrimEnd('\')
        $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$guiScript`" -Root `"$rootNoSlash`" -StartInTray"

        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        $td = $sched.NewTask(0)
        $td.RegistrationInfo.Description = 'Zapret2 Kotek — тихий запуск иконки в трее при входе в Windows (без UAC)'
        $td.RegistrationInfo.Author = 'Zapret2 Kotek'
        $td.Principal.LogonType = 3
        $td.Principal.RunLevel  = 1
        $td.Settings.Enabled = $true
        $td.Settings.Hidden  = $false
        $td.Settings.DisallowStartIfOnBatteries = $false
        $td.Settings.StopIfGoingOnBatteries     = $false
        $td.Settings.ExecutionTimeLimit         = 'PT0S'
        $td.Settings.MultipleInstances          = 2
        $td.Settings.AllowDemandStart           = $true

        $trig = $td.Triggers.Create(9)
        $trig.Enabled = $true
        $trig.Delay   = 'PT5S'

        $act = $td.Actions.Create(0)
        $act.Path             = $psExe
        $act.Arguments        = $taskArgs
        $act.WorkingDirectory = $rootClean.TrimEnd('\')

        $folder.RegisterTaskDefinition('Zapret2KotekTray', $td, 6, $null, $null, 3, $null) | Out-Null
        return $true
    } catch { return $false }
}

function Unregister-Z2TrayStartupTask {
    try {
        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        $folder.DeleteTask('Zapret2KotekTray', 0)
    } catch {}
    try { & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN 'Zapret2KotekTray' /F >$null 2>&1 } catch {}
}
function Test-Z2IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Stop-Z2ServiceAndProcess {
    param(
        [string]$ServiceName = 'zapret',
        [int]$ServiceTimeoutSec = 5,
        [int]$ProcessTimeoutMs = 3000
    )
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        try {
            if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                try {
                    if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                        $svc.Stop()
                    }
                } catch {}
                try {
                    $svc.WaitForStatus(
                        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                        [TimeSpan]::FromSeconds($ServiceTimeoutSec)
                    )
                } catch {}
            }
        } finally {
            try { $svc.Dispose() } catch {}
        }
    }
    foreach ($pn in @('winws2', 'winws')) {
        $procs = @(Get-Process -Name $pn -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            try {
                if (-not $p.HasExited) {
                    $p.Kill()
                    [void]$p.WaitForExit($ProcessTimeoutMs)
                }
            } catch {}
        }
    }
}
function Get-Z2Targets {
    param(
        [string]$Root = '',
        [ValidateSet('CORE', 'ALL')]
        [string]$Mode = 'CORE'
    )
    $list = New-Object System.Collections.Generic.List[object]
    $tFile = Join-Path (Resolve-Z2Root $Root) 'utils\targets.txt'
    if (Test-Path -LiteralPath $tFile) {
        foreach ($tl in (Get-Content -LiteralPath $tFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $tt = $tl.Trim()
            if (-not $tt -or $tt.StartsWith('#')) { continue }
            $tp = $tt -split '\|'
            if ($tp.Count -ge 3) {
                $cat  = $tp[0].Trim().ToUpperInvariant()
                $tmod = $tp[1].Trim().ToUpperInvariant()
                $url  = $tp[2].Trim()
                if ($url -and ($Mode -eq 'ALL' -or $tmod -eq 'CORE')) {
                    $list.Add([PSCustomObject]@{ Cat = $cat; Mode = $tmod; Url = $url })
                }
            }
        }
    }
    if ($list.Count -eq 0) {
        $fallback = @(
            @{ Cat='YT';  Mode='CORE'; Url='https://www.youtube.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://i.ytimg.com/favicon.ico' },
            @{ Cat='YT';  Mode='CORE'; Url='https://yt3.ggpht.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://jnn-pa.googleapis.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://redirector.googlevideo.com' },
            @{ Cat='YT';  Mode='EXT';  Url='https://m.youtube.com' },
            @{ Cat='YT';  Mode='EXT';  Url='https://play.google.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.com/api/v10/gateway' },
            @{ Cat='DC';  Mode='CORE'; Url='https://cdn.discordapp.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.gg' },
            @{ Cat='DC';  Mode='EXT';  Url='https://media.discordapp.net' },
            @{ Cat='DC';  Mode='EXT';  Url='https://status.discord.com' },
            @{ Cat='TG';  Mode='EXT';  Url='https://web.telegram.org' },
            @{ Cat='TG';  Mode='EXT';  Url='https://t.me' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://cloudflare-dns.com' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://one.one.one.one' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://speed.cloudflare.com/__down?bytes=65536' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://7tv.io' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://cdn.7tv.app' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://betterttv.net' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://frankerfacez.com' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://raw.githubusercontent.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://github.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://soundcloud.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://rutracker.org' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://ntc.party' }
        )
        foreach ($fb in $fallback) {
            if ($Mode -eq 'ALL' -or $fb.Mode -eq 'CORE') {
                $list.Add([PSCustomObject]$fb)
            }
        }
    }
    return $list.ToArray()
}
