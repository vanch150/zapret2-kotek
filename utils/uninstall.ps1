param(
    [string]$Root = '',
    [switch]$Force,
    [switch]$DeleteFolder
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
try { $Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/') + '\' } catch { $Root = $Root.Trim('"', "'", '\', '/') + '\' }
$rootTrim = $Root.TrimEnd('\')

function Get-ServiceImagePath([string]$ServiceName) {
    try {
        $regPath = "HKLM:\System\CurrentControlSet\Services\$ServiceName"
        if (Test-Path -LiteralPath $regPath) {
            return [string](Get-ItemProperty -Path $regPath -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
        }
    } catch {}
    return ''
}

function Test-ServiceBelongsToRoot([string]$ServiceName, [string]$RootPath) {
    $img = Get-ServiceImagePath $ServiceName
    if ([string]::IsNullOrWhiteSpace($img)) { return $false }
    $normImg = $img.Trim()
    if ($normImg.StartsWith('\??\')) { $normImg = $normImg.Substring(4) }
    $normImg = $normImg.Replace('/', '\')
    $normRoot = $RootPath.TrimEnd('\', '/').Replace('/', '\') + '\'
    return ($normImg.IndexOf($normRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-OtherWinDivertServicesPresent([string]$RootPath) {
    $skipNames = @('windivert', 'windivert14', 'zapret', 'zapret2', 'zapret-tgws')
    try {
        foreach ($sk in @(Get-ChildItem -Path 'HKLM:\System\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
            $sName = $sk.PSChildName
            if ($skipNames -contains $sName.ToLowerInvariant()) { continue }
            $props = Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $deps = @($props.DependOnService)
            foreach ($dep in $deps) {
                if ([string]$dep -match '^(?i)WinDivert(14)?$') { return $true }
            }
            $img = [string]$props.ImagePath
            if (-not [string]::IsNullOrWhiteSpace($img)) {
                $normImg = $img.Trim()
                if ($normImg.StartsWith('\??\')) { $normImg = $normImg.Substring(4) }
                $normRoot = $RootPath.TrimEnd('\', '/').Replace('/', '\') + '\'
                $inRoot = ($normImg.IndexOf($normRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
                if (-not $inRoot -and ($normImg -match '(?i)(goodbyedpi|winws|discordfix|windivert)')) {
                    return $true
                }
            }
        }
    } catch {}
    return $false
}

if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch {} }
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Red
Write-Host '               ПОЛНОЕ УДАЛЕНИЕ ZAPRET2 (В 1 КЛИК)                   ' -ForegroundColor Red
Write-Host '  ==================================================================' -ForegroundColor Red
Write-Host "  Папка: $Root" -ForegroundColor Gray
Write-Host '  Будут остановлены и удалены службы zapret, zapret-tgws, WinDivert,' -ForegroundColor Gray
Write-Host '  а также откачены записи Zapret2 из системного файла hosts.' -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------'

# Instant 1-click uninstall without Enter confirmation

foreach ($procName in @('winws2', 'tg-ws-proxy')) {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host "`n  [1/4] Остановка и удаление служб Windows..." -ForegroundColor Yellow
foreach ($svcName in @('zapret', 'zapret2', 'zapret-tgws')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $svcName" -WindowStyle Hidden -Wait | Out-Null
        Write-Host "        [OK] Удалена служба: $svcName" -ForegroundColor Green
    }
}
foreach ($extSvcName in @('discordfix_zapret', 'winws1')) {
    $svc = Get-Service -Name $extSvcName -ErrorAction SilentlyContinue
    if ($svc) {
        if (Test-ServiceBelongsToRoot $extSvcName $Root) {
            Stop-Service -Name $extSvcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $extSvcName" -WindowStyle Hidden -Wait | Out-Null
            Write-Host "        [OK] Удалена служба: $extSvcName" -ForegroundColor Green
        } else {
            Write-Host "        [ИНФО] Сторонняя служба $extSvcName указывает на другую папку — пропущена" -ForegroundColor Gray
        }
    }
}

try { Unregister-ScheduledTask -TaskName 'Zapret2KotekAutoUpdate' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
& "$env:SystemRoot\System32\schtasks.exe" /Delete /TN 'Zapret2KotekAutoUpdate' /F >$null 2>&1
try { Unregister-ScheduledTask -TaskName 'Zapret2KotekTray' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
& "$env:SystemRoot\System32\schtasks.exe" /Delete /TN 'Zapret2KotekTray' /F >$null 2>&1

Write-Host "`n  [2/4] Завершение процессов и выгрузка драйвера WinDivert..." -ForegroundColor Yellow
foreach ($procName in @('winws2', 'tg-ws-proxy')) {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 300
$hasOtherWd = Test-OtherWinDivertServicesPresent $Root
foreach ($drv in @('WinDivert', 'WinDivert14')) {
    if (Test-Path -LiteralPath "HKLM:\System\CurrentControlSet\Services\$drv") {
        $drvInRoot = Test-ServiceBelongsToRoot $drv $Root
        if ($drvInRoot -or (-not $hasOtherWd)) {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $drv" -WindowStyle Hidden -Wait | Out-Null
        } else {
            Write-Host "        [ИНФО] Драйвер $drv используется сторонней службой — оставлен без изменений" -ForegroundColor Gray
        }
    }
}
Write-Host '        [OK] Процессы остановлены, драйвер WinDivert обработан' -ForegroundColor Green

Write-Host "`n  [3/4] Откат изменений в системном файле hosts..." -ForegroundColor Yellow
$sysHosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$hostsCleanedOk = $false
if (Test-Path -LiteralPath $sysHosts) {
    try {
        $lines = @(Get-Content -LiteralPath $sysHosts -Encoding UTF8 -ErrorAction Stop)
        $outLines = New-Object System.Collections.Generic.List[string]
        $inZapretBlock = $false
        $removedCount = 0
        $unmatchedOpen = $false
        $inLegacyBlock = $false
        for ($li = 0; $li -lt $lines.Count; $li++) {
            $ln = $lines[$li]
            $t = $ln.Trim()
            if (-not $inZapretBlock -and $t -eq '# --- Zapret2 Auto-Updated Hosts ---') {
                $hasCloseMarker = $false
                for ($lj = $li + 1; $lj -lt $lines.Count; $lj++) {
                    if ($lines[$lj].Trim() -eq '# --- End Zapret2 Hosts ---') {
                        $hasCloseMarker = $true
                        break
                    }
                }
                if ($hasCloseMarker) {
                    $inZapretBlock = $true
                    $removedCount++
                    continue
                } else {
                    $unmatchedOpen = $true
                    $outLines.Add($ln)
                    continue
                }
            }
            if ($inZapretBlock) {
                if ($t -eq '# --- End Zapret2 Hosts ---') {
                    $inZapretBlock = $false
                    continue
                }
                $removedCount++
                continue
            }
            if ($t -eq '# Zapret2 Kotek auto-hosts') {
                $inLegacyBlock = $true
                $removedCount++
                continue
            }
            if ($inLegacyBlock) {
                if ($t -eq '' -or $t.StartsWith('#')) {
                    $inLegacyBlock = $false
                    $outLines.Add($ln)
                    continue
                }
                $removedCount++
                continue
            }
            $outLines.Add($ln)
        }
        if ($unmatchedOpen) {
            Write-Host '        [!] В hosts найден открывающий маркер Zapret2 без закрывающего — незакрытый блок пропущен' -ForegroundColor Yellow
        }
        if ($removedCount -gt 0) {
            [System.IO.File]::WriteAllLines($sysHosts, $outLines, $utf8NoBom)
            & "$env:SystemRoot\System32\ipconfig.exe" /flushdns >$null 2>&1
            Write-Host "        [OK] Записи Zapret2 удалены из hosts (сброшен DNS-кеш)" -ForegroundColor Green
            if (-not $unmatchedOpen) { $hostsCleanedOk = $true }
        } elseif (-not $unmatchedOpen) {
            Write-Host '        [OK] Записей Zapret2 в hosts не обнаружено' -ForegroundColor Gray
            $hostsCleanedOk = $true
        }
    } catch {
        Write-Host "        [!] Не удалось автоматически очистить hosts: $_" -ForegroundColor Yellow
    }
} else {
    $hostsCleanedOk = $true
}
$hostsBak = "$env:SystemRoot\System32\drivers\etc\hosts.zapret2.bak"
if ($hostsCleanedOk -and (Test-Path -LiteralPath $hostsBak)) {
    Remove-Item -LiteralPath $hostsBak -Force -ErrorAction SilentlyContinue
}

$bpMarker = Join-Path $Root 'utils\browser_policy.applied'
$bpHelper = Join-Path $Root 'utils\browser_helper.ps1'
$bpRegFlag = $false
try { $bpRegFlag = ((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -ErrorAction SilentlyContinue).BrowserPolicyApplied -eq 1) } catch {}
if (($bpRegFlag -or (Test-Path -LiteralPath $bpMarker)) -and (Test-Path -LiteralPath $bpHelper)) {
    & $bpHelper -Action revert -Root $Root
    Write-Host '        [OK] Политики QUIC/DoH в браузерах откачены к стандарту' -ForegroundColor Green
}

Write-Host "`n  [4/4] Очистка временных файлов в папке Zapret2..." -ForegroundColor Yellow
$unsafeDirs = @(
    $env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
    (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'),
    (Split-Path -Parent $env:USERPROFILE)
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
$isUnsafeRoot = ($rootTrim.Length -le 6) -or ($unsafeDirs -contains $rootTrim) -or (-not (Test-Path -LiteralPath (Join-Path $rootTrim 'utils\service.bat')))
if (Test-Path -LiteralPath $rootTrim) {
    if (-not $isUnsafeRoot) {
        & "$env:SystemRoot\System32\icacls.exe" "$rootTrim" /reset /T /C /L /Q >$null 2>&1
    } else {
        foreach ($sub in @('bin', 'utils', 'lists', 'strategies', 'configs_archive')) {
            $subP = Join-Path $rootTrim $sub
            if (Test-Path -LiteralPath $subP) {
                & "$env:SystemRoot\System32\icacls.exe" "$subP" /reset /T /C /L /Q >$null 2>&1
            }
        }
    }
}
foreach ($rel in @('bin\service.conf', 'bin\logs\tg-ws-proxy.log', 'bin\logs\tg-ws-proxy.log.1', 'bin\tg-ws-proxy.log', 'bin\tg-ws-proxy.log.1', 'utils\.tgws_connected', 'utils\diag_report.txt', 'utils\diag_report.json', 'utils\last_hybrid.json', 'lists\list-exclude.effective.txt', 'utils\browser_policy.applied', 'utils\browser_policy.backup.json', 'utils\ai_bypass.conf', 'utils\nlm_auto.enabled', 'utils\nlm_filter.enabled', 'utils\nlm_filter.names', 'utils\vpn_ifidx.enabled', 'utils\vpn_ifidx.custom', 'utils\vpn_ifidx.names', 'bin\filters\vpn_exclude.txt', 'utils\kotek_folder.ico', 'utils\telemetry.enabled', 'utils\telemetry.id', 'utils\telemetry.state.json', 'utils\telemetry.prompted')) {
    $fp = Join-Path $Root $rel
    if (Test-Path -LiteralPath $fp) {
        Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
    }
}
$utilsDir = Join-Path $Root 'utils'
if (Test-Path -LiteralPath $utilsDir) {
    foreach ($pat in @('autoupdate.*', 'nlm_filter.*')) {
        Get-ChildItem -LiteralPath $utilsDir -Filter $pat -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
# Keep HKLM:\SOFTWARE\Zapret2\TgWsSecret so Telegram Desktop reuses the same proxy without duplicates on reinstall
try {
    $nrptReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig'
    if (Test-Path -LiteralPath $nrptReg) {
        foreach ($subN in @(Get-ChildItem -LiteralPath $nrptReg -ErrorAction SilentlyContinue)) {
            $prN = Get-ItemProperty -LiteralPath $subN.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $prN -and [string]$prN.Comment -eq 'Zapret2KotekAI') {
                Remove-Item -LiteralPath $subN.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq 'Zapret2KotekAI' } | ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -Confirm:$false -ErrorAction SilentlyContinue }
} catch {}
& "$env:SystemRoot\System32\ipconfig.exe" /flushdns >$null 2>&1
Write-Host '        [OK] Временные конфиги, логи и правила NRPT Gemini очищены' -ForegroundColor Green

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host '                    ZAPRET2 ПОЛНОСТЬЮ УДАЛЁН!                       ' -ForegroundColor Green
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host '  Все службы, драйвер WinDivert и правки hosts убраны из Windows.' -ForegroundColor White
Write-Host '  [!] Telegram Desktop: переключи Настройки -> Продвинутые -> Тип соединения -> Системный / Выкл.' -ForegroundColor Yellow
Write-Host '  Теперь эту папку можно спокойно удалить в корзину.' -ForegroundColor Gray

# Remove Desktop & Start Menu shortcuts + folder desktop.ini
try {
    foreach ($lnkDir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if ($lnkDir) {
            $lnkP = Join-Path $lnkDir 'Zapret2 Kotek.lnk'
            if (Test-Path -LiteralPath $lnkP) { Remove-Item -LiteralPath $lnkP -Force -ErrorAction SilentlyContinue }
        }
    }
    $iniP = Join-Path $rootTrim 'desktop.ini'
    if (Test-Path -LiteralPath $iniP) {
        & "$env:SystemRoot\System32\attrib.exe" -h -s "$iniP" 2>$null | Out-Null
        Remove-Item -LiteralPath $iniP -Force -ErrorAction SilentlyContinue
        & "$env:SystemRoot\System32\attrib.exe" -s "$rootTrim" 2>$null | Out-Null
    }
} catch {}

$doDelFolder = [bool]$DeleteFolder
if (-not $doDelFolder -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected -and -not $Force) {
    Write-Host ''
    $ansDel = Read-Host '  Удалить также саму папку программы? [Y/N] (Enter = нет)'
    if ($ansDel -match '^(?i)(y|yes|д|да)$') { $doDelFolder = $true }
}
try { Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Zapret2Kotek' -Recurse -Force -ErrorAction SilentlyContinue } catch {}

if ($doDelFolder) {
    $rootDel = $rootTrim
    $isUnsafe = $isUnsafeRoot
    if (-not $isUnsafe) {
        try {
            $guiProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'gui_app\.ps1' }
            foreach ($gp in $guiProcs) { Stop-Process -Id $gp.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch {}
        Write-Host "  [*] Запланировано чистое удаление папки $rootDel (до 8 попыток)..." -ForegroundColor Yellow
        $env:Z2_DEL_DIR = $rootDel
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile -WindowStyle Hidden -Command "for ($i = 0; $i -lt 8; $i++) { Start-Sleep -Seconds 1; if (-not $env:Z2_DEL_DIR -or -not (Test-Path -LiteralPath $env:Z2_DEL_DIR)) { break }; Remove-Item -LiteralPath $env:Z2_DEL_DIR -Recurse -Force -ErrorAction SilentlyContinue }"' -WorkingDirectory $env:TEMP -WindowStyle Hidden
        exit 20
    } else {
        Write-Host "  [!] Пропущено удаление папки ($rootDel) из соображений безопасности." -ForegroundColor Yellow
    }
}

Write-Host ''
exit 0
