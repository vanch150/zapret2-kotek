#Requires -Version 5.1
# Zapret2 Kotek — Safe Interactive GitHub Commit & Release Publisher (dev/publish_github.ps1)
param(
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$verFile   = Join-Path $Root 'utils\version.txt'
$curVer    = if (Test-Path -LiteralPath $verFile) { ([string](Get-Content -LiteralPath $verFile -TotalCount 1 -Encoding UTF8)).Trim() } else { '1.0.9' }

# Detect GitHub repo from utils\repo.conf
$repoSlug = 'vanch150/zapret2-kotek'
$repoConf = Join-Path $Root 'utils\repo.conf'
if (Test-Path -LiteralPath $repoConf) {
    foreach ($rl in (Get-Content -LiteralPath $repoConf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($rl -match '^\s*repo\s*=\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*$') {
            $repoSlug = $matches[1].Trim()
            break
        }
    }
}

Clear-Host
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "     (=^.^=) ZAPRET2 KOTEK v$curVer — ПУБЛИКАЦИЯ НА GITHUB" -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "  Папка       : $Root" -ForegroundColor Gray
Write-Host "  Репозиторий : https://github.com/$repoSlug" -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCmd) {
    Write-Host '  [X] git не найден в PATH. Установи Git for Windows.' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
    Write-Host "  [X] В папке $Root нет .git репозитория." -ForegroundColor Red
    exit 1
}

Push-Location -LiteralPath $Root
try {
    # 1. Run audit gate first
    $verifyScript = Join-Path $Root 'dev\verify_audit.ps1'
    if (Test-Path -LiteralPath $verifyScript) {
        Write-Host "`n  [1] Проверка dev\verify_audit.ps1..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        & $verifyScript -Root $Root
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n  [!] Аудит нашёл ошибки! Публиковать сломанный код не рекомендуется." -ForegroundColor Red
            $cont = Read-Host '  Всё равно продолжить? [д/Н] (Enter = Отмена)'
            if ($cont -notmatch '^[yYдД]') { exit 1 }
        }
    }

    # 2. Detect personal secrets / proxy domains in utils\tgws_proxy.conf (write deferred until final confirmation!)
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    $shouldCleanTgConf = $false
    if (Test-Path -LiteralPath $tgConf) {
        $tgRaw = [System.IO.File]::ReadAllText($tgConf, [System.Text.Encoding]::UTF8)
        if ($tgRaw -match '(?m)^(secret|cfproxy_domain|cfproxy_worker_domain)=\S+') {
            Write-Host "`n  [!] В utils\tgws_proxy.conf обнаружены личные значения (secret / cfproxy_*_domain)!" -ForegroundColor Yellow
            $clr = Read-Host '  Очистить secret= и cfproxy_*_domain= перед коммитом (рекомендуется)? [Д/н] (Enter = Да)'
            if ([string]::IsNullOrWhiteSpace($clr) -or $clr -notmatch '^[nNнН]') {
                $shouldCleanTgConf = $true
            }
        }
    }

    # 3. Show current git status
    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    Write-Host "`n  Ветка: $branch" -ForegroundColor Cyan
    $statusLines = @(& git status --short)
    if ($statusLines.Count -eq 0) {
        Write-Host '  Изменений в рабочей папке нет (working tree clean).' -ForegroundColor DarkGray
    } else {
        Write-Host "  Изменённых файлов: $($statusLines.Count)" -ForegroundColor Gray
        foreach ($sl in ($statusLines | Select-Object -First 20)) {
            Write-Host "    $sl" -ForegroundColor DarkGray
        }
        if ($statusLines.Count -gt 20) {
            Write-Host "    ... и ещё $($statusLines.Count - 20)" -ForegroundColor DarkGray
        }
    }

    # 4. Main menu — default is [0] Exit so accidental Enter does nothing
    Write-Host ''
    Write-Host '  [1] Только коммит + push в код на GitHub' -ForegroundColor Green
    Write-Host '  [2] Коммит + push + сборка и публикация Релиза (ZIP + SHA256SUMS.txt)' -ForegroundColor Cyan
    Write-Host '  [0] Выход (по умолчанию)' -ForegroundColor Gray
    Write-Host ''
    $mode = Read-Host '  Выбери действие (0-2, Enter = 0 Выход)'
    if ([string]::IsNullOrWhiteSpace($mode) -or $mode.Trim() -eq '0') {
        Write-Host '  [ОТМЕНА] Выход без изменений.' -ForegroundColor Gray
        exit 0
    }
    $mode = $mode.Trim()
    if ($mode -ne '1' -and $mode -ne '2') {
        Write-Host '  [!] Неверный выбор — выход без изменений.' -ForegroundColor Yellow
        exit 0
    }

    $targetVer = $curVer
    $doRelease = ($mode -eq '2')
    $usePublic = $true
    $relNotes  = ''

    # 5. For Release mode: ask version & strictly forbid existing local/remote tag
    if ($doRelease) {
        while ($true) {
            Write-Host ''
            $verInput = Read-Host "  Новая версия релиза (текущая: $curVer; Enter = отмена)"
            if ([string]::IsNullOrWhiteSpace($verInput)) {
                Write-Host '  [ОТМЕНА] Версия не указана — выход без изменений.' -ForegroundColor Gray
                exit 0
            }
            $candVer = $verInput.Trim().TrimStart('v', 'V')
            if ($candVer -notmatch '^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9.-]+)?$') {
                Write-Host "  [X] Некорректный формат версии: '$candVer' (пример: 1.0.10 или 1.1)." -ForegroundColor Red
                continue
            }
            $candTag = "v$candVer"
            $localTag = (& git tag -l $candTag 2>$null | Out-String).Trim()
            if ($localTag) {
                Write-Host "  [X] Локальный тег $candTag уже существует! Перезаливка старой версии запрещена — введи новую версию." -ForegroundColor Red
                continue
            }
            Write-Host "  [*] Проверяю тег $candTag на GitHub..." -ForegroundColor DarkGray
            $global:LASTEXITCODE = 0
            $remoteTag = (& git ls-remote --tags origin "refs/tags/$candTag" 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                Write-Host '  [X] Не удалось проверить удалённые теги (git ls-remote) — проверь интернет/доступ к GitHub.' -ForegroundColor Red
                exit 1
            }
            if ($remoteTag) {
                Write-Host "  [X] Удалённый тег $candTag уже существует на GitHub! Перезаливка запрещена — введи новую версию." -ForegroundColor Red
                continue
            }
            $targetVer = $candVer
            break
        }

        $pubAns = Read-Host '  Собрать как PublicRelease (очистить cfproxy_*_domain)? [Д/н] (Enter = Да)'
        $usePublic = ([string]::IsNullOrWhiteSpace($pubAns) -or $pubAns -notmatch '^[nNнН]')
        $relNotesFile = Join-Path $Root 'dev\RELEASE_NOTES.md'
        $hasNotesFile = (Test-Path -LiteralPath $relNotesFile) -and ((Get-Item -LiteralPath $relNotesFile).Length -gt 0)
        if ($hasNotesFile) {
            $relNotes = Read-Host '  Описание релиза для GitHub (Enter = взять из dev\RELEASE_NOTES.md)'
        } else {
            $relNotes = Read-Host '  Описание релиза для GitHub (Enter = автогенерация из коммитов)'
        }
    }

    $defaultMsg = if ($doRelease) { "Release v$targetVer" } else { "Update v$targetVer" }
    $commitMsg = Read-Host "  Сообщение коммита (Enter = '$defaultMsg')"
    if ([string]::IsNullOrWhiteSpace($commitMsg)) { $commitMsg = $defaultMsg }

    # 6. Summary Card + Explicit Confirmation Gate (NO disk writes have happened yet!)
    $verSummary = if ($targetVer -ne $curVer) { "v$curVer -> v$targetVer (будут обновлены version.txt, README, service.bat)" } else { "v$curVer (без изменений)" }
    $pubSummary = if ($doRelease) { if ($usePublic) { 'Да (-PublicRelease)' } else { 'Нет (обычный релиз)' } } else { '—' }
    $relSummary = if ($doRelease) { "Да (тег v$targetVer + ZIP + SHA256SUMS.txt)" } else { 'Нет (только код)' }
    $cleanSummary = if ($shouldCleanTgConf) { 'Да (очистит secret / cfproxy_*_domain)' } else { 'Нет' }

    Write-Host ''
    Write-Host '  ==================================================================' -ForegroundColor Yellow
    Write-Host '                  ПРОВЕРКА ПЕРЕД ПУБЛИКАЦИЕЙ                        ' -ForegroundColor Yellow
    Write-Host '  ==================================================================' -ForegroundColor Yellow
    Write-Host "  Ветка                : $branch" -ForegroundColor White
    Write-Host "  Версия               : $verSummary" -ForegroundColor White
    Write-Host "  Режим PublicRelease  : $pubSummary" -ForegroundColor White
    Write-Host "  Очистка tgws_proxy   : $cleanSummary" -ForegroundColor White
    Write-Host "  Файлов в git status  : $($statusLines.Count)" -ForegroundColor White
    Write-Host "  Сообщение коммита    : $commitMsg" -ForegroundColor White
    Write-Host "  Релиз на GitHub      : $relSummary" -ForegroundColor White
    Write-Host '  ==================================================================' -ForegroundColor Yellow
    Write-Host ''

    if ($doRelease) {
        $confirm = Read-Host "  Для подтверждения релиза введи точную версию '$targetVer' (Enter = отмена)"
        if ($confirm -cne $targetVer) {
            Write-Host '  [ОТМЕНА] Подтверждение не совпало — ни один файл на диске не изменён.' -ForegroundColor Yellow
            exit 0
        }
    } else {
        $confirm = Read-Host "  Для подтверждения отправки кода введи PUSH (Enter = отмена)"
        if ($confirm -cne 'PUSH') {
            Write-Host '  [ОТМЕНА] Подтверждение не совпало — ни один файл на диске не изменён.' -ForegroundColor Yellow
            exit 0
        }
    }

    # 7. Apply approved file edits ONLY after explicit confirmation
    if ($shouldCleanTgConf -and (Test-Path -LiteralPath $tgConf)) {
        $tgRawNow = [System.IO.File]::ReadAllText($tgConf, [System.Text.Encoding]::UTF8)
        $tgClean = [regex]::Replace($tgRawNow, '(?m)^secret=[^\r\n]*', 'secret=')
        $tgClean = [regex]::Replace($tgClean, '(?m)^cfproxy_domain=[^\r\n]*', 'cfproxy_domain=')
        $tgClean = [regex]::Replace($tgClean, '(?m)^cfproxy_worker_domain=[^\r\n]*', 'cfproxy_worker_domain=')
        [System.IO.File]::WriteAllText($tgConf, $tgClean, $utf8NoBom)
        Write-Host '  [OK] secret= и cfproxy_*_domain= очищены в utils\tgws_proxy.conf.' -ForegroundColor Green
    }

    if ($doRelease -and $targetVer -ne $curVer) {
        Write-Host "  [*] Обновляю версию $curVer -> $targetVer в файлах проекта..." -ForegroundColor Cyan
        [System.IO.File]::WriteAllText($verFile, "$targetVer`r`n", $utf8NoBom)

        $readmePath = Join-Path $Root 'README.md'
        if (Test-Path -LiteralPath $readmePath) {
            $bt = [char]96
            $rm = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
            $rm = [regex]::Replace($rm, ($bt + 'v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?' + $bt), ($bt + "v$targetVer" + $bt))
            $rm = [regex]::Replace($rm, 'zapret2-kotek-v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?\.zip', "zapret2-kotek-v$targetVer.zip")
            $rm = [regex]::Replace($rm, 'Скачать v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?', "Скачать v$targetVer")
            [System.IO.File]::WriteAllText($readmePath, $rm, $utf8NoBom)
        }

        $readmeRu = Join-Path $Root 'utils\README_ZAPRET2_RU.txt'
        if (Test-Path -LiteralPath $readmeRu) {
            $ru = [System.IO.File]::ReadAllText($readmeRu, [System.Text.Encoding]::UTF8)
            $ru = [regex]::Replace($ru, 'ZAPRET2 KOTEK v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?', "ZAPRET2 KOTEK v$targetVer")
            [System.IO.File]::WriteAllText($readmeRu, $ru, $utf8NoBom)
        }

        $svcBat = Join-Path $Root 'utils\service.bat'
        if (Test-Path -LiteralPath $svcBat) {
            $sb = [System.IO.File]::ReadAllText($svcBat, [System.Text.Encoding]::UTF8)
            $sb = [regex]::Replace($sb, '(?m)^set "LOCAL_VERSION=[^\r\n]*"', "set `"LOCAL_VERSION=$targetVer`"")
            [System.IO.File]::WriteAllText($svcBat, $sb, $utf8NoBom)
        }
        Write-Host "  [OK] Версия обновлена до v$targetVer." -ForegroundColor Green
    }

    # 8. Build clean release ZIP + SHA256SUMS.txt BEFORE commit/push (so build failure never pushes a broken release)
    $parentDir = Split-Path -Parent $Root
    $zipPath   = Join-Path $parentDir "zapret2-kotek-v$targetVer.zip"
    $sumsPath  = Join-Path $parentDir 'SHA256SUMS.txt'
    if ($doRelease) {
        $buildScript = Join-Path $Root 'dev\build_release.ps1'
        Write-Host "`n  [*] Запускаю сборку релиза v$targetVer (до отправки на GitHub)..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        if ($usePublic) {
            & $buildScript -Version $targetVer -PublicRelease
        } else {
            & $buildScript -Version $targetVer
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] Ошибка сборки релиза (build_release.ps1). Коммит и публикация отменены.' -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path -LiteralPath $zipPath) -or -not (Test-Path -LiteralPath $sumsPath)) {
            Write-Host "  [X] Не найдены собранные файлы релиза: $zipPath / $sumsPath" -ForegroundColor Red
            exit 1
        }
    }

    # 8b. Scan tracked / non-ignored files for personal Windows user paths before git add -A
    $userPathHits = New-Object System.Collections.Generic.List[string]
    $binExts = @('.exe', '.dll', '.sys', '.bin', '.png', '.ico', '.jpg', '.jpeg', '.gif', '.zip', '.7z', '.pdf')
    $candFiles = @(& git ls-files -c -o --exclude-standard 2>$null | Sort-Object -Unique)
    foreach ($cf in $candFiles) {
        if ([string]::IsNullOrWhiteSpace($cf)) { continue }
        $fullCf = Join-Path $Root ($cf.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $fullCf -PathType Leaf)) { continue }
        $ext = [System.IO.Path]::GetExtension($fullCf).ToLowerInvariant()
        if ($binExts -contains $ext) { continue }
        try {
            $txt = [System.IO.File]::ReadAllText($fullCf, [System.Text.Encoding]::UTF8)
            if ($txt -match '[A-Za-z]:[/\\]Users[/\\]') {
                $userPathHits.Add($cf)
            }
        } catch {}
    }
    if ($userPathHits.Count -gt 0) {
        Write-Host "`n  [!] ВНИМАНИЕ: Обнаружены локальные пути пользователя ([A-Za-z]:\Users\) в файлах:" -ForegroundColor Red
        foreach ($uh in $userPathHits) {
            Write-Host "      - $uh" -ForegroundColor Yellow
        }
        $allowPaths = Read-Host '  Всё равно продолжить публикацию? [д/Н] (Enter = Отмена)'
        if ($allowPaths -notmatch '^[yYдД]') {
            Write-Host '  [ОТМЕНА] Публикация отменена из-за найденных локальных путей.' -ForegroundColor Yellow
            exit 1
        }
    }

    # 9. Commit & Push code
    $global:LASTEXITCODE = 0
    & git add -A
    $staged = @(& git diff --cached --name-only)
    if ($staged.Count -gt 0) {
        Write-Host "`n  [*] Создаю коммит ($($staged.Count) файлов)..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        & git commit -m $commitMsg
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] Ошибка git commit.' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "`n  [i] Нет новых изменений для коммита — пропускаю git commit." -ForegroundColor Gray
    }

    Write-Host "  [*] Отправляю код на GitHub (git push origin $branch)..." -ForegroundColor Yellow
    $global:LASTEXITCODE = 0
    & git push origin $branch
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [X] Ошибка git push. Проверь интернет и авторизацию GitHub.' -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Код успешно отправлен в ветку $branch!" -ForegroundColor Green

    if (-not $doRelease) { exit 0 }

    # 10. Create & push git tag v<targetVer>
    $tagName = "v$targetVer"
    $global:LASTEXITCODE = 0
    & git tag -a $tagName -m "Zapret2 Kotek $tagName"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] Не удалось создать тег $tagName." -ForegroundColor Red
        exit 1
    }
    $global:LASTEXITCODE = 0
    & git push origin $tagName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [X] Не удалось отправить тег $tagName на GitHub." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Тег $tagName отправлен на GitHub." -ForegroundColor Green

    # 11. Publish GitHub Release via gh CLI if available, otherwise open browser + Explorer
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    $ghReady = $false
    if ($null -ne $ghCmd) {
        $global:LASTEXITCODE = 0
        & gh auth status >$null 2>&1
        if ($LASTEXITCODE -eq 0) { $ghReady = $true }
    }

    if ($ghReady) {
        Write-Host "`n  [*] Публикую релиз $tagName на GitHub через gh CLI..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        if ([string]::IsNullOrWhiteSpace($relNotes)) {
            if ($hasNotesFile) {
                Write-Host '  [*] Использую описание релиза из dev\RELEASE_NOTES.md...' -ForegroundColor Cyan
                & gh release create $tagName $zipPath $sumsPath --repo $repoSlug --title "Zapret2 Kotek $tagName" --notes-file $relNotesFile
            } else {
                & gh release create $tagName $zipPath $sumsPath --repo $repoSlug --title "Zapret2 Kotek $tagName" --generate-notes
            }
        } else {
            & gh release create $tagName $zipPath $sumsPath --repo $repoSlug --title "Zapret2 Kotek $tagName" --notes $relNotes
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n  [OK] Релиз $tagName опубликован на GitHub (ZIP + SHA256SUMS.txt прикреплены)!" -ForegroundColor Green
            Write-Host "       https://github.com/$repoSlug/releases/tag/$tagName" -ForegroundColor Cyan
        } else {
            Write-Host '  [!] Не удалось создать релиз через gh CLI. Открой страницу релизов вручную.' -ForegroundColor Yellow
            Start-Process explorer.exe -ArgumentList ('/select,"' + $zipPath + '"')
        }
    } else {
        Write-Host "`n  [i] GitHub CLI (gh) не установлен или не авторизован (gh auth login)." -ForegroundColor Yellow
        Write-Host '      Код и тег уже на GitHub! Открываю папку с архивом и страницу создания релиза —' -ForegroundColor Cyan
        Write-Host "      просто перетащи туда оба файла: zapret2-kotek-v$targetVer.zip и SHA256SUMS.txt." -ForegroundColor Cyan
        Start-Process explorer.exe -ArgumentList ('/select,"' + $zipPath + '"')
        Start-Process "https://github.com/$repoSlug/releases/new?tag=$tagName&title=Zapret2+Kotek+$tagName"
    }
} finally {
    Pop-Location
}
