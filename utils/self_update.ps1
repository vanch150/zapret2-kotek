param(
    [string]$Root = '',
    [string]$Repo = '',
    [switch]$Silent
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
if (-not (Get-Command Test-Z2IsAdmin -ErrorAction SilentlyContinue)) {
    function Test-Z2IsAdmin {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $pr = New-Object Security.Principal.WindowsPrincipal($id)
            return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { return $false }
    }
}
$Root = if (Get-Command Resolve-Z2Root -ErrorAction SilentlyContinue) {
    Resolve-Z2Root $Root
} else {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $env:Z2_ROOT }
    $cleanR = if ($null -ne $Root) { $Root.Trim().Trim('"').Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($cleanR)) { $cleanR = Split-Path -Parent $PSScriptRoot }
    if ($cleanR -match '^[A-Za-z]:$') { $cleanR += '\' }
    try { [System.IO.Path]::GetFullPath($cleanR).TrimEnd('\', '/') + '\' } catch { $cleanR.TrimEnd('\', '/') + '\' }
}
if (-not (Test-Z2IsAdmin)) {
    Write-Host '  [X] Требуются права администратора для обновления Zapret2 Kotek.' -ForegroundColor Red
    exit 1
}

$verFile = Join-Path $Root 'utils\version.txt'
$CurrentVersion = if (Test-Path -LiteralPath $verFile) { ([string](Get-Content -LiteralPath $verFile -TotalCount 1)).Trim() } else { '1.1.1' }

# SemVer-aware comparator: 1.0.8 > 1.0.8-rc1 > 1.0.8-beta.2 (ID 4.15)
function Compare-KotekVersion([string]$a, [string]$b) {
    $aClean = ([string]$a).Trim().TrimStart('v', 'V') -replace '\+.*$', ''
    $bClean = ([string]$b).Trim().TrimStart('v', 'V') -replace '\+.*$', ''

    $aCore = $aClean; $aPre = ''
    $bCore = $bClean; $bPre = ''
    $aDash = $aClean.IndexOf('-')
    if ($aDash -ge 0) { $aCore = $aClean.Substring(0, $aDash); $aPre = $aClean.Substring($aDash + 1) }
    $bDash = $bClean.IndexOf('-')
    if ($bDash -ge 0) { $bCore = $bClean.Substring(0, $bDash); $bPre = $bClean.Substring($bDash + 1) }

    $pa = @(([regex]::Matches($aCore, '\d+') | ForEach-Object { [int]$_.Value }))
    $pb = @(([regex]::Matches($bCore, '\d+') | ForEach-Object { [int]$_.Value }))
    $len = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }

    # Equal core versions: release (no prerelease) > prerelease
    if (-not $aPre -and -not $bPre) { return 0 }
    if (-not $aPre -and $bPre)      { return 1 }
    if ($aPre -and -not $bPre)      { return -1 }

    $ap = $aPre -split '\.'
    $bp = $bPre -split '\.'
    $plen = [Math]::Max($ap.Count, $bp.Count)
    for ($j = 0; $j -lt $plen; $j++) {
        if ($j -ge $ap.Count) { return -1 }
        if ($j -ge $bp.Count) { return 1 }
        $ia = 0; $ib = 0
        $isNumA = [int]::TryParse($ap[$j], [ref]$ia)
        $isNumB = [int]::TryParse($bp[$j], [ref]$ib)
        if ($isNumA -and $isNumB) {
            if ($ia -gt $ib) { return 1 }
            if ($ia -lt $ib) { return -1 }
        } else {
            $cmp = [string]::Compare($ap[$j], $bp[$j], [System.StringComparison]::OrdinalIgnoreCase)
            if ($cmp -gt 0) { return 1 }
            if ($cmp -lt 0) { return -1 }
        }
    }
    return 0
}

# Asymmetric RSA/ECDSA signature verification for SHA256SUMS.txt (ID 4.1)
function Test-Z2ReleaseSignature([byte[]]$DataBytes, [string]$SigBase64, [string]$PubKeyXml) {
    if ([string]::IsNullOrWhiteSpace($SigBase64) -or [string]::IsNullOrWhiteSpace($PubKeyXml)) { return $false }
    try {
        $sigBytes = [System.Convert]::FromBase64String($SigBase64.Trim())
        if ($PubKeyXml -match '<RSAKeyValue') {
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
            try {
                $rsa.FromXmlString($PubKeyXml)
                $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
                return $rsa.VerifyData($DataBytes, $oid, $sigBytes)
            } finally {
                $rsa.Dispose()
            }
        } elseif ($PubKeyXml -match '<ECDSAKeyValue') {
            $ec = New-Object System.Security.Cryptography.ECDsaCng
            try {
                $ec.FromXmlString($PubKeyXml, [System.Security.Cryptography.ECKeyXmlFormat]::Rfc4050)
                $ec.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
                return $ec.VerifyData($DataBytes, $sigBytes)
            } finally {
                $ec.Dispose()
            }
        }
    } catch {}
    return $false
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

# Mandatory release ZIP asset + SHA256SUMS.txt (no unsigned zipball fallback, ID 4.1)
$zipAsset = $null
$shaAsset = $null
$sigAsset = $null
foreach ($a in @($rel.assets)) {
    if (-not $zipAsset -and $a.name -like '*.zip') { $zipAsset = $a }
    elseif ($a.name -ieq 'SHA256SUMS.txt') { $shaAsset = $a }
    elseif ($a.name -ieq 'SHA256SUMS.txt.sig') { $sigAsset = $a }
}
if (-not $zipAsset -or -not $shaAsset) {
    Write-Host '  [ОШИБКА] В релизе отсутствуют обязательные ZIP-архив или SHA256SUMS.txt — обновление отменено!' -ForegroundColor Red
    exit 1
}
$dlUrl = [string]$zipAsset.browser_download_url
$shaUrl = [string]$shaAsset.browser_download_url
$trustedGhRx = '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/'
if (($dlUrl -notmatch $trustedGhRx) -or ($shaUrl -notmatch $trustedGhRx)) {
    Write-Host '  [ОШИБКА] Недоверенный URL ассета релиза — обновление отменено!' -ForegroundColor Red
    exit 1
}

$workDir     = Join-Path $env:TEMP ('zapret2_kotek_upd_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$zipPath     = Join-Path $workDir 'release.zip'
$extDir      = Join-Path $workDir 'extracted'
$rollbackDir = Join-Path $workDir 'rollback'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

Write-Host "  [2/5] Скачивание v$latestTag ($($zipAsset.name))..." -ForegroundColor Yellow
$curlExe = "$env:SystemRoot\System32\curl.exe"

function Invoke-Z2SecureDownload([string]$Url, [string]$OutFile, [int]$TimeoutSec = 15, [int]$MinBytes = 1) {
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $curlExe) {
        & $curlExe --proto =https --proto-redir =https -L -s -f --max-time $TimeoutSec -o $OutFile $Url 2>$null
        if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -ge $MinBytes) { return $true }
    }
    try {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        $res = Invoke-WebRequest -Uri $Url -Headers $hdr -OutFile $OutFile -PassThru -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $isHttps = ($null -ne $res -and $null -ne $res.BaseResponse -and $null -ne $res.BaseResponse.ResponseUri -and ($res.BaseResponse.ResponseUri.Scheme -eq 'https'))
        if (-not $isHttps) {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            throw 'Перенаправление на небезопасный протокол (не HTTPS) заблокировано'
        }
        if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -ge $MinBytes) { return $true }
    } catch {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw
    }
    return $false
}

$dlOk = $false
try {
    $dlOk = Invoke-Z2SecureDownload $dlUrl $zipPath 60 50001
} catch {}

if (-not $dlOk) {
    Write-Host '  [ОШИБКА] Не удалось скачать архив обновления.' -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Mandatory SHA-256 verification + optional/pinned asymmetric signature verification (ID 4.1)
try {
    $sumsBytes = $null
    $shaTmp = Join-Path $workDir 'SHA256SUMS.txt'
    if (-not (Invoke-Z2SecureDownload $shaUrl $shaTmp 15 1)) {
        throw 'Не удалось скачать SHA256SUMS.txt'
    }
    $sumsBytes = [System.IO.File]::ReadAllBytes($shaTmp)
    $sumsRaw   = ([System.Text.Encoding]::UTF8.GetString($sumsBytes)).TrimStart([char]0xFEFF)

    # Check pinned asymmetric public key (utils\release_pubkey.xml)
    $pubKeyFile = Join-Path $Root 'utils\release_pubkey.xml'
    if (Test-Path -LiteralPath $pubKeyFile) {
        $pubKeyXml = [System.IO.File]::ReadAllText($pubKeyFile, [System.Text.Encoding]::UTF8)
        if (-not $sigAsset) {
            throw 'Отсутствует обязательный файл подписи SHA256SUMS.txt.sig при наличии release_pubkey.xml'
        }
        $sigUrl = [string]$sigAsset.browser_download_url
        if ($sigUrl -notmatch $trustedGhRx) { throw "Недоверенный URL подписи: $sigUrl" }
        $sigTmp = Join-Path $workDir 'SHA256SUMS.txt.sig'
        if (-not (Invoke-Z2SecureDownload $sigUrl $sigTmp 15 1)) {
            throw 'Не удалось скачать SHA256SUMS.txt.sig'
        }
        $sigRaw = [System.IO.File]::ReadAllText($sigTmp, [System.Text.Encoding]::UTF8)
        if (-not (Test-Z2ReleaseSignature $sumsBytes ([string]$sigRaw) $pubKeyXml)) {
            throw 'Криптографическая подпись SHA256SUMS.txt.sig недействительна!'
        }
        Write-Host '        [OK] Криптографическая подпись SHA256SUMS.txt.sig подтверждена.' -ForegroundColor Green
    }

    $expectedHash = ''
    foreach ($sl in ($sumsRaw -split "`r?`n")) {
        if ($sl -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $matches[2].Trim() -ieq $zipAsset.name) {
            $expectedHash = $matches[1].ToLowerInvariant()
            break
        }
    }
    if (-not $expectedHash) {
        throw 'В SHA256SUMS.txt не найдена запись для скачанного архива'
    }
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw 'Несовпадение контрольной суммы SHA-256!'
    }
    Write-Host '        [OK] Контрольная сумма SHA-256 подтверждена.' -ForegroundColor Green
} catch {
    Write-Host "  [ОШИБКА] Проверка целостности/подписи не пройдена: $($_.Exception.Message) — обновление отменено!" -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host '  [3/5] Распаковка архива и проверка структуры...' -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $maxFiles = 2000
    $maxBytes = 262144000L # 250 MB
    $totalBytes = 0L
    $fullExt = [System.IO.Path]::GetFullPath($extDir).TrimEnd('\') + '\'
    $za = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($za.Entries.Count -gt $maxFiles) {
            throw "Zip-Bomb blocked: too many entries ($($za.Entries.Count) > $maxFiles)"
        }
        $copyBuf = New-Object byte[] 65536
        foreach ($entry in $za.Entries) {
            if ($entry.FullName.Contains(':')) {
                throw "ADS blocked in archive entry: $($entry.FullName)"
            }
            if ($entry.FullName.StartsWith('/') -or $entry.FullName.StartsWith('\')) {
                throw "Absolute entry path blocked: $($entry.FullName)"
            }
            $destPath = [System.IO.Path]::GetFullPath((Join-Path $extDir $entry.FullName))
            if (-not $destPath.StartsWith($fullExt, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Zip-Slip blocked: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if (-not (Test-Path -LiteralPath $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
            } else {
                $destParent = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
                if ((Get-Item -LiteralPath $destParent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "ReparsePoint blocked: $destParent"
                }
                $inStream = $entry.Open()
                try {
                    $outStream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        while ($true) {
                            $read = $inStream.Read($copyBuf, 0, $copyBuf.Length)
                            if ($read -le 0) { break }
                            $totalBytes += $read
                            if ($totalBytes -gt $maxBytes) {
                                throw "Zip-Bomb blocked: unpacked size exceeds 250 MB"
                            }
                            $outStream.Write($copyBuf, 0, $read)
                        }
                    } finally {
                        $outStream.Dispose()
                    }
                } finally {
                    $inStream.Dispose()
                }
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
    'lists\ai-custom-domains.txt',
    'utils\tgws_proxy.conf',
    'utils\strategy_scores.json',
    'utils\active_udp_fake.txt',
    'utils\autohostlist.enabled',
    'utils\warp_unblock.enabled',
    'utils\game_filter.enabled',
    'lists\ipset-all.txt.backup',
    'utils\browser_policy.backup.json',
    'utils\browser_policy.applied',
    'utils\nlm_filter.init',
    'utils\last_autosetup.json',
    'utils\last_hybrid.json',
    'utils\telemetry.state.json',
    'utils\vpn_ifidx.enabled',
    'utils\vpn_ifidx.custom',
    'utils\vpn_ifidx.names',
    'utils\.tgws_connected',
    'utils\repo.conf',
    'utils\autoupdate.mode',
    'utils\targets.txt',
    'utils\kernel_filter.enabled',
    'utils\tray_mode.enabled',
    'utils\tray_start_minimized.enabled',
    'utils\ai_bypass.conf',
    'utils\telemetry.enabled',
    'utils\telemetry.id',
    'utils\telemetry.prompted',
    'utils\wf_priority.conf',
    'utils\release_pubkey.xml',
    'bin\ACTIVE_DISCORD_UDP.bin',
    'bin\ACTIVE_GAME_UDP.bin',
    'strategies\custom_auto_synthesized.bat',
    'custom_auto_synthesized.bat'
)
$boolFlagsToTrack = @('utils\autohostlist.enabled', 'utils\warp_unblock.enabled', 'utils\kernel_filter.enabled', 'utils\vpn_ifidx.enabled', 'utils\telemetry.enabled', 'utils\game_filter.enabled', 'utils\tray_mode.enabled', 'utils\tray_start_minimized.enabled')
$absentBoolFlags = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $verFile) {
    foreach ($bf in $boolFlagsToTrack) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $bf))) { $absentBoolFlags.Add($bf) }
    }
}
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

# Full system folder and root files backup for atomic rollback on copy failure (ID 4.4)
$rollbackDirs = @('utils', 'bin', 'lua', 'strategies', 'configs_archive', 'lists')
$updMarker = Join-Path $Root '.update_in_progress'
try {
    New-Item -ItemType Directory -Path $rollbackDir -Force -ErrorAction Stop | Out-Null
    foreach ($rd in $rollbackDirs) {
        $srcD = Join-Path $Root $rd
        if (Test-Path -LiteralPath $srcD) {
            Copy-Item -LiteralPath $srcD -Destination $rollbackDir -Recurse -Force -ErrorAction Stop
        }
    }
    foreach ($rf in @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction Stop)) {
        if ($rf.Name -ieq '.update_in_progress') { continue }
        Copy-Item -LiteralPath $rf.FullName -Destination (Join-Path $rollbackDir $rf.Name) -Force -ErrorAction Stop
    }
} catch {
    Write-Host "  [ОШИБКА] Не удалось создать резервную копию перед обновлением: $($_.Exception.Message) — обновление отменено!" -ForegroundColor Red
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host '  [4/5] Остановка служб, выгрузка WinDivert и установка файлов...' -ForegroundColor Yellow
$wasZapret = $false
$wasTgws   = $false
$svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
if ($null -ne $svcZ) {
    if ($svcZ.Status -eq 'Running') { $wasZapret = $true }
    try { $svcZ.Dispose() } catch {}
}
$svcT = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
if ($null -ne $svcT) {
    if ($svcT.Status -eq 'Running') { $wasTgws = $true }
    try { $svcT.Dispose() } catch {}
}

if (Get-Command Stop-Z2ServiceAndProcess -ErrorAction SilentlyContinue) {
    Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
} else {
    Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'winws2','winws' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
foreach ($drv in @('WinDivert', 'WinDivert14')) {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
}
Start-Sleep -Milliseconds 300

# Write .update_in_progress marker before modifying files on disk
try {
    [System.IO.File]::WriteAllText($updMarker, "v$CurrentVersion -> v$latestTag`r`n$(Get-Date -Format 'o')`r`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {}

# Copy updated files over current folder FIRST (before deleting any legacy files, ID 4.4)
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
    Write-Host '  [*] Откат системных папок, файлов корня и пользовательских настроек...' -ForegroundColor Yellow
    foreach ($rd in $rollbackDirs) {
        $rbSrc = Join-Path $rollbackDir $rd
        if (Test-Path -LiteralPath $rbSrc) {
            Copy-Item -LiteralPath $rbSrc -Destination $Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($rf in @(Get-ChildItem -LiteralPath $rollbackDir -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $rf.FullName -Destination (Join-Path $Root $rf.Name) -Force -ErrorAction SilentlyContinue
    }
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
    if (Test-Path -LiteralPath $updMarker) { Remove-Item -LiteralPath $updMarker -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Remove old compiled tg-ws-proxy.exe and legacy root .bat files ONLY AFTER successful copy (ID 4.4)
$oldTgExe = Join-Path $Root 'bin\tg-ws-proxy.exe'
$newTgExe = Join-Path $srcRoot 'bin\tg-ws-proxy.exe'
if ((Test-Path -LiteralPath $oldTgExe) -and -not (Test-Path -LiteralPath $newTgExe)) {
    Remove-Item -LiteralPath $oldTgExe -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath (Join-Path $srcRoot 'strategies')) {
    $legacySynth = Join-Path $Root 'custom_auto_synthesized.bat'
    if (Test-Path -LiteralPath $legacySynth) {
        $newSynthDir = Join-Path $Root 'strategies'
        $newSynthFp = Join-Path $newSynthDir 'custom_auto_synthesized.bat'
        if (-not (Test-Path -LiteralPath $newSynthDir)) { New-Item -ItemType Directory -Path $newSynthDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $newSynthFp)) {
            Move-Item -LiteralPath $legacySynth -Destination $newSynthFp -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $legacySynth -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($sf in (Get-ChildItem -LiteralPath (Join-Path $srcRoot 'strategies') -Filter '*.bat' -File)) {
        $oldRootBat = Join-Path $Root $sf.Name
        if (Test-Path -LiteralPath $oldRootBat) { Remove-Item -LiteralPath $oldRootBat -Force -ErrorAction SilentlyContinue }
    }
    foreach ($legacyRootBat in @('DEEP_OPTIMIZE.bat','1_AUTO_SETUP.bat','2_KOTEK.bat','KOTEK.bat','service.bat','README_ZAPRET2_RU.txt','AUTO_SETUP.bat','PAUSE_RESUME.bat')) {
        $oldB = Join-Path $Root $legacyRootBat
        if (Test-Path -LiteralPath $oldB) { Remove-Item -LiteralPath $oldB -Force -ErrorAction SilentlyContinue }
    }
}

# Restore preserved user settings
foreach ($relPath in $preserveRel) {
    $srcBak = Join-Path $bakDir $relPath
    if (Test-Path -LiteralPath $srcBak) {
        if ($relPath -eq 'utils\repo.conf') {
            $oldRc = [string](Get-Content -LiteralPath $srcBak -Raw)
            if ([string]::IsNullOrWhiteSpace($oldRc) -or $oldRc -like '*OWNER/*') { continue }
        }
        if ($relPath -eq 'custom_auto_synthesized.bat' -and (Test-Path -LiteralPath (Join-Path $Root 'strategies'))) {
            if (Test-Path -LiteralPath (Join-Path $Root 'strategies\custom_auto_synthesized.bat')) { continue }
            $targetRel = 'strategies\custom_auto_synthesized.bat'
        } else {
            $targetRel = $relPath
        }
        $dstFp = Join-Path $Root $targetRel
        $dstDir = Split-Path -Parent $dstFp
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        if ($relPath -eq 'utils\targets.txt' -and (Test-Path -LiteralPath $dstFp)) {
            try {
                $newTgtLines = @(Get-Content -LiteralPath $dstFp -Encoding UTF8 -ErrorAction SilentlyContinue)
                $oldTgtLines = @(Get-Content -LiteralPath $srcBak -Encoding UTF8 -ErrorAction SilentlyContinue)
                $haveUrls = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                $mergedTgt = New-Object System.Collections.Generic.List[string]
                foreach ($ol in $oldTgtLines) {
                    $olUpd = $ol
                    if ($olUpd -match '(?i)https://i\.ytimg\.com/favicon\.ico\s*$') {
                        $olUpd = $olUpd -replace '(?i)https://i\.ytimg\.com/favicon\.ico', 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg'
                    } elseif ($olUpd -match '(?i)https://speed\.cloudflare\.com/__down\?bytes=65536\s*$') {
                        $olUpd = $olUpd -replace '(?i)bytes=65536', 'bytes=262144'
                    }
                    $mergedTgt.Add($olUpd)
                    if ($olUpd -match '^[^#]*\|(https?://\S+)') { [void]$haveUrls.Add($matches[1].Trim()) }
                }
                foreach ($nl in $newTgtLines) {
                    if ($nl -match '^[^#]*\|(https?://\S+)') {
                        if ($haveUrls.Add($matches[1].Trim())) { $mergedTgt.Add($nl) }
                    }
                }
                [System.IO.File]::WriteAllLines($dstFp, $mergedTgt, (New-Object System.Text.UTF8Encoding($false)))
                continue
            } catch {}
        }
        Copy-Item -LiteralPath $srcBak -Destination $dstFp -Force -ErrorAction SilentlyContinue
    }
}

foreach ($abFlag in $absentBoolFlags) {
    $abPath = Join-Path $Root $abFlag
    if (Test-Path -LiteralPath $abPath) { Remove-Item -LiteralPath $abPath -Force -ErrorAction SilentlyContinue }
}

# One-time migration from <= 1.1.0 to 1.1.1: clear forced-on nlm_auto and raise circular thresholds in custom_auto_synthesized.bat
if ((Compare-KotekVersion $CurrentVersion '1.1.0') -le 0) {
    foreach ($mf in @('utils\nlm_auto.enabled', 'utils\nlm_filter.enabled', 'utils\nlm_filter.names')) {
        $mfp = Join-Path $Root $mf
        if (Test-Path -LiteralPath $mfp) { Remove-Item -LiteralPath $mfp -Force -ErrorAction SilentlyContinue }
    }
    try { [System.IO.File]::WriteAllText((Join-Path $Root 'utils\vpn_ifidx.enabled'), "1`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
    $migSynth = Join-Path $Root 'strategies\custom_auto_synthesized.bat'
    if (Test-Path -LiteralPath $migSynth) {
        try {
            $sRaw = [System.IO.File]::ReadAllText($migSynth, [System.Text.Encoding]::UTF8)
            if ($sRaw -like '*circular:fails=1:time=60:reset:retrans=2*') {
                $sRaw = $sRaw.Replace('circular:fails=1:time=60:reset:retrans=2', 'circular:fails=3:time=60:reset:retrans=4')
                [System.IO.File]::WriteAllText($migSynth, $sRaw, (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch {}
    }
    $migBh = Join-Path $Root 'utils\browser_helper.ps1'
    if (Test-Path -LiteralPath $migBh) {
        try {
            . $migBh -Root $Root
            [void](Disable-BrowserFix $true @() $Root $false $true)
        } catch {}
    }
}

Write-Host '  [5/5] Пересборка конфигурации и перезапуск служб...' -ForegroundColor Yellow
if ($wasZapret) {
    $confBuiltOk = $true
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
                $global:LASTEXITCODE = 0
                & (Join-Path $Root 'utils\build_service_conf.ps1')
                if ($LASTEXITCODE -ne 0) {
                    $confBuiltOk = $false
                    Write-Host "  [!] Предупреждение: ошибка пересборки bin\service.conf (код $LASTEXITCODE) — служба zapret не запущена." -ForegroundColor Yellow
                }
            }
        }
    } catch {
        $confBuiltOk = $false
        Write-Host "  [!] Предупреждение: ошибка пересборки bin\service.conf ($($_.Exception.Message)) — служба zapret не запущена." -ForegroundColor Yellow
    }
    if ($confBuiltOk) {
        try {
            $zDepend = if (Get-Command Get-Z2ZapretDepend -ErrorAction SilentlyContinue) { Get-Z2ZapretDepend } else { 'BFE/nlasvc' }
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "config zapret depend= $zDepend" -WindowStyle Hidden -Wait | Out-Null
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "failureflag zapret 1" -WindowStyle Hidden -Wait | Out-Null
        } catch {}
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    }
}
$tgHelper = Join-Path $Root 'utils\tgws_helper.ps1'
$tgSvcObj = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
$tgSvcInstalled = ($null -ne $tgSvcObj)
if ($null -ne $tgSvcObj) { try { $tgSvcObj.Dispose() } catch {} }
if ($wasTgws) {
    if (Test-Path -LiteralPath $tgHelper) {
        $env:Z2_ROOT = $Root
        $tgAct = if ($Silent) { 'ensure-service-silent' } else { 'ensure-service' }
        & $tgHelper $tgAct | Out-Null
    } else {
        Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    }
} else {
    # Ensure paused/stopped zapret-tgws binary & NetworkService ACLs stay intact after update
    $icSu = "$env:SystemRoot\System32\icacls.exe"
    $suBin = Join-Path $Root 'bin'
    $suLogs = Join-Path $suBin 'logs'
    $suExe = Join-Path $suBin 'tg-ws-proxy.exe'
    $suConf = Join-Path $Root 'utils\tgws_proxy.conf'
    if ($tgSvcInstalled -and -not (Test-Path -LiteralPath $suExe) -and (Test-Path -LiteralPath $tgHelper)) {
        try { $env:Z2_ROOT = $Root; & $tgHelper compile-only | Out-Null } catch {}
    }
    if (Test-Path -LiteralPath $icSu) {
        if (Test-Path -LiteralPath $suExe)  { try { & $icSu "$suExe"  /L /grant:r "*S-1-5-20:(RX)" /Q >$null 2>&1 } catch {} }
        if (Test-Path -LiteralPath $suConf) { try { & $icSu "$suConf" /L /grant:r "*S-1-5-20:(R)"  /Q >$null 2>&1 } catch {} }
        if (Test-Path -LiteralPath $suBin) {
            if (-not (Test-Path -LiteralPath $suLogs)) { try { New-Item -ItemType Directory -Path $suLogs -Force | Out-Null } catch {} }
            if (Test-Path -LiteralPath $suLogs) { try { & $icSu "$suLogs" /L /grant:r "*S-1-5-20:(OI)(CI)(M)" /Q >$null 2>&1 } catch {} }
        }
    }
}

if (Test-Path -LiteralPath $updMarker) { Remove-Item -LiteralPath $updMarker -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
try { . (Join-Path $Root 'utils\common.ps1'); Register-Z2UninstallEntry $Root; Set-Z2DesktopAndFolderIcons $Root -FolderOnly } catch {}

Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host "     (=^.^=) ZAPRET2 KOTEK ОБНОВЛЁН ДО v$latestTag!                 " -ForegroundColor Green
Write-Host '  ==================================================================' -ForegroundColor Green
Write-Host '  Все личные списки, стратегия и настройки Telegram Proxy сохранены.'
try { [IO.File]::AppendAllText((Join-Path $Root 'utils\autoupdate.log'), "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Updated to v$latestTag`r`n") } catch {}
if (-not $Silent) { Write-Host "  [Z2_UPDATED] v$latestTag" -ForegroundColor Green }
Write-Host '  Перезапусти окно Zapret2 Kotek, чтобы применить новый интерфейс.'
Write-Host ''
exit 0
