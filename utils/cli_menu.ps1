param(
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$Root = Resolve-Z2Root $Root
$Version = Get-Z2Version $Root

function Show-FlowsealUpstreamCheck {
    $upVer = '1.10.4'
    Write-Host "`n  [*] Проверка апстрима Flowseal/zapret-discord-youtube (база v$upVer)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $raw = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt' -TimeoutSec 6 -UseBasicParsing).Content.Trim()
        if ($raw -eq $upVer) { Write-Host "  [OK] Upstream Flowseal актуален: $raw" -ForegroundColor Green }
        else { Write-Host "  [!] Доступна новая база Flowseal: $raw (текущая: $upVer)" -ForegroundColor Yellow }
    } catch {
        Write-Host '  [!] Не удалось проверить upstream Flowseal.' -ForegroundColor Yellow
    }
    Read-Host '  Нажми Enter'
}

while ($true) {
    Clear-Host
    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $svcSt = if ($svc) { $svc.Status } else { 'NOT_INSTALLED' }
    $strat = ''
    try { $strat = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube' } catch {}
    $ipMode = Get-Z2IpsetMode $Root
    $ahOn = Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled')
    $nlmOn = Test-Path -LiteralPath (Join-Path $Root 'utils\nlm_filter.enabled')

    Write-Host ''
    Write-Host '  ========================================================' -ForegroundColor Cyan
    Write-Host "    ZAPRET2 KOTEK v$Version — CLI MENU (service.bat --cli)" -ForegroundColor Cyan
    Write-Host "    Служба: $svcSt  |  Стратегия: $(if ($strat) { $strat } else { 'нет' })" -ForegroundColor Gray
    Write-Host "    IPSet: $ipMode  |  AutoHost: $(if ($ahOn) {'ВКЛ'} else {'ВЫКЛ'})  |  NLM: $(if ($nlmOn) {'ВКЛ'} else {'ВЫКЛ'})" -ForegroundColor Gray
    Write-Host '  ========================================================' -ForegroundColor Cyan
    Write-Host '   1. Автонастройка в 1 клик (auto_setup.ps1)'
    Write-Host '   2. Установить стратегию вручную (strategies/ и configs_archive/)'
    Write-Host '   3. Глубокий тест и синтез (deep_optimize.ps1)'
    Write-Host '   4. Telegram WS Proxy (tgws_helper.ps1)'
    Write-Host '   5. Оптимизатор UDP-фейков (fake_selector.ps1)'
    Write-Host '   6. Фильтр IPSet (переключить loaded -> none -> any)'
    Write-Host '   7. WARP и защита от VPN / NLM (nlm_helper.ps1)'
    Write-Host '   8. Фикс браузера QUIC/DoH (browser_helper.ps1)'
    Write-Host '   9. Обновить списки IPSet + Hosts (update_lists.ps1)'
    Write-Host '  10. Диагностика подключения (diag_report.ps1)'
    Write-Host '  11. Проверить обновления (Zapret2 Kotek / Flowseal upstream)'
    Write-Host '  12. Удалить службы Zapret2 (uninstall.ps1)'
    Write-Host '   0. Выход'
    Write-Host '  --------------------------------------------------------'
    $ch = (Read-Host '  Выбери пункт (0-12)').Trim()

    switch ($ch) {
        '0' { exit 0 }
        '1' { & (Join-Path $Root 'utils\auto_setup.ps1') -Root $Root; Read-Host '  Нажми Enter' }
        '2' {
            $core = @(Get-Z2Strategies $Root 'core')
            $arch = @(Get-Z2Strategies $Root 'arch')
            $all  = @($core) + @($arch)
            Write-Host ''
            for ($i = 0; $i -lt $all.Count; $i++) {
                $tag = if ($i -lt $core.Count) { '[BASE]' } else { '[ARCH]' }
                Write-Host ("  {0,2}. {1} {2}" -f ($i + 1), $tag, $all[$i].Name)
            }
            $n = Read-Host "`n  Номер стратегии (Enter = отмена)"
            $idx = 0
            if ([int]::TryParse($n, [ref]$idx) -and $idx -ge 1 -and $idx -le $all.Count) {
                & (Join-Path $Root 'utils\apply_strategy.ps1') -Root $Root -BatPath $all[$idx - 1].FullName
                Read-Host '  Нажми Enter'
            }
        }
        '3' { & (Join-Path $Root 'utils\deep_optimize.ps1') -Root $Root; Read-Host '  Нажми Enter' }
        '4' { & (Join-Path $Root 'utils\tgws_helper.ps1') menu }
        '5' { & (Join-Path $Root 'utils\fake_selector.ps1') -Action menu -Root $Root }
        '6' {
            $next = switch ($ipMode) { 'loaded' { 'none' } 'none' { 'any' } default { 'loaded' } }
            $ok = Set-Z2IpsetMode $Root $next
            if ($ok) { Write-Host "  [OK] Режим IPSet: $next" -ForegroundColor Green }
            else { Write-Host '  [!] Нет бэкапа IPSet — сначала обнови списки (п. 9).' -ForegroundColor Yellow }
            Start-Sleep -Seconds 1
        }
        '7' {
            $global:LASTEXITCODE = 0
            & (Join-Path $Root 'utils\nlm_helper.ps1') -Action menu -Root $Root
            if ($LASTEXITCODE -eq 10 -and $strat) {
                $batHit = $null
                foreach ($sub in @('strategies', 'configs_archive', '')) {
                    $candB = if ($sub) { Join-Path (Join-Path $Root $sub) ($strat + '.bat') } else { Join-Path $Root ($strat + '.bat') }
                    if (Test-Path -LiteralPath $candB) { $batHit = $candB; break }
                }
                if ($batHit) { & (Join-Path $Root 'utils\apply_strategy.ps1') -Root $Root -BatPath $batHit }
            }
        }
        '8' { & (Join-Path $Root 'utils\browser_helper.ps1') -Action menu -Root $Root }
        '9' { & (Join-Path $Root 'utils\update_lists.ps1') -Root $Root; Read-Host '  Нажми Enter' }
        '10' { & (Join-Path $Root 'utils\diag_report.ps1') -Root $Root; Read-Host '  Нажми Enter' }
        '11' {
            Write-Host "`n  [1] Обновление Zapret2 Kotek (GitHub)"
            Write-Host '  [2] Проверка upstream Flowseal (для разработчика)'
            $uCh = (Read-Host '  Выбери (1-2)').Trim()
            if ($uCh -eq '1') { & (Join-Path $Root 'utils\self_update.ps1') -Root $Root; Read-Host '  Нажми Enter' }
            elseif ($uCh -eq '2') { Show-FlowsealUpstreamCheck }
        }
        '12' { & (Join-Path $Root 'utils\uninstall.ps1') -Root $Root; if ($LASTEXITCODE -eq 20) { Set-Location $env:TEMP; exit 0 }; Read-Host '  Нажми Enter' }
    }
}
