param(
    [ValidateSet('enable', 'disable', 'status')]
    [string]$Action = 'status',
    [string]$Root = '',
    [ValidateSet('weekly', 'twiceweekly', 'monthly', 'onboot')]
    [string]$Mode = 'weekly'
)
$ErrorActionPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $env:Z2_ROOT }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$rawRoot = ([string]$Root).Trim().Trim('"')
if ($rawRoot -match '^[A-Za-z]:$') { $rawRoot = $rawRoot + '\' }
try {
    $Root = [System.IO.Path]::GetFullPath($rawRoot).TrimEnd('\', '/') + '\'
} catch {
    $Root = $rawRoot.TrimEnd('\', '/') + '\'
}

$_commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $_commonPath) {
    try { . $_commonPath } catch {}
}
if (-not (Get-Command Test-Z2IsAdmin -ErrorAction SilentlyContinue)) {
    function Test-Z2IsAdmin {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $pr = New-Object Security.Principal.WindowsPrincipal($id)
            return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { return $false }
    }
}

$TaskName   = 'Zapret2KotekAutoUpdate'
$ScriptPath = Join-Path $Root 'utils\self_update.ps1'
$ModeFile   = Join-Path $Root 'utils\autoupdate.mode'
$ValidModes = @('weekly', 'twiceweekly', 'monthly', 'onboot')
$PsExeFull  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$IcaclsExe  = "$env:SystemRoot\System32\icacls.exe"

function Test-AuTaskExists {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $t) { return $true }
    } catch {}
    try {
        $global:LASTEXITCODE = 0
        $null = & "$env:SystemRoot\System32\schtasks.exe" /Query /TN $TaskName 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    return $false
}

if ($Action -eq 'status') {
    if (Test-AuTaskExists) {
        $curM = 'weekly'
        if (Test-Path -LiteralPath $ModeFile) {
            $mv = (Get-Content -LiteralPath $ModeFile -TotalCount 1).Trim().ToLowerInvariant()
            if ($mv -in $ValidModes) { $curM = $mv }
        }
        Write-Output "ON:$curM"
        exit 0
    }
    Write-Output 'OFF'
    exit 1
}

if ($Action -eq 'disable') {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host "[X] Требуются права администратора для отключения задачи автообновления '$TaskName'." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-AuTaskExists)) {
        Write-Output 'DISABLED'
        exit 0
    }
    $delOk = $false
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        $delOk = $true
    } catch {}
    if (-not $delOk -or (Test-AuTaskExists)) {
        $global:LASTEXITCODE = 0
        & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN $TaskName /F >$null 2>&1
        if ($LASTEXITCODE -eq 0) { $delOk = $true }
    }
    if ($delOk -and -not (Test-AuTaskExists)) {
        Write-Output 'DISABLED'
        exit 0
    }
    Write-Host "[X] Не удалось удалить задачу планировщика '$TaskName'." -ForegroundColor Red
    exit 1
}

