param(
    [string]$Root = '',
    [string]$Repo = '',
    [switch]$Silent
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'
$verFile = Join-Path $Root 'utils\version.txt'
$CurrentVersion = if (Test-Path -LiteralPath $verFile) { ([string](Get-Content -LiteralPath $verFile -TotalCount 1)).Trim() } else { '1.0.0' }

function Compare-KotekVersion([string]$a, [string]$b) {
    $pa = @(([regex]::Matches($a, '\d+') | ForEach-Object { [int]$_.Value }))
    $pb = @(([regex]::Matches($b, '\d+') | ForEach-Object { [int]$_.Value }))
    $len = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '     (=^.^=) ZAPRET2 KOTEK — АВТООБНОВЛЕНИЕ С GITHUB' -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan

if (-not $Repo) {
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc)) {
            if ($l -match '^\s*repo\s*=\s*(.+)$') { $Repo = $matches[1].Trim() }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Repo) -or $Repo -like 'OWNER/*' -or ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) {
    Write-Host '  [!] Некорректный или не настроенный репозиторий в utils\repo.conf.' -ForegroundColor Yellow
    exit 1
}

$hdr = @{ 'User-Agent' = 'Zapret2-Kotek-Updater' }
Write-Host "  [1/5] Проверка последнего релиза на github.com/$Repo ..." -ForegroundColor Yellow
function Invoke-Z2SilentListsRefresh([string]$RootDir) {
    try {
        $ipf = Join-Path $RootDir 'lists\ipset-all.txt'
        $needLists = (-not (Test-Path -LiteralPath $ipf)) -or (((Get-Date) - (Get-Item -LiteralPath $ipf).LastWriteTime).TotalDays -ge 3)
        $updScript = Join-Path $RootDir 'utils\update_lists.ps1'
        if ($needLists -and (Test-Path -LiteralPath $updScript)) {
            & $updScript -Root $RootDir | Out-Null
        }
    } catch {}
}

try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $hdr -TimeoutSec 10 -ErrorAction Stop
} catch {
    Write-Host "  [ОШИБКА] Не удалось подключиться к GitHub API: $($_.Exception.Message)" -ForegroundColor Red
    if ($Silent) { Invoke-Z2SilentListsRefresh $Root }
    exit 1
}

$latestTag = ([string]$rel.tag_name).Trim().TrimStart('v', 'V')
if ([string]::IsNullOrWhiteSpace($latestTag)) {
    Write-Host '  [ОШИБКА] У релиза отсутствует тег версии.' -ForegroundColor Red
    exit 1
}

if ((Compare-KotekVersion $latestTag $CurrentVersion) -le 0) {
    if ($Silent) { Invoke-Z2SilentListsRefresh $Root }
    Write-Host "  [OK] Установлена актуальная версия (v$CurrentVersion). Обновление не требуется." -ForegroundColor Green
    exit 0
}

$zipAsset = $null
foreach ($a in @($rel.assets)) {
    if ($a.name -like '*.zip') { $zipAsset = $a; break }
}
$dlUrl = if ($zipAsset) { [string]$zipAsset.browser_download_url } else { [string]$rel.zipball_url }
if ([string]::IsNullOrWhiteSpace($dlUrl) -or ($dlUrl -notmatch '^https://(github\.com|api\.github\.com|objects\.githubusercontent\.com)/')) {
    Write-Host '  [ОШИБКА] В релизе не найден безопасный ZIP-архив для скачивания.' -ForegroundColor Red
    exit 1
}

