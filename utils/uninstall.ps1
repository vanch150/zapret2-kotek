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

foreach ($procName in @('winws2', 'winws', 'tg-ws-proxy')) {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host "`n  [1/4] Остановка и удаление служб Windows..." -ForegroundColor Yellow
foreach ($svcName in @('zapret', 'zapret2', 'zapret-tgws', 'discordfix_zapret', 'winws1')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $svcName" -WindowStyle Hidden -Wait | Out-Null
        Write-Host "        [OK] Удалена служба: $svcName" -ForegroundColor Green
    }
}

try { Unregister-ScheduledTask -TaskName 'Zapret2KotekAutoUpdate' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
& "$env:SystemRoot\System32\schtasks.exe" /Delete /TN 'Zapret2KotekAutoUpdate' /F >$null 2>&1

Write-Host "`n  [2/4] Завершение процессов и выгрузка драйвера WinDivert..." -ForegroundColor Yellow
foreach ($procName in @('winws2', 'winws', 'tg-ws-proxy')) {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 300
foreach ($drv in @('WinDivert', 'WinDivert14')) {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "delete $drv" -WindowStyle Hidden -Wait | Out-Null
}
Write-Host '        [OK] Процессы остановлены, драйвер WinDivert выгружен' -ForegroundColor Green

Write-Host "`n  [3/4] Откат изменений в системном файле hosts..." -ForegroundColor Yellow
$sysHosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if (Test-Path -LiteralPath $sysHosts) {
    try {
        $lines = Get-Content -LiteralPath $sysHosts
        $outLines = New-Object System.Collections.Generic.List[string]
        $inZapretBlock = $false
        $removedCount = 0
        $inLegacyBlock = $false
        foreach ($ln in $lines) {
            $t = $ln.Trim()
            if ($t -eq '# --- Zapret2 Auto-Updated Hosts ---') {
                $inZapretBlock = $true
                $removedCount++
                continue
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
        if ($removedCount -gt 0) {
            [System.IO.File]::WriteAllLines($sysHosts, $outLines, $utf8NoBom)
            & ipconfig.exe /flushdns >$null 2>&1
            Write-Host "        [OK] Записи Zapret2 удалены из hosts (сброшен DNS-кеш)" -ForegroundColor Green
        } else {
            Write-Host '        [OK] Записей Zapret2 в hosts не обнаружено' -ForegroundColor Gray
        }
    } catch {
        Write-Host "        [!] Не удалось автоматически очистить hosts: $_" -ForegroundColor Yellow
    }
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
foreach ($rel in @('bin\service.conf', 'bin\tg-ws-proxy.log', 'utils\.tgws_connected')) {
    $fp = Join-Path $Root $rel
    if (Test-Path -LiteralPath $fp) {
        Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
    }
}
# Keep HKLM:\SOFTWARE\Zapret2\TgWsSecret so Telegram Desktop reuses the same proxy without duplicates on reinstall
Write-Host '        [OK] Временные конфиги и логи очищены' -ForegroundColor Green

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
    $iniP = Join-Path ($Root.TrimEnd('\')) 'desktop.ini'
    if (Test-Path -LiteralPath $iniP) {
        & attrib.exe -h -s "$iniP" 2>$null | Out-Null
        Remove-Item -LiteralPath $iniP -Force -ErrorAction SilentlyContinue
        & attrib.exe -s "$($Root.TrimEnd('\'))" 2>$null | Out-Null
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
    $rootDel = $Root.TrimEnd('\')
    $unsafeDirs = @(
        $env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'),
        (Split-Path -Parent $env:USERPROFILE)
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $isUnsafe = ($rootDel.Length -le 6) -or ($unsafeDirs -contains $rootDel) -or (-not (Test-Path -LiteralPath (Join-Path $rootDel 'utils\service.bat')))
    if (-not $isUnsafe) {
        try {
            $guiProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'gui_app\.ps1' }
            foreach ($gp in $guiProcs) { Stop-Process -Id $gp.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch {}
        Write-Host "  [*] Запланировано чистое удаление папки $rootDel через 2 секунды..." -ForegroundColor Yellow
        $env:Z2_DEL_DIR = $rootDel
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; if ($env:Z2_DEL_DIR -and (Test-Path -LiteralPath $env:Z2_DEL_DIR)) { Remove-Item -LiteralPath $env:Z2_DEL_DIR -Recurse -Force -ErrorAction SilentlyContinue }"' -WorkingDirectory $env:TEMP -WindowStyle Hidden
        exit 20
    } else {
        Write-Host "  [!] Пропущено удаление папки ($rootDel) из соображений безопасности." -ForegroundColor Yellow
    }
}

Write-Host ''
exit 0
