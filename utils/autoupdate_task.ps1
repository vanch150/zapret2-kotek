param(
    [ValidateSet('enable', 'disable', 'status')]
    [string]$Action = 'status',
    [string]$Root = '',
    [ValidateSet('weekly', 'twiceweekly', 'monthly', 'onboot')]
    [string]$Mode = 'weekly'
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'

$TaskName   = 'Zapret2KotekAutoUpdate'
$ScriptPath = Join-Path $Root 'utils\self_update.ps1'
$ModeFile   = Join-Path $Root 'utils\autoupdate.mode'
$ValidModes = @('weekly', 'twiceweekly', 'monthly', 'onboot')

if ($Action -eq 'status') {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $exists = ($null -ne $t)
    if (-not $exists) {
        $q = & "$env:SystemRoot\System32\schtasks.exe" /Query /TN $TaskName 2>$null
        if ($LASTEXITCODE -eq 0) { $exists = $true }
    }
    if ($exists) {
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
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN $TaskName /F >$null 2>&1
    Write-Output 'DISABLED'
    exit 0
}

if ($Action -eq 'enable') {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    $RootTrim = $Root.TrimEnd('\')
    # Harden NTFS ACLs on executable/script directories so unprivileged processes (e.g. malware/RAT)
    # cannot tamper with scripts executed by the SYSTEM scheduled task, while Admin/SYSTEM keep full access.
    foreach ($secSub in @('utils', 'bin', 'strategies', 'lua')) {
        $secDir = Join-Path $RootTrim $secSub
        if (Test-Path -LiteralPath $secDir) {
            try {
                & "$env:SystemRoot\System32\icacls.exe" $secDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /C /Q >$null 2>&1
            } catch {}
        }
    }
    $argsStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Root `"$RootTrim`" -Silent"
    $ok = $false
    try {
        $act  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argsStr -WorkingDirectory $RootTrim
        $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $idleSet = New-ScheduledTaskSettingsSet -RunOnlyIfIdle -IdleDuration (New-TimeSpan -Minutes 10) -IdleWaitTimeout (New-TimeSpan -Hours 12) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        if ($Mode -eq 'onboot') {
            $trig = New-ScheduledTaskTrigger -AtStartup
            $trig.Delay = 'PT2M'
            $set  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            $desc = 'Auto-update for Zapret2 Kotek 2 minutes after Windows startup'
        } elseif ($Mode -eq 'twiceweekly') {
            $trig = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday,Sunday -At '04:00'
            $set  = $idleSet
            $desc = 'Twice-weekly silent idle auto-update for Zapret2 Kotek (app + IPSet/Hosts)'
        } elseif ($Mode -eq 'monthly') {
            $trig = New-ScheduledTaskTrigger -Once -At '04:00' -RepetitionInterval (New-TimeSpan -Days 30)
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
        $tr = "powershell.exe $argsStr"
        if ($Mode -eq 'onboot') {
            & "$env:SystemRoot\System32\schtasks.exe" /Create /TN $TaskName /SC ONSTART /DELAY 0002:00 /RL HIGHEST /RU SYSTEM /F /TR ($tr.Replace('"', '\"')) >$null 2>&1
        } elseif ($Mode -eq 'twiceweekly') {
            & "$env:SystemRoot\System32\schtasks.exe" /Create /TN $TaskName /SC WEEKLY /D WED,SUN /ST 04:00 /RL HIGHEST /RU SYSTEM /F /TR ($tr.Replace('"', '\"')) >$null 2>&1
        } elseif ($Mode -eq 'monthly') {
            & "$env:SystemRoot\System32\schtasks.exe" /Create /TN $TaskName /SC MONTHLY /D 1 /ST 04:00 /RL HIGHEST /RU SYSTEM /F /TR ($tr.Replace('"', '\"')) >$null 2>&1
        } else {
            & "$env:SystemRoot\System32\schtasks.exe" /Create /TN $TaskName /SC WEEKLY /D SUN /ST 04:00 /RL HIGHEST /RU SYSTEM /F /TR ($tr.Replace('"', '\"')) >$null 2>&1
        }
        if ($LASTEXITCODE -eq 0) { $ok = $true }
    }
    if ($ok) {
        [System.IO.File]::WriteAllText($ModeFile, $Mode, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "ENABLED:$Mode"
        exit 0
    }
    exit 1
}