$workDir = Join-Path $env:TEMP ('zapret2_kotek_upd_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$zipPath = Join-Path $workDir 'release.zip'
$extDir  = Join-Path $workDir 'extracted'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$assetLabel = if ($zipAsset) { [string]$zipAsset.name } else { "source-zipball" }
Write-Host "  [2/5] Скачивание v$latestTag ($assetLabel)..." -ForegroundColor Yellow
$curlExe = "$env:SystemRoot\System32\curl.exe"
$dlOk = $false
if (Test-Path -LiteralPath $curlExe) {
    & $curlExe --ssl-no-revoke --proto =https --proto-redir =https -L -s -f --max-time 60 -o $zipPath $dlUrl 2>$null
    if ((Test-Path -LiteralPath $zipPath) -and (Get-Item -LiteralPath $zipPath).Length -gt 50000) { $dlOk = $true }
}
if (-not $dlOk) {
    try {
        Invoke-WebRequest -Uri $dlUrl -Headers $hdr -OutFile $zipPath -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        if ((Test-Path -LiteralPath $zipPath) -and (Get-Item -LiteralPath $zipPath).Length -gt 50000) { $dlOk = $true }
    } catch {}
}

if (-not $dlOk) {
    Write-Host '  [ОШИБКА] Не удалось скачать архив обновления.' -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Optional SHA-256 verification if SHA256SUMS.txt is published in the GitHub release
$shaAsset = $null
foreach ($a in @($rel.assets)) {
    if ($a.name -ieq 'SHA256SUMS.txt') { $shaAsset = $a; break }
}
if ($shaAsset -and $zipAsset) {
    try {
        $shaUrl = [string]$shaAsset.browser_download_url
        if ($shaUrl -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw "Untrusted SHA256SUMS URL: $shaUrl" }
        $sumsRaw = Invoke-RestMethod -Uri $shaUrl -Headers $hdr -TimeoutSec 15 -ErrorAction Stop
        $expectedHash = ''
        foreach ($sl in (($sumsRaw -split "`r?`n"))) {
            if ($sl -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $matches[2].Trim() -ieq $zipAsset.name) {
                $expectedHash = $matches[1].ToLowerInvariant()
                break
            }
        }
        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                Write-Host '  [ОШИБКА] Несовпадение контрольной суммы SHA-256 — обновление отменено!' -ForegroundColor Red
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
                exit 1
            }
            Write-Host '        [OK] Контрольная сумма SHA-256 подтверждена.' -ForegroundColor Green
        } else {
            Write-Host '  [ОШИБКА] В SHA256SUMS.txt не найдена запись для скачанного архива — обновление отменено!' -ForegroundColor Red
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }
    } catch {
        Write-Host "  [ОШИБКА] Не удалось проверить SHA256SUMS.txt: $($_.Exception.Message) — обновление отменено!" -ForegroundColor Red
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Write-Host '  [3/5] Распаковка архива и проверка структуры...' -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $fullExt = [System.IO.Path]::GetFullPath($extDir).TrimEnd('\') + '\'
    $za = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $za.Entries) {
            $destPath = [System.IO.Path]::GetFullPath((Join-Path $extDir $entry.FullName))
            if (-not $destPath.StartsWith($fullExt, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Zip-Slip blocked: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if (-not (Test-Path -LiteralPath $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
            } else {
                $destParent = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            }
        }
    } finally {
        $za.Dispose()
    }
} catch {
    Write-Host "  [ОШИБКА] Не удалось распаковать архив: $($_.Exception.Message)" -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Locate and strictly verify actual root inside extracted archive
function Test-Z2ReleaseRoot([string]$Dir) {
    return (Test-Path -LiteralPath (Join-Path $Dir 'utils')) -and (
        (Test-Path -LiteralPath (Join-Path $Dir 'utils\service.bat')) -or
        (Test-Path -LiteralPath (Join-Path $Dir '!_START_KOTEK.bat')) -or
        (Test-Path -LiteralPath (Join-Path $Dir 'service.bat'))
    )
}
$srcRoot = $extDir
if (-not (Test-Z2ReleaseRoot $srcRoot)) {
    $sub = Get-ChildItem -LiteralPath $extDir -Directory | Select-Object -First 1
    if ($sub -and (Test-Z2ReleaseRoot $sub.FullName)) {
        $srcRoot = $sub.FullName
    }
}
if (-not (Test-Z2ReleaseRoot $srcRoot)) {
    Write-Host '  [ОШИБКА] Архив релиза повреждён или не содержит структуру Zapret2 Kotek — обновление отменено.' -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Preserve all user-specific settings, lists, active UDP fakes and synthesized strategy
$preserveRel = @(
    'lists\list-general-user.txt',
    'lists\list-exclude-user.txt',
    'lists\ipset-exclude-user.txt',
    'lists\list-auto.txt',
    'utils\tgws_proxy.conf',
    'utils\strategy_scores.json',
    'utils\active_udp_fake.txt',
    'utils\autohostlist.enabled',
    'utils\warp_unblock.enabled',
    'utils\game_filter.enabled',
    'lists\hosts-extra.txt',
    'lists\ipset-all.txt.backup',
    'utils\nlm_auto.enabled',
    'utils\nlm_filter.enabled',
    'utils\nlm_filter.names',
    'utils\.tgws_connected',
    'utils\repo.conf',
    'utils\autoupdate.mode',
    'utils\targets.txt',
    'utils\kernel_filter.enabled',
    'utils\tray_mode.enabled',
    'utils\wf_priority.conf',
    'bin\ACTIVE_DISCORD_UDP.bin',
    'bin\ACTIVE_GAME_UDP.bin',
    'strategies\custom_auto_synthesized.bat',
    'custom_auto_synthesized.bat'
)
$bakDir = Join-Path $workDir 'user_backup'
New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
foreach ($relPath in $preserveRel) {
    $fp = Join-Path $Root $relPath
    if (Test-Path -LiteralPath $fp) {
        $dstBak = Join-Path $bakDir $relPath
        $dstParent = Split-Path -Parent $dstBak
        if (-not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
        Copy-Item -LiteralPath $fp -Destination $dstBak -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '  [4/5] Остановка служб, выгрузка WinDivert и установка файлов...' -ForegroundColor Yellow
$wasZapret = $false
$wasTgws   = $false
$svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
if ($null -ne $svcZ -and $svcZ.Status -eq 'Running') { $wasZapret = $true }
$svcT = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
if ($null -ne $svcT -and $svcT.Status -eq 'Running') { $wasTgws = $true }

Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
Get-Process -Name 'winws2','tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
foreach ($drv in @('WinDivert', 'WinDivert14')) {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
}
Start-Sleep -Milliseconds 400

# Remove old compiled tg-ws-proxy.exe only if new archive does not ship a precompiled binary
$oldTgExe = Join-Path $Root 'bin\tg-ws-proxy.exe'
$newTgExe = Join-Path $srcRoot 'bin\tg-ws-proxy.exe'
if ((Test-Path -LiteralPath $oldTgExe) -and -not (Test-Path -LiteralPath $newTgExe)) {
    Remove-Item -LiteralPath $oldTgExe -Force -ErrorAction SilentlyContinue
}
# Migrate/cleanup legacy root .bat strategies when updating to strategies\ layout
if (Test-Path -LiteralPath (Join-Path $srcRoot 'strategies')) {
    $legacySynth = Join-Path $Root 'custom_auto_synthesized.bat'
    if (Test-Path -LiteralPath $legacySynth) {
        $newSynthDir = Join-Path $Root 'strategies'
        if (-not (Test-Path -LiteralPath $newSynthDir)) { New-Item -ItemType Directory -Path $newSynthDir -Force | Out-Null }
        Move-Item -LiteralPath $legacySynth -Destination (Join-Path $newSynthDir 'custom_auto_synthesized.bat') -Force -ErrorAction SilentlyContinue
    }
    foreach ($sf in (Get-ChildItem -LiteralPath (Join-Path $srcRoot 'strategies') -Filter '*.bat' -File)) {
        $oldRootBat = Join-Path $Root $sf.Name
        if (Test-Path -LiteralPath $oldRootBat) { Remove-Item -LiteralPath $oldRootBat -Force -ErrorAction SilentlyContinue }
    }
    foreach ($oldEntry in @('AUTO_SETUP.bat','KOTEK.bat')) { $oeP = Join-Path $Root $oldEntry; if (Test-Path -LiteralPath $oeP) { Remove-Item -LiteralPath $oeP -Force -ErrorAction SilentlyContinue } }
    foreach ($legacyRootBat in @('DEEP_OPTIMIZE.bat','1_AUTO_SETUP.bat','2_KOTEK.bat','KOTEK.bat','service.bat','README_ZAPRET2_RU.txt','AUTO_SETUP.bat','PAUSE_RESUME.bat','UNINSTALL.bat')) {
        $oldB = Join-Path $Root $legacyRootBat
        if (Test-Path -LiteralPath $oldB) { Remove-Item -LiteralPath $oldB -Force -ErrorAction SilentlyContinue }
    }
}

# Copy updated files over current folder (fail if core binaries are locked)
$copyErrors = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $srcRoot -Force | ForEach-Object {
    $destItem = Join-Path $Root $_.Name
    try {
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $destItem -Force -ErrorAction Stop
        }
    } catch {
        $copyErrors.Add("$($_.Name): $($_.Exception.Message)")
    }
}
if ($copyErrors.Count -gt 0) {
    Write-Host "  [ОШИБКА] Часть файлов заблокирована (антивирус или процесс): $($copyErrors -join '; ')" -ForegroundColor Red
    foreach ($relPath in $preserveRel) {
        $srcBak = Join-Path $bakDir $relPath
        if (Test-Path -LiteralPath $srcBak) {
            Copy-Item -LiteralPath $srcBak -Destination (Join-Path $Root $relPath) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($wasZapret) { Start-Service -Name 'zapret' -ErrorAction SilentlyContinue }
    if ($wasTgws) {
        $tgHelper = Join-Path $Root 'utils\tgws_helper.ps1'
        if (Test-Path -LiteralPath $tgHelper) { $env:Z2_ROOT = $Root; & $tgHelper ensure-service-silent | Out-Null }
        else { Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Restore preserved user settings
foreach ($relPath in $preserveRel) {
    $srcBak = Join-Path $bakDir $relPath
    if (Test-Path -LiteralPath $srcBak) {
        if ($relPath -eq 'utils\repo.conf') {
            $oldRc = [string](Get-Content -LiteralPath $srcBak -Raw)
            if ([string]::IsNullOrWhiteSpace($oldRc) -or $oldRc -like '*OWNER/*') { continue }
        }
        $targetRel = if ($relPath -eq 'custom_auto_synthesized.bat' -and (Test-Path -LiteralPath (Join-Path $Root 'strategies'))) { 'strategies\custom_auto_synthesized.bat' } else { $relPath }
        $dstFp = Join-Path $Root $targetRel
        $dstDir = Split-Path -Parent $dstFp
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $srcBak -Destination $dstFp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '  [5/5] Пересборка конфигурации и перезапуск служб...' -ForegroundColor Yellow
if ($wasZapret) {
    try {
        $curStrat = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube'
        if (-not [string]::IsNullOrWhiteSpace($curStrat)) {
            $batTry = Join-Path (Join-Path $Root 'strategies') ($curStrat + '.bat')
            if (-not (Test-Path -LiteralPath $batTry)) { $batTry = Join-Path $Root ($curStrat + '.bat') }
            if (-not (Test-Path -LiteralPath $batTry)) { $batTry = Join-Path (Join-Path $Root 'configs_archive') ($curStrat + '.bat') }
            if (Test-Path -LiteralPath $batTry) {
                $gfFile = Join-Path $Root 'utils\game_filter.enabled'
                $gfTcp = '12'; $gfUdp = '12'; $gfMode = 'disabled'; $tcpR = '1024-65535'; $udpR = '1024-65535'
                if (Test-Path -LiteralPath $gfFile) {
                    foreach ($gl in (Get-Content -LiteralPath $gfFile)) {
                        if ($gl -match '^(?i)mode=(.+)$') { $gfMode = $matches[1].Trim() }
                        elseif ($gl -match '^(?i)tcp=(.+)$') { $tcpR = $matches[1].Trim() }
                        elseif ($gl -match '^(?i)udp=(.+)$') { $udpR = $matches[1].Trim() }
                    }
                    if ($gfMode -ieq 'all') { $gfTcp = $tcpR; $gfUdp = $udpR }
                    elseif ($gfMode -ieq 'tcp') { $gfTcp = $tcpR }
                    elseif ($gfMode -ieq 'udp') { $gfUdp = $udpR }
                }
                $env:GameFilterTCP = $gfTcp; $env:GameFilterUDP = $gfUdp
                $env:GameFilter = if ($gfTcp -ne '12') { $gfTcp } else { $gfUdp }
                $env:Z2_ROOT = $Root; $env:Z2_BAT = $batTry; $env:Z2_CONF = Join-Path $Root 'bin\service.conf'
                $env:Z2_AUTOHOST = if (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')) { '1' } else { '0' }
                $env:BIN = Join-Path $Root 'bin\'; $env:LISTS = Join-Path $Root 'lists\'; $env:LUA = Join-Path $Root 'lua\'
                $env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
                $env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'
                & (Join-Path $Root 'utils\build_service_conf.ps1')
            }
        }
    } catch {}
    Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
}
if ($wasTgws) {
    $tgHelper = Join-Path $Root 'utils\tgws_helper.ps1'
    if (Test-Path -LiteralPath $tgHelper) {
        $env:Z2_ROOT = $Root
        $tgAct = if ($Silent) { 'ensure-service-silent' } else { 'ensure-service' }
        & $tgHelper $tgAct | Out-Null
    } else {
        Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
try { . (Join-Path $Root 'utils\common.ps1'); Register-Z2UninstallEntry $Root } catch {}

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host "     (=^.^=) ZAPRET2 KOTEK ОБНОВЛЁН ДО v$latestTag!                 " -ForegroundColor Green
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host '  Все личные списки, стратегия и настройки Telegram Proxy сохранены.'
try { [IO.File]::AppendAllText((Join-Path $Root 'utils\autoupdate.log'), "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Updated to v$latestTag`r`n") } catch {}
Write-Host '  Перезапусти окно Zapret2 Kotek, чтобы применить новый интерфейс.'
Write-Host ''
exit 0
