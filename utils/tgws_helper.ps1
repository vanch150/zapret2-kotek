$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
$RootDir = $RootDir.Trim('"', "'", '\', '/')
$BinDir   = Join-Path $RootDir 'bin'
$UtilsDir = Join-Path $RootDir 'utils'
$ListsDir = Join-Path $RootDir 'lists'
$ConfPath = Join-Path $UtilsDir 'tgws_proxy.conf'
$CsPath   = Join-Path $UtilsDir 'TgWsProxyService.cs'
$ExePath  = Join-Path $BinDir 'tg-ws-proxy.exe'
$LogPath  = Join-Path $BinDir 'tg-ws-proxy.log'
$AutoConnectedMarker = Join-Path $UtilsDir '.tgws_connected'
$SvcName  = 'zapret-tgws'

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

function Get-TgWsConfig {
    $cfg = [ordered]@{
        enabled = '1'
        host = '127.0.0.1'
        port = '1443'
        secret = ''
        mode = 'smart'
        pool_size = '4'
        cfproxy_domain = ''
        cfproxy_worker_domain = ''
        verbose = '0'
    }
    if (Test-Path -LiteralPath $ConfPath) {
        foreach ($raw in (Get-Content -LiteralPath $ConfPath)) {
            if ($null -eq $raw) { continue }
            $line = $raw.Trim()
            if ($line.Length -eq 0 -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) {
                $k = $line.Substring(0, $eq).Trim().ToLowerInvariant()
                $v = $line.Substring($eq + 1).Trim()
                if ($cfg.Contains($k) -and ($k -ne 'secret' -or $v -match '^[0-9a-fA-F]{32}$')) {
                    $cfg[$k] = if ($k -eq 'secret') { $v.ToLowerInvariant() } else { $v }
                }
            }
        }
    }
    $regPath = 'HKLM:\SOFTWARE\Zapret2'
    if ($cfg['secret'] -notmatch '^[0-9a-fA-F]{32}$') {
        $regSec = $null
        try {
            $regSec = (Get-ItemProperty -Path $regPath -Name 'TgWsSecret' -ErrorAction SilentlyContinue).TgWsSecret
        } catch {}
        if ($regSec -match '^[0-9a-fA-F]{32}$') {
            $cfg['secret'] = $regSec.ToLowerInvariant()
            $script:SecretReusedFromReg = $true
        } else {
            $cfg['secret'] = New-RandomHexSecret
            try {
                if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                New-ItemProperty -Path $regPath -Name 'TgWsSecret' -Value $cfg['secret'] -PropertyType String -Force | Out-Null
            } catch {}
        }
        Save-TgWsConfig $cfg
    } else {
        try {
            if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            New-ItemProperty -Path $regPath -Name 'TgWsSecret' -Value $cfg['secret'] -PropertyType String -Force | Out-Null
        } catch {}
    }
    return $cfg
}

function Save-TgWsConfig($cfg) {
    $lines = @(
        '# Zapret2 Native Telegram MTProto WebSocket Bridge Configuration',
        '# Managed via service.bat -> Option 5 (TG WS Proxy)',
        "enabled=$($cfg['enabled'])",
        "host=$($cfg['host'])",
        "port=$($cfg['port'])",
        "secret=$($cfg['secret'])",
        "mode=$($cfg['mode'])",
        "pool_size=$($cfg['pool_size'])",
        "cfproxy_domain=$($cfg['cfproxy_domain'])",
        "cfproxy_worker_domain=$($cfg['cfproxy_worker_domain'])",
        "verbose=$($cfg['verbose'])"
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($ConfPath, $lines, $utf8NoBom)
}

function Ensure-TgWsBinary {
    $shaFile = Join-Path $BinDir 'tg-ws-proxy.sha256'
    if ((Test-Path -LiteralPath $ExePath) -and (Test-Path -LiteralPath $CsPath)) {
        if (Test-Path -LiteralPath $shaFile) {
            $hashMatched = $false
            try {
                $wantHash = (Get-Content -LiteralPath $shaFile -TotalCount 1).Trim().ToUpperInvariant()
                $curHash  = (Get-FileHash -LiteralPath $CsPath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($wantHash -and $wantHash -eq $curHash) { $hashMatched = $true }
            } catch {}
            if ($hashMatched) { return $true }
            # Hash file exists and does NOT match: force recompile (do not fall through to timestamps)
        } else {
            $exeTime = (Get-Item -LiteralPath $ExePath).LastWriteTimeUtc
            $csTime  = (Get-Item -LiteralPath $CsPath).LastWriteTimeUtc
            if ($exeTime -ge $csTime) { return $true }
        }
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
    $outArg = "`"/out:$ExePath`""
    $csArg  = "`"$CsPath`""
    $p = Start-Process -FilePath $csc -ArgumentList @(
        '/nologo', '/optimize+', '/target:exe',
        '/r:System.dll', '/r:System.Core.dll', '/r:System.ServiceProcess.dll',
        $outArg, $csArg
    ) -NoNewWindow -Wait -PassThru

    if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $ExePath)) {
        try {
            $builtHash = (Get-FileHash -LiteralPath $CsPath -Algorithm SHA256).Hash.ToUpperInvariant()
            [System.IO.File]::WriteAllText($shaFile, $builtHash, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
        Write-Host "[OK] Compiled native bin\tg-ws-proxy.exe successfully." -ForegroundColor Green
        return $true
    }
    Write-Host "[X] Failed to compile tg-ws-proxy.exe (exit code $($p.ExitCode))." -ForegroundColor Red
    return $false
}

function Get-ServiceState {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 'NOT_INSTALLED' }
    return $svc.Status.ToString().ToUpperInvariant()
}

function Connect-TelegramOneClick($cfg, [bool]$quietIfAlreadyConnected = $false) {
    $tgLink = "tg://proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"
    $httpLink = "https://t.me/proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"
    try { Set-Clipboard -Value $tgLink } catch { }
    Write-Host "        [TG WS Proxy] Ссылка скопирована в буфер обмена: $tgLink" -ForegroundColor Green
    $connSig = "$($cfg['host']):$($cfg['port']):$($cfg['secret'])"
    if ($quietIfAlreadyConnected -and (Test-Path -LiteralPath $AutoConnectedMarker)) {
        $savedSig = ([string](Get-Content -LiteralPath $AutoConnectedMarker -Raw -ErrorAction SilentlyContinue)).Trim()
        if ($savedSig -eq $connSig) {
            Write-Host "        [TG WS Proxy] Сохранён прежний секрет ПК — повторно добавлять прокси в Telegram не нужно." -ForegroundColor Gray
            return
        }
    }
    try {
        Start-Process $tgLink -ErrorAction Stop
        [IO.File]::WriteAllText($AutoConnectedMarker, $connSig, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "        [TG WS Proxy] Открыто окно подключения в Telegram Desktop -> нажмите «Включить»!" -ForegroundColor Cyan
    } catch {
        Write-Host "        [TG WS Proxy] Вставьте ссылку в Telegram для подключения: $httpLink" -ForegroundColor Yellow
    }
}

function Install-And-Start-TgWsService([bool]$autoOpenTelegram = $false) {
    $cfg = Get-TgWsConfig

    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    $svcExists = ($null -ne $svc)
    if ($svcExists) {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
            try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5)) } catch { Start-Sleep -Milliseconds 700 }
        }
        try { $svc.Dispose() } catch {}
    }
    Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 250

    if (-not (Ensure-TgWsBinary)) { return $false }

    $binEscaped = "\`"$ExePath\`" --service"
    if ($svcExists) {
        $pCfg = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config $SvcName binPath= `"$binEscaped`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait -PassThru
        if ($pCfg.ExitCode -ne 0) {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create $SvcName binPath= `"$binEscaped`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait | Out-Null
        }
    } else {
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "create $SvcName binPath= `"$binEscaped`" DisplayName= `"Zapret2 Telegram WS Proxy`" start= auto" -WindowStyle Hidden -Wait | Out-Null
    }
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "description $SvcName `"Zapret2 Native Telegram Desktop MTProto WebSocket Bridge`"" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failure $SvcName reset= 60 actions= restart/1000/restart/3000/restart/5000" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "start $SvcName" -WindowStyle Hidden -Wait | Out-Null
    Start-Sleep -Milliseconds 900

    $state = Get-ServiceState
    if ($state -eq 'RUNNING') {
        Write-Host "        [OK] Служба '$SvcName' запущена на $($cfg['host']):$($cfg['port']) (режим: $($cfg['mode']))." -ForegroundColor Green
        if ($autoOpenTelegram) {
            Connect-TelegramOneClick $cfg $true
        }
        return $true
    } else {
        Write-Host "[!] Service '$SvcName' state: $state. Check $LogPath for details." -ForegroundColor Yellow
        return $false
    }
}

function Remove-TgWsService {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $SvcName | Out-Null
        Write-Host "Service '$SvcName' stopped and removed." -ForegroundColor Yellow
    } else {
        Write-Host "Service '$SvcName' is not installed." -ForegroundColor DarkGray
    }
    Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$cfg = Get-TgWsConfig
if ($Action -eq 'status') {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Output "running ($($cfg['host']):$($cfg['port']), $($cfg['mode']))"
    } elseif ($cfg['enabled'] -eq '1') {
        Write-Output "ready ($($cfg['host']):$($cfg['port']), $($cfg['mode']))"
    } else {
        Write-Output "disabled"
    }
    exit 0
}
if ($Action -eq 'ensure-service' -or $Action -eq 'ensure-service-silent') {
    if ($cfg['enabled'] -ne '0') {
        $cfg['enabled'] = '1'
        Save-TgWsConfig $cfg
        $openTg = ($Action -eq 'ensure-service')
        $ok = Install-And-Start-TgWsService $openTg
        if (-not $ok) { exit 1 }
    }
    exit 0
}

if ($Action -eq 'remove-service') {
    Remove-TgWsService
    exit 0
}

if ((Get-ServiceState) -ne 'RUNNING' -and $cfg['enabled'] -eq '1') {
    Write-Host "Auto-starting 'zapret-tgws' service..." -ForegroundColor Cyan
    Install-And-Start-TgWsService $false | Out-Null
}

# Interactive Menu (Option 5)
while ($true) {
    Clear-Host
    $cfg = Get-TgWsConfig
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    $svcState = if ($svc) { $svc.Status.ToString() } else { 'Не установлена' }
    $proxyLink = "tg://proxy?server=$($cfg['host'])&port=$($cfg['port'])&secret=dd$($cfg['secret'])"

    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '           ФИКС TELEGRAM В 1 КЛИК (TG WS PROXY)                 ' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ("  Статус службы  : {0}" -f $svcState) -ForegroundColor $(if ($svcState -eq 'Running') { 'Green' } else { 'Yellow' })
    Write-Host ("  Локальный адрес: {0}:{1} (режим: {2})" -f $cfg['host'], $cfg['port'], $cfg['mode'])
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
        $cfg['enabled'] = '1'
        Save-TgWsConfig $cfg
        if (Install-And-Start-TgWsService $false) { Connect-TelegramOneClick $cfg $false }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '2') {
        $modes = @('smart', 'direct', 'cfonly')
        $curIdx = [array]::IndexOf($modes, $cfg['mode'])
        if ($curIdx -lt 0) { $curIdx = 0 }
        $nextMode = $modes[($curIdx + 1) % $modes.Length]
        $cfg['mode'] = $nextMode
        Save-TgWsConfig $cfg
        if (Install-And-Start-TgWsService $false) { Write-Host "`n  [OK] Режим переключен на: $nextMode" -ForegroundColor Green }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '3') {
        $cfg['enabled'] = '0'
        Save-TgWsConfig $cfg
        Remove-TgWsService
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '4') {
        Write-Host "`n  Ссылка прокси: $proxyLink" -ForegroundColor Cyan
        if (Test-Path -LiteralPath $LogPath) {
            Write-Host "`n  --- Последние 15 строк лога ---" -ForegroundColor Gray
            try { Get-Content -LiteralPath $LogPath -Tail 15 } catch { Write-Host '  [!] Лог сейчас обновляется, попробуйте ещё раз.' -ForegroundColor Yellow }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
}
