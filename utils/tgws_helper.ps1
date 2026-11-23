$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Action = 'menu'
if ($args.Count -ge 1) {
    if ($args[0] -eq '-Action' -and $args.Count -ge 2) {
        $Action = $args[1].ToLowerInvariant()
    } else {
        $Action = $args[0].ToLowerInvariant()
    }
}
$RootDir = $env:Z2_ROOT
if ([string]::IsNullOrWhiteSpace($RootDir)) {
    $RootDir = Split-Path -Parent $PSScriptRoot
}
$rawRoot = ([string]$RootDir).Trim().Trim('"')
if ($rawRoot -match '^[A-Za-z]:$') { $rawRoot = $rawRoot + '\' }
try {
    $RootDir = [System.IO.Path]::GetFullPath($rawRoot)
    if ($RootDir.Length -gt 3) { $RootDir = $RootDir.TrimEnd('\', '/') }
} catch {
    $RootDir = $rawRoot
    if ($RootDir.Length -gt 3) { $RootDir = $RootDir.TrimEnd('\', '/') }
    if ($RootDir -match '^[A-Za-z]:$') { $RootDir = $RootDir + '\' }
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

$BinDir   = Join-Path $RootDir 'bin'
$LogsDir  = Join-Path $BinDir 'logs'
$UtilsDir = Join-Path $RootDir 'utils'
$ListsDir = Join-Path $RootDir 'lists'
$ConfPath = Join-Path $UtilsDir 'tgws_proxy.conf'
$CsPath   = Join-Path $UtilsDir 'TgWsProxyService.cs'
$ExePath  = Join-Path $BinDir 'tg-ws-proxy.exe'
$LogPath  = Join-Path $LogsDir 'tg-ws-proxy.log'
$AutoConnectedMarker = Join-Path $UtilsDir '.tgws_connected'
$SvcName  = 'zapret-tgws'
$KnownTemplateSecrets = @('127217fa4fff26dd96ab708be1407e69')

function Test-SafeExePath([string]$PathToCheck) {
    if ([string]::IsNullOrWhiteSpace($PathToCheck)) { return $false }
    if ($PathToCheck -match '["\x00-\x1F]') { return $false }
    try {
        $fullExe = [System.IO.Path]::GetFullPath($PathToCheck)
        $fullBin = [System.IO.Path]::GetFullPath($BinDir).TrimEnd('\') + '\'
        if (-not $fullExe.StartsWith($fullBin, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($fullExe -match '["\x00-\x1F]') { return $false }
        return $true
    } catch { return $false }
}

function Set-TgWsHardenedAcls {
    if (-not (Test-Z2IsAdmin)) { return }
    $icacls = "$env:SystemRoot\System32\icacls.exe"
    if (-not (Test-Path -LiteralPath $icacls)) { return }

    $isUserOrRootDir = ($RootDir -match '(?i)\\(Users|Downloads|Desktop|OneDrive|Temp)(\\|$)') -or ($RootDir.Length -le 3)
    $helperPath = Join-Path $UtilsDir 'tgws_helper.ps1'
    $shaPath    = Join-Path $BinDir 'tg-ws-proxy.sha256'

    if ($isUserOrRootDir) {
        # Inside user profile folders or drive root: NEVER strip inherited ACLs (/inheritance:r); add minimal NetworkService grants only
        try { & $icacls "$RootDir" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
        if (Test-Path -LiteralPath $UtilsDir) {
            try { & $icacls "$UtilsDir" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
        }
        if (Test-Path -LiteralPath $BinDir) {
            try { & $icacls "$BinDir" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
        }
        if (Test-Path -LiteralPath $ExePath) {
            try { & $icacls "$ExePath" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
        }
        if (Test-Path -LiteralPath $ConfPath) {
            try { & $icacls "$ConfPath" /L /grant:r "*S-1-5-20:(R)" /Q >$null 2>&1 } catch {}
        }
        if (-not (Test-Path -LiteralPath $LogsDir)) {
            try { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null } catch {}
        }
        if (Test-Path -LiteralPath $LogsDir) {
            $liLogs = Get-Item -LiteralPath $LogsDir -Force -ErrorAction SilentlyContinue
            if ($null -ne $liLogs -and (($liLogs.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
                try { & $icacls "$LogsDir" /L /grant:r "*S-1-5-20:(OI)(CI)(M)" /Q >$null 2>&1 } catch {}
                try {
                    Get-ChildItem -LiteralPath $LogsDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                            & $icacls $_.FullName /L /reset /Q >$null 2>&1
                        }
                    }
                } catch {}
            }
        }
        return
    }

    # Outside user profile and drive root: harden utils/bin/logs and 5 target files without inheriting NetworkService onto utils/bin children
    try { & $icacls "$RootDir" /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
    if (Test-Path -LiteralPath $UtilsDir) {
        try { & $icacls "$UtilsDir" /L /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" /grant:r "*S-1-5-32-544:(OI)(CI)(F)" /grant:r "*S-1-5-32-545:(OI)(CI)(RX)" /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
    }
    if (Test-Path -LiteralPath $BinDir) {
        try { & $icacls "$BinDir" /L /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" /grant:r "*S-1-5-32-544:(OI)(CI)(F)" /grant:r "*S-1-5-32-545:(OI)(CI)(RX)" /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {}
    }

    if (-not (Test-Path -LiteralPath $LogsDir)) {
        try { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null } catch {}
    }
    if (Test-Path -LiteralPath $LogsDir) {
        $liLogs = Get-Item -LiteralPath $LogsDir -Force -ErrorAction SilentlyContinue
        if ($null -ne $liLogs -and (($liLogs.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
            try { & $icacls "$LogsDir" /L /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" /grant:r "*S-1-5-32-544:(OI)(CI)(F)" /grant:r "*S-1-5-20:(OI)(CI)(M)" /grant:r "*S-1-5-32-545:(OI)(CI)(RX)" /Q >$null 2>&1 } catch {}
            try {
                Get-ChildItem -LiteralPath $LogsDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        & $icacls $_.FullName /L /reset /Q >$null 2>&1
                    }
                }
            } catch {}
        }
    }

    # Restrict write access on executable, source, helper, sha256, and config to SYSTEM + Administrators only
    if (Test-Path -LiteralPath $ExePath) {
        try { & $icacls "$ExePath"    /L /inheritance:r /grant:r "*S-1-5-18:(F)" /grant:r "*S-1-5-32-544:(F)" /grant:r "*S-1-5-20:(RX)" /grant:r "*S-1-5-32-545:(RX)" /Q >$null 2>&1 } catch {}
    }
    if (Test-Path -LiteralPath $CsPath) {
        try { & $icacls "$CsPath"     /L /inheritance:r /grant:r "*S-1-5-18:(F)" /grant:r "*S-1-5-32-544:(F)" /grant:r "*S-1-5-32-545:(R)" /Q >$null 2>&1 } catch {}
    }
    if (Test-Path -LiteralPath $helperPath) {
        try { & $icacls "$helperPath" /L /inheritance:r /grant:r "*S-1-5-18:(F)" /grant:r "*S-1-5-32-544:(F)" /grant:r "*S-1-5-32-545:(R)" /Q >$null 2>&1 } catch {}
    }
    if (Test-Path -LiteralPath $shaPath) {
        try { & $icacls "$shaPath"    /L /inheritance:r /grant:r "*S-1-5-18:(F)" /grant:r "*S-1-5-32-544:(F)" /grant:r "*S-1-5-32-545:(R)" /Q >$null 2>&1 } catch {}
    }
    if (Test-Path -LiteralPath $ConfPath) {
        try { & $icacls "$ConfPath"   /L /inheritance:r /grant:r "*S-1-5-18:(F)" /grant:r "*S-1-5-32-544:(F)" /grant:r "*S-1-5-20:(R)" /grant:r "*S-1-5-32-545:(R)" /Q >$null 2>&1 } catch {}
    }
}

function Stop-TgWsProcessByPath {
    $normExe = ''
    try { $normExe = [System.IO.Path]::GetFullPath($ExePath) } catch { $normExe = $ExePath }
    $procs = @(Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            $pPath = $null
            try { $pPath = $p.MainModule.FileName } catch {}
            if (-not $pPath) {
                try {
                    $wmi = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue
                    if ($wmi) { $pPath = $wmi.ExecutablePath }
                } catch {}
            }
            if ($pPath -and $pPath.Equals($normExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not $p.HasExited) {
                    $p.Kill()
                    [void]$p.WaitForExit(3000)
                }
            }
        } catch {}
    }
}

function New-RandomHexSecret {
    $bytes = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-TgWsConfig([switch]$ReadOnly) {
    $cfg = [ordered]@{
        enabled = '1'
        host = '127.0.0.1'
        port = '1443'
        secret = ''
        mode = 'smart'
        pool_size = '4'
        cfproxy_domain = ''
        cfproxy_worker_domain = ''
        log_file = ''
        verbose = '0'
    }
    if (Test-Path -LiteralPath $ConfPath) {
        foreach ($raw in (Get-Content -LiteralPath $ConfPath -Encoding UTF8)) {
            if ($null -eq $raw) { continue }
            $line = $raw.Trim()
            if ($line.Length -eq 0 -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) {
                $k = $line.Substring(0, $eq).Trim().ToLowerInvariant()
                $v = $line.Substring($eq + 1).Trim()
                if ($cfg.Contains($k)) {
                    if ($k -eq 'secret') {
                        if ($v -match '^[0-9a-fA-F]{32}$') { $cfg[$k] = $v.ToLowerInvariant() }
                    } else {
                        $cfg[$k] = $v
                    }
                }
            }
        }
    }

    # Strict validation of host, port, mode (ID 1.3)
    $needSave = $false
    $h = ([string]$cfg['host']).Trim()
    if ($h -ieq 'localhost') {
        $cfg['host'] = '127.0.0.1'
        $needSave = $true
    } elseif ($h -ne '127.0.0.1' -and $h -ne '::1') {
        $cfg['host'] = '127.0.0.1'
        $needSave = $true
    }

    $portInt = 0
    if (-not [int]::TryParse(([string]$cfg['port']).Trim(), [ref]$portInt) -or $portInt -lt 1 -or $portInt -gt 65535) {
        $cfg['port'] = '1443'
        $needSave = $true
    } else {
        $cfg['port'] = $portInt.ToString()
    }

    $m = ([string]$cfg['mode']).Trim().ToLowerInvariant()
    if (@('smart', 'direct', 'cfonly') -notcontains $m) {
        $cfg['mode'] = 'smart'
        $needSave = $true
    } else {
        $cfg['mode'] = $m
    }

    # Secret management with registry precedence over template/default values (ID 1.2)
    $regPath = 'HKLM:\SOFTWARE\Zapret2'
    $regSec = $null
    try {
        $regSec = (Get-ItemProperty -Path $regPath -Name 'TgWsSecret' -ErrorAction SilentlyContinue).TgWsSecret
    } catch {}
    $regSecClean = if ($null -ne $regSec) { ([string]$regSec).Trim().ToLowerInvariant() } else { '' }
    $hasValidReg = ($regSecClean -match '^[0-9a-f]{32}$') -and ($KnownTemplateSecrets -notcontains $regSecClean)
    $fileSec = ([string]$cfg['secret']).ToLowerInvariant()
    $hasValidFile = ($fileSec -match '^[0-9a-fA-F]{32}$')
    $isTemplateSec = ($KnownTemplateSecrets -contains $fileSec)

    if ($hasValidReg -and (-not $hasValidFile -or $isTemplateSec)) {
        $cfg['secret'] = $regSecClean
        $needSave = $true
    } elseif (-not $hasValidFile -or $isTemplateSec) {
        $cfg['secret'] = New-RandomHexSecret
        $needSave = $true
        try {
            if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            New-ItemProperty -Path $regPath -Name 'TgWsSecret' -Value $cfg['secret'] -PropertyType String -Force | Out-Null
        } catch {}
    } elseif (-not $hasValidReg -or $regSecClean -ne $fileSec) {
        try {
            if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            New-ItemProperty -Path $regPath -Name 'TgWsSecret' -Value $cfg['secret'] -PropertyType String -Force | Out-Null
        } catch {}
    }

    if (-not $ReadOnly -and $needSave) {
        try { Save-TgWsConfig $cfg } catch {}
    }
    return $cfg
}

function Save-TgWsConfig($cfg) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Zapret2 Native Telegram MTProto WebSocket Bridge Configuration')
    $lines.Add('# Managed via service.bat -> Option 5 (TG WS Proxy)')
    $lines.Add("enabled=$($cfg['enabled'])")
    $lines.Add("host=$($cfg['host'])")
    $lines.Add("port=$($cfg['port'])")
    $lines.Add("secret=$($cfg['secret'])")
    $lines.Add("mode=$($cfg['mode'])")
    $lines.Add("pool_size=$($cfg['pool_size'])")
    $lines.Add("cfproxy_domain=$($cfg['cfproxy_domain'])")
    $lines.Add("cfproxy_worker_domain=$($cfg['cfproxy_worker_domain'])")
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg['log_file'])) {
        $lines.Add("log_file=$([string]$cfg['log_file'])")
    }
    $lines.Add("verbose=$($cfg['verbose'])")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($ConfPath, $lines.ToArray(), $utf8NoBom)
}

function Resolve-TgWsLogPath($cfg) {
    $defaultLog = Join-Path $LogsDir 'tg-ws-proxy.log'
    if ($null -eq $cfg) { return $defaultLog }
    $rawLog = ([string]$cfg['log_file']).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($rawLog)) { return $defaultLog }
    try {
        if ([System.IO.Path]::IsPathRooted($rawLog)) {
            return [System.IO.Path]::GetFullPath($rawLog)
        }
        $candRoot = [System.IO.Path]::GetFullPath((Join-Path $RootDir $rawLog))
        if (Test-Path -LiteralPath $candRoot) { return $candRoot }
        $candLogs = [System.IO.Path]::GetFullPath((Join-Path $LogsDir $rawLog))
        if (Test-Path -LiteralPath $candLogs) { return $candLogs }
        return $candRoot
    } catch {
        return $defaultLog
    }
}

function Ensure-TgWsBinary([switch]$SkipAcls) {
    $shaFile = Join-Path $BinDir 'tg-ws-proxy.sha256'
    if ((Test-Path -LiteralPath $ExePath) -and (Test-Path -LiteralPath $CsPath) -and (Test-Path -LiteralPath $shaFile)) {
        $wantCs = ''
        $wantExe = ''
        try {
            foreach ($sl in (Get-Content -LiteralPath $shaFile -Encoding UTF8)) {
                $st = $sl.Trim()
                if ($st -match '^(?i)CS=([0-9A-F]{64})$')  { $wantCs  = $matches[1].ToUpperInvariant() }
                if ($st -match '^(?i)EXE=([0-9A-F]{64})$') { $wantExe = $matches[1].ToUpperInvariant() }
            }
            if ($wantCs -and $wantExe) {
                $curCs  = (Get-FileHash -LiteralPath $CsPath  -Algorithm SHA256).Hash.ToUpperInvariant()
                $curExe = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($wantCs -eq $curCs -and $wantExe -eq $curExe) {
                    if (-not $SkipAcls -and (Test-Z2IsAdmin)) { Set-TgWsHardenedAcls }
                    return $true
                }
            }
        } catch {}
    }

    if (-not (Test-Path -LiteralPath $CsPath)) {
        Write-Host "[X] Source file not found: $CsPath" -ForegroundColor Red
        return $false
    }

    $cscCandidates = @(
        "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) {
        Write-Host "[X] Microsoft .NET Framework 4.x C# compiler (csc.exe) not found." -ForegroundColor Red
        return $false
    }

    Write-Host "Compiling native bin\tg-ws-proxy.exe via Microsoft .NET csc.exe..." -ForegroundColor Cyan
    $tmpExe = "$ExePath.tmp"
    if (Test-Path -LiteralPath $tmpExe) { Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue }
    $outArg = "`"/out:$tmpExe`""
    $csArg  = "`"$CsPath`""
    $p = Start-Process -FilePath $csc -ArgumentList @(
        '/nologo', '/optimize+', '/target:exe', '/platform:anycpu',
        '/r:System.dll', '/r:System.Core.dll', '/r:System.ServiceProcess.dll',
        $outArg, $csArg
    ) -NoNewWindow -Wait -PassThru

    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmpExe)) {
        try {
            Move-Item -LiteralPath $tmpExe -Destination $ExePath -Force
            $builtCs  = (Get-FileHash -LiteralPath $CsPath  -Algorithm SHA256).Hash.ToUpperInvariant()
            $builtExe = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToUpperInvariant()
            $shaText = "CS=$builtCs`r`nEXE=$builtExe`r`n"
            [System.IO.File]::WriteAllText($shaFile, $shaText, (New-Object System.Text.UTF8Encoding($false)))
            if (-not $SkipAcls -and (Test-Z2IsAdmin)) { Set-TgWsHardenedAcls }
            Write-Host "[OK] Compiled native bin\tg-ws-proxy.exe successfully." -ForegroundColor Green
            return $true
        } catch {
            Write-Host "[X] Failed to finalize tg-ws-proxy.exe: $($_.Exception.Message)" -ForegroundColor Red
            if (Test-Path -LiteralPath $tmpExe) { Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue }
            return $false
        }
    }
    if (Test-Path -LiteralPath $tmpExe) { Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue }
    Write-Host "[X] Failed to compile tg-ws-proxy.exe (exit code $($p.ExitCode))." -ForegroundColor Red
    return $false
}

function Get-ServiceState {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 'NOT_INSTALLED' }
    try {
        return $svc.Status.ToString().ToUpperInvariant()
    } finally {
        try { $svc.Dispose() } catch {}
    }
}

function Connect-TelegramOneClick($cfg, [bool]$quietIfAlreadyConnected = $false) {
    $tgLink = "tg://proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"
    $httpLink = "https://t.me/proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"
    $connSig = "$($cfg['host']):$($cfg['port']):$($cfg['secret'])"
    if ($quietIfAlreadyConnected -and (Test-Path -LiteralPath $AutoConnectedMarker)) {
        $savedSig = ([string](Get-Content -LiteralPath $AutoConnectedMarker -Raw -ErrorAction SilentlyContinue)).Trim()
        if ($savedSig -eq $connSig) {
            Write-Host "        [TG WS Proxy] Сохранён прежний секрет ПК — повторно добавлять прокси в Telegram не нужно." -ForegroundColor Gray
            return
        }
    }
    try { Set-Clipboard -Value $tgLink } catch { }
    Write-Host "        [TG WS Proxy] Ссылка скопирована в буфер обмена: $tgLink" -ForegroundColor Green
    $openedOk = $false
    try {
        Start-Process $tgLink -ErrorAction Stop
        $openedOk = $true
        Write-Host "        [TG WS Proxy] Открыто окно подключения в Telegram Desktop -> нажмите «Включить»!" -ForegroundColor Cyan
    } catch {
        Write-Host "        [TG WS Proxy] Вставьте ссылку в Telegram для подключения: $httpLink" -ForegroundColor Yellow
    }
    if ($openedOk) {
        try {
            [IO.File]::WriteAllText($AutoConnectedMarker, $connSig, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
}

function Install-And-Start-TgWsService([bool]$autoOpenTelegram = $false) {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host "[X] Требуются права администратора для установки и запуска службы '$SvcName'." -ForegroundColor Red
        return $false
    }
    $cfg = Get-TgWsConfig
    $curLogPath = Resolve-TgWsLogPath $cfg

    if (-not (Test-SafeExePath $ExePath)) {
        Write-Host "[X] Небезопасный путь к бинарнику: $ExePath" -ForegroundColor Red
        return $false
    }

    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    $svcExists = ($null -ne $svc)
    if ($svcExists) {
        try {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
                try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5)) } catch { Start-Sleep -Milliseconds 700 }
            }
        } finally {
            try { $svc.Dispose() } catch {}
        }
    }
    Stop-TgWsProcessByPath
    Start-Sleep -Milliseconds 250

    if (-not (Ensure-TgWsBinary -SkipAcls)) { return $false }

    $safeExe = [System.IO.Path]::GetFullPath($ExePath)
    $binEscaped = "\`"$safeExe\`" --service"
    $scExe = "$env:SystemRoot\System32\sc.exe"
    $svcAccount = 'NT AUTHORITY\NetworkService'
    if ($svcExists) {
        $pCfg = Start-Process -FilePath $scExe -ArgumentList "config $SvcName binPath= `"$binEscaped`" obj= `"$svcAccount`" password= `"`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait -PassThru
        $cfgRc = if ($null -ne $pCfg) { $pCfg.ExitCode } else { 1 }
        if ($cfgRc -ne 0) {
            $pCreate = Start-Process -FilePath $scExe -ArgumentList "create $SvcName binPath= `"$binEscaped`" obj= `"$svcAccount`" password= `"`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait -PassThru
            $createRc = if ($null -ne $pCreate) { $pCreate.ExitCode } else { 1 }
            if ($createRc -ne 0) {
                Write-Host "[X] Ошибка регистрации службы '$SvcName' (sc config=$cfgRc, sc create=$createRc)." -ForegroundColor Red
                return $false
            }
        }
    } else {
        $pCreate = Start-Process -FilePath $scExe -ArgumentList "create $SvcName binPath= `"$binEscaped`" obj= `"$svcAccount`" password= `"`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait -PassThru
        $createRc = if ($null -ne $pCreate) { $pCreate.ExitCode } else { 1 }
        if ($createRc -ne 0) {
            Write-Host "[X] Ошибка создания службы '$SvcName' (sc create=$createRc)." -ForegroundColor Red
            return $false
        }
    }
    $pDesc = Start-Process -FilePath $scExe -ArgumentList "description $SvcName `"Zapret2 Native Telegram Desktop MTProto WebSocket Bridge`"" -WindowStyle Hidden -Wait -PassThru
    if ($null -eq $pDesc -or $pDesc.ExitCode -ne 0) {
        $descRc = if ($null -ne $pDesc) { $pDesc.ExitCode } else { 1 }
        Write-Host "[!] Предупреждение: sc description вернул код $descRc." -ForegroundColor Yellow
    }
    $pFail = Start-Process -FilePath $scExe -ArgumentList "failure $SvcName reset= 60 actions= restart/1000/restart/3000/restart/5000" -WindowStyle Hidden -Wait -PassThru
    $failRc = if ($null -ne $pFail) { $pFail.ExitCode } else { 1 }
    if ($failRc -ne 0) {
        Write-Host "[X] Ошибка настройки перезапуска службы '$SvcName' (sc failure=$failRc)." -ForegroundColor Red
        return $false
    }
    $pFailFlag = Start-Process -FilePath $scExe -ArgumentList "failureflag $SvcName 1" -WindowStyle Hidden -Wait -PassThru
    if ($null -eq $pFailFlag -or $pFailFlag.ExitCode -ne 0) {
        $ffRc = if ($null -ne $pFailFlag) { $pFailFlag.ExitCode } else { 1 }
        Write-Host "[!] Предупреждение: sc failureflag вернул код $ffRc." -ForegroundColor Yellow
    }
    Set-TgWsHardenedAcls
    $pStart = Start-Process -FilePath $scExe -ArgumentList "start $SvcName" -WindowStyle Hidden -Wait -PassThru
    $startRc = if ($null -ne $pStart) { $pStart.ExitCode } else { 1 }
    if ($startRc -ne 0 -and $startRc -ne 1056) {
        Write-Host "[X] Ошибка запуска службы '$SvcName' (sc start=$startRc). Лог: $curLogPath" -ForegroundColor Red
        return $false
    }

    $state = 'STOPPED'
    for ($w = 0; $w -lt 20; $w++) {
        $state = Get-ServiceState
        if ($state -eq 'RUNNING') { break }
        Start-Sleep -Milliseconds 500
    }

    if ($state -eq 'RUNNING') {
        Write-Host "        [OK] Служба '$SvcName' запущена на $($cfg['host']):$($cfg['port']) (режим: $($cfg['mode']))." -ForegroundColor Green
        if ($autoOpenTelegram) {
            Connect-TelegramOneClick $cfg $true
        }
        return $true
    } else {
        Write-Host "[!] Service '$SvcName' state: $state. Check $curLogPath for details." -ForegroundColor Yellow
        return $false
    }
}

function Remove-TgWsService {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host "[X] Требуются права администратора для удаления службы '$SvcName'." -ForegroundColor Red
        return $false
    }
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        try {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
                try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(8)) } catch { Start-Sleep -Milliseconds 700 }
            }
        } finally {
            try { $svc.Dispose() } catch {}
        }
        Stop-TgWsProcessByPath
        $scExe = "$env:SystemRoot\System32\sc.exe"
        $pDel = Start-Process -FilePath $scExe -ArgumentList "delete $SvcName" -WindowStyle Hidden -Wait -PassThru
        $delRc = if ($null -ne $pDel) { $pDel.ExitCode } else { 1 }
        $stillExists = $false
        for ($i = 0; $i -lt 10; $i++) {
            $chk = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
            if ($null -eq $chk) {
                $stillExists = $false
                break
            }
            $stillExists = $true
            try { $chk.Dispose() } catch {}
            Start-Sleep -Milliseconds 200
        }
        if ($delRc -ne 0 -or $stillExists) {
            Write-Host "[X] Не удалось удалить службу '$SvcName' (sc delete=$delRc, exists=$stillExists)." -ForegroundColor Red
            return $false
        }
        Write-Host "Service '$SvcName' stopped and removed." -ForegroundColor Yellow
        return $true
    } else {
        Write-Host "Service '$SvcName' is not installed." -ForegroundColor DarkGray
        Stop-TgWsProcessByPath
        return $true
    }
}

$cfg = Get-TgWsConfig -ReadOnly:($Action -eq 'status' -or $Action -eq 'remove-service' -or -not (Test-Z2IsAdmin))
if ($Action -eq 'status') {
    $st = Get-ServiceState
    if ($st -eq 'RUNNING') {
        Write-Output "running ($($cfg['host']):$($cfg['port']), $($cfg['mode']))"
    } elseif ($cfg['enabled'] -eq '1') {
        Write-Output "ready ($($cfg['host']):$($cfg['port']), $($cfg['mode']))"
    } else {
        Write-Output "disabled"
    }
    exit 0
}
if ($Action -eq 'compile-only') {
    if (Ensure-TgWsBinary) { exit 0 } else { exit 1 }
}
if ($Action -eq 'ensure-service' -or $Action -eq 'ensure-service-silent') {
    if ($cfg['enabled'] -ne '0') {
        if (-not (Test-Z2IsAdmin)) {
            Write-Host "[X] Требуются права администратора для установки и запуска службы '$SvcName'." -ForegroundColor Red
            exit 1
        }
        $cfg['enabled'] = '1'
        Save-TgWsConfig $cfg
        $openTg = ($Action -eq 'ensure-service')
        $ok = Install-And-Start-TgWsService $openTg
        if (-not $ok) { exit 1 }
    }
    exit 0
}

if ($Action -eq 'remove-service') {
    if (-not (Test-Z2IsAdmin)) {
        Write-Host "[X] Требуются права администратора для удаления службы '$SvcName'." -ForegroundColor Red
        exit 1
    }
    $remOk = Remove-TgWsService
    if (-not $remOk) {
        Write-Host "[X] Ошибка удаления службы '$SvcName'." -ForegroundColor Red
        exit 1
    }
    exit 0
}

if ((Test-Z2IsAdmin) -and (Get-ServiceState) -ne 'RUNNING' -and $cfg['enabled'] -eq '1') {
    Write-Host "Auto-starting 'zapret-tgws' service..." -ForegroundColor Cyan
    Install-And-Start-TgWsService $false | Out-Null
}

# Interactive Menu (Option 5)
while ($true) {
    Clear-Host
    $isAdmin = Test-Z2IsAdmin
    $cfg = Get-TgWsConfig -ReadOnly:(-not $isAdmin)
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    $svcState = 'Не установлена'
    if ($null -ne $svc) {
        try { $svcState = $svc.Status.ToString() } finally { try { $svc.Dispose() } catch {} }
    }
    $proxyLink = "tg://proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"

    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '           ФИКС TELEGRAM В 1 КЛИК (TG WS PROXY)                 ' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ("  Статус службы  : {0}" -f $svcState) -ForegroundColor $(if ($svcState -eq 'Running') { 'Green' } else { 'Yellow' })
    Write-Host ("  Локальный адрес: {0}:{1} (режим: {2})" -f $cfg['host'], $cfg['port'], $cfg['mode'])
    if (-not $isAdmin) {
        Write-Host '  [!] ВНИМАНИЕ: запущено без прав администратора (действия со службой недоступны).' -ForegroundColor Yellow
    }
    Write-Host '  --------------------------------------------------------------'
    Write-Host '  [1] Подключить Telegram в 1 клик (Запуск службы + открытие TG)' -ForegroundColor Green
    Write-Host '  [2] Переключить режим прокси (smart / direct / cfonly)'
    Write-Host '  [3] Остановить и удалить службу TG WS Proxy'
    Write-Host '  [4] Показать ссылку прокси и последние строки лога'
    Write-Host '  [0] Назад в главное меню'
    Write-Host '  --------------------------------------------------------------'
    $ch = Read-Host '  Выберите пункт (0-4, Enter = 1)'
    if ([string]::IsNullOrWhiteSpace($ch)) { $ch = '1' }

    if ($ch -eq '0') { break }
    elseif ($ch -eq '1') {
        if (-not (Test-Z2IsAdmin)) {
            Write-Host "`n  [X] Требуются права администратора для установки и запуска службы." -ForegroundColor Red
        } else {
            $cfg['enabled'] = '1'
            Save-TgWsConfig $cfg
            if (Install-And-Start-TgWsService $false) { Connect-TelegramOneClick $cfg $false }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '2') {
        if (-not (Test-Z2IsAdmin)) {
            Write-Host "`n  [X] Требуются права администратора для переключения режима и перезапуска службы." -ForegroundColor Red
        } else {
            $modes = @('smart', 'direct', 'cfonly')
            $curIdx = [array]::IndexOf($modes, $cfg['mode'])
            if ($curIdx -lt 0) { $curIdx = 0 }
            $nextMode = $modes[($curIdx + 1) % $modes.Length]
            $cfg['mode'] = $nextMode
            Save-TgWsConfig $cfg
            if (Install-And-Start-TgWsService $false) { Write-Host "`n  [OK] Режим переключен на: $nextMode" -ForegroundColor Green }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '3') {
        if (-not (Test-Z2IsAdmin)) {
            Write-Host "`n  [X] Требуются права администратора для остановки и удаления службы." -ForegroundColor Red
        } else {
            if (Remove-TgWsService) {
                $cfg['enabled'] = '0'
                Save-TgWsConfig $cfg
            } else {
                Write-Host "`n  [X] Не удалось удалить службу '$SvcName'." -ForegroundColor Red
            }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '4') {
        Write-Host "`n  Ссылка прокси: $proxyLink" -ForegroundColor Cyan
        $curLogPath = Resolve-TgWsLogPath $cfg
        if (Test-Path -LiteralPath $curLogPath) {
            Write-Host "`n  --- Последние 15 строк лога ($curLogPath) ---" -ForegroundColor Gray
            try { Get-Content -LiteralPath $curLogPath -Tail 15 } catch { Write-Host '  [!] Лог сейчас обновляется, попробуйте ещё раз.' -ForegroundColor Yellow }
        } else {
            Write-Host "`n  [i] Файл лога не найден: $curLogPath" -ForegroundColor DarkGray
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
}