if ($Action -eq 'enable') {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host "[X] Требуются права администратора для включения задачи автообновления '$TaskName'." -ForegroundColor Red
        exit 1
    }
    $RootTrim = if ($Root.Length -gt 3) { $Root.TrimEnd('\', '/') } else { $Root }

    # Refuse registering SYSTEM scheduled task only from temporary/cloud folders (OneDrive / Temp)
    if ($RootTrim -match '(?i)\\(OneDrive|Temp)(\\|$)') {
        Write-Host "[X] Отказ: автообновление от SYSTEM запрещено из временной/облачной папки '$RootTrim'. Перенесите сборку в C:\Zapret2." -ForegroundColor Red
        exit 1
    }

    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    $utilsDirAu  = Join-Path $Root 'utils'
    $binDirAu    = Join-Path $Root 'bin'
    $tgLogsDirAu = Join-Path $binDirAu 'logs'
    $tgConfAu    = Join-Path $utilsDirAu 'tgws_proxy.conf'
    $tgExeAu     = Join-Path $binDirAu 'tg-ws-proxy.exe'

    # Inside user profile folders (Users/Desktop/Downloads) do NOT strip inherited user ACLs (/inheritance:r breaks Explorer/write access);
    # on a drive root (e.g. D:\) NEVER run recursive /setowner or /inheritance:r across the drive — harden utils\ only;
    # outside profile folders and drive roots (e.g. C:\Zapret2) apply full hardened owner & NTFS ACLs.
    if ($RootTrim -match '(?i)\\(Users|Downloads|Desktop)(\\|$)') {
        try { & $IcaclsExe "$RootTrim" /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /L /Q >$null 2>&1 } catch {}
    } elseif ($RootTrim.Length -le 3) {
        if (Test-Path -LiteralPath $utilsDirAu) {
            $global:LASTEXITCODE = 0
            & $IcaclsExe "$utilsDirAu" /setowner "*S-1-5-32-544" /T /C /L /Q >$null 2>&1
            $ownRc = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            & $IcaclsExe "$utilsDirAu" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" /grant:r "*S-1-5-32-544:(OI)(CI)F" /grant:r "*S-1-5-32-545:(OI)(CI)RX" /T /C /L /Q >$null 2>&1
            $aclRc = $LASTEXITCODE
            if ($ownRc -ne 0 -or $aclRc -ne 0) {
                Write-Host "[X] Ошибка защиты прав доступа (icacls owner=$ownRc, acl=$aclRc) — задача SYSTEM не зарегистрирована." -ForegroundColor Red
                exit 1
            }
        }
    } else {
        $global:LASTEXITCODE = 0
        & $IcaclsExe "$RootTrim" /setowner "*S-1-5-32-544" /T /C /L /Q >$null 2>&1
        $ownRc = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        & $IcaclsExe "$RootTrim" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" /grant:r "*S-1-5-32-544:(OI)(CI)F" /grant:r "*S-1-5-32-545:(OI)(CI)RX" /T /C /L /Q >$null 2>&1
        $aclRc = $LASTEXITCODE
        if ($ownRc -ne 0 -or $aclRc -ne 0) {
            Write-Host "[X] Ошибка защиты прав доступа (icacls owner=$ownRc, acl=$aclRc) — задача SYSTEM не зарегистрирована." -ForegroundColor Red
            exit 1
        }
    }

    # Restore minimal NetworkService (*S-1-5-20) rights so zapret-tgws service keeps working
    try { & $IcaclsExe "$RootTrim" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
    if (Test-Path -LiteralPath $utilsDirAu) { try { & $IcaclsExe "$utilsDirAu" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {} }
    if (Test-Path -LiteralPath $binDirAu)   { try { & $IcaclsExe "$binDirAu"   /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {} }
    if (Test-Path -LiteralPath $tgExeAu)    { try { & $IcaclsExe "$tgExeAu"    /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {} }
    if (Test-Path -LiteralPath $tgConfAu)   { try { & $IcaclsExe "$tgConfAu"   /L /grant:r "*S-1-5-20:(R)"  /Q >$null 2>&1 } catch {} }
    if (Test-Path -LiteralPath $binDirAu) {
        if (-not (Test-Path -LiteralPath $tgLogsDirAu)) {
            try { New-Item -ItemType Directory -Path $tgLogsDirAu -Force | Out-Null } catch {}
        }
        if (Test-Path -LiteralPath $tgLogsDirAu) {
            $liAu = Get-Item -LiteralPath $tgLogsDirAu -Force -ErrorAction SilentlyContinue
            if ($null -ne $liAu -and (($liAu.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
                try { & $IcaclsExe "$tgLogsDirAu" /L /grant:r "*S-1-5-20:(OI)(CI)(M)" /Q >$null 2>&1 } catch {}
                try {
                    Get-ChildItem -LiteralPath $tgLogsDirAu -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                            & $IcaclsExe $_.FullName /L /reset /Q >$null 2>&1
                        }
                    }
                } catch {}
            }
        }
    }

    $argsStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Silent"
    $ok = $false
    try {
        $act  = New-ScheduledTaskAction -Execute $PsExeFull -Argument $argsStr -WorkingDirectory $RootTrim
        $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $idleSet = New-ScheduledTaskSettingsSet -RunOnlyIfIdle -IdleDuration (New-TimeSpan -Minutes 10) -IdleWaitTimeout (New-TimeSpan -Hours 12) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        if ($Mode -eq 'onboot') {
            $trig = New-ScheduledTaskTrigger -AtStartup
            $trig.Delay = 'PT30S'
            $set  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            $desc = 'Auto-update for Zapret2 Kotek 30 seconds after Windows startup'
        } elseif ($Mode -eq 'twiceweekly') {
            $trig = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday,Sunday -At '04:00'
            $set  = $idleSet
            $desc = 'Twice-weekly silent idle auto-update for Zapret2 Kotek (app + IPSet/Hosts)'
        } elseif ($Mode -eq 'monthly') {
            $trig = New-ScheduledTaskTrigger -Once -At '04:00' -RepetitionInterval (New-TimeSpan -Days 30) -RepetitionDuration (New-TimeSpan -Days 3650)
            $set  = $idleSet
            $desc = 'Monthly silent idle auto-update for Zapret2 Kotek (app + IPSet/Hosts)'
        } else {
            $trig = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'
            $set  = $idleSet
            $desc = 'Weekly silent idle auto-update for Zapret2 Kotek (app + IPSet/Hosts)'
        }
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trig -Settings $set -Principal $prin -Description $desc -Force -ErrorAction Stop | Out-Null
        $ok = $true
    } catch {
        $ok = $false
    }
    if (-not $ok) {
        $argsStrEsc = $argsStr.Replace('"', '\"')
        $trArg = "/TR `"\`"$PsExeFull\`" $argsStrEsc`""
        if ($Mode -eq 'onboot') {
            $schArgs = "/Create /TN `"$TaskName`" /SC ONSTART /DELAY 0000:30 /RL HIGHEST /RU SYSTEM /F $trArg"
        } elseif ($Mode -eq 'twiceweekly') {
            $schArgs = "/Create /TN `"$TaskName`" /SC WEEKLY /D WED,SUN /ST 04:00 /RL HIGHEST /RU SYSTEM /F $trArg"
        } elseif ($Mode -eq 'monthly') {
            $schArgs = "/Create /TN `"$TaskName`" /SC MONTHLY /D 1 /ST 04:00 /RL HIGHEST /RU SYSTEM /F $trArg"
        } else {
            $schArgs = "/Create /TN `"$TaskName`" /SC WEEKLY /D SUN /ST 04:00 /RL HIGHEST /RU SYSTEM /F $trArg"
        }
        try {
            $proc = Start-Process -FilePath "$env:SystemRoot\System32\schtasks.exe" -ArgumentList $schArgs -WindowStyle Hidden -Wait -PassThru
            if ($null -ne $proc -and $proc.ExitCode -eq 0) { $ok = $true }
        } catch {
            $ok = $false
        }
    }
    if ($ok) {
        [System.IO.File]::WriteAllText($ModeFile, $Mode, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "ENABLED:$Mode"
        exit 0
    }
    Write-Host "[X] Не удалось зарегистрировать задачу планировщика '$TaskName'." -ForegroundColor Red
    exit 1
}
