param(
    [string]$Root = '',
    [switch]$AutoStart,
    [switch]$StartInTray
)
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'gui_runner.ps1')
. (Join-Path $PSScriptRoot 'gui_lists_dialog.ps1')
. (Join-Path $PSScriptRoot 'gui_nlm_dialog.ps1')
. (Join-Path $PSScriptRoot 'gui_diag_dialog.ps1')
. (Join-Path $PSScriptRoot 'gui_browser_dialog.ps1')
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'gui_antigravity_dialog.ps1')) { . (Join-Path $PSScriptRoot 'gui_antigravity_dialog.ps1') }
. (Join-Path $PSScriptRoot 'gui_msg_dialog.ps1')
if (-not (Enter-Z2GuiMutex)) {
    try {
        $evExist = $null
        if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\Zapret2KotekGuiShowEvent', [ref]$evExist)) {
            [void]$evExist.Set()
            $evExist.Dispose()
        }
    } catch {}
    exit 0
}
$script:ShowWindowEvent = $null
try {
    $script:ShowWindowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\Zapret2KotekGuiShowEvent')
} catch {}
$Root = Resolve-Z2Root $Root
$script:IsDevWorkspace = (Test-Path -LiteralPath (Join-Path $Root 'dev')) -or (Test-Path -LiteralPath (Join-Path $Root '.git'))
$script:BrushConv = New-Object System.Windows.Media.BrushConverter
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'browser_helper.ps1'))   { . (Join-Path $PSScriptRoot 'browser_helper.ps1')   -Root $Root }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ai_bypass_helper.ps1')) { . (Join-Path $PSScriptRoot 'ai_bypass_helper.ps1') -Root $Root }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'telemetry_helper.ps1')) { . (Join-Path $PSScriptRoot 'telemetry_helper.ps1') }
$Version = Get-Z2Version $Root

function Clamp-Byte([double]$v) {
    if ($v -lt 0) { return 0 }
    if ($v -gt 255) { return 255 }
    return [int][Math]::Round($v)
}
function To-Hex([int]$r, [int]$g, [int]$b, [int]$a = -1) {
    if ($a -ge 0) { return ('#{0:X2}{1:X2}{2:X2}{3:X2}' -f $a, $r, $g, $b) }
    return ('#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b)
}
function Mix-Color([int]$r, [int]$g, [int]$b, [int]$tr, [int]$tg, [int]$tb, [double]$t) {
    return @(
        (Clamp-Byte ($r + ($tr - $r) * $t)),
        (Clamp-Byte ($g + ($tg - $g) * $t)),
        (Clamp-Byte ($b + ($tb - $b) * $t))
    )
}

# Dynamic Windows system accent color (ABGR in DWM\AccentColor or Explorer\Accent\AccentColorMenu, ARGB in ColorizationColor)
$accR = 159; $accG = 199; $accB = 184
try {
    $dwm = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -ErrorAction SilentlyContinue
    $expAcc = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction SilentlyContinue
    if ($null -ne $dwm -and $null -ne $dwm.AccentColor) {
        $v = [int64]$dwm.AccentColor -band 0xFFFFFFFFL
        $accR = [int]($v -band 0xFF)
        $accG = [int](($v -shr 8) -band 0xFF)
        $accB = [int](($v -shr 16) -band 0xFF)
    } elseif ($null -ne $expAcc -and $null -ne $expAcc.AccentColorMenu) {
        $v = [int64]$expAcc.AccentColorMenu -band 0xFFFFFFFFL
        $accR = [int]($v -band 0xFF)
        $accG = [int](($v -shr 8) -band 0xFF)
        $accB = [int](($v -shr 16) -band 0xFF)
    } elseif ($null -ne $dwm -and $null -ne $dwm.ColorizationColor) {
        $v = [int64]$dwm.ColorizationColor -band 0xFFFFFFFFL
        $accR = [int](($v -shr 16) -band 0xFF)
        $accG = [int](($v -shr 8) -band 0xFF)
        $accB = [int]($v -band 0xFF)
    }
} catch {}

$AccentHex      = To-Hex $accR $accG $accB
$hv             = Mix-Color $accR $accG $accB 255 255 255 0.14
$AccentHoverHex = To-Hex $hv[0] $hv[1] $hv[2]
$pr             = Mix-Color $accR $accG $accB 0 0 0 0.16
$AccentPressHex = To-Hex $pr[0] $pr[1] $pr[2]
$lt             = Mix-Color $accR $accG $accB 255 255 255 0.48
$AccentLightHex = To-Hex $lt[0] $lt[1] $lt[2]
$AccentSoftHex  = To-Hex $accR $accG $accB 0x2E
$AccentBorderHx = To-Hex $accR $accG $accB 0x88
$yiq            = (($accR * 299) + ($accG * 587) + ($accB * 114)) / 1000
$AccentFgHex    = if ($yiq -ge 135) { '#121316' } else { '#FFFFFF' }

# Native Dark Titlebar (Windows 10 2004+ / Windows 11)
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinDwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@ -ErrorAction SilentlyContinue
} catch {}

$xamlPath = Join-Path $PSScriptRoot 'gui_layout.xaml'
$xamlRaw  = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$xamlRaw  = $xamlRaw.Replace('{{VERSION}}', $Version).Replace('{{ACCENT_HEX}}', $AccentHex).Replace('{{ACCENT_HOVER_HEX}}', $AccentHoverHex).Replace('{{ACCENT_PRESS_HEX}}', $AccentPressHex).Replace('{{ACCENT_LIGHT_HEX}}', $AccentLightHex).Replace('{{ACCENT_SOFT_HEX}}', $AccentSoftHex).Replace('{{ACCENT_BORDER_HX}}', $AccentBorderHx).Replace('{{ACCENT_FG_HEX}}', $AccentFgHex)
try {
    [xml]$xaml = $xamlRaw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    try {
        $win = [Windows.Markup.XamlReader]::Load($reader)
    } finally {
        try { $reader.Close() } catch {}
    }
    if ($script:IsDevWorkspace -and $win.Title -notlike '*[DEV]*') {
        $win.Title = "$($win.Title) [DEV]"
    }
} catch {
    $errMsg = $_.Exception.ToString()
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'z2_gui_crash.log'), $errMsg, [System.Text.Encoding]::UTF8) } catch {}
    try {
        [void](Show-Z2MessageDialog -Owner $null -Title 'Zapret2 Kotek — Ошибка' -Message "Ошибка запуска окна Zapret2 Kotek:`n`n$($_.Exception.Message)`n`nЛог: $env:TEMP\z2_gui_crash.log" -Kind 'Error' -Buttons 'OK' -AccentHex $AccentHex)
    } catch {}
    Exit-Z2GuiMutex
    exit 1
}
try { $icoF = Join-Path $Root 'utils\kotek.ico'; if (Test-Path -LiteralPath $icoF) { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($icoF), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad) } } catch {}

$win.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $dark = 1
        [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) | Out-Null
        $capColor = 0x00161312  # BGR for #121316
        [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$capColor, 4) | Out-Null
    } catch {}
})

$TxtCatArt       = $win.FindName('TxtCatArt')
$TxtCatMood      = $win.FindName('TxtCatMood')
$TxtSideState    = $win.FindName('TxtSideState')
$TxtSideStrat    = $win.FindName('TxtSideStrat')
$TxtFolder       = $win.FindName('TxtFolder')
$TxtZapretState  = $win.FindName('TxtZapretState')
$TxtHeroMeta     = $win.FindName('TxtHeroMeta')
$TxtTgStatusLine = $win.FindName('TxtTgStatusLine')
$TxtStatusBar    = $win.FindName('TxtStatusBar')
$ImgKotek        = $win.FindName('ImgKotek')
$TxtKotekPurr    = $win.FindName('TxtKotekPurr')
$KotekScale      = $win.FindName('KotekScale')
$KotekRotate     = $win.FindName('KotekRotate')
$KotekTranslate  = $win.FindName('KotekTranslate')
$TxtKotekHeart   = $win.FindName('TxtKotekHeart')
$HeartTranslate  = $win.FindName('HeartTranslate')
$CmbQuickStrat   = $win.FindName('CmbQuickStrat')
$CmbTgMode       = $win.FindName('CmbTgMode')
$BtnAddStrat     = $win.FindName('BtnAddStrat')
$BtnSynthStrat   = $win.FindName('BtnSynthStrat')
$BtnProbeStrat   = $win.FindName('BtnProbeStrat')
$ToastBanner     = $win.FindName('ToastBanner')
$TxtToastMsg     = $win.FindName('TxtToastMsg')
$BtnCloseToast   = $win.FindName('BtnCloseToast')
$BarProgress     = $win.FindName('BarProgress')
$BarActiveTask   = $win.FindName('BarActiveTask')
$ActiveTaskCard     = $win.FindName('ActiveTaskCard')
$TxtActiveTaskTitle = $win.FindName('TxtActiveTaskTitle')
$TxtActiveTaskStep  = $win.FindName('TxtActiveTaskStep')
$BtnToggleTaskLog   = $win.FindName('BtnToggleTaskLog')
$BtnCopyTaskLog     = $win.FindName('BtnCopyTaskLog')
$TaskLogBorder      = $win.FindName('TaskLogBorder')
$TxtTaskLogBox      = $win.FindName('TxtTaskLogBox')
$BtnTgToggle        = $win.FindName('BtnTgToggle')
$ColSidebar         = $win.FindName('ColSidebar')
$SideBorder         = $win.FindName('SideBorder')
$TxtBrandTitle      = $win.FindName('TxtBrandTitle')
$TxtBrandVer        = $win.FindName('TxtBrandVer')
$PanelCatMood       = $win.FindName('PanelCatMood')
$BtnToggleSide      = $win.FindName('BtnToggleSide')
$PathToggleArrow    = $win.FindName('PathToggleArrow')
$LblNavHome         = $win.FindName('LblNavHome')
$LblNavStrats       = $win.FindName('LblNavStrats')
$LblNavSettings     = $win.FindName('LblNavSettings')
$PanelSideStatusText= $win.FindName('PanelSideStatusText')
$SideHeaderPanel    = $win.FindName('SideHeaderPanel')
$ColHeaderTitle     = $win.FindName('ColHeaderTitle')
$ColSideStatusText  = $win.FindName('ColSideStatusText')
$SideStatusCard     = $win.FindName('SideStatusCard')
$StatusRow          = $win.FindName('StatusRow')
$TxtActiveTaskEta   = $win.FindName('TxtActiveTaskEta')
$BtnCancelHybrid    = $win.FindName('BtnCancelHybrid')
$AutoDoneCard       = $win.FindName('AutoDoneCard')
$TxtAutoDoneTitle   = $win.FindName('TxtAutoDoneTitle')
$TxtAutoDoneHints   = $win.FindName('TxtAutoDoneHints')
$TxtAutoDoneSummary = $win.FindName('TxtAutoDoneSummary')
$BtnAutoDoneDismiss = $win.FindName('BtnAutoDoneDismiss')
$BtnAutoDoneDeep    = $win.FindName('BtnAutoDoneDeep')
$BtnAutoDoneAutoUpd = $win.FindName('BtnAutoDoneAutoUpd')

$BtnGitHub       = $win.FindName('BtnGitHub')
$BtnNavHome      = $win.FindName('BtnNavHome')
$BtnNavStrats    = $win.FindName('BtnNavStrats')
$BtnNavSettings  = $win.FindName('BtnNavSettings')
$ViewHome        = $win.FindName('ViewHome')
$ViewStrats      = $win.FindName('ViewStrats')
$ViewSettings    = $win.FindName('ViewSettings')

$ListStrategies  = $win.FindName('ListStrategies')
$BdHybridRecipe  = $win.FindName('BdHybridRecipe')
$TxtHybridRecipe = $win.FindName('TxtHybridRecipe')
$TxtHybridScore  = $win.FindName('TxtHybridScore')
$BtnTabCore      = $win.FindName('BtnTabCore')
$BtnTabArch      = $win.FindName('BtnTabArch')
$BtnApplyStrat   = $win.FindName('BtnApplyStrat')
$BtnDeepOpt      = $win.FindName('BtnDeepOpt')
$BtnAutoSetup    = $win.FindName('BtnAutoSetup')
$BtnTgConnect    = $win.FindName('BtnTgConnect')
$BtnUdpOpt       = $win.FindName('BtnUdpOpt')
$CmbUdpFake      = $win.FindName('CmbUdpFake')
$BtnDiag         = $win.FindName('BtnDiag')
$BtnOpenDir      = $win.FindName('BtnOpenDir')
$BtnCreateShortcut = $win.FindName('BtnCreateShortcut')
$BtnUpdateLists  = $win.FindName('BtnUpdateLists')
$BtnCheckUpdate  = $win.FindName('BtnCheckUpdate')
$TxtUpdateInfo   = $win.FindName('TxtUpdateInfo')
$BtnUninstall    = $win.FindName('BtnUninstall')
$BtnRefresh      = $win.FindName('BtnRefresh')
$BtnPause        = $win.FindName('BtnPause')
$ChkAutoHost     = $win.FindName('ChkAutoHost')
$ChkWarp         = $win.FindName('ChkWarp')
$ChkGameFilter   = $win.FindName('ChkGameFilter')
$ChkNlmVpn       = $win.FindName('ChkNlmVpn')
$TxtNlmStatus    = $win.FindName('TxtNlmStatus')
$BtnNlmConfig    = $win.FindName('BtnNlmConfig')
$ChkKernelFilter = $win.FindName('ChkKernelFilter')
$ChkTrayMode     = $win.FindName('ChkTrayMode')
$ChkTrayStartMin = $win.FindName('ChkTrayStartMin')
$TxtBrowserFixState = $win.FindName('TxtBrowserFixState')
$BtnBrowserFix   = $win.FindName('BtnBrowserFix')
$ChkBrowserQuic    = $win.FindName('ChkBrowserQuic')
$TxtAiStatusLine    = $win.FindName('TxtAiStatusLine')
$BtnAiServices      = $win.FindName('BtnAiServices')
$PnlAiServices      = $win.FindName('PnlAiServices')
$CmbAiMode          = $win.FindName('CmbAiMode')
$BtnAiToggle        = $win.FindName('BtnAiToggle')
$BtnAiProbe         = $win.FindName('BtnAiProbe')
$ChkAi_gemini       = $win.FindName('ChkAi_gemini')
$ChkAi_chatgpt      = $win.FindName('ChkAi_chatgpt')
$ChkAi_claude       = $win.FindName('ChkAi_claude')
$ChkAi_copilot      = $win.FindName('ChkAi_copilot')
$ChkAi_grok         = $win.FindName('ChkAi_grok')
$ChkAi_perplexity   = $win.FindName('ChkAi_perplexity')
$ChkAi_ide_ai       = $win.FindName('ChkAi_ide_ai')
$ChkAi_antigravity  = $win.FindName('ChkAi_antigravity')
$BtnAiSelAll        = $win.FindName('BtnAiSelAll')
$TxtAiPendingHint   = $win.FindName('TxtAiPendingHint')
$BdAiClaudeWarn     = $win.FindName('BdAiClaudeWarn')
$BdAiAntigravityHint= $win.FindName('BdAiAntigravityHint')
$BtnAiAntigravityHelper = $win.FindName('BtnAiAntigravityHelper')
$script:AiAppliedServicesStr = ''
$script:AiNeedsRestart = $false
$script:AiServiceCheckMap = [ordered]@{
    'gemini'     = $ChkAi_gemini
    'chatgpt'    = $ChkAi_chatgpt
    'claude'     = $ChkAi_claude
    'copilot'    = $ChkAi_copilot
    'grok'       = $ChkAi_grok
    'perplexity' = $ChkAi_perplexity
    'ide_ai'      = $ChkAi_ide_ai
    'antigravity' = $ChkAi_antigravity
}
$BdBrowserFixBadge = $win.FindName('BdBrowserFixBadge')
$TxtBrowserFixBadge= $win.FindName('TxtBrowserFixBadge')
$TxtUdpCurrent     = $win.FindName('TxtUdpCurrent')
$ChkUdpManual      = $win.FindName('ChkUdpManual')
$BtnEditGenUser  = $win.FindName('BtnEditGenUser')
$BtnEditExUser   = $win.FindName('BtnEditExUser')
$ChkAutoUpdate       = $win.FindName('ChkAutoUpdate')
$ChkTelemetry        = $win.FindName('ChkTelemetry')
$BtnTelemetryPreview = $win.FindName('BtnTelemetryPreview')
$CmbAutoUpdMode  = $win.FindName('CmbAutoUpdMode')
$CmbIpsetMode    = $win.FindName('CmbIpsetMode')
$TxtAutoUpdDesc  = $win.FindName('TxtAutoUpdDesc')

$TxtFolder.Text = Format-Z2DirNoSlash $Root
function Load-KotekSprite([string]$FileName) {
    $fp = Join-Path $Root ("utils\$FileName")
    if (-not (Test-Path -LiteralPath $fp)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = New-Object System.Uri($fp, [System.UriKind]::Absolute)
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch { return $null }
}
$script:KotekBmpHappy = Load-KotekSprite 'kotek_happy.png'
if (-not $script:KotekBmpHappy) { $script:KotekBmpHappy = Load-KotekSprite 'kotek.png' }
$script:KotekBmpWork  = Load-KotekSprite 'kotek_work.png'
$script:KotekBmpSleep = Load-KotekSprite 'kotek_sleep.png'
$script:ZapretIsRunning = $false
$script:LastKotekMood = ''
function Set-KotekEmotion([string]$Mood) {
    if ($script:LastKotekMood -eq $Mood) { return }
    $bmp = switch ($Mood) {
        'work'  { if ($script:KotekBmpWork)  { $script:KotekBmpWork }  else { $script:KotekBmpHappy } }
        'sleep' { if ($script:KotekBmpSleep) { $script:KotekBmpSleep } else { $script:KotekBmpHappy } }
        default { $script:KotekBmpHappy }
    }
    if ($bmp) {
        $ImgKotek.Source = $bmp
        $script:LastKotekMood = $Mood
    }
}
Set-KotekEmotion 'happy'
$script:PetUntilTick = 0
$script:PurrWords = @('мур ♡', 'мррр~ ♡', 'приятно ♡', 'мур-мур ♡', 'ня~ ♡', 'на страже ♡')
$script:SecretWords = @('за ушком! =^w^=', 'пакеты летят! ♡', 'DPI нас не видит! ♡', 'хочу рыбку ♡')
$script:PurrIdx = 0
$script:SecretIdx = 0
$script:PetCombo = 0
$script:LastPetTime = [DateTime]::MinValue

function Invoke-KotekThankYou {
    try {
        Set-KotekEmotion 'happy'
        Invoke-KotekSquish $true
        Invoke-KotekHeartPop '♡'
        $script:PetUntilTick = $script:CatIdx + 6
        if ($null -ne $TxtCatArt)  { $TxtCatArt.Text  = '(=^w^=)' }
        if ($null -ne $TxtCatMood) {
            $TxtCatMood.Text = '  спасибо ♡'
            $TxtCatMood.Foreground = $script:BrushConv.ConvertFromString('#F2A7BE')
        }
        $tPop = New-Object System.Windows.Threading.DispatcherTimer
        $tPop.Interval = [TimeSpan]::FromMilliseconds(480)
        $tPop.Tag = @{ Step = 0 }
        $tPop.Add_Tick({
            param($s, $e)
            $st = $s.Tag
            if ($null -eq $st) { $s.Stop(); return }
            $st.Step++
            if ($st.Step -eq 1) {
                Invoke-KotekHeartPop '♥'
                Invoke-KotekSquish $false
            } else {
                $s.Stop()
                $s.Tag = $null
            }
        })
        $tPop.Start()
    } catch {}
}

function Invoke-Z2TelemetryPromptOnce {
    $fPrompt = Join-Path $Root 'utils\telemetry.prompted'
    $fTel    = Join-Path $Root 'utils\telemetry.enabled'
    $u8nb    = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $fPrompt) {
        $pv = ([string](Get-Content -LiteralPath $fPrompt -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($pv -match '^[12](\||$)') { return }
    }

    # Pre-enable telemetry by default before showing first-run dialog
    try {
        [System.IO.File]::WriteAllText($fTel, "1`r`n", $u8nb)
        if ($null -ne $ChkTelemetry) { $ChkTelemetry.IsChecked = $true }
    } catch {}

    $nowUnix = [int64]([DateTime]::UtcNow - (New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc))).TotalSeconds
    $msg = "Оставить включёнными анонимные отчёты, чтобы помогать Котеку становиться лучше?`r`n`r`nОтправляются версия, стратегия, тех-срез и логи при сбоях (без путей, IP и списков сайтов).`r`nЕсли нажмёшь «Нет» — отправка сразу выключится. Изменить выбор можно в любой момент в Настройках."
    $ans = Show-Z2MessageDialog -Owner $win -Title 'Помочь развитию Котека ♡' -Message $msg -Kind 'Question' -Buttons 'YesNo' -AccentHex '#E88CA5' -CloseResult 'Yes'
    if ($ans -eq 'No') {
        try {
            if (Test-Path -LiteralPath $fTel) { Remove-Item -LiteralPath $fTel -Force -ErrorAction SilentlyContinue }
            if ($null -ne $ChkTelemetry) { $ChkTelemetry.IsChecked = $false }
            # Stage 1 + timestamp: at most 1 gentle non-modal pink toast after 30 days, then permanently 2
            [System.IO.File]::WriteAllText($fPrompt, "1|$nowUnix`r`n", $u8nb)
            Show-Toast 'Анонимные отчёты отключены. Включить можно в любой момент в Настройках.' $false
        } catch {}
    } else {
        try {
            [System.IO.File]::WriteAllText($fPrompt, "2`r`n", $u8nb)
            [System.IO.File]::WriteAllText($fTel, "1`r`n", $u8nb)
            if ($null -ne $ChkTelemetry) { $ChkTelemetry.IsChecked = $true }
            Invoke-KotekThankYou
            Show-Toast 'Спасибо ♡ Анонимные отчёты включены!' $false
            if (Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue) {
                try {
                    $optScore = ''
                    $optRf = Join-Path $Root 'utils\last_autosetup.json'
                    if (Test-Path -LiteralPath $optRf) {
                        $orj = Get-Content -LiteralPath $optRf -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
                        if ($null -ne $orj -and $null -ne $orj.total -and [int]$orj.total -gt 0) {
                            $optScore = "$($orj.ok)/$($orj.total) ($($orj.pct)%)"
                        }
                    }
                    $optSnap = if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) { Get-Z2TelemetrySnapshot $Root } else { '' }
                    [void](Send-Z2TelemetryEvent -RootPath $Root -Event 'optin' -Strategy $script:ActiveStratName -Score $optScore -Code '0' -Detail $optSnap)
                } catch {}
            }
        } catch {}
    }
}

function Invoke-Z2TelemetrySoftRemind {
    if ($script:IsDevWorkspace) { return }
    $fPrompt = Join-Path $Root 'utils\telemetry.prompted'
    $fTel    = Join-Path $Root 'utils\telemetry.enabled'
    if (Test-Path -LiteralPath $fTel) { return }
    if (-not (Test-Path -LiteralPath $fPrompt)) { return }
    $pv = ([string](Get-Content -LiteralPath $fPrompt -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
    if ($pv -match '^1\|(\d+)$') {
        $ts0 = [int64]$matches[1]
        $nowUnix = [int64]([DateTime]::UtcNow - (New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc))).TotalSeconds
        if (($nowUnix - $ts0) -ge 2592000) {
            try { [System.IO.File]::WriteAllText($fPrompt, "2`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
            Show-Toast '♡ Если Котек выручает — можешь включить анонимные отчёты внизу Настроек (больше не напомню).' $false
            try {
                $ToastBanner.Background  = $script:BrushConv.ConvertFromString('#24181E')
                $ToastBanner.BorderBrush = $script:BrushConv.ConvertFromString('#E88CA5')
                $TxtToastMsg.Foreground  = $script:BrushConv.ConvertFromString('#FCE7EF')
            } catch {}
        }
    }
}

function Start-KotekIdleBreath {
    try {
        $sine = New-Object System.Windows.Media.Animation.SineEase
        $sine.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
        $animY = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 1.022, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(2200))))
        $animY.AutoReverse = $true
        $animY.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $animY.EasingFunction = $sine
        $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $animY)

        $animX = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.993, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(2200))))
        $animX.AutoReverse = $true
        $animX.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $animX.EasingFunction = $sine
        $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $animX)

    } catch {}
}

function Invoke-KotekHeartPop([string]$Glyph = '♡') {
    try {
        $TxtKotekHeart.Text = $Glyph
        $aY = New-Object System.Windows.Media.Animation.DoubleAnimation(4.0, -26.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(680))))
        $aOp = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(680))))
        $HeartTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $aY)
        $TxtKotekHeart.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $aOp)
    } catch {}
}

function Invoke-KotekSquish([bool]$WithHop = $false) {
    try {
        $el = New-Object System.Windows.Media.Animation.ElasticEase
        $el.Oscillations = 1; $el.Springiness = 6
        $aX = New-Object System.Windows.Media.Animation.DoubleAnimation(1.08, 1.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(420))))
        $aX.EasingFunction = $el
        $aY = New-Object System.Windows.Media.Animation.DoubleAnimation(0.92, 1.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(420))))
        $aY.EasingFunction = $el
        $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $aX)
        $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $aY)
        if ($WithHop) {
            $aHop = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, -9.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(150))))
            $aHop.AutoReverse = $true
            $KotekTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $aHop)
        }
    } catch {}
}

Start-KotekIdleBreath

$script:LastMouseMoveUtc = [DateTime]::MinValue
$ImgKotek.Add_MouseMove({
    param($s, $e)
    $nowMm = [DateTime]::UtcNow
    if (($nowMm - $script:LastMouseMoveUtc).TotalMilliseconds -lt 45) { return }
    $script:LastMouseMoveUtc = $nowMm
    try {
        $w = [Math]::Max(1.0, $ImgKotek.ActualWidth)
        $h = [Math]::Max(1.0, $ImgKotek.ActualHeight)
        $pt = $e.GetPosition($ImgKotek)
        $nx = [Math]::Max(-1.0, [Math]::Min(1.0, (($pt.X / $w) - 0.5) * 2.0))
        $ny = [Math]::Max(-1.0, [Math]::Min(1.0, (($pt.Y / $h) - 0.5) * 2.0))
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(120))
        $aX = New-Object System.Windows.Media.Animation.DoubleAnimation(($nx * 5.5), $dur)
        $aY = New-Object System.Windows.Media.Animation.DoubleAnimation(($ny * 3.5 - 1.5), $dur)
        $KotekTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $aX)
        $KotekTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $aY)
    } catch {}
})
$ImgKotek.Add_MouseLeave({
    try {
        $ease = New-Object System.Windows.Media.Animation.SineEase
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(240))
        $aX = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, $dur); $aX.EasingFunction = $ease
        $aY = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, $dur); $aY.EasingFunction = $ease
        $KotekTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $aX)
        $KotekTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $aY)
    } catch {}
    Start-KotekIdleBreath
})

$ImgKotek.Add_MouseLeftButtonDown({
    $now = [DateTime]::UtcNow
    if (($now - $script:LastPetTime).TotalSeconds -lt 1.8) { $script:PetCombo++ } else { $script:PetCombo = 1 }
    $script:LastPetTime = $now
    $script:PetUntilTick = $script:CatIdx + 5
    Set-KotekEmotion 'happy'
    if ($script:PetCombo -ge 3) {
        $TxtKotekPurr.Text = 'мррррр!! ♡♡'
        $TxtCatArt.Text = '(=^▽^=)'
        $TxtCatMood.Text = '  в восторге ♡'
        Invoke-KotekSquish $true
        Invoke-KotekHeartPop '♡♡'
    } else {
        $TxtKotekPurr.Text = $script:PurrWords[($script:PurrIdx++) % $script:PurrWords.Count]
        $TxtCatArt.Text = '(=^w^=)'
        $TxtCatMood.Text = '  мурчит ♡'
        Invoke-KotekSquish $false
        Invoke-KotekHeartPop '♡'
    }
    $TxtKotekPurr.Visibility = 'Visible'
})

$ImgKotek.Add_MouseRightButtonDown({
    $script:PetUntilTick = $script:CatIdx + 6
    Set-KotekEmotion 'happy'
    $TxtKotekPurr.Text = $script:SecretWords[($script:SecretIdx++) % $script:SecretWords.Count]
    $TxtKotekPurr.Visibility = 'Visible'
    $TxtCatArt.Text = '(=^ω^=)'
    $TxtCatMood.Text = '  доволен ♡'
    Invoke-KotekSquish $false
    Invoke-KotekHeartPop '✦'
})


$script:SuppressTgModeEvent = $true
$script:TgModeKeys = @('smart', 'direct', 'cfonly')
$script:TgModeLabels = @('smart (авто)', 'direct (прямой)', 'cfonly (CF)')
$script:TgModeHints = @{
    'smart'  = 'Авто (прямой → CF)'
    'direct' = 'Только прямой WS'
    'cfonly' = 'Только Cloudflare'
}
$script:TgModeTooltips = @(
    'Рекомендуемый режим: сначала пробует прямое подключение к Telegram, при блокировке мгновенно переключается на Cloudflare.',
    'Только прямое WebSocket-подключение к серверам Telegram без Cloudflare (минимальный пинг, если IP Telegram не заблокированы).',
    'Всегда через пул чистых IP Cloudflare (выбирай, если провайдер наглухо блокирует прямые IP Telegram).'
)
for ($ti = 0; $ti -lt $script:TgModeLabels.Count; $ti++) {
    $cbi = New-Object System.Windows.Controls.ComboBoxItem
    $cbi.Content = $script:TgModeLabels[$ti]
    $cbi.ToolTip = $script:TgModeTooltips[$ti]
    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($cbi, 120)
    [void]$CmbTgMode.Items.Add($cbi)
}
$CmbTgMode.SelectedIndex = 0
$script:SuppressTgModeEvent = $false
$script:SuppressAiModeEvent = $false
$aiKeysList = New-Object System.Collections.Generic.List[string]
$aiKeysList.Add('auto')
$aiLabelsList = New-Object System.Collections.Generic.List[string]
$aiLabelsList.Add('Авто (живой)')
if (Get-Command Get-Z2AiDnsPool -ErrorAction SilentlyContinue) {
    foreach ($ap in (Get-Z2AiDnsPool $Root)) {
        if (-not $aiKeysList.Contains($ap.Name)) {
            $aiKeysList.Add($ap.Name)
            $aiLabelsList.Add($ap.Name)
        }
    }
}
$script:AiModeKeys = $aiKeysList.ToArray()
if ($null -ne $CmbAiMode) {
    $script:SuppressAiModeEvent = $true
    foreach ($al in $aiLabelsList) { [void]$CmbAiMode.Items.Add($al) }
    $CmbAiMode.SelectedIndex = 0
    $script:SuppressAiModeEvent = $false
}
$script:SuppressQuickStratEvent = $false
$script:SuppressAutoUpdEvent = $true
$script:AutoUpdKeys = @('weekly', 'twiceweekly', 'monthly', 'onboot')
$script:AutoUpdLabels = @('1 раз в неделю', '2 раза в неделю', '1 раз в месяц', 'При включении ПК')
foreach ($auLbl in $script:AutoUpdLabels) { [void]$CmbAutoUpdMode.Items.Add($auLbl) }
$script:IpsetModeKeys = @('loaded', 'none', 'any')
$script:SuppressIpsetEvent = $false
foreach ($ipLbl in @('loaded (список IP)', 'none (только домены)', 'any (весь трафик)')) { [void]$CmbIpsetMode.Items.Add($ipLbl) }
$CmbAutoUpdMode.SelectedIndex = 0
$script:SuppressAutoUpdEvent = $false
$script:TaskLogPath = Join-Path $env:TEMP 'z2_gui_task.log'
$script:ActiveTaskLabel = ''
$script:ActiveTaskKind  = ''
$script:ActiveTaskBtn = $null
$script:ActiveTaskBtnOrigText = ''
$script:ToastHideTick = 0
$script:BgOpBusy = $false
$script:BgPs     = $null
$script:BgRs     = $null
$script:BgTimer  = $null
$script:AiPausedByVpn     = $false
$script:AiPausedByVpnInfo = $null
$script:AiVpnOverride     = $false
$script:VpnWatchTick      = 0

function Set-Z2BusyUiState([bool]$IsBusy) {
    $enabled = -not $IsBusy
    $mutControls = @(
        $BtnAutoSetup, $BtnDeepOpt, $BtnApplyStrat, $BtnProbeStrat, $BtnSynthStrat, $BtnAddStrat,
        $BtnTgConnect, $BtnTgToggle, $BtnUdpOpt, $CmbUdpFake, $CmbQuickStrat, $CmbTgMode,
        $CmbIpsetMode, $BtnDiag, $BtnUpdateLists, $BtnCheckUpdate, $BtnUninstall,
        $ChkAutoHost, $ChkWarp, $ChkGameFilter, $ChkKernelFilter, $ChkNlmVpn, $BtnNlmConfig,
        $BtnBrowserFix, $ChkBrowserQuic, $BtnEditGenUser, $BtnEditExUser,
        $BtnAiToggle, $BtnAiProbe, $CmbAiMode, $BtnAiSelAll,
        $ChkAi_gemini, $ChkAi_chatgpt, $ChkAi_claude, $ChkAi_copilot, $ChkAi_grok, $ChkAi_perplexity, $ChkAi_ide_ai, $ChkAi_antigravity, $BtnPause
    )
    foreach ($ctrl in $mutControls) {
        if ($null -ne $ctrl) { $ctrl.IsEnabled = $enabled }
    }

}

function Stop-Z2BgUiWork {
    if ($null -ne $script:BgTimer) {
        try { $script:BgTimer.Stop() } catch {}
        try { $script:BgTimer.Tag = $null } catch {}
        $script:BgTimer = $null
    }
    if ($null -ne $script:BgPs) {
        try { $script:BgPs.Stop() } catch {}
        try { $script:BgPs.Dispose() } catch {}
        $script:BgPs = $null
    }
    if ($null -ne $script:BgRs) {
        try { $script:BgRs.Close() } catch {}
        try { $script:BgRs.Dispose() } catch {}
        $script:BgRs = $null
    }
    $script:BgOpBusy = $false
}

function Invoke-Z2BgUiWork([scriptblock]$WorkScript, [hashtable]$Params, [scriptblock]$OnComplete, [int]$TimeoutSec = 90) {
    if ($script:BgOpBusy) { return }
    $script:BgOpBusy = $true
    Set-Z2BusyUiState $true
    $rs = $null
    $ps = $null
    $ar = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($WorkScript)
        if ($null -ne $Params) {
            foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
        }
        $ar = $ps.BeginInvoke()
        $script:BgRs = $rs
        $script:BgPs = $ps
    } catch {
        $initErr = $_.Exception.Message
        if ($null -ne $ps) { try { $ps.Dispose() } catch {} }
        if ($null -ne $rs) { try { $rs.Close(); $rs.Dispose() } catch {} }
        $script:BgPs = $null
        $script:BgRs = $null
        $script:BgTimer = $null
        $script:BgOpBusy = $false
        if ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited) {
            Set-Z2BusyUiState $false
        }
        if ($null -ne $OnComplete) {
            try { & $OnComplete $null $initErr } catch {}
        }
        return
    }
    $tBg = New-Object System.Windows.Threading.DispatcherTimer
    $tBg.Interval = [TimeSpan]::FromMilliseconds(100)
    $tBg.Tag = @{ Ar = $ar; Ps = $ps; Rs = $rs; OnComplete = $OnComplete; StartedAt = [DateTime]::UtcNow; TimeoutSec = $TimeoutSec }
    $script:BgTimer = $tBg
    $tBg.Add_Tick({
        param($s, $e)
        $st = $s.Tag
        if ($null -eq $st) { $s.Stop(); return }
        $timedOut = (([DateTime]::UtcNow - $st.StartedAt).TotalSeconds -ge $st.TimeoutSec)
        if (-not $st.Ar.IsCompleted -and -not $timedOut) { return }
        $s.Stop()
        $resObj = $null
        $errObj = $null
        try {
            if ($timedOut -and -not $st.Ar.IsCompleted) {
                try { [void]$st.Ps.BeginStop($null, $null) } catch {}
                $errObj = 'Превышено время ожидания операции'
            } else {
                $resObj = $st.Ps.EndInvoke($st.Ar)
                if ($st.Ps.HadErrors -and $st.Ps.Streams.Error.Count -gt 0) {
                    $errObj = $st.Ps.Streams.Error[0].ToString()
                }
            }
        } catch {
            $errObj = $_.Exception.Message
        } finally {
            try { $st.Ps.Dispose() } catch {}
            try { $st.Rs.Close(); $st.Rs.Dispose() } catch {}
            $s.Tag = $null
            if ([object]::ReferenceEquals($script:BgTimer, $s)) { $script:BgTimer = $null }
            if ([object]::ReferenceEquals($script:BgPs, $st.Ps)) { $script:BgPs = $null }
            if ([object]::ReferenceEquals($script:BgRs, $st.Rs)) { $script:BgRs = $null }
            $script:BgOpBusy = $false
            if ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited) {
                Set-Z2BusyUiState $false
            }
        }
        if ($null -ne $st.OnComplete) {
            try { & $st.OnComplete $resObj $errObj } catch {}
        }
    })
    $tBg.Start()
}

function Show-Toast([string]$Msg, [bool]$IsError = $false) {
    $bc = $script:BrushConv
    if ($IsError) {
        $ToastBanner.Background = $bc.ConvertFromString('#261818')
        $ToastBanner.BorderBrush = $bc.ConvertFromString('#D97777')
        $TxtToastMsg.Foreground = $bc.ConvertFromString('#F2D6D6')
        $TxtToastMsg.Text = "✕  $Msg"
    } else {
        $ToastBanner.Background = $bc.ConvertFromString('#181A1F')
        $ToastBanner.BorderBrush = $bc.ConvertFromString($AccentLightHex)
        $TxtToastMsg.Foreground = $bc.ConvertFromString('#F1F3F5')
        $TxtToastMsg.Text = "✓  $Msg"
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
    }
    $ToastBanner.Visibility = 'Visible'
    $StatusRow.Visibility = 'Collapsed'
    $script:ToastHideTick = $script:CatIdx + 14
}
function Test-Z2GuiAdmin([switch]$RefreshUi) {
    if (Test-Z2IsAdmin) { return $true }
    Show-Toast 'Требуются права администратора — запусти !_START_KOTEK.bat от имени администратора.' $true
    if ($RefreshUi) { Refresh-Dashboard }
    return $false
}
if ($null -ne $BtnAutoDoneDismiss) { $BtnAutoDoneDismiss.Add_Click({ $AutoDoneCard.Visibility = 'Collapsed' }) }
$BtnAutoDoneDeep.Add_Click({
    $AutoDoneCard.Visibility = 'Collapsed'
    Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Глубокий тест (22 стратегии)' $BtnDeepOpt
})
if ($null -ne $BtnCancelHybrid) {
    $BtnCancelHybrid.Add_Click({
        if ($null -ne $script:WatchedProc) {
            Stop-Z2ActiveTask $script:WatchedProc
            try { $script:WatchedProc.Dispose() } catch {}
            $script:WatchedProc = $null
        }
        $script:ActiveTaskKind = ''
        $BtnCancelHybrid.Visibility = 'Collapsed'
        $BarProgress.Visibility = 'Collapsed'
        $ActiveTaskCard.Visibility = 'Collapsed'
        if ($null -ne $script:ActiveTaskBtn) {
            $script:ActiveTaskBtn.Content = $script:ActiveTaskBtnOrigText
            $script:ActiveTaskBtn.IsEnabled = $true
            $script:ActiveTaskBtn = $null
        }
        Set-Status 'Отмена гибрида и восстановление службы...' '#D9B066'
        Invoke-Z2BgUiWork {
            param($RootDir)
            try {
                . (Join-Path $RootDir 'utils\common.ps1')
                Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
                $bakConf = Join-Path $RootDir 'bin\service.conf.deepbak'
                $liveConf = Join-Path $RootDir 'bin\service.conf'
                if (Test-Path -LiteralPath $bakConf) {
                    Move-Item -LiteralPath $bakConf -Destination $liveConf -Force -ErrorAction SilentlyContinue
                }
                Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 350
                $s = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
                $ok = ($null -ne $s -and $s.Status -eq 'Running')
                if ($s) { try { $s.Dispose() } catch {} }
                return $ok
            } catch { return $false }
        } @{ RootDir = $Root } {
            param($res, $err)
            Refresh-Dashboard
            $ok = ($res -is [System.Collections.IList] -and $res.Count -gt 0 -and [bool]$res[0]) -or ($res -eq $true)
            if ($ok) {
                $keepMsg = "Гибрид отменён — оставлена стратегия $($script:ActiveStratName)"
                Set-Status $keepMsg $AccentLightHex
                Show-Toast $keepMsg $false
            } else {
                $failMsg = 'Гибрид отменён, но не удалось запустить службу zapret — проверь права или запусти вручную.'
                Set-Status $failMsg '#D97777'
                Show-Toast $failMsg $true
            }
        }
    })
}
function Sync-AutoDoneUpdBtn {
    $isOn = [bool]$ChkAutoUpdate.IsChecked
    $bc = $script:BrushConv
    if ($isOn) {
        $BtnAutoDoneAutoUpd.Content = '● Автообновление: ВКЛ'
        $BtnAutoDoneAutoUpd.Foreground = $bc.ConvertFrom($AccentLightHex)
        $BtnAutoDoneAutoUpd.BorderBrush = $bc.ConvertFrom($AccentBorderHx)
    } else {
        $BtnAutoDoneAutoUpd.Content = '○ Автообновление: ВЫКЛ'
        $BtnAutoDoneAutoUpd.Foreground = $bc.ConvertFrom('#9CA3AF')
        $BtnAutoDoneAutoUpd.BorderBrush = $bc.ConvertFrom('#2E3342')
    }
}
$BtnAutoDoneAutoUpd.Add_Click({
    if (-not (Test-Z2GuiAdmin)) { return }
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    $turnOn = -not [bool]$ChkAutoUpdate.IsChecked
    if ($turnOn) {
        $global:LASTEXITCODE = 0
        & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
        if ($LASTEXITCODE -ne 0 -or $null -eq (Get-Z2AutoUpdateTask)) {
            $ChkAutoUpdate.IsChecked = $false
            $CmbAutoUpdMode.IsEnabled = $false
            Show-Toast 'Не удалось включить автообновление — перенеси сборку в C:\Zapret2.' $true
        } else {
            $ChkAutoUpdate.IsChecked = $true
            $CmbAutoUpdMode.IsEnabled = $true
            $mTxt = switch ($selM) { 'onboot' { 'при включении ПК' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
            Show-Toast "Автообновление включено: $mTxt" $false
        }
    } else {
        $global:LASTEXITCODE = 0
        & $auScript -Action disable -Root $Root | Out-Null
        if ($LASTEXITCODE -ne 0 -or $null -ne (Get-Z2AutoUpdateTask)) {
            $ChkAutoUpdate.IsChecked = $true
            $CmbAutoUpdMode.IsEnabled = $true
            Show-Toast 'Не удалось отключить автообновление — проверь права администратора.' $true
        } else {
            $ChkAutoUpdate.IsChecked = $false
            $CmbAutoUpdMode.IsEnabled = $false
            Show-Toast 'Автообновление отключено.' $false
        }
    }
    Sync-AutoDoneUpdBtn
})
$BtnCloseToast.Add_Click({
    $ToastBanner.Visibility = 'Collapsed'
    $StatusRow.Visibility = 'Visible'
})

$script:SideCollapsed = $false
$BtnToggleSide.Add_Click({
    $script:SideCollapsed = -not $script:SideCollapsed
    if ($script:SideCollapsed) {
        $ColSidebar.Width = New-Object System.Windows.GridLength(64)
        $SideBorder.Padding = New-Object System.Windows.Thickness(8,16,8,14)
        if ($null -ne $SideHeaderPanel) { $SideHeaderPanel.Margin = New-Object System.Windows.Thickness(0,0,0,16) }
        if ($null -ne $ColHeaderTitle) { $ColHeaderTitle.Width = New-Object System.Windows.GridLength(0) }
        [System.Windows.Controls.Grid]::SetColumn($BtnToggleSide, 0)
        [System.Windows.Controls.Grid]::SetColumnSpan($BtnToggleSide, 3)
        $BtnToggleSide.HorizontalAlignment = 'Center'
        $TxtBrandTitle.Visibility = 'Collapsed'
        $TxtBrandVer.Visibility = 'Collapsed'
        $PanelCatMood.Visibility = 'Collapsed'
        $BtnGitHub.Visibility = 'Collapsed'
        $LblNavHome.Visibility = 'Collapsed'
        $LblNavStrats.Visibility = 'Collapsed'
        $LblNavSettings.Visibility = 'Collapsed'
        foreach ($nb in @($BtnNavHome, $BtnNavStrats, $BtnNavSettings)) {
            $nb.HorizontalContentAlignment = 'Center'
            $nb.Padding = New-Object System.Windows.Thickness(0,10,0,10)
        }
        $PanelSideStatusText.Visibility = 'Collapsed'
        if ($null -ne $ColSideStatusText) { $ColSideStatusText.Width = New-Object System.Windows.GridLength(0) }
        [System.Windows.Controls.Grid]::SetColumn($BtnRefresh, 0)
        [System.Windows.Controls.Grid]::SetColumnSpan($BtnRefresh, 2)
        $BtnRefresh.HorizontalAlignment = 'Center'
        $SideStatusCard.Padding = New-Object System.Windows.Thickness(0,6,0,6)
        $ImgKotek.Width = 44
        $PathToggleArrow.Data = [System.Windows.Media.Geometry]::Parse('M8.59,16.59 L10,18 L16,12 L10,6 L8.59,7.41 L13.17,12 Z')
    } else {
        $ColSidebar.Width = New-Object System.Windows.GridLength(232)
        $SideBorder.Padding = New-Object System.Windows.Thickness(12,18,12,14)
        if ($null -ne $SideHeaderPanel) { $SideHeaderPanel.Margin = New-Object System.Windows.Thickness(4,0,2,20) }
        if ($null -ne $ColHeaderTitle) { $ColHeaderTitle.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        [System.Windows.Controls.Grid]::SetColumn($BtnToggleSide, 2)
        [System.Windows.Controls.Grid]::SetColumnSpan($BtnToggleSide, 1)
        $BtnToggleSide.HorizontalAlignment = 'Center'
        $TxtBrandTitle.Visibility = 'Visible'
        $TxtBrandVer.Visibility = 'Visible'
        $PanelCatMood.Visibility = 'Visible'
        $BtnGitHub.Visibility = 'Visible'
        $LblNavHome.Visibility = 'Visible'
        $LblNavStrats.Visibility = 'Visible'
        $LblNavSettings.Visibility = 'Visible'
        foreach ($nb in @($BtnNavHome, $BtnNavStrats, $BtnNavSettings)) {
            $nb.HorizontalContentAlignment = 'Left'
            $nb.ClearValue([System.Windows.Controls.Control]::PaddingProperty)
        }
        $PanelSideStatusText.Visibility = 'Visible'
        if ($null -ne $ColSideStatusText) { $ColSideStatusText.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        [System.Windows.Controls.Grid]::SetColumn($BtnRefresh, 1)
        [System.Windows.Controls.Grid]::SetColumnSpan($BtnRefresh, 1)
        $BtnRefresh.HorizontalAlignment = 'Right'
        $SideStatusCard.Padding = New-Object System.Windows.Thickness(10,8,10,8)
        $ImgKotek.Width = 134
        $PathToggleArrow.Data = [System.Windows.Media.Geometry]::Parse('M15.41,7.41 L14,6 L8,12 L14,18 L15.41,16.59 L10.83,12 Z')
    }
})

function Get-StrategyScores {
    $map = @{}
    $sf = Join-Path $Root 'utils\strategy_scores.json'
    if (Test-Path -LiteralPath $sf) {
        try {
            $obj = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj) {
                foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
            }
        } catch {}
    }
    return $map
}

$script:CurrentTab = 'core'
$script:CurrentItems = @()
$script:WatchedProc = $null
$script:SuppressUdpEvent = $false
$script:CatIdleFrames = @('(=^.^=)', '(=^.^=)', '(=^.^=)', '(=^.^=)', '(=-.-=)', '(=^.^=)')
$script:CatWorkFrames = @('(=^.^=) .  ', '(=^.^=) .. ', '(=^.^=) ...', '(=-.-=) ...', '(=-.-=)  ~ ', '(=^.^=)    ')
$script:CatIdx = 0

function Set-Status([string]$msg, [string]$hex = '#737A86') {
    $TxtStatusBar.Text = $msg
    $TxtStatusBar.Foreground = $script:BrushConv.ConvertFromString($hex)
}

function Switch-Nav([string]$page) {
    $ViewHome.Visibility     = if ($page -eq 'home')     { 'Visible' } else { 'Collapsed' }
    $ViewStrats.Visibility   = if ($page -eq 'strats')   { 'Visible' } else { 'Collapsed' }
    $ViewSettings.Visibility = if ($page -eq 'settings') { 'Visible' } else { 'Collapsed' }

    $BtnNavHome.Style     = if ($page -eq 'home')     { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    $BtnNavStrats.Style   = if ($page -eq 'strats')   { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    $BtnNavSettings.Style = if ($page -eq 'settings') { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    if ($page -ne 'home' -and $null -ne $AutoDoneCard) {
        $AutoDoneCard.Visibility = 'Collapsed'
    }
    if ($ActiveTaskCard.Visibility -eq 'Visible') {
        $StatusRow.Visibility = if ($page -eq 'home') { 'Collapsed' } else { 'Visible' }
    }
}

$BtnGitHub.Add_Click({
    $repoUrl = 'https://github.com/vanch150/zapret2-kotek'
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc -Encoding UTF8)) {
            if ($l -match '^\s*repo\s*=\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*$') {
                $r = $matches[1].Trim()
                if ($r -and $r -notlike 'OWNER/*') { $repoUrl = "https://github.com/$r" }
            }
        }
    }
    if ($repoUrl -match '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        try { Start-Process $repoUrl } catch {}
    }
})
$BtnNavHome.Add_Click({ Switch-Nav 'home' })
$BtnNavStrats.Add_Click({ Switch-Nav 'strats' })
$BtnNavSettings.Add_Click({ Switch-Nav 'settings' })

function Load-UdpFakes([string]$ActiveName) {
    $script:SuppressUdpEvent = $true
    $CmbUdpFake.Items.Clear()
    $binDir = Join-Path $Root 'bin'
    $allUdp = @(Get-ChildItem -LiteralPath $binDir -Filter '*.bin' -File | Where-Object {
        $_.Name -notlike 'ACTIVE_*' -and $_.Name -match '^(quic|dtls|discord|stun|wireguard|dht|dns|ntp|zero|isakmp|sip|snmp)'
    } | Sort-Object Name)
    $selIdx = 0
    for ($i = 0; $i -lt $allUdp.Count; $i++) {
        [void]$CmbUdpFake.Items.Add($allUdp[$i].Name)
        if ($allUdp[$i].Name -ieq $ActiveName) { $selIdx = $i }
    }
    if ($CmbUdpFake.Items.Count -gt 0) { $CmbUdpFake.SelectedIndex = $selIdx }
    if ($null -ne $TxtUdpCurrent) { $TxtUdpCurrent.Text = "Сейчас: $ActiveName" }
    $script:SuppressUdpEvent = $false
}

function Load-Strategies([string]$tab) {
    $script:CurrentTab = $tab
    $core = @(Get-Z2Strategies $Root 'core')
    $arch = @(Get-Z2Strategies $Root 'arch')

    $BtnTabCore.Content = "Базовые ($($core.Count))"
    $BtnTabArch.Content = "Дополнительные ($($arch.Count))"

    if ($tab -eq 'core') {
        $BtnTabCore.Style = $win.Resources['SegActive']
        $BtnTabArch.Style = $win.Resources['SegInactive']
        $script:CurrentItems = $core
    } else {
        $BtnTabCore.Style = $win.Resources['SegInactive']
        $BtnTabArch.Style = $win.Resources['SegActive']
        $script:CurrentItems = $arch
    }

    # Refresh hybrid recipe banner (if utils\last_hybrid.json exists)
    $hybRecipeDesc = ''
    $hybFile = Join-Path $Root 'utils\last_hybrid.json'
    if (Test-Path -LiteralPath $hybFile) {
        try {
            $hj = Get-Content -LiteralPath $hybFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($null -ne $hj -and $hj.yt) {
                $hYtS  = [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.yt)
                $hDcS  = [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.dc)
                $hWebS = [System.IO.Path]::GetFileNameWithoutExtension([string]$hj.web)
                $hybRecipeDesc = "YT: $hYtS · DC: $hDcS · WEB: $hWebS"
                if ($null -ne $BdHybridRecipe -and $null -ne $TxtHybridRecipe) {
                    if ($script:ActiveStratName -ieq 'custom_auto_synthesized') {
                        $TxtHybridRecipe.Text = $hybRecipeDesc
                        if ($null -ne $TxtHybridScore) {
                            $TxtHybridScore.Text = if ($hj.total -and [int]$hj.total -gt 0) { "$($hj.ok)/$($hj.total) · ~$($hj.ms) мс" } else { '' }
                        }
                        $BdHybridRecipe.Visibility = 'Visible'
                    } else {
                        $BdHybridRecipe.Visibility = 'Collapsed'
                    }
                }
            }
        } catch {}
    } elseif ($null -ne $BdHybridRecipe) {
        $BdHybridRecipe.Visibility = 'Collapsed'
    }

    $stratMetaMap = @{
        'custom_auto_synthesized'  = @('Гибрид',        'Персональный гибрид YouTube + Discord + Web под твоего провайдера')
        'general (ALT12)'          = @('hostfakesplit', 'Подмена SNI + multisplit — часто лучшая для YouTube 1080p и 7TV')
        'general (ALT11)'          = @('multisplit',    'Агрессивный fake (tcp_ts) + multisplit seqovl — быстрая универсальная база')
        'general (ALT)'            = @('fakedsplit',    'Классический fakedsplit + tcp_ts — стабильная база для большинства сетей')
        'general (ALT7)'           = @('syndata',       'Чистый multisplit seqovl + syndata в TCP SYN (без зависимости от tcp_ts)')
        'general (FAKE TLS AUTO)'  = @('multidisorder', 'Обратный порядок сегментов + badseq/badack — работает там, где tcp_ts не идёт')
        'custom_wssize_antifreeze' = @('wssize',        'Антифриз TCP-окна (wssize) + multisplit против 16-КБ шейпинга скорости')
        'custom_md5_disorder'      = @('tcp_md5',       'fakeddisorder + hostfakesplit с подписью TCP MD5 (без tcp_ts)')
        'custom_youtube_south'     = @('fakedsplit',    'Оптимизирована под региональные кэши YouTube и южных провайдеров')
        'custom_clean_disorder'    = @('multidisorder', 'Чистый multidisorder + seqovl без фейков (когда ТСПУ режет любые фейки)')
        'custom_badsum_hostfake'   = @('badsum',        'hostfakesplit:disorder_after + badsum + ip_autottl (без tcp_ts)')
        'custom_fakeddisorder_pad' = @('padencap',      'fakeddisorder + tcp_seq/tcp_ack + tls_mod=rnd,dupsid,padencap (без tcp_ts)')
        'custom_youtube_wssize'    = @('wssize YT',     'Точечный wssize на list-google.txt + multidisorder против 16-КБ фриза YouTube')
        'custom_domru_spb'         = @('fakedsplit',    'Лёгкий профиль с минимумом фейков и низким пингом (Дом.ру / СПб)')
        'custom_auto_circular'     = @('circular',      'Авто-ротация 5 механик при сбоях (экспериментальная)')
        'custom_autottl_hostfake'  = @('autottl',       'hostfakesplit + disorder_after с автоподбором TTL')
        'custom_oob_ts'            = @('oob',           'Внеполосные TCP-байты (OOB) + tcp_ts')
        'custom_delayed_split'     = @('tcpseg',        'Отложенная нарезка сегментов (tcpseg / delayed split)')
        'custom_kyber_tls13'       = @('kyber',         'Фейки с постквантовым TLS 1.3 Kyber + padencap')
        'custom_ultimate_pro'      = @('комбо',         'Комбинированный тяжёлый профиль для жёстких ТСПУ')
        'custom_valorant_end'      = @('игровой',       'Щадящий профиль для онлайн-игр и чувствительных античитов')
    }

    $prevSelName = if ($ListStrategies.SelectedItem -and $ListStrategies.SelectedItem.Name) { [string]$ListStrategies.SelectedItem.Name } else { '' }
    $scores = Get-StrategyScores
    $bc = $script:BrushConv
    $rowsList = New-Object System.Collections.Generic.List[object]

    foreach ($f in $script:CurrentItems) {
        $shortName = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $isAct = ($script:ActiveStratName -and ($shortName -ieq $script:ActiveStratName))
        $techTag = ''
        $descTxt = 'Пользовательская или архивная стратегия обхода'
        if ($stratMetaMap.ContainsKey($shortName)) {
            $techTag = $stratMetaMap[$shortName][0]
            $descTxt = $stratMetaMap[$shortName][1]
        } elseif ($shortName -match '(?i)ALT\d*') {
            $techTag = 'Flowseal ALT'
            $descTxt = 'Альтернативный профиль из коллекции Flowseal'
        }
        if ($shortName -ieq 'custom_auto_synthesized' -and $hybRecipeDesc) {
            $descTxt = $hybRecipeDesc
        }

        $scoreMain = '—'
        $pingTxt   = ''
        $pingVis   = 'Collapsed'
        $bdTxt     = ''
        $bdVis     = 'Collapsed'
        $frVis     = 'Collapsed'
        $frTxt     = ''
        $frBg      = '#23262E'
        $frBorder  = '#343844'
        $frFg      = '#9CA3AF'
        $tipTxt    = "$($f.Name)`nЕщё не проверялась — выбери и нажми «Проверить выбранную»"
        $stClr     = '#646B78'
        $sortHas   = 0
        $sortRatio = -1.0
        $sortFr    = 0
        $sortMs    = 99999

        if ($scores.ContainsKey($f.Name)) {
            $sc = $scores[$f.Name]
            $okN = [int]$sc.ok; $totN = if ($sc.total) { [int]$sc.total } else { 17 }; $msN = [int]$sc.ms
            $scoreMain = "$okN/$totN"
            $pingTxt   = "~${msN} мс"
            $pingVis   = 'Visible'
            $ratio = if ($totN -gt 0) { $okN / [double]$totN } else { 0.0 }
            if ($ratio -ge 0.80) { $stClr = $AccentLightHex }
            elseif ($ratio -ge 0.55) { $stClr = '#D9B066' }
            else { $stClr = '#D97777' }
            $ytPart = if ($null -ne $sc.ytHits) { "YT $($sc.ytHits)/$($sc.ytTotal)" } else { if ($sc.yt) { 'YT OK' } else { 'YT ✕' } }
            $dcPart = if ($null -ne $sc.dcHits) { "DC $($sc.dcHits)/$($sc.dcTotal)" } else { if ($sc.dc) { 'DC OK' } else { 'DC ✕' } }
            $bdTxt = "$ytPart · $dcPart"
            $bdVis = 'Visible'

            $frVis = 'Visible'
            if ($sc.freeze) {
                $frTxt = 'HD OK'; $frBg = '#14261E'; $frBorder = '#25523D'; $frFg = '#6EE7B7'
            } else {
                $frTxt = 'SLOW'; $frBg = '#2A2115'; $frBorder = '#5C4421'; $frFg = '#F5B971'
            }
            $ytFPart = if ($null -ne $sc.PSObject.Properties['ytF']) { if ($sc.ytF) { 'OK' } else { 'SLOW' } } else { if ($sc.freeze) { 'OK' } else { 'SLOW' } }
            $cfFPart = if ($null -ne $sc.PSObject.Properties['cfF']) { if ($sc.cfF) { 'OK' } else { 'SLOW' } } else { if ($sc.freeze) { 'OK' } else { 'SLOW' } }
            $tsPart = if ($sc.ts) { $sc.ts } else { '—' }
            $tipTxt = "$($f.Name)`nИтог: $okN/$totN (~${msN} мс)`n$ytPart | $dcPart`nYT-HD (120KB): $ytFPart | CF (256KB): $cfFPart`nТест: $tsPart"

            $sortHas   = 1
            $sortRatio = $ratio
            $sortFr    = if ($sc.freeze) { 1 } else { 0 }
            $sortMs    = $msN
        }

        $rowsList.Add([PSCustomObject]@{
            FileObj       = $f
            Name          = $f.Name
            DisplayName   = $shortName
            FullName      = $f.FullName
            ActiveVis     = if ($isAct) { 'Visible' } else { 'Collapsed' }
            TechTag       = $techTag
            TagVis        = if ($techTag) { 'Visible' } else { 'Collapsed' }
            DescText      = $descTxt
            BreakdownText = $bdTxt
            BreakdownVis  = $bdVis
            FreezeVis     = $frVis
            FreezeText    = $frTxt
            FreezeBg      = $bc.ConvertFromString($frBg)
            FreezeBorder  = $bc.ConvertFromString($frBorder)
            FreezeFg      = $bc.ConvertFromString($frFg)
            ScoreMain     = $scoreMain
            PingText      = $pingTxt
            PingVis       = $pingVis
            ScoreText     = if ($pingTxt) { "$scoreMain · $pingTxt" } else { $scoreMain }
            ScoreTip      = $tipTxt
            ScoreBrush    = $bc.ConvertFromString($stClr)
            SortAct       = if ($isAct) { 1 } else { 0 }
            SortHas       = $sortHas
            SortRatio     = $sortRatio
            SortFr        = $sortFr
            SortMs        = $sortMs
        })
    }

    $sortedRows = @($rowsList | Sort-Object @{Expression='SortAct';Descending=$true}, @{Expression='SortHas';Descending=$true}, @{Expression='SortRatio';Descending=$true}, @{Expression='SortFr';Descending=$true}, @{Expression='SortMs';Ascending=$true}, @{Expression='DisplayName';Ascending=$true})
    $script:CurrentItems = @($sortedRows | ForEach-Object { $_.FileObj })
    $ListStrategies.Items.Clear()
    $restoreIdx = 0
    $rowIdx = 0
    foreach ($ro in $sortedRows) {
        [void]$ListStrategies.Items.Add($ro)
        if ($prevSelName -and $ro.Name -ieq $prevSelName) { $restoreIdx = $rowIdx }
        $rowIdx++
    }
    if ($ListStrategies.Items.Count -gt 0) { $ListStrategies.SelectedIndex = $restoreIdx }

    # Populate Home quick strategy ComboBox (placeholder at index 0 + all core & archive)
    $script:SuppressQuickStratEvent = $true
    $script:AllQuickStrats = @($core) + @($arch)
    $CmbQuickStrat.Items.Clear()
    [void]$CmbQuickStrat.Items.Add('— выбери стратегию —')
    $selQ = 0
    for ($qi = 0; $qi -lt $script:AllQuickStrats.Count; $qi++) {
        $sfItem = $script:AllQuickStrats[$qi]
        $shortN = [System.IO.Path]::GetFileNameWithoutExtension($sfItem.Name)
        [void]$CmbQuickStrat.Items.Add($sfItem.Name)
        if ($shortN -ieq $script:ActiveStratName) { $selQ = $qi + 1 }
    }
    $CmbQuickStrat.SelectedIndex = $selQ
    $script:SuppressQuickStratEvent = $false
}

function Refresh-Dashboard {
    $bc = $script:BrushConv
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $svcZ -and $svcZ.Status -eq 'Running') {
        $script:ZapretIsRunning = $true
        $TxtZapretState.Text = '● Обход DPI работает'
        $TxtZapretState.Foreground = $bc.ConvertFromString($AccentLightHex)
        $TxtSideState.Text = '● Работает'
        $TxtSideState.Foreground = $bc.ConvertFromString($AccentLightHex)
        $BtnPause.Content = 'Пауза'
    } else {
        $script:ZapretIsRunning = $false
        $TxtZapretState.Text = '○ Обход DPI остановлен'
        $TxtZapretState.Foreground = $bc.ConvertFromString('#D97777')
        $TxtSideState.Text = '○ Остановлен'
        $TxtSideState.Foreground = $bc.ConvertFromString('#D97777')
        $BtnPause.Content = 'Включить'
    }
    if ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited) {
        if ($script:ZapretIsRunning) { Set-KotekEmotion 'happy' } else { Set-KotekEmotion 'sleep' }
    }

    $strat = 'Не установлена'
    try {
        $rv = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube'
        if (-not [string]::IsNullOrWhiteSpace($rv)) { $strat = $rv }
    } catch {}
    $script:ActiveStratName = $strat
    $TxtSideStrat.Text = $strat

    $tgMode = 'smart'; $tgHost = '127.0.0.1'; $tgPort = '1443'
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    if (Test-Path -LiteralPath $tgConf) {
        foreach ($l in (Get-Content -LiteralPath $tgConf -Encoding UTF8)) {
            if ($l -match '^(?i)mode=(.+)$') { $tgMode = $matches[1].Trim() }
            elseif ($l -match '^(?i)host=(.+)$') { $tgHost = $matches[1].Trim() }
            elseif ($l -match '^(?i)port=(\d+)$') { $tgPort = $matches[1].Trim() }
        }
    }

    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    $script:SuppressTgModeEvent = $true
    $mIdx = [Array]::IndexOf(@('smart','direct','cfonly'), $tgMode.ToLowerInvariant())
    if ($mIdx -ge 0) { $CmbTgMode.SelectedIndex = $mIdx }
    $script:SuppressTgModeEvent = $false
    $modeHint = if ($script:TgModeHints.ContainsKey($tgMode.ToLowerInvariant())) { $script:TgModeHints[$tgMode.ToLowerInvariant()] } else { $tgMode }
    if ($null -ne $svcTg -and $svcTg.Status -eq 'Running') {
        $TxtTgStatusLine.Text = "Активен · ${tgHost}:${tgPort} · $modeHint"
        $TxtTgStatusLine.Foreground = $bc.ConvertFromString($AccentLightHex)
        if ($null -ne $BtnTgToggle) { $BtnTgToggle.Content = 'Выключить' }
    } else {
        $TxtTgStatusLine.Text = "Выключен · ${tgHost}:${tgPort} · $modeHint"
        $TxtTgStatusLine.Foreground = $bc.ConvertFromString('#9CA3AF')
        if ($null -ne $BtnTgToggle) { $BtnTgToggle.Content = 'Включить' }
    }
    if ($script:AllQuickStrats) {
        $script:SuppressQuickStratEvent = $true
        $foundQ = 0
        for ($qi = 0; $qi -lt $script:AllQuickStrats.Count; $qi++) {
            if ([System.IO.Path]::GetFileNameWithoutExtension($script:AllQuickStrats[$qi].Name) -ieq $script:ActiveStratName) {
                $foundQ = $qi + 1
                break
            }
        }
        $CmbQuickStrat.SelectedIndex = $foundQ
        $script:SuppressQuickStratEvent = $false
    }

    $ipTxt = 'IPSet: нет'
    $ipFile = Join-Path $Root 'lists\ipset-all.txt'
    if (Test-Path -LiteralPath $ipFile) {
        $sz = (Get-Item -LiteralPath $ipFile).Length
        if ($sz -eq 0) { $ipTxt = 'IPSet: ANY' }
        elseif ($sz -ge 64) {
            $ipStamp = (Get-Item -LiteralPath $ipFile).LastWriteTimeUtc.Ticks
            if ($script:CachedIpStamp -ne $ipStamp) {
                $c = 0
                foreach ($ln in [System.IO.File]::ReadLines($ipFile)) {
                    if ($ln.Length -gt 0 -and $ln[0] -ne '#') { $c++ }
                }
                $script:CachedIpStamp = $ipStamp
                $script:CachedIpCount = $c
            }
            $ipCnt = $script:CachedIpCount
            $ipTxt = if ($ipCnt -ge 1000) { "IPSet: $([Math]::Round($ipCnt / 1000.0, 1))k" } else { "IPSet: $ipCnt" }
        }
        else { $ipTxt = 'IPSet: NONE' }
    }

    $ufFile = Join-Path $Root 'utils\active_udp_fake.txt'
    $udpFake = 'quic_initial_www_google_com.bin'
    if (Test-Path -LiteralPath $ufFile) {
        $v = ([string](Get-Content -LiteralPath $ufFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($v) { $udpFake = $v }
    }
    $TxtHeroMeta.Text = "$ipTxt  ·  UDP: $udpFake"
    Load-UdpFakes $udpFake

    $ChkAutoHost.IsChecked = (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled'))
    $ChkWarp.IsChecked     = (Test-Path -LiteralPath (Join-Path $Root 'utils\warp_unblock.enabled'))

    $gfOn = $false
    $gfFile = Join-Path $Root 'utils\game_filter.enabled'
    if (Test-Path -LiteralPath $gfFile) {
        foreach ($l in (Get-Content -LiteralPath $gfFile -Encoding UTF8)) {
            if ($l -match '^(?i)mode=(.+)$') {
                $m = $matches[1].Trim().ToLowerInvariant()
                if ($m -ne 'disabled' -and $m -ne 'off') { $gfOn = $true }
            }
        }
    }
    $ChkGameFilter.IsChecked = $gfOn
    $vpnIfFlag  = Join-Path $Root 'utils\vpn_ifidx.enabled'
    $vpnIfNames = Join-Path $Root 'utils\vpn_ifidx.names'
    $vpnIfOn    = (Test-Path -LiteralPath $vpnIfFlag)
    $ChkNlmVpn.IsChecked = $vpnIfOn
    if ($vpnIfOn) {
        $nmTxt = if (Test-Path -LiteralPath $vpnIfNames) { ([string](Get-Content -LiteralPath $vpnIfNames -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '' }
        if ($nmTxt) {
            $cleanNms = @($nmTxt -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $shortNms = if ($cleanNms.Count -gt 2) { ($cleanNms[0..1] -join ', ') + " и ещё $($cleanNms.Count - 2)" } else { ($cleanNms -join ', ') }
            $TxtNlmStatus.Text = "Обход на: $shortNms (все VPN исключены)"
            $TxtNlmStatus.ToolTip = "Интерфейсы обхода WinDivert: $($cleanNms -join ', ')"
            $TxtNlmStatus.Foreground = $bc.ConvertFromString($AccentLightHex)
        } else {
            $TxtNlmStatus.Text = 'Активно: обход только на физ. картах (Ethernet / Wi-Fi / PPPoE), все VPN исключены'
            $TxtNlmStatus.ToolTip = $null
            $TxtNlmStatus.Foreground = $bc.ConvertFromString($AccentLightHex)
        }
    } else {
        $TxtNlmStatus.Text = 'Выключено — обход работает на всех сетевых интерфейсах Windows'
        $TxtNlmStatus.ToolTip = $null
        $TxtNlmStatus.Foreground = $bc.ConvertFromString('#9CA3AF')
    }
    $ChkKernelFilter.IsChecked = (Test-Path -LiteralPath (Join-Path $Root 'utils\kernel_filter.enabled'))
    $trayEn = (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_mode.enabled'))
    $ChkTrayMode.IsChecked = $trayEn
    if ($null -ne $ChkTrayStartMin) { $ChkTrayStartMin.IsChecked = $trayEn -and (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_start_minimized.enabled')) }
    if ($null -ne $ChkTelemetry)    { $ChkTelemetry.IsChecked    = (Test-Path -LiteralPath (Join-Path $Root 'utils\telemetry.enabled')) }
    $bpAppliedNames = @()
    $anyQuicOff = $false
    $anyDohOn   = $false
    $bpMissingNames = @()
    $bhCheck = Join-Path $Root 'utils\browser_helper.ps1'
    if (Test-Path -LiteralPath $bhCheck) {
        try {
            $brAll = @(Get-Z2BrowserStates)
            $brAuto = @($brAll | Where-Object { $_.Kind -ne 'manual' })
            $bpAppliedNames = @($brAuto | Where-Object { $_.QuicOff } | ForEach-Object { $_.Name })
            $bpMissingNames = @($brAuto | Where-Object { -not $_.QuicOff } | ForEach-Object { $_.Name })
            $anyQuicOff = ($bpAppliedNames.Count -gt 0)
            $anyDohOn   = (@($brAuto | Where-Object { $_.DohOn }).Count -gt 0)
        } catch {}
    }
    if ($null -ne $ChkBrowserQuic) { $ChkBrowserQuic.IsChecked = $anyQuicOff }
    $bpApplied = ($bpAppliedNames.Count -gt 0)

    # Refresh AI bypass card
    $aiHelperPath = Join-Path $Root 'utils\ai_bypass_helper.ps1'
    if ((Test-Path -LiteralPath $aiHelperPath) -and $null -ne $TxtAiStatusLine) {
        $aiSt = $null
        try { $aiSt = Get-Z2AiBypassState $Root } catch {}
        if ($null -ne $aiSt) {
            if ($null -ne $CmbAiMode) {
                try {
                    $script:SuppressAiModeEvent = $true
                    $aIdx = [Array]::IndexOf([string[]]$script:AiModeKeys, [string]$aiSt.Mode)
                    if ($aIdx -lt 0) { $aIdx = 0 }
                    $CmbAiMode.SelectedIndex = $aIdx
                } catch {} finally {
                    $script:SuppressAiModeEvent = $false
                }
            }
            $selSvcList = @($aiSt.Services)
            $script:AiAppliedServicesStr = ($selSvcList -join ',')
            $script:AiNeedsRestart = $false
            foreach ($sid in @($script:AiServiceCheckMap.Keys)) {
                $chk = $script:AiServiceCheckMap[$sid]
                if ($null -ne $chk) { $chk.IsChecked = ($selSvcList -contains $sid) }
            }
            if ($null -ne $TxtAiPendingHint) { $TxtAiPendingHint.Visibility = 'Collapsed' }
            Update-Z2AiSpecialHints
            $vpnNowAi = $null
            if (Get-Command Get-Z2ActiveVpnInfo -ErrorAction SilentlyContinue) {
                try { $vpnNowAi = Get-Z2ActiveVpnInfo } catch {}
            }
            $script:AiBypassActiveNow = [bool]$aiSt.Active
            if ($aiSt.Active) {
                $warnDoh = if ($anyDohOn) { ' · [!] DoH браузера мешает' } else { '' }
                $warnVpn = if ($null -ne $vpnNowAi -and $vpnNowAi.Active) { " · [!] VPN ($($vpnNowAi.Label)) — возможен двойной прокси" } else { '' }
                $TxtAiStatusLine.Text = "Включён · $($aiSt.ActiveName) · $($aiSt.ServicesLabel) ($($aiSt.RuleCount) доменов)$warnDoh$warnVpn"
                $TxtAiStatusLine.Foreground = if ($anyDohOn -or ($null -ne $vpnNowAi -and $vpnNowAi.Active)) { $bc.ConvertFromString('#D9B066') } else { $bc.ConvertFromString($AccentLightHex) }
                if ($null -ne $BtnAiToggle) { $BtnAiToggle.Content = 'Выключить' }
            } elseif ($script:AiPausedByVpn) {
                $vpnLblP = if ($null -ne $vpnNowAi -and $vpnNowAi.Active) { $vpnNowAi.Label } else { 'VPN' }
                $TxtAiStatusLine.Text = "На паузе (активен $vpnLblP) · вернётся сам после отключения VPN"
                $TxtAiStatusLine.Foreground = $bc.ConvertFromString('#D9B066')
                if ($null -ne $BtnAiToggle) { $BtnAiToggle.Content = 'Выключить' }
            } else {
                $TxtAiStatusLine.Text = if ($aiSt.ServicesLabel -and $aiSt.ServicesLabel -ne 'не выбрано') { "Выключен · выбрано: $($aiSt.ServicesLabel)" } else { 'Выключен' }
                $TxtAiStatusLine.Foreground = $bc.ConvertFromString('#9CA3AF')
                if ($null -ne $BtnAiToggle) { $BtnAiToggle.Content = 'Включить' }
            }
        }
    }
    if ($bpApplied) {
        if ($bpMissingNames.Count -gt 0) {
            $totBr = $bpAppliedNames.Count + $bpMissingNames.Count
            $TxtBrowserFixState.Text = "QUIC выкл: $($bpAppliedNames -join ', ')  ·  Без фикса: $($bpMissingNames -join ', ')"
            $TxtBrowserFixState.Foreground = $bc.ConvertFromString('#D9B066')
            if ($null -ne $TxtBrowserFixBadge) { $TxtBrowserFixBadge.Text = "$($bpAppliedNames.Count) из $totBr"; $TxtBrowserFixBadge.Foreground = $bc.ConvertFromString('#D9B066') }
            if ($null -ne $BdBrowserFixBadge)  { $BdBrowserFixBadge.Background = $bc.ConvertFromString('#2B2518'); $BdBrowserFixBadge.BorderBrush = $bc.ConvertFromString('#4E4226') }
        } else {
            $TxtBrowserFixState.Text = "QUIC выкл для: $($bpAppliedNames -join ', ')"
            $TxtBrowserFixState.Foreground = $bc.ConvertFromString($AccentLightHex)
            if ($null -ne $TxtBrowserFixBadge) { $TxtBrowserFixBadge.Text = "Применён ($($bpAppliedNames.Count))"; $TxtBrowserFixBadge.Foreground = $bc.ConvertFromString('#7BC4A4') }
            if ($null -ne $BdBrowserFixBadge)  { $BdBrowserFixBadge.Background = $bc.ConvertFromString('#1C3128'); $BdBrowserFixBadge.BorderBrush = $bc.ConvertFromString('#2B4E40') }
        }
    } else {
        $TxtBrowserFixState.Text = 'Включай, если тормозит YouTube или не грузятся смайлы 7TV (переводит браузеры на стабильный TCP 443)'
        $TxtBrowserFixState.Foreground = $bc.ConvertFromString('#9CA3AF')
        if ($null -ne $TxtBrowserFixBadge) { $TxtBrowserFixBadge.Text = 'Выключен'; $TxtBrowserFixBadge.Foreground = $bc.ConvertFromString('#9CA3AF') }
        if ($null -ne $BdBrowserFixBadge)  { $BdBrowserFixBadge.Background = $bc.ConvertFromString('#23262E'); $BdBrowserFixBadge.BorderBrush = $bc.ConvertFromString('#343844') }
    }
    $auTask = Get-Z2AutoUpdateTask
    $curIpMode = Get-Z2IpsetMode $Root
    $script:SuppressIpsetEvent = $true
    $ipIdx = [Array]::IndexOf($script:IpsetModeKeys, $curIpMode)
    $CmbIpsetMode.SelectedIndex = if ($ipIdx -ge 0) { $ipIdx } else { 0 }
    $script:SuppressIpsetEvent = $false
    $ChkAutoUpdate.IsChecked = ($null -ne $auTask)
    $auModeVal = 'weekly'
    $auModeFile = Join-Path $Root 'utils\autoupdate.mode'
    if (Test-Path -LiteralPath $auModeFile) {
        $mv = ([string](Get-Content -LiteralPath $auModeFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim().ToLowerInvariant()
        if ($mv -in $script:AutoUpdKeys) { $auModeVal = $mv }
    }
    $script:SuppressAutoUpdEvent = $true
    $auIdx = [Array]::IndexOf($script:AutoUpdKeys, $auModeVal)
    $CmbAutoUpdMode.SelectedIndex = if ($auIdx -ge 0) { $auIdx } else { 0 }
    $CmbAutoUpdMode.IsEnabled = ($null -ne $auTask)
    $script:SuppressAutoUpdEvent = $false
}

$CmbUdpFake.Add_SelectionChanged({
    if ($script:SuppressUdpEvent) { return }
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $sel = [string]$CmbUdpFake.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $src = Join-Path (Join-Path $Root 'bin') $sel
    if (Test-Path -LiteralPath $src) {
        try {
            Copy-Item -LiteralPath $src -Destination (Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin') -Force -ErrorAction Stop
            Copy-Item -LiteralPath $src -Destination (Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin') -Force -ErrorAction Stop
            [System.IO.File]::WriteAllText((Join-Path $Root 'utils\active_udp_fake.txt'), $sel, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            Show-Toast "Не удалось сохранить UDP-фейк: $($_.Exception.Message)" $true
            Refresh-Dashboard
            return
        }
        if ($null -ne $TxtUdpCurrent) { $TxtUdpCurrent.Text = "Сейчас: $sel" }
        $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        $restartOk = $true
        if ($null -ne $svcZ) {
            try {
                if ($svcZ.Status -eq 'Running') {
                    Restart-Service -Name 'zapret' -Force -ErrorAction Stop
                }
            } catch {
                $restartOk = $false
                Show-Toast "UDP-фейк обновлён, но не удалось перезапустить службу zapret: $($_.Exception.Message)" $true
            } finally {
                try { $svcZ.Dispose() } catch {}
            }
        }
        $TxtHeroMeta.Text = ($TxtHeroMeta.Text -replace 'UDP: .*$', "UDP: $sel")
        if ($restartOk) {
            Set-Status "Применён UDP-фейк: $sel" $AccentLightHex
        } else {
            Set-Status 'Не удалось перезапустить службу zapret после смены UDP-фейка.' '#D97777'
        }
    }
})

$script:CatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CatTimer.Interval = [TimeSpan]::FromMilliseconds(650)
$script:CatTimer.Add_Tick({
    $script:CatIdx++
    $busy = ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited)
    if ($ToastBanner.Visibility -eq 'Visible' -and $script:ToastHideTick -gt 0 -and $script:CatIdx -ge $script:ToastHideTick) {
        $ToastBanner.Visibility = 'Collapsed'
        $StatusRow.Visibility = 'Visible'
        $script:ToastHideTick = 0
    }
    $isPetted = ($script:PetUntilTick -gt 0 -and $script:CatIdx -le $script:PetUntilTick)
    if ($isPetted) {
        if ($script:CatIdx -ge ($script:PetUntilTick - 4)) {
            try {
                $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
                $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
                $KotekScale.ScaleX = 1.0
                $KotekScale.ScaleY = 1.0
            } catch {}
        }
    } elseif ($script:PetUntilTick -gt 0) {
        $script:PetUntilTick = 0
        $TxtKotekPurr.Visibility = 'Collapsed'
        try {
            $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
            $KotekScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
            $KotekScale.ScaleX = 1.0
            $KotekScale.ScaleY = 1.0
        } catch {}
    }
    if ($busy) {
        if (-not $isPetted) {
            $TxtCatArt.Text = $script:CatWorkFrames[$script:CatIdx % $script:CatWorkFrames.Count]
            $TxtCatMood.Text = '  трудится...'
            Set-KotekEmotion 'work'
            if ($null -ne $KotekRotate) {
                try {
                    $ang = if (($script:CatIdx % 2) -eq 0) { -2.4 } else { 2.4 }
                    $aRot = New-Object System.Windows.Media.Animation.DoubleAnimation($ang, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(420))))
                    $KotekRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $aRot)
                } catch {}
            }
        }
        if (Test-Path -LiteralPath $script:TaskLogPath) {
            try {
                $fs = New-Object System.IO.FileStream($script:TaskLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt 0 -and $fs.Length -ne $script:LastLogLen) {
                        $script:LastLogLen = $fs.Length
                        $tailBytes = [int][Math]::Min([long]16384, $fs.Length)
                        [void]$fs.Seek(-[long]$tailBytes, [System.IO.SeekOrigin]::End)
                        $buf = New-Object byte[] $tailBytes
                        $readN = $fs.Read($buf, 0, $tailBytes)
                        $startOff = 0
                        while ($startOff -lt $readN -and (($buf[$startOff] -band 0xC0) -eq 0x80)) { $startOff++ }
                        $chunk = [System.Text.Encoding]::UTF8.GetString($buf, $startOff, $readN - $startOff)
                        $parts = $chunk -split '[\r\n]+'
                        $lastLine = ''
                        for ($li = $parts.Length - 1; $li -ge 0; $li--) {
                            $candL = $parts[$li].Trim()
                            if ($candL.Length -gt 2 -and $candL -notmatch '^[=\-\s/\\_()=*~^o.]+$') {
                                $lastLine = $candL
                                break
                            }
                        }
                        if ($lastLine) {
                            if ($lastLine -match '\[(\d+)/(\d+)\]') {
                                $script:ActiveTaskCurStep = [int]$matches[1]
                                $script:ActiveTaskTotStep = [int]$matches[2]
                                if ($null -ne $BarActiveTask -and $script:ActiveTaskTotStep -gt 0) {
                                    $BarActiveTask.IsIndeterminate = $false
                                    $BarActiveTask.Maximum = $script:ActiveTaskTotStep
                                    $BarActiveTask.Value   = [Math]::Min($script:ActiveTaskCurStep, $script:ActiveTaskTotStep)
                                }
                            }
                            if ($lastLine.Length -gt 78) { $lastLine = $lastLine.Substring(0, 75) + '...' }
                            Set-Status "$($script:ActiveTaskLabel): $lastLine" $AccentLightHex
                            $TxtActiveTaskStep.Text = $lastLine
                        }
                        if ($null -ne $TxtActiveTaskEta -and $null -ne $script:ActiveTaskStartUtc) {
                            $elSec = [int][Math]::Max(0, ([DateTime]::UtcNow - $script:ActiveTaskStartUtc).TotalSeconds)
                            $elTxt = if ($elSec -ge 60) { "{0}м {1:D2}с" -f [int][Math]::Floor($elSec / 60), ($elSec % 60) } else { "${elSec} сек" }
                            if ($script:ActiveTaskTotStep -gt 1 -and $script:ActiveTaskCurStep -ge 2 -and $script:ActiveTaskCurStep -lt $script:ActiveTaskTotStep) {
                                $remSec = [int][Math]::Max(3, [Math]::Round(($elSec / [double]$script:ActiveTaskCurStep) * ($script:ActiveTaskTotStep - $script:ActiveTaskCurStep)))
                                $remTxt = if ($remSec -ge 60) { "~{0}м {1:D2}с" -f [int][Math]::Floor($remSec / 60), ($remSec % 60) } else { "~${remSec} сек" }
                                $TxtActiveTaskEta.Text = "Прошло $elTxt · осталось $remTxt"
                            } else {
                                $TxtActiveTaskEta.Text = "Прошло $elTxt · $($script:ActiveTaskEtaBase)"
                            }
                        }
                        if ($null -ne $TxtTaskLogBox) {
                            $TxtTaskLogBox.Text = ($chunk -replace "`r(?!`n)", "`r`n").TrimStart()
                            $TxtTaskLogBox.ScrollToEnd()
                        }
                    }
                } finally {
                    $fs.Close()
                }
            } catch {}
        }
    } else {
        if ($null -ne $script:WatchedProc) {
            $ec = 0
            try { $ec = $script:WatchedProc.ExitCode } catch {}
            try { $script:WatchedProc.Dispose() } catch {}
            $script:WatchedProc = $null
            $BarProgress.Visibility = 'Collapsed'
            $ActiveTaskCard.Visibility = 'Collapsed'
            if ($null -ne $BtnCancelHybrid) { $BtnCancelHybrid.Visibility = 'Collapsed' }
            if ($null -ne $KotekRotate) {
                try { $KotekRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, (New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(220)))))) } catch {}
            }
            Set-Z2BusyUiState $false
            if ($null -ne $script:ActiveTaskBtn) {
                $script:ActiveTaskBtn.Content = $script:ActiveTaskBtnOrigText
                $script:ActiveTaskBtn.IsEnabled = $true
                $script:ActiveTaskBtn = $null
            }
            $summaryLine = ''
            $errLine = ''
            if (Test-Path -LiteralPath $script:TaskLogPath) {
                try {
                    $allLogLines = @(Get-Content -LiteralPath $script:TaskLogPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })
                    $okLines  = @($allLogLines | Where-Object { $_ -match '^(\[OK\]|\[ЛУЧШАЯ\]|\[ПОБЕДИТЕЛЬ\])' })
                    $errLines = @($allLogLines | Where-Object { $_ -match '^(\[X\]|\[ОШИБКА\])' })
                    if ($okLines.Count -gt 0)  { $summaryLine = $okLines[$okLines.Count - 1] }
                    if ($errLines.Count -gt 0) { $errLine     = $errLines[$errLines.Count - 1] }
                } catch {}
            }
            Refresh-Dashboard
            Load-Strategies $script:CurrentTab
            $lbl = if ($script:ActiveTaskLabel) { $script:ActiveTaskLabel } else { 'Задача' }
            $taskKind = $script:ActiveTaskKind
            $script:ActiveTaskKind = ''
            if ($ec -ne 0) {
                $errMsg = if ($errLine) { "$lbl — $errLine" } else { "$lbl завершилось с кодом $ec" }
                Set-Status $errMsg '#D97777'
                Show-Toast $errMsg $true
                if ((Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue) -and (Test-Z2TelemetryEnabled $Root)) {
                    try {
                        $snapE = if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) { Get-Z2TelemetrySnapshot $Root } else { '' }
                        $logTailE = if ($allLogLines -and $allLogLines.Count -gt 0) { ($allLogLines | Select-Object -Last 15) -join "`n" } else { '' }
                        $errDet = "$errMsg`n$snapE"
                        if ($logTailE) { $errDet += "`n--- Last log ---`n$logTailE" }
                        $errCode = if ($taskKind) { "${taskKind}:$ec" } else { "$ec" }
                        [void](Send-Z2TelemetryEvent -RootPath $Root -Event 'error' -Strategy $script:ActiveStratName -Code $errCode -Detail $errDet)
                    } catch {}
                }
            } elseif ($taskKind -eq 'autosetup' -and -not $script:ZapretIsRunning) {
                $errMsg = if ($errLine) { "Автонастройка: $errLine" } else { "Автонастройка не смогла запустить службу zapret (проверь диагностику)." }
                Set-Status $errMsg '#D97777'
                Show-Toast $errMsg $true
                if ((Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue) -and (Test-Z2TelemetryEnabled $Root)) {
                    try {
                        $snapE = if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) { Get-Z2TelemetrySnapshot $Root } else { '' }
                        $logTailE = if ($allLogLines -and $allLogLines.Count -gt 0) { ($allLogLines | Select-Object -Last 15) -join "`n" } else { '' }
                        $errDet = "$errMsg`n$snapE"
                        if ($logTailE) { $errDet += "`n--- Last log ---`n$logTailE" }
                        [void](Send-Z2TelemetryEvent -RootPath $Root -Event 'error' -Strategy $script:ActiveStratName -Code 'autosetup:no_svc' -Detail $errDet)
                    } catch {}
                }
            } else {
                $okMsg = if ($taskKind -eq 'autosetup') { "Автонастройка завершена — стратегия $($script:ActiveStratName) активна!" } elseif ($summaryLine) { "$lbl — $summaryLine" } else { "$lbl — успешно завершено!" }
                Set-Status $okMsg $AccentLightHex
                Show-Toast $okMsg $false
                if ($taskKind -eq 'diag') { [void](Show-Z2DiagDialog $Root $win $AccentHex) }
                if (($taskKind -eq 'autosetup' -or $taskKind -eq 'hybrid') -and $script:ZapretIsRunning) {
                    $tgSt = if ($TxtTgStatusLine.Text -like 'Активен*') { 'активен' } else { 'готов' }
                    $pct = 100; $okN = 0; $totN = 0
                    $resFile = if ($taskKind -eq 'hybrid') { Join-Path $Root 'utils\last_hybrid.json' } else { Join-Path $Root 'utils\last_autosetup.json' }
                    if (Test-Path -LiteralPath $resFile) {
                        try {
                            $rj = Get-Content -LiteralPath $resFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            if ($null -ne $rj.total -and [int]$rj.total -gt 0) {
                                $okN = [int]$rj.ok
                                $totN = [int]$rj.total
                                $pct = [int]$rj.pct
                            }
                        } catch {}
                    }
                    $bcDone = $script:BrushConv
                    $primStyle = $win.FindResource('PrimaryBtn')
                    $secStyle  = $win.FindResource('SecondaryBtn')
                    if ($taskKind -eq 'autosetup' -and $totN -gt 0 -and $pct -lt 85) {
                        $warnMsg = "Упс! Быстрый тест набрал $okN из $totN ($pct% — ниже 85%). Автоматически запускаю персональный гибрид..."
                        Set-Status $warnMsg '#F59E0B'
                        Show-Toast $warnMsg $false
                        Switch-Nav 'home'
                        Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Персональный гибрид (22 стратегии)' $BtnDeepOpt 'hybrid'
                        if ($null -ne $TxtActiveTaskTitle) {
                            $TxtActiveTaskTitle.Text = "Упс! Быстрый тест ($okN/$totN · $pct%) — собираю гибрид"
                        }
                        if ($null -ne $BtnCancelHybrid) { $BtnCancelHybrid.Visibility = 'Visible' }
                        return
                    } else {
                        $AutoDoneCard.Background  = $bcDone.ConvertFromString('#17191D')
                        $AutoDoneCard.BorderBrush = $bcDone.ConvertFromString($AccentBorderHx)
                        if ($null -ne $TxtAutoDoneTitle) {
                            $TxtAutoDoneTitle.Text = "✓  Котек всё настроил — можно пользоваться!"
                            $TxtAutoDoneTitle.Foreground = $bcDone.ConvertFromString($AccentLightHex)
                        }
                        $scoreSuffix = if ($totN -gt 0) { " ($okN/$totN · $pct%)" } else { "" }
                        $TxtAutoDoneSummary.Text = "Активная стратегия: $($script:ActiveStratName)$scoreSuffix  ·  Обход DPI: работает  ·  Telegram Proxy: $tgSt"
                        if ($null -ne $TxtAutoDoneHints) {
                            $TxtAutoDoneHints.Text = "Обход работает в фоне сам — это окно можно свернуть или закрыть в любой момент."
                        }
                        if ($taskKind -eq 'hybrid') {
                            $BtnAutoDoneDeep.Visibility = 'Collapsed'
                        } else {
                            $BtnAutoDoneDeep.Visibility = 'Visible'
                            $BtnAutoDoneDeep.Style  = $primStyle
                        }
                    }
                    if ((Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue) -and (Test-Z2TelemetryEnabled $Root)) {
                        $tScore = if ($totN -gt 0) { "$okN/$totN ($pct%)" } else { 'OK' }
                        try {
                            $okSnap = if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) { Get-Z2TelemetrySnapshot $Root } else { '' }
                            [void](Send-Z2TelemetryEvent -RootPath $Root -Event $taskKind -Strategy $script:ActiveStratName -Score $tScore -Code '0' -Detail $okSnap)
                        } catch {}
                    }
                    Sync-AutoDoneUpdBtn
                    $AutoDoneCard.Visibility = 'Visible'
                    Switch-Nav 'home'
                }
            }
        }
        if (-not $isPetted) {
            if ($null -ne $TxtCatMood) { $TxtCatMood.Foreground = $script:BrushConv.ConvertFromString('#9CA3AF') }
            if ($script:ZapretIsRunning) {
                $TxtCatArt.Text = $script:CatIdleFrames[([int]($script:CatIdx / 3)) % $script:CatIdleFrames.Count]
                $TxtCatMood.Text = '  на страже'
                Set-KotekEmotion 'happy'
            } else {
                $TxtCatArt.Text = '(=-.-=)'
                $TxtCatMood.Text = '  отдыхает'
                Set-KotekEmotion 'sleep'
            }
        }
    }
})
$script:CatTimer.Start()

function Run-ConsoleTool([string]$ScriptRel, [string]$ExtraArgs = '', [bool]$KeepOpen = $false, [string]$Label = '', $SourceBtn = $null, [string]$TaskKind = '') {
    if (($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) -or $script:BgOpBusy) {
        Set-Status 'Дождись завершения текущей задачи перед запуском новой.' '#D9B066'
        return
    }
    $sp = Join-Path $Root $ScriptRel
    $script:ActiveTaskLabel = if ($Label) { $Label } else { [System.IO.Path]::GetFileNameWithoutExtension($ScriptRel) }
    if ($TaskKind) {
        $script:ActiveTaskKind = $TaskKind
    } elseif ($ScriptRel -match 'auto_setup') {
        $script:ActiveTaskKind = 'autosetup'
    } elseif ($ScriptRel -match 'deep_optimize') {
        $script:ActiveTaskKind = 'hybrid'
    } elseif ($ScriptRel -match 'diag_report') {
        $script:ActiveTaskKind = 'diag'
    } elseif ($ScriptRel -match 'probe_one') {
        $script:ActiveTaskKind = 'probe'
    } else {
        $script:ActiveTaskKind = 'other'
    }
    if ($null -ne $SourceBtn) {
        $script:ActiveTaskBtn = $SourceBtn
        $script:ActiveTaskBtnOrigText = [string]$SourceBtn.Content
        $SourceBtn.Content = 'Работает...'
        $SourceBtn.IsEnabled = $false
    }
    $script:LastLogLen = -1
    if (Test-Path -LiteralPath $script:TaskLogPath) { Remove-Item -LiteralPath $script:TaskLogPath -Force -ErrorAction SilentlyContinue }
    $BarProgress.Visibility = 'Visible'
    $script:ActiveTaskStartUtc = [DateTime]::UtcNow
    $script:ActiveTaskCurStep  = 0
    $script:ActiveTaskTotStep  = 0
    if ($null -ne $BarActiveTask) {
        $BarActiveTask.IsIndeterminate = $true
        $BarActiveTask.Value = 0
    }
    Set-Z2BusyUiState $true
    $script:ActiveTaskEtaBase  = if ($ScriptRel -match 'deep_optimize') { 'обычно ~2–4 мин' } elseif ($ScriptRel -match 'auto_setup') { 'обычно ~1–2 мин' } elseif ($ScriptRel -match 'probe_one') { 'обычно ~5–10 сек' } else { 'обычно ~5–15 сек' }
    if ($null -ne $TxtActiveTaskEta) { $TxtActiveTaskEta.Text = $script:ActiveTaskEtaBase }
    $TxtActiveTaskTitle.Text = "Выполняется: $($script:ActiveTaskLabel)"
    $TxtActiveTaskStep.Text  = "Запуск задачи..."
    if ($null -ne $TxtTaskLogBox) { $TxtTaskLogBox.Text = "Запуск задачи..." }
    Set-KotekEmotion 'work'
    $AutoDoneCard.Visibility = 'Collapsed'
    if ($null -ne $BtnCancelHybrid) { $BtnCancelHybrid.Visibility = if ($script:ActiveTaskKind -eq 'hybrid') { 'Visible' } else { 'Collapsed' } }
    $ActiveTaskCard.Visibility = 'Visible'
    if ($ScriptRel -match 'auto_setup|deep_optimize|probe_one|fake_selector|apply_strategy') {
        $bcBusy = $script:BrushConv
        $TxtZapretState.Text = '◐ Тестирование'
        $TxtZapretState.Foreground = $bcBusy.ConvertFromString('#D9B066')
        $TxtSideState.Text = '◐ Тест...'
        $TxtSideState.Foreground = $bcBusy.ConvertFromString('#D9B066')
        $BtnPause.IsEnabled = $false
    }
    $ToastBanner.Visibility = 'Collapsed'
    $StatusRow.Visibility = if ($ViewHome.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    Set-Status "Выполняется: $($script:ActiveTaskLabel)..." $AccentLightHex
    try {
        $script:WatchedProc = Start-Z2AsyncTask $Root $sp $ExtraArgs $script:TaskLogPath
    } catch {
        $BarProgress.Visibility = 'Collapsed'
        $ActiveTaskCard.Visibility = 'Collapsed'
            if ($null -ne $BtnCancelHybrid) { $BtnCancelHybrid.Visibility = 'Collapsed' }
        $script:ActiveTaskKind = ''
        Set-Z2BusyUiState $false
        $StatusRow.Visibility = 'Visible'
        if ($null -ne $script:ActiveTaskBtn) {
            $script:ActiveTaskBtn.Content = $script:ActiveTaskBtnOrigText
            $script:ActiveTaskBtn.IsEnabled = $true
            $script:ActiveTaskBtn = $null
        }
        Show-Toast "Не удалось запустить $($script:ActiveTaskLabel)" $true
    }
}

function Install-Strategy([string]$BatFullPath) {
    $batName = [System.IO.Path]::GetFileName($BatFullPath)
    $escBat = $BatFullPath.Replace("'", "''")
    Run-ConsoleTool 'utils\apply_strategy.ps1' "-BatPath '$escBat'" $false "Установка $batName" $BtnApplyStrat
}

$BtnTabCore.Add_Click({ Load-Strategies 'core' })
$BtnTabArch.Add_Click({ Load-Strategies 'arch' })
$BtnRefresh.Add_Click({ Refresh-Dashboard; Load-Strategies $script:CurrentTab; Set-Status 'Статус обновлён.' $AccentLightHex })
$BtnOpenDir.Add_Click({
    $dirArg = Format-Z2DirNoSlash $Root
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$dirArg`""
})
$BtnCreateShortcut.Add_Click({
    Set-Z2DesktopAndFolderIcons $Root
    Show-Toast 'Ярлык Zapret2 Kotek создан на Рабочем столе и в меню Пуск' $false
})

$BtnApplyStrat.Add_Click({
    $i = $ListStrategies.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:CurrentItems.Count) { Install-Strategy $script:CurrentItems[$i].FullName }
})
$ListStrategies.Add_MouseDoubleClick({
    $i = $ListStrategies.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:CurrentItems.Count) { Install-Strategy $script:CurrentItems[$i].FullName }
})

$CmbQuickStrat.Add_SelectionChanged({
    if ($script:SuppressQuickStratEvent) { return }
    if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) {
        Set-Status 'Дождись завершения текущей задачи перед сменой стратегии.' '#D9B066'
        Refresh-Dashboard
        return
    }
    $i = $CmbQuickStrat.SelectedIndex - 1
    if ($script:AllQuickStrats -and $i -ge 0 -and $i -lt $script:AllQuickStrats.Count) {
        Install-Strategy $script:AllQuickStrats[$i].FullName
    }
})

$CmbTgMode.Add_SelectionChanged({
    if ($script:SuppressTgModeEvent) { return }
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $mi = $CmbTgMode.SelectedIndex
    if ($mi -lt 0 -or $mi -ge $script:TgModeKeys.Count) { return }
    $newMode = $script:TgModeKeys[$mi]
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    try {
        if (Test-Path -LiteralPath $tgConf) {
            $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8 -ErrorAction Stop)
            if ($rawC -match '(?m)^mode=[^\r\n]*') { $rawC = [regex]::Replace($rawC, '(?m)^mode=[^\r\n]*', "mode=$newMode") }
            else { $rawC = $rawC.TrimEnd() + "`r`nmode=$newMode`r`n" }
            [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {
        Refresh-Dashboard
        Show-Toast "Не удалось сохранить режим Telegram Proxy: $($_.Exception.Message)" $true
        return
    }
    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    $restartOk = $true
    if ($null -ne $svcTg) {
        try {
            if ($svcTg.Status -eq 'Running') {
                Restart-Service -Name 'zapret-tgws' -Force -ErrorAction Stop
            }
        } catch {
            $restartOk = $false
            Show-Toast "Режим сохранён, но не удалось перезапустить службу zapret-tgws: $($_.Exception.Message)" $true
        } finally {
            try { $svcTg.Dispose() } catch {}
        }
    }
    Refresh-Dashboard
    if ($restartOk) {
        Show-Toast "Telegram Proxy: $($script:TgModeHints[$newMode])" $false
    }
})

$BtnAddStrat.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $ofd.Title = 'Выбери .bat файл стратегии Zapret2'
        $ofd.Filter = 'Batch стратегии (*.bat)|*.bat'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $leaf = [System.IO.Path]::GetFileName($ofd.FileName)
            $reserved = @('service.bat','1_AUTO_SETUP.bat','2_KOTEK.bat','!_START_KOTEK.bat','KOTEK.bat','AUTO_SETUP.bat','DEEP_OPTIMIZE.bat','PAUSE_RESUME.bat','UNINSTALL.bat')
            if ($reserved -contains $leaf) {
                Show-Toast "Имя $leaf зарезервировано системой — переименуй файл стратегии." $true
                return
            }
            if ($leaf -notmatch '^[A-Za-z0-9 _().-]+\.bat$') {
                Show-Toast "Недопустимые символы в имени файла: $leaf" $true
                return
            }
            $fi = Get-Item -LiteralPath $ofd.FileName -ErrorAction SilentlyContinue
            if ($null -eq $fi -or $fi.Length -gt 524288) {
                Show-Toast "Файл $leaf слишком большой (макс. 512 КБ)." $true
                return
            }
            $batText = [string](Get-Content -LiteralPath $ofd.FileName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($batText -notmatch '(?i)winws2\.exe') {
                Show-Toast "Файл $leaf не содержит запуск winws2.exe — это не стратегия Zapret2." $true
                return
            }
            $stratDir = Join-Path $Root 'strategies'
            if (-not (Test-Path -LiteralPath $stratDir)) { New-Item -ItemType Directory -Path $stratDir -Force | Out-Null }
            $dstBat = Join-Path $stratDir $leaf
            try {
                if ([System.IO.Path]::GetFullPath($ofd.FileName) -ine [System.IO.Path]::GetFullPath($dstBat)) {
                    Copy-Item -LiteralPath $ofd.FileName -Destination $dstBat -Force -ErrorAction Stop
                }
                Load-Strategies 'core'
                Show-Toast "Стратегия $leaf добавлена в Базовые" $false
            } catch {
                Show-Toast "Не удалось добавить $leaf" $true
            }
        }
    } finally {
        try { $ofd.Dispose() } catch {}
    }
})

$BtnSynthStrat.Add_Click({
    Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Синтез гибридной стратегии' $BtnSynthStrat
})

$BtnProbeStrat.Add_Click({
    $i = $ListStrategies.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:CurrentItems.Count) {
        $f = $script:CurrentItems[$i]
        $escBat = $f.FullName.Replace("'", "''")
        Run-ConsoleTool 'utils\probe_one.ps1' "-BatPath '$escBat'" $false "Тест $($f.Name)" $BtnProbeStrat
    } else {
        Set-Status 'Сначала выбери стратегию в списке.' '#D9B066'
    }
})

$BtnAutoSetup.Add_Click({ Run-ConsoleTool 'utils\auto_setup.ps1' '-NonInteractive' $false 'Автонастройка' $BtnAutoSetup })
$BtnDeepOpt.Add_Click({ Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Глубокий тест (22 стратегии)' $BtnDeepOpt })
$BtnUdpOpt.Add_Click({ Run-ConsoleTool 'utils\fake_selector.ps1' '-Action auto' $false 'Подбор UDP-фейка' $BtnUdpOpt })
if ($null -ne $ChkUdpManual) {
    $ChkUdpManual.Add_Click({
        $CmbUdpFake.Visibility = if ($ChkUdpManual.IsChecked) { 'Visible' } else { 'Collapsed' }
    })
}
$BtnDiag.Add_Click({ Run-ConsoleTool 'utils\diag_report.ps1' '' $false 'Диагностика' $BtnDiag })
$BtnUpdateLists.Add_Click({ Run-ConsoleTool 'utils\update_lists.ps1' '' $false 'Обновление IPSet и Hosts' $BtnUpdateLists })

$BtnCheckUpdate.Add_Click({
    $repo = ''
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc -Encoding UTF8)) {
            if ($l -match '^\s*repo\s*=\s*(.+)$') { $repo = $matches[1].Trim() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($repo) -or $repo -like 'OWNER/*' -or ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) {
        $TxtUpdateInfo.Text = 'Укажи свой GitHub в utils\repo.conf (repo=НИК/zapret2-kotek)'
        Set-Status 'Укажи свой GitHub-репозиторий в utils\repo.conf.' '#D9B066'
        return
    }
    Set-Status "Проверяю релизы на github.com/$repo ..." $AccentLightHex
    $BtnCheckUpdate.IsEnabled = $false
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'Zapret2-Kotek-Updater')
    $script:PendingUpdRepo = $repo
    $wc.add_DownloadStringCompleted({
        param($sender, $ev)
        try {
            if ($null -ne $win -and $null -ne $win.Dispatcher -and -not $win.Dispatcher.HasShutdownStarted -and -not $win.Dispatcher.HasShutdownFinished) {
                $win.Dispatcher.Invoke([Action]{
                    if (-not $script:BgOpBusy -and ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited)) {
                        $BtnCheckUpdate.IsEnabled = $true
                    }
                    try {
                        if ($ev.Error) {
                            $msg = [string]$ev.Error.Message
                            if ($msg -match '404') {
                                $TxtUpdateInfo.Text = "Обновлений пока нет (v$Version)"
                                Set-Status "Обновлений пока нет (v$Version)." $AccentLightHex
                            } else {
                                $TxtUpdateInfo.Text = "Нет связи с GitHub (проверь интернет)"
                                Set-Status 'Не удалось подключиться к GitHub.' '#D97777'
                            }
                            return
                        }
                        $rel = $ev.Result | ConvertFrom-Json
                        $latestTag = ([string]$rel.tag_name).Trim().TrimStart('v', 'V')
                        $curNorm   = $Version.Trim().TrimStart('v', 'V')
                        $pa = @(([regex]::Matches($latestTag, '\d+') | ForEach-Object { [int]$_.Value })); $pb = @(([regex]::Matches($curNorm, '\d+') | ForEach-Object { [int]$_.Value })); $isNewer = $false; for ($vi=0; $vi -lt [Math]::Max($pa.Count,$pb.Count); $vi++) { $va = if ($vi -lt $pa.Count){$pa[$vi]}else{0}; $vb = if ($vi -lt $pb.Count){$pb[$vi]}else{0}; if ($va -gt $vb){$isNewer=$true; break}; if ($va -lt $vb){break} }
                        if ($latestTag -and $isNewer) {
                            $TxtUpdateInfo.Text = "Доступна новая версия: v$latestTag (у тебя v$Version)"
                            Set-Status "Найдено обновление: v$latestTag" $AccentLightHex
                            $ans = Show-Z2MessageDialog -Owner $win -Title 'Обновление Zapret2 Kotek' -Message "Вышла новая версия Zapret2 Kotek: v$latestTag.`nСкачать и установить обновление автоматически (с сохранением настроек)?" -Kind 'Info' -Buttons 'YesNo' -AccentHex $AccentHex
                            if ($ans -eq 'Yes') {
                                Run-ConsoleTool 'utils\self_update.ps1' "-Repo $($script:PendingUpdRepo)" $false 'Обновление Zapret2 Kotek' $BtnCheckUpdate
                            }
                        } else {
                            $TxtUpdateInfo.Text = "Установлена последняя версия (v$Version)"
                            Set-Status "Обновлений нет — у тебя последняя версия (v$Version)." $AccentLightHex
                        }
                    } catch {
                        $TxtUpdateInfo.Text = 'Ошибка разбора ответа GitHub'
                        Set-Status "Ошибка проверки обновлений: $($_.Exception.Message)" '#D97777'
                    }
                })
            }
        } catch {
        } finally {
            if ($null -ne $sender) { try { $sender.Dispose() } catch {} }
        }
    })
    try { $wc.DownloadStringAsync([Uri]"https://api.github.com/repos/$repo/releases/latest") } catch { if (-not $script:BgOpBusy -and ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited)) { $BtnCheckUpdate.IsEnabled = $true }; try { $wc.Dispose() } catch {}; Show-Toast "Не удалось подключиться к GitHub." $true }
})

$BtnUninstall.Add_Click({
    $ans = Show-Z2MessageDialog -Owner $win -Title 'Удаление Zapret2 Kotek' -Message 'Удалить службы Zapret2 Kotek, Telegram Proxy, WinDivert и автообновление?' -Kind 'Warning' -Buttons 'YesNo' -AccentHex $AccentHex
    if ($ans -eq 'Yes') {
        Run-ConsoleTool 'utils\uninstall.ps1' '-Force' $false 'Удаление Zapret2 Kotek' $BtnUninstall
    }
})

$BtnTgConnect.Add_Click({
    if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) {
        Set-Status 'Дождись завершения текущей задачи перед запуском новой.' '#D9B066'
        return
    }
    $env:Z2_ROOT = $Root
    $marker = Join-Path $Root 'utils\.tgws_connected'
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    Run-ConsoleTool 'utils\tgws_helper.ps1' 'ensure-service' $false 'Telegram Proxy' $BtnTgConnect
})

$BtnToggleTaskLog.Add_Click({
    if ($TaskLogBorder.Visibility -eq 'Visible') {
        $TaskLogBorder.Visibility = 'Collapsed'
        if ($null -ne $BtnCopyTaskLog) { $BtnCopyTaskLog.Visibility = 'Collapsed' }
        $BtnToggleTaskLog.Content = 'Лог ▾'
    } else {
        $TaskLogBorder.Visibility = 'Visible'
        if ($null -ne $BtnCopyTaskLog) { $BtnCopyTaskLog.Visibility = 'Visible' }
        $BtnToggleTaskLog.Content = 'Скрыть ▴'
        if ($null -ne $TxtTaskLogBox) { $TxtTaskLogBox.ScrollToEnd() }
    }
})
if ($null -ne $BtnCopyTaskLog) {
    $BtnCopyTaskLog.Add_Click({
        try {
            if ($TxtTaskLogBox -and $TxtTaskLogBox.Text) {
                [System.Windows.Clipboard]::SetText($TxtTaskLogBox.Text)
                Set-Status 'Лог скопирован в буфер обмена.' $AccentLightHex
            }
        } catch {}
    })
}

$BtnTgToggle.Add_Click({
    if (-not (Test-Z2GuiAdmin)) { return }
    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    $svcExists = ($null -ne $svcTg)
    $isRun = ($svcExists -and $svcTg.Status -eq 'Running')
    if ($svcTg) { try { $svcTg.Dispose() } catch {} }

    $tgNeedsReinstall = (-not $svcExists)
    if (-not $isRun -and $svcExists) {
        try {
            $tgExpectedExe = [System.IO.Path]::GetFullPath((Join-Path $Root 'bin\tg-ws-proxy.exe'))
            $tgImgPath = [string](Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret-tgws' -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
            $tgMatch = [regex]::Match($tgImgPath, '"?([A-Za-z]:\\(?:[^"]+\\)?bin\\tg-ws-proxy\.exe)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $tgMatch.Success) {
                $tgNeedsReinstall = $true
            } else {
                $tgActualExe = [System.IO.Path]::GetFullPath($tgMatch.Groups[1].Value)
                if (($tgActualExe -ine $tgExpectedExe) -or (-not (Test-Path -LiteralPath $tgExpectedExe))) {
                    $tgNeedsReinstall = $true
                }
            }
        } catch {
            $tgNeedsReinstall = $true
        }
    }

    if (-not $isRun -and $tgNeedsReinstall) {
        $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
        try {
            if (Test-Path -LiteralPath $tgConf) {
                $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
                $rawC = if ($rawC -match '(?m)^enabled=[^\r\n]*') { [regex]::Replace($rawC, '(?m)^enabled=[^\r\n]*', 'enabled=1') } else { $rawC.TrimEnd() + "`r`nenabled=1`r`n" }
                [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch {}
        $env:Z2_ROOT = $Root
        Run-ConsoleTool 'utils\tgws_helper.ps1' 'ensure-service-silent' $false 'Запуск Telegram Proxy' $BtnTgToggle
        return
    }

    Set-Status $(if ($isRun) { 'Остановка Telegram Proxy...' } else { 'Запуск Telegram Proxy...' }) '#D9B066'
    Invoke-Z2BgUiWork {
        param($RootDir, $TurnOff)
        $tgConf = Join-Path $RootDir 'utils\tgws_proxy.conf'
        try {
            if ($TurnOff) {
                Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
                Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList 'config zapret-tgws start= demand' -WindowStyle Hidden -Wait | Out-Null
                if (Test-Path -LiteralPath $tgConf) {
                    $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
                    $rawC = if ($rawC -match '(?m)^enabled=[^\r\n]*') { [regex]::Replace($rawC, '(?m)^enabled=[^\r\n]*', 'enabled=0') } else { $rawC.TrimEnd() + "`r`nenabled=0`r`n" }
                    [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
                }
                Start-Sleep -Milliseconds 300
                $s = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
                $ok = ($null -eq $s -or $s.Status -eq 'Stopped')
                if ($s) { try { $s.Dispose() } catch {} }
                return @{ Ok = $ok; Off = $true }
            } else {
                if (Test-Path -LiteralPath $tgConf) {
                    $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
                    $rawC = if ($rawC -match '(?m)^enabled=[^\r\n]*') { [regex]::Replace($rawC, '(?m)^enabled=[^\r\n]*', 'enabled=1') } else { $rawC.TrimEnd() + "`r`nenabled=1`r`n" }
                    [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
                }
                Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList 'config zapret-tgws start= auto' -WindowStyle Hidden -Wait | Out-Null
                Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 450
                $s = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
                $ok = ($null -ne $s -and $s.Status -eq 'Running')
                if ($s) { try { $s.Dispose() } catch {} }
                return @{ Ok = $ok; Off = $false }
            }
        } catch { return @{ Ok = $false; Off = $TurnOff } }
    } @{ RootDir = $Root; TurnOff = $isRun } {
        param($res, $err)
        $r = if ($res -is [System.Collections.IList] -and $res.Count -gt 0) { $res[0] } else { $res }
        Refresh-Dashboard
        if ($r -and $r.Ok) {
            if ($r.Off) { Show-Toast 'TG Proxy выключен — в Telegram переключи Тип соединения на Системный' $false }
            else { Show-Toast 'Telegram Proxy запущен' $false }
        } else {
            Show-Toast 'Не удалось изменить состояние службы Telegram Proxy' $true
        }
    }
})

$BtnPause.Add_Click({
    if (-not (Test-Z2GuiAdmin)) { return }
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -eq $svcZ) {
        Set-Status 'Служба zapret не установлена — сначала запусти Автонастройку.' '#D9B066'
        Refresh-Dashboard
        return
    }
    $isRunNow = ($svcZ.Status -eq 'Running')
    try { $svcZ.Dispose() } catch {}
    Set-Status $(if ($isRunNow) { 'Приостановка обхода...' } else { 'Возобновление обхода...' }) '#D9B066'
    Invoke-Z2BgUiWork {
        param($RootDir, $DoPause)
        try {
            . (Join-Path $RootDir 'utils\common.ps1')
            if ($DoPause) {
                Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
                Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
                $scExeP = "$env:SystemRoot\System32\sc.exe"
                foreach ($drv in @('WinDivert', 'WinDivert14')) {
                    try { Start-Process -FilePath $scExeP -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null } catch {}
                }
                Start-Sleep -Milliseconds 200
                $svcAfterP = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
                $okP = ($null -eq $svcAfterP -or $svcAfterP.Status -ne 'Running')
                if ($null -ne $svcAfterP) { try { $svcAfterP.Dispose() } catch {} }
                return @{ Action = 'pause'; Ok = $okP }
            } else {
                Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
                $tgEnResume = $true
                $tgConfResume = Join-Path $RootDir 'utils\tgws_proxy.conf'
                if (Test-Path -LiteralPath $tgConfResume) {
                    $rcResume = [string](Get-Content -LiteralPath $tgConfResume -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
                    if ($rcResume -match '(?m)^enabled=0\s*$') { $tgEnResume = $false }
                }
                if ($tgEnResume) { Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 450
                $svcAfter = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
                $ok = ($null -ne $svcAfter -and $svcAfter.Status -eq 'Running')
                if ($svcAfter) { try { $svcAfter.Dispose() } catch {} }
                return @{ Action = 'resume'; Ok = $ok }
            }
        } catch { return @{ Action = 'error'; Ok = $false } }
    } @{ RootDir = $Root; DoPause = $isRunNow } {
        param($res, $err)
        $r = if ($res -is [System.Collections.IList] -and $res.Count -gt 0) { $res[0] } else { $res }
        Refresh-Dashboard
        if ($r -and $r.Action -eq 'pause' -and $r.Ok) {
            Set-Status 'Обход поставлен на паузу.' '#D9B066'
        } elseif ($r -and $r.Action -eq 'resume' -and $r.Ok) {
            Set-Status 'Обход возобновлён.' $AccentLightHex
        } else {
            Set-Status 'Не удалось изменить состояние службы zapret — проверь диагностику.' '#D97777'
            Show-Toast 'Ошибка управления службой zapret' $true
        }
    }
})

function Apply-SettingsNow([bool]$UpdateGameFilter = $false) {
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return $false }
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $fAuto = Join-Path $Root 'utils\autohostlist.enabled'
        if ($ChkAutoHost.IsChecked) { [IO.File]::WriteAllText($fAuto, "1`r`n", $utf8NoBom) }
        elseif (Test-Path -LiteralPath $fAuto) { Remove-Item -LiteralPath $fAuto -Force -ErrorAction Stop }

        $fWarp = Join-Path $Root 'utils\warp_unblock.enabled'
        if ($ChkWarp.IsChecked) { [IO.File]::WriteAllText($fWarp, "1`r`n", $utf8NoBom) }
        elseif (Test-Path -LiteralPath $fWarp) { Remove-Item -LiteralPath $fWarp -Force -ErrorAction Stop }

        $fKern = Join-Path $Root 'utils\kernel_filter.enabled'
        if ($ChkKernelFilter.IsChecked) { [IO.File]::WriteAllText($fKern, "1`r`n", $utf8NoBom) }
        elseif (Test-Path -LiteralPath $fKern) { Remove-Item -LiteralPath $fKern -Force -ErrorAction Stop }

        if ($UpdateGameFilter) {
            $fGf = Join-Path $Root 'utils\game_filter.enabled'
            $curTcp = '1024-65535'; $curUdp = '1024-65535'; $curMode = 'all'
            if (Test-Path -LiteralPath $fGf) {
                foreach ($gl in (Get-Content -LiteralPath $fGf -Encoding UTF8)) {
                    if ($gl -match '^(?i)tcp=(.+)$') { $curTcp = $matches[1].Trim() }
                    elseif ($gl -match '^(?i)udp=(.+)$') { $curUdp = $matches[1].Trim() }
                    elseif ($gl -match '^(?i)mode=(.+)$') { $m = $matches[1].Trim().ToLowerInvariant(); if ($m -in @('all','tcp','udp')) { $curMode = $m } }
                }
            }
            $gfVal = if ($ChkGameFilter.IsChecked) { $curMode } else { 'disabled' }
            [IO.File]::WriteAllText($fGf, "mode=$gfVal`r`ntcp=$curTcp`r`nudp=$curUdp`r`n", $utf8NoBom)
        }
    } catch {
        Show-Toast "Не удалось сохранить настройки на диск: $($_.Exception.Message)" $true
        Refresh-Dashboard
        return $false
    }

    $cur = $script:ActiveStratName
    $batTry = Join-Path (Join-Path $Root 'strategies') ($cur + '.bat')
    if (-not (Test-Path -LiteralPath $batTry)) { $batTry = Join-Path $Root ($cur + '.bat') }
    if (-not (Test-Path -LiteralPath $batTry)) { $batTry = Join-Path (Join-Path $Root 'configs_archive') ($cur + '.bat') }
    if (Test-Path -LiteralPath $batTry) {
        Install-Strategy $batTry
    } else {
        Refresh-Dashboard
        Set-Status 'Настройка сохранена.' '#D9B066'
    }
    return $true
}
$ChkAutoHost.Add_Click({ [void](Apply-SettingsNow $false) })
$ChkWarp.Add_Click({ [void](Apply-SettingsNow $false) })
$ChkGameFilter.Add_Click({ [void](Apply-SettingsNow $true) })
$ChkKernelFilter.Add_Click({ [void](Apply-SettingsNow $false) })
$ChkNlmVpn.Add_Click({
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $nlmScript = Join-Path $Root 'utils\nlm_helper.ps1'
    if ($ChkNlmVpn.IsChecked) {
        $global:LASTEXITCODE = 0
        & $nlmScript -Action auto -Root $Root | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $ChkNlmVpn.IsChecked = $false
            Show-Toast 'Не найдено физических адаптеров для фильтра WinDivert.' $true
            return
        }
    } else {
        & $nlmScript -Action clear -Root $Root | Out-Null
    }
    [void](Apply-SettingsNow $false)
})
$BtnNlmConfig.Add_Click({
    if (-not (Test-Z2GuiAdmin)) { return }
    if (Get-Command Show-Z2NlmDialog -ErrorAction SilentlyContinue) {
        $saved = Show-Z2NlmDialog $Root $win $AccentHex
        if ($saved) {
            Refresh-Dashboard
            if (Apply-SettingsNow $false) {
                Show-Toast 'Список интерфейсов обхода (WinDivert) обновлён и применён' $false
            }
        }
    }
})
$BtnBrowserFix.Add_Click({
    if (-not (Test-Z2GuiAdmin)) { return }
    if (Show-Z2BrowserDialog $Root $win $AccentHex) {
        Refresh-Dashboard
        if ($script:Z2LastBrowserOpOk) {
            Show-Toast 'Настройки браузеров обновлены — перезапусти браузер.' $false
        } else {
            Show-Toast 'Не все политики браузеров удалось обновить — проверь права администратора.' $true
        }
    }
})
if ($null -ne $ChkBrowserQuic) {
    $ChkBrowserQuic.Add_Click({
        if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) { $ChkBrowserQuic.IsChecked = -not [bool]$ChkBrowserQuic.IsChecked; Set-Status 'Дождись завершения текущей задачи.' '#D9B066'; return }
        if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
        $bhP = Join-Path $Root 'utils\browser_helper.ps1'
        if (Test-Path -LiteralPath $bhP) {
            if ($ChkBrowserQuic.IsChecked) {
                [void](Disable-BrowserFix $true @() $Root $false $true)
                $dohClrOk = $script:Z2LastBrowserOpOk
                $appliedBr = @(Enable-BrowserFix @() $Root $true $false | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                Refresh-Dashboard
                if (-not $dohClrOk -or -not $script:Z2LastBrowserOpOk) {
                    Show-Toast 'Не удалось применить политики браузеров — проверь права администратора.' $true
                } elseif ($appliedBr.Count -gt 0) {
                    Show-Toast 'QUIC (HTTP/3) отключён в браузерах — перезапусти браузер.' $false
                } else {
                    Show-Toast 'Подходящие браузеры не найдены (Opera настраивается вручную).' $true
                }
            } else {
                [void](Disable-BrowserFix $true @() $Root $true $true)
                Refresh-Dashboard
                if ($script:Z2LastBrowserOpOk) {
                    Show-Toast 'Политики браузеров возвращены к стандартным — перезапусти браузер.' $false
                } else {
                    Show-Toast 'Не удалось сбросить политики браузеров — проверь права администратора.' $true
                }
            }
        }
    })
}

function Get-Z2GuiCheckedAiServices {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($sid in $script:AiServiceCheckMap.Keys) {
        $chk = $script:AiServiceCheckMap[$sid]
        if ($null -ne $chk -and [bool]$chk.IsChecked) { $ids.Add($sid) }
    }
    return $ids.ToArray()
}

if ($null -ne $BtnAiServices -and $null -ne $PnlAiServices) {
    $BtnAiServices.Add_Click({
        if ($PnlAiServices.Visibility -eq 'Visible') {
            $PnlAiServices.Visibility = 'Collapsed'
            $BtnAiServices.Content = 'Сервисы ▾'
        } else {
            $PnlAiServices.Visibility = 'Visible'
            $BtnAiServices.Content = 'Сервисы ▴'
        }
    })
}

function Update-Z2AiSpecialHints {
    if ($null -ne $BdAiClaudeWarn) {
        $BdAiClaudeWarn.Visibility = if ($null -ne $ChkAi_claude -and [bool]$ChkAi_claude.IsChecked) { 'Visible' } else { 'Collapsed' }
    }
    if ($null -ne $BdAiAntigravityHint) {
        $BdAiAntigravityHint.Visibility = if ($null -ne $ChkAi_antigravity -and [bool]$ChkAi_antigravity.IsChecked) { 'Visible' } else { 'Collapsed' }
    }
}

if ($null -ne $BtnAiAntigravityHelper) {
    $BtnAiAntigravityHelper.Add_Click({
        if (Get-Command Show-Z2AntigravityDialog -ErrorAction SilentlyContinue) {
            if (Show-Z2AntigravityDialog $Root $win $AccentHex) {
                if (Get-Command Refresh-Dashboard -ErrorAction SilentlyContinue) { Refresh-Dashboard }
            }
        } else {
            try { Start-Process 'https://github.com/vanch150/kotek-antigravity-helper/releases/latest' } catch {}
        }
    })
}

function Sync-Z2AiSelectionUi {
    Update-Z2AiSpecialHints
    $selIds = @(Get-Z2GuiCheckedAiServices)
    $selStr = ($selIds -join ',')
    if ($selIds.Count -gt 0) { $ToastBanner.Visibility = 'Collapsed'; $StatusRow.Visibility = 'Visible' }
    if ($script:AiBypassActiveNow) {
        $hasCustNow = $false
        if (Get-Command Get-Z2AiCustomDomains -ErrorAction SilentlyContinue) {
            $hasCustNow = (@(Get-Z2AiCustomDomains $Root).Count -gt 0)
        }
        if ($selIds.Count -eq 0 -and -not $hasCustNow) {
            $script:AiNeedsRestart = $false
            if ($null -ne $BtnAiToggle) { $BtnAiToggle.Content = 'Выключить' }
            if ($null -ne $TxtAiPendingHint) { $TxtAiPendingHint.Visibility = 'Collapsed' }
        } else {
            $changed = ($selStr -ne $script:AiAppliedServicesStr)
            $script:AiNeedsRestart = $changed
            if ($null -ne $BtnAiToggle) {
                $BtnAiToggle.Content = if ($changed) { 'Перезапустить' } else { 'Выключить' }
            }
            if ($null -ne $TxtAiPendingHint) {
                $TxtAiPendingHint.Visibility = if ($changed) { 'Visible' } else { 'Collapsed' }
            }
        }
    } elseif ($script:AiPausedByVpn) {
        $script:AiNeedsRestart = $false
        try {
            $cfgAuto = Get-Z2AiBypassConf $Root
            $cfgAuto.Services = $selStr
            Save-Z2AiBypassConf $Root $cfgAuto
            if ($null -ne $script:AiPausedByVpnInfo) {
                $selNewP = Get-Z2AiSelectionInfo $Root $selStr
                $script:AiPausedByVpnInfo.Domains = [string[]]@($selNewP.Domains)
            }
        } catch {}
        if ($null -ne $TxtAiPendingHint) { $TxtAiPendingHint.Visibility = 'Collapsed' }
    } else {
        $script:AiNeedsRestart = $false
        try {
            $cfgAuto = Get-Z2AiBypassConf $Root
            $cfgAuto.Services = $selStr
            Save-Z2AiBypassConf $Root $cfgAuto
        } catch {}
        if ($null -ne $TxtAiStatusLine) {
            $lblList = New-Object System.Collections.Generic.List[string]
            foreach ($sidL in $selIds) {
                $cL = $script:AiServiceCheckMap[$sidL]
                if ($null -ne $cL -and $cL.Content) { $lblList.Add([string]$cL.Content) }
            }
            $lblTxt = $lblList -join ', '
            $TxtAiStatusLine.Text = if ($lblTxt) { "Выключен · выбрано: $lblTxt" } else { 'Выключен' }
        }
        if ($null -ne $TxtAiPendingHint) { $TxtAiPendingHint.Visibility = 'Collapsed' }
    }
}

foreach ($sid in @($script:AiServiceCheckMap.Keys)) {
    $chkAiItem = $script:AiServiceCheckMap[$sid]
    if ($null -ne $chkAiItem) {
        $chkAiItem.Add_Click({ Sync-Z2AiSelectionUi })
    }
}

if ($null -ne $BtnAiSelAll) {
    $BtnAiSelAll.Add_Click({
        $safeKeys = @($script:AiServiceCheckMap.Keys | Where-Object { $_ -notin @('claude', 'antigravity') })
        $curSafeChecked = @($safeKeys | Where-Object { $c = $script:AiServiceCheckMap[$_]; $null -ne $c -and [bool]$c.IsChecked })
        $targetState = ($curSafeChecked.Count -lt $safeKeys.Count)
        foreach ($sid in $safeKeys) {
            $chk = $script:AiServiceCheckMap[$sid]
            if ($null -ne $chk) { $chk.IsChecked = $targetState }
        }
        Sync-Z2AiSelectionUi
    })
}

if ($null -ne $BtnAiToggle) {
    $BtnAiToggle.Add_Click({
        if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) { Set-Status 'Дождись завершения текущей задачи.' '#D9B066'; return }
        if (-not (Test-Z2GuiAdmin)) { return }
        $aiP = Join-Path $Root 'utils\ai_bypass_helper.ps1'
        $bhP = Join-Path $Root 'utils\browser_helper.ps1'
        if (-not (Test-Path -LiteralPath $aiP)) { return }
        $st = Get-Z2AiBypassState $Root
        if (($st.Active -or $script:AiPausedByVpn) -and -not $script:AiNeedsRestart) {
            $script:AiPausedByVpn     = $false
            $script:AiPausedByVpnInfo = $null
            $script:AiVpnOverride     = $false
            Set-Status 'Отключение обхода ИИ...' '#D9B066'
            Invoke-Z2BgUiWork {
                param($RootDir)
                try {
                    . (Join-Path $RootDir 'utils\ai_bypass_helper.ps1') -Root $RootDir
                    [void](Disable-Z2AiBypass $RootDir)
                    return (-not (Get-Z2AiBypassState $RootDir).Active)
                } catch { return $false }
            } @{ RootDir = $Root } {
                param($res, $err)
                Refresh-Dashboard
                $ok = ($res -is [System.Collections.IList] -and $res.Count -gt 0 -and [bool]$res[0]) -or ($res -eq $true)
                if ($ok) { Show-Toast 'Обход ИИ выключен, правила NRPT удалены.' $false }
                else { Show-Toast 'Не удалось отключить обход ИИ.' $true }
            } 20
        } else {
            $selIds = @(Get-Z2GuiCheckedAiServices)
            $selStr = ($selIds -join ',')
            $hasCustomAi = $false
            if (Get-Command Get-Z2AiCustomDomains -ErrorAction SilentlyContinue) {
                $hasCustomAi = (@(Get-Z2AiCustomDomains $Root).Count -gt 0)
            }
            if ($selIds.Count -eq 0 -and -not $hasCustomAi) {
                if ($null -ne $PnlAiServices) { $PnlAiServices.Visibility = 'Visible' }
                if ($null -ne $BtnAiServices) { $BtnAiServices.Content = 'Сервисы ▴' }
                Show-Toast 'Отметь нужные ИИ-сервисы и нажми «Включить».' $true
                return
            }
            if (Get-Command Get-Z2ActiveVpnInfo -ErrorAction SilentlyContinue) {
                $vpnBeforeEn = Get-Z2ActiveVpnInfo
                if ($vpnBeforeEn.Active) {
                    $vpnMsg = "Сейчас активен VPN/прокси: $($vpnBeforeEn.Label).`r`nОдновременная работа «Обхода ИИ» (SmartDNS) и VPN создаёт двойной прокси и сильные тормоза (особенно в Gemini и ChatGPT).`r`n`r`nВсё равно включить «Обход ИИ» принудительно?"
                    $vpnAns = Show-Z2MessageDialog -Owner $win -Title 'Конфликт: активен VPN' -Message $vpnMsg -Kind 'Warning' -Buttons 'YesNo' -AccentHex $AccentHex
                    if ($vpnAns -ne 'Yes') { return }
                    $script:AiVpnOverride = $true
                } else {
                    $script:AiVpnOverride = $false
                }
            }
            $script:AiPausedByVpn     = $false
            $script:AiPausedByVpnInfo = $null
            try {
                $cfgNow = Get-Z2AiBypassConf $Root
                $cfgNow.Services = $selStr
                Save-Z2AiBypassConf $Root $cfgNow
            } catch {}
            $dohConflict = $false
            if (Test-Path -LiteralPath $bhP) {
                $dohConflict = (@(Get-Z2BrowserStates | Where-Object { $_.DohOn }).Count -gt 0)
            }
            if ($dohConflict) {
                [void](Disable-BrowserFix $true @() $Root $false $true)
                if ($script:Z2LastBrowserOpOk) {
                    Show-Toast 'DoH в браузерах автоматически отключён (несовместим с «Обходом ИИ») — перезапусти браузер.' $false
                } else {
                    Show-Toast 'В браузерах включён DoH — не удалось автоматически отключить (отключи вручную в Настройках).' $true
                }
            }
            $selMode = 'auto'
            if ($null -ne $CmbAiMode -and $CmbAiMode.SelectedIndex -ge 0 -and $CmbAiMode.SelectedIndex -lt $script:AiModeKeys.Count) {
                $selMode = $script:AiModeKeys[$CmbAiMode.SelectedIndex]
            }
            $escM = $selMode.Replace("'", "''")
            $escS = $selStr.Replace("'", "''")
            Run-ConsoleTool 'utils\ai_bypass_helper.ps1' "-Action enable -Provider '$escM' -Services '$escS'" $false 'Включение обхода ИИ' $BtnAiToggle
        }
    })
}

if ($null -ne $BtnAiProbe) {
    $BtnAiProbe.Add_Click({
        if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) { Set-Status 'Дождись завершения текущей задачи.' '#D9B066'; return }
        Run-ConsoleTool 'utils\ai_bypass_helper.ps1' '-Action probe' $false 'Проверка обхода ИИ' $BtnAiProbe
    })
}

if ($null -ne $CmbAiMode) {
    $CmbAiMode.Add_SelectionChanged({
        if ($script:SuppressAiModeEvent) { return }
        if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) { Set-Status 'Дождись завершения текущей задачи.' '#D9B066'; Refresh-Dashboard; return }
        $aiP = Join-Path $Root 'utils\ai_bypass_helper.ps1'
        if (-not (Test-Path -LiteralPath $aiP)) { return }
        $st = Get-Z2AiBypassState $Root
        $selMode = if ($CmbAiMode.SelectedIndex -ge 0 -and $CmbAiMode.SelectedIndex -lt $script:AiModeKeys.Count) { $script:AiModeKeys[$CmbAiMode.SelectedIndex] } else { 'auto' }
        if ($st.Active) {
            $escM = $selMode.Replace("'", "''")
            Run-ConsoleTool 'utils\ai_bypass_helper.ps1' "-Action enable -Provider '$escM'" $false 'Переключение SmartDNS ИИ' $BtnAiToggle
        } else {
            try { $cfg = Get-Z2AiBypassConf $Root; $cfg.Mode = $selMode; Save-Z2AiBypassConf $Root $cfg } catch {}
        }
    })
}
$BtnEditGenUser.Add_Click({
    if (Show-Z2ListsDialog $Root $win 'general' $AccentHex) {
        Refresh-Dashboard
        Show-Toast 'Списки сайтов сохранены, служба перезапущена.' $false
    }
})
$BtnEditExUser.Add_Click({
    if (Show-Z2ListsDialog $Root $win 'exclude' $AccentHex) {
        Refresh-Dashboard
        Show-Toast 'Списки исключений сохранены, служба перезапущена.' $false
    }
})
$ChkAutoUpdate.Add_Click({
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { Sync-AutoDoneUpdBtn; return }
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    if ($ChkAutoUpdate.IsChecked) {
        $global:LASTEXITCODE = 0
        & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
        if ($LASTEXITCODE -ne 0 -or $null -eq (Get-Z2AutoUpdateTask)) {
            $ChkAutoUpdate.IsChecked = $false
            $CmbAutoUpdMode.IsEnabled = $false
            Show-Toast 'Не удалось включить автообновление — перенеси сборку в C:\Zapret2.' $true
        } else {
            $CmbAutoUpdMode.IsEnabled = $true
            $mTxt = switch ($selM) { 'onboot' { 'при включении ПК' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
            Show-Toast "Автообновление включено: $mTxt" $false
        }
    } else {
        $global:LASTEXITCODE = 0
        & $auScript -Action disable -Root $Root | Out-Null
        if ($LASTEXITCODE -ne 0 -or $null -ne (Get-Z2AutoUpdateTask)) {
            $ChkAutoUpdate.IsChecked = $true
            $CmbAutoUpdMode.IsEnabled = $true
            Show-Toast 'Не удалось отключить автообновление — проверь права администратора.' $true
        } else {
            $CmbAutoUpdMode.IsEnabled = $false
            Show-Toast 'Автообновление отключено.' $false
        }
    }
    Sync-AutoDoneUpdBtn
})
$CmbAutoUpdMode.Add_SelectionChanged({
    if ($script:SuppressAutoUpdEvent -or -not $ChkAutoUpdate.IsChecked) { return }
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    $global:LASTEXITCODE = 0
    & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
    if ($LASTEXITCODE -ne 0 -or $null -eq (Get-Z2AutoUpdateTask)) {
        $ChkAutoUpdate.IsChecked = $false
        $CmbAutoUpdMode.IsEnabled = $false
        Show-Toast 'Не удалось обновить задачу автообновления — перенеси сборку в C:\Zapret2.' $true
    } else {
        $mTxt = switch ($selM) { 'onboot' { 'при включении ПК' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
        Show-Toast "Режим автообновления: $mTxt" $false
    }
})


# Auto-sync WinDivert hardware interface filter on GUI launch (catches newly plugged USB modems / adapters)
try {
    $vpnIfSyncFlag = Join-Path $Root 'utils\vpn_ifidx.enabled'
    $nlmHlpSync = Join-Path $Root 'utils\nlm_helper.ps1'
    if ((Test-Path -LiteralPath $vpnIfSyncFlag) -and (Test-Path -LiteralPath $nlmHlpSync)) {
        $global:LASTEXITCODE = 0
        & $nlmHlpSync -Action sync -Root $Root | Out-Null
        if ($LASTEXITCODE -eq 10) {
            $sZSync = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
            if ($null -ne $sZSync -and $sZSync.Status -eq 'Running') {
                Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
            }
            if ($null -ne $sZSync) { try { $sZSync.Dispose() } catch {} }
        }
    }
} catch {}
Load-Strategies 'core'
Refresh-Dashboard
# Unified ContentRendered handler is registered below (merges AutoStart relocation + service migration)
$CmbIpsetMode.Add_SelectionChanged({
    if ($script:SuppressIpsetEvent) { return }
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $idx = $CmbIpsetMode.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:IpsetModeKeys.Count) { return }
    $mode = $script:IpsetModeKeys[$idx]
    $ok = Set-Z2IpsetMode $Root $mode
    if (-not $ok) {
        $bakChk = Join-Path $Root 'lists\ipset-all.txt.backup'
        if ($mode -eq 'loaded' -and -not (Test-Path -LiteralPath $bakChk)) {
            Show-Toast 'Нет резервной копии IPSet — нажми «Обновить» для загрузки списка.' $true
        } else {
            Show-Toast 'Не удалось переключить режим IPSet или перезапустить службу zapret.' $true
        }
        Refresh-Dashboard
        return
    }
    $script:CachedIpStamp = ''
    Refresh-Dashboard
    Show-Toast "Режим IPSet переключён: $mode" $false
})

$script:ForceExitGui = $false
$script:TrayIcon = $null
$script:TrayMenu = $null

function Dispose-Z2TrayIcon {
    if ($null -ne $script:TrayIcon) {
        try {
            $script:TrayIcon.Visible = $false
            if ($null -ne $script:TrayIcon.Icon) {
                try { $script:TrayIcon.Icon.Dispose() } catch {}
            }
            $script:TrayIcon.Dispose()
        } catch {}
        $script:TrayIcon = $null
    }
    if ($null -ne $script:TrayMenu) {
        try { $script:TrayMenu.Dispose() } catch {}
        $script:TrayMenu = $null
    }
}

function Ensure-Z2TrayIcon {
    if ($null -ne $script:TrayIcon) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Text = "Zapret2 Kotek v$Version"
    $icoF = Join-Path $Root 'utils\kotek.ico'
    if (Test-Path -LiteralPath $icoF) {
        try {
            $icoBytes = [System.IO.File]::ReadAllBytes($icoF)
            $msIco = New-Object System.IO.MemoryStream (,$icoBytes)
            try {
                $tmpIco = New-Object System.Drawing.Icon($msIco)
                try { $ni.Icon = [System.Drawing.Icon]$tmpIco.Clone() } finally { $tmpIco.Dispose() }
            } finally {
                $msIco.Dispose()
            }
        } catch {}
    }
    if ($null -eq $ni.Icon) { $ni.Icon = [System.Drawing.SystemIcons]::Shield }

    if (-not ('Z2DarkTrayRenderer' -as [type])) {
        try {
            Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class Z2DarkTrayColorTable : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(22, 27, 25); } }
    public override Color MenuBorder { get { return Color.FromArgb(46, 53, 50); } }
    public override Color MenuItemBorder { get { return Color.FromArgb(59, 73, 67); } }
    public override Color MenuItemSelected { get { return Color.FromArgb(37, 46, 43); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(37, 46, 43); } }
    public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(37, 46, 43); } }
    public override Color ImageMarginGradientBegin { get { return Color.FromArgb(22, 27, 25); } }
    public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(22, 27, 25); } }
    public override Color ImageMarginGradientEnd { get { return Color.FromArgb(22, 27, 25); } }
    public override Color SeparatorDark { get { return Color.FromArgb(42, 49, 46); } }
    public override Color SeparatorLight { get { return Color.FromArgb(42, 49, 46); } }
}
public class Z2DarkTrayRenderer : ToolStripProfessionalRenderer {
    public Z2DarkTrayRenderer() : base(new Z2DarkTrayColorTable()) { RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        if (e.Item != null && e.Item.ForeColor != Color.Empty) { e.TextColor = e.Item.ForeColor; }
        base.OnRenderItemText(e);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        using (Pen p = new Pen(Color.FromArgb(44, 52, 49))) {
            int y = e.Item.Height / 2;
            e.Graphics.DrawLine(p, 10, y, e.Item.Width - 10, y);
        }
    }
}
'@
        } catch {}
    }
    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $cm.ShowImageMargin = $false
    $cm.BackColor = [System.Drawing.Color]::FromArgb(22, 27, 25)
    $cm.ForeColor = [System.Drawing.Color]::FromArgb(241, 243, 245)
    $cm.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $cm.Padding = New-Object System.Windows.Forms.Padding(4, 5, 4, 5)
    try { if ('Z2DarkTrayRenderer' -as [type]) { $cm.Renderer = New-Object Z2DarkTrayRenderer } } catch {}

    $miOpen = $cm.Items.Add('Открыть Zapret2 Kotek')
    $miOpen.ForeColor = [System.Drawing.Color]::FromArgb(241, 243, 245)
    $miOpen.Padding = New-Object System.Windows.Forms.Padding(8, 5, 12, 5)
    $miOpen.Add_Click({
        $win.ShowInTaskbar = $true
        $win.Show()
        Fit-Z2WindowToScreen
        $win.Activate()
        $script:CatTimer.Start()
        Refresh-Dashboard
    })
    $miPause = $cm.Items.Add('Пауза / Возобновить обход')
    $miPause.ForeColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $miPause.Padding = New-Object System.Windows.Forms.Padding(8, 5, 12, 5)
    $miPause.Add_Click({
        if ($BtnPause.IsEnabled -and ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited) -and -not $script:BgOpBusy) {
            $BtnPause.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
    })
    [void]$cm.Items.Add('-')
    $miExit = $cm.Items.Add('Выход')
    $miExit.ForeColor = [System.Drawing.Color]::FromArgb(252, 165, 165)
    $miExit.Padding = New-Object System.Windows.Forms.Padding(8, 5, 12, 5)
    $miExit.Add_Click({
        $script:ForceExitGui = $true
        if ($null -ne $script:WatchedProc) {
            try { Stop-Z2ActiveTask $script:WatchedProc } catch {}
            try { $script:WatchedProc.Dispose() } catch {}
            $script:WatchedProc = $null
        }
        Stop-Z2BgUiWork
        Dispose-Z2TrayIcon
        try { $win.Close() } catch {}
        try { if ($null -ne $script:WpfApp) { $script:WpfApp.Shutdown() } } catch {}
    })
    $ni.ContextMenuStrip = $cm
    $ni.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $win.ShowInTaskbar = $true
            $win.Show()
            Fit-Z2WindowToScreen
            $win.Activate()
            $script:CatTimer.Start()
            Refresh-Dashboard
        }
    })
    $ni.Visible = $true
    $script:TrayIcon = $ni
    $script:TrayMenu = $cm
}

$ChkTrayMode.Add_Click({
    if (-not (Test-Z2GuiAdmin -RefreshUi)) { return }
    $fTray = Join-Path $Root 'utils\tray_mode.enabled'
    $fMin  = Join-Path $Root 'utils\tray_start_minimized.enabled'
    try {
        if ($ChkTrayMode.IsChecked) {
            $taskOk = [bool](Register-Z2TrayStartupTask $Root)
            if (-not $taskOk) {
                Show-Toast 'Не удалось зарегистрировать задачу автозапуска в трее (проверь права администратора).' $true
                Refresh-Dashboard
                return
            }
            [System.IO.File]::WriteAllText($fTray, "1`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Ensure-Z2TrayIcon
            Show-Toast 'Иконка в трее включена и добавлена в автозапуск Windows (без окна UAC)' $false
        } else {
            $unregOk = [bool](Unregister-Z2TrayStartupTask)
            if (-not $unregOk) {
                Show-Toast 'Не удалось удалить задачу автозапуска из Планировщика (проверь права администратора).' $true
                Refresh-Dashboard
                return
            }
            if (Test-Path -LiteralPath $fTray) { Remove-Item -LiteralPath $fTray -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $fMin)  { Remove-Item -LiteralPath $fMin  -Force -ErrorAction Stop }
            if ($null -ne $ChkTrayStartMin) { $ChkTrayStartMin.IsChecked = $false }
            Dispose-Z2TrayIcon
            Show-Toast 'Иконка в трее отключена и убрана из автозапуска' $false
        }
    } catch {
        Show-Toast "Не удалось изменить настройку трея: $($_.Exception.Message)" $true
        Refresh-Dashboard
    }
})

if ($null -ne $ChkTrayStartMin) {
    $ChkTrayStartMin.Add_Click({
        $fMin = Join-Path $Root 'utils\tray_start_minimized.enabled'
        try {
            if ($ChkTrayStartMin.IsChecked) {
                [System.IO.File]::WriteAllText($fMin, "1`r`n", (New-Object System.Text.UTF8Encoding($false)))
                Show-Toast 'Котек будет запускаться сразу свёрнутым в трей' $false
            } else {
                if (Test-Path -LiteralPath $fMin) { Remove-Item -LiteralPath $fMin -Force -ErrorAction SilentlyContinue }
                Show-Toast 'Окно Котека будет открываться обычно при запуске' $false
            }
        } catch {
            Show-Toast "Не удалось сохранить настройку запуска в трее: $($_.Exception.Message)" $true
            Refresh-Dashboard
        }
    })
}

if ($null -ne $ChkTelemetry) {
    $ChkTelemetry.Add_Click({
        $fTel    = Join-Path $Root 'utils\telemetry.enabled'
        $fPrompt = Join-Path $Root 'utils\telemetry.prompted'
        $u8nb    = New-Object System.Text.UTF8Encoding($false)
        try {
            [System.IO.File]::WriteAllText($fPrompt, "2`r`n", $u8nb)
            if ($ChkTelemetry.IsChecked) {
                [System.IO.File]::WriteAllText($fTel, "1`r`n", $u8nb)
                Invoke-KotekThankYou
                Show-Toast 'Спасибо ♡ Анонимные отчёты включены!' $false
            } else {
                if (Test-Path -LiteralPath $fTel) { Remove-Item -LiteralPath $fTel -Force -ErrorAction SilentlyContinue }
                Show-Toast 'Анонимные отчёты выключены.' $false
            }
        } catch {
            Show-Toast "Не удалось изменить настройку отчётов: $($_.Exception.Message)" $true
            Refresh-Dashboard
        }
    })
}

if ($null -ne $BtnTelemetryPreview) {
    $BtnTelemetryPreview.Add_Click({
        $sample = if (Get-Command Get-Z2TelemetryPreview -ErrorAction SilentlyContinue) { Get-Z2TelemetryPreview $Root } else { '{}' }
        [void](Show-Z2MessageDialog -Owner $win -Title 'Что отправляется в анонимном отчёте' -Message "Никаких личных данных, путей C:\Users, IP или списков сайтов. Пример JSON:`n`n$sample" -Kind 'Info' -Buttons 'OK' -AccentHex $AccentHex)
    })
}

$win.Add_Closing({
    param($s, $e)
    $hasActiveTask = ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) -or $script:BgOpBusy
    if (-not $script:ForceExitGui -and $ChkTrayMode.IsChecked) {
        $e.Cancel = $true
        Ensure-Z2TrayIcon
        if (-not $hasActiveTask) { $script:CatTimer.Stop() }
        $win.Hide()
        $win.ShowInTaskbar = $false
        return
    }
    if (-not $script:ForceExitGui -and $hasActiveTask) {
        $qClose = "Сейчас выполняется задача «$($script:ActiveTaskLabel)».`r`nПрервать её и закрыть окно?"
        $ansClose = Show-Z2MessageDialog -Owner $win -Title 'Активная задача' -Message $qClose -Kind 'Warning' -Buttons 'YesNo' -AccentHex $AccentHex
        if ($ansClose -ne 'Yes') {
            $e.Cancel = $true
            return
        }
    }
    if ($null -ne $script:WatchedProc) {
        Stop-Z2ActiveTask $script:WatchedProc
        try { $script:WatchedProc.Dispose() } catch {}
        $script:WatchedProc = $null
    }
    Stop-Z2BgUiWork
    Dispose-Z2TrayIcon
    try { $script:WpfApp.Shutdown() } catch {}
})

$script:WpfApp = [System.Windows.Application]::Current
if ($null -eq $script:WpfApp) { $script:WpfApp = New-Object System.Windows.Application }
$script:WpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:WpfApp.Add_DispatcherUnhandledException({
    param($sender, $ev)
    try {
        $crashPath = Join-Path $env:TEMP 'z2_gui_crash.log'
        [System.IO.File]::AppendAllText($crashPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $($ev.Exception.ToString())`r`n`r`n", [System.Text.Encoding]::UTF8)
        if ((Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue) -and (Test-Z2TelemetryEnabled $Root)) {
            try {
                $crSnap = if (Get-Command Get-Z2TelemetrySnapshot -ErrorAction SilentlyContinue) { Get-Z2TelemetrySnapshot $Root } else { '' }
                $stTrace = if ($ev.Exception.StackTrace) { (($ev.Exception.StackTrace -split "`r?`n") | Select-Object -First 8) -join "`n" } else { '' }
                $crDet = "$($ev.Exception.Message)`n$stTrace`n$crSnap"
                [void](Send-Z2TelemetryEvent -RootPath $Root -Event 'crash' -Strategy $script:ActiveStratName -Code $ev.Exception.GetType().Name -Detail $crDet)
            } catch {}
        }
        [void](Show-Z2MessageDialog -Owner $win -Title 'Zapret2 Kotek — Ошибка интерфейса' -Message "Произошла непредвиденная ошибка:`n`n$($ev.Exception.Message)`n`nПодробности записаны в $crashPath" -Kind 'Error' -Buttons 'OK' -AccentHex $AccentHex)
    } catch {}
    $ev.Handled = $true
})

# Unified ContentRendered handler: sequential relocation (AutoStart) + foreign/Kotek service migration (ID 3.1, 3.8, 6.2)
$win.Add_ContentRendered({
    if ($AutoStart) {
        $needsMove = (-not $script:IsDevWorkspace) -and ($Root -notmatch '^(?i)C:\\Zapret2\\?$') -and (
            ($Root -match '(?i)\\(Downloads|Desktop|OneDrive|Temp)\\') -or
            ($Root -match '[\s()]') -or
            ($Root -match '[\u0400-\u04FF]')
        )
        if ($needsMove) {
            $mvAns = Show-Z2MessageDialog -Owner $win -Title 'Перенос в C:\Zapret2' -Message "Папка находится в ненадёжном пути:`n$Root`n`nПути в Загрузках, с пробелами/скобками или кириллицей могут ломать службы Windows.`nПеренести Zapret2 Kotek в чистую папку C:\Zapret2 и продолжить настройку оттуда?" -Kind 'Question' -Buttons 'YesNo' -AccentHex $AccentHex
            if ($mvAns -eq 'Yes') {
                Set-Status 'Перенос сборки в C:\Zapret2...' '#D9B066'
                Invoke-Z2BgUiWork {
                    param($SrcRoot)
                    $targetRoot = 'C:\Zapret2'
                    try {
                        . (Join-Path $SrcRoot 'utils\common.ps1')
                        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
                        foreach ($s in @('zapret2','zapret-tgws','WinDivert','WinDivert14')) {
                            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $s" -WindowStyle Hidden -Wait | Out-Null
                        }
                        Get-Process -Name 'winws2','winws','tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Milliseconds 350
                        if (-not (Test-Path -LiteralPath $targetRoot)) { New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null }
                        & "$env:SystemRoot\System32\robocopy.exe" (Format-Z2DirNoSlash $SrcRoot) $targetRoot /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
                        return @{ Rc = $LASTEXITCODE; Target = $targetRoot }
                    } catch {
                        return @{ Rc = 16; Target = $targetRoot; Err = $_.Exception.Message }
                    }
                } @{ SrcRoot = $Root } {
                    param($res, $err)
                    $r = if ($res -is [System.Collections.IList] -and $res.Count -gt 0) { $res[0] } else { $res }
                    if ($r -and $null -ne $r.Rc -and $r.Rc -ge 0 -and $r.Rc -lt 8) {
                        $targetNoSlash = $r.Target.TrimEnd('\')
                        $newGui = Join-Path $targetNoSlash 'utils\gui_app.ps1'
                        $psFull = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                        $script:ForceExitGui = $true
                        Exit-Z2GuiMutex
                        $env:Z2_ROOT = $targetNoSlash
                        Start-Process -FilePath $psFull -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$newGui`" -Root `"$targetNoSlash`" -AutoStart" -WorkingDirectory $targetNoSlash
                        $win.Close()
                    } else {
                        $rcVal = if ($r) { $r.Rc } else { -1 }
                        Show-Toast "Ошибка переноса в C:\Zapret2 (robocopy код $rcVal) — продолжаю из текущей папки." $true
                        Run-ConsoleTool 'utils\auto_setup.ps1' '-NonInteractive' $false 'Автонастройка' $BtnAutoSetup 'autosetup'
                    }
                }
                return
            }
        }
        Run-ConsoleTool 'utils\auto_setup.ps1' '-NonInteractive' $false 'Автонастройка' $BtnAutoSetup 'autosetup'
        return
    }

    if ($script:IsDevWorkspace) { return }

    try {
        $imgPath = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
        if (-not [string]::IsNullOrWhiteSpace($imgPath)) {
            $exeMatch = [regex]::Match($imgPath, '"?([A-Za-z]:\\(?:[^"]+\\)?bin\\winws2\.exe)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($exeMatch.Success) {
                $svcRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $exeMatch.Groups[1].Value))).TrimEnd('\') + '\'
                $curRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
                if ($svcRoot -ine $curRoot) {
                    # Verify the other folder is actually Zapret2 Kotek (not a foreign Zapret 2 installation, ID 6.2)
                    if (Test-Path -LiteralPath $svcRoot) {
                        $isOtherKotek = (Test-Path -LiteralPath (Join-Path $svcRoot 'utils\gui_app.ps1')) -and (Test-Path -LiteralPath (Join-Path $svcRoot 'utils\kotek.ico'))
                        if (-not $isOtherKotek) { return }
                    } else {
                        # Old folder was moved/deleted: verify Kotek ownership via zapret registry metadata
                        $hasStratVal = $false
                        try {
                            $sv = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube'
                            $hasStratVal = -not [string]::IsNullOrWhiteSpace([string]$sv)
                        } catch {}
                        if (-not $hasStratVal) { return }
                    }

                    $msg = "Служба Zapret2 Kotek сейчас работает из другой папки:`r`n$svcRoot`r`n`r`nПеренести твои списки и настройки сюда, переключить службы на новую папку и провести обязательный начальный тест?`r`n$curRoot`r`n`r`n(Старую папку программа не удалит — после переноса её можно удалить вручную.)"
                    $ans = Show-Z2MessageDialog -Owner $win -Title 'Zapret2 Kotek — обнаружена другая папка службы' -Message $msg -Kind 'Question' -Buttons 'YesNo' -AccentHex $AccentHex
                    if ($ans -eq 'Yes') {
                        Set-Status 'Перенос настроек и переключение служб...' '#D9B066'
                        Invoke-Z2BgUiWork {
                            param($OldRoot, $NewRoot)
                            try {
                                . (Join-Path $NewRoot 'utils\common.ps1')
                                $wasTg = $false
                                $svcTgCheck = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
                                if ($null -ne $svcTgCheck) {
                                    $tgStartMode = 3
                                    try { $tgStartMode = [int](Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret-tgws' -Name 'Start' -ErrorAction SilentlyContinue).Start } catch {}
                                    if ($svcTgCheck.Status -eq 'Running' -or $tgStartMode -eq 2) { $wasTg = $true }
                                    try { $svcTgCheck.Dispose() } catch {}
                                }
                                $oldStrat = ''
                                try { $oldStrat = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue).'zapret-discord-youtube' } catch {}

                                Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
                                Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
                                Get-Process -Name 'winws2','tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                                Start-Sleep -Milliseconds 300
                                foreach ($drv in @('WinDivert', 'WinDivert14')) {
                                    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $drv" -WindowStyle Hidden -Wait | Out-Null
                                }
                                Start-Sleep -Milliseconds 250

                                if (Test-Path -LiteralPath $OldRoot) {
                                    $oldHadNlmAuto = Test-Path -LiteralPath (Join-Path $OldRoot 'utils\nlm_auto.enabled')
                                    $migFiles = @(
                                        'lists\list-general-user.txt', 'lists\list-exclude-user.txt', 'lists\ipset-exclude-user.txt',
                                        'lists\list-auto.txt', 'lists\ai-custom-domains.txt', 'utils\tgws_proxy.conf', 'utils\strategy_scores.json',
                                        'utils\active_udp_fake.txt', 'utils\game_filter.enabled', 'utils\nlm_filter.enabled',
                                        'utils\nlm_filter.names', 'utils\tray_mode.enabled', 'utils\tray_start_minimized.enabled', 'utils\wf_priority.conf', 'utils\ai_bypass.conf', 'utils\telemetry.enabled', 'utils\telemetry.id', 'utils\telemetry.prompted',
                                        'utils\targets.txt', 'utils\autoupdate.mode',
                                        'bin\ACTIVE_DISCORD_UDP.bin', 'bin\ACTIVE_GAME_UDP.bin',
                                        'strategies\custom_auto_synthesized.bat'
                                    )
                                    foreach ($mf in $migFiles) {
                                        if ($oldHadNlmAuto -and ($mf -eq 'utils\nlm_filter.enabled' -or $mf -eq 'utils\nlm_filter.names')) { continue }
                                        $sFp = Join-Path $OldRoot $mf
                                        if (Test-Path -LiteralPath $sFp) {
                                            $dFp = Join-Path $NewRoot $mf
                                            $dDir = Split-Path -Parent $dFp
                                            if (-not (Test-Path -LiteralPath $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
                                            Copy-Item -LiteralPath $sFp -Destination $dFp -Force -ErrorAction SilentlyContinue
                                        }
                                    }
                                    $migSynthNew = Join-Path $NewRoot 'strategies\custom_auto_synthesized.bat'
                                    if (Test-Path -LiteralPath $migSynthNew) {
                                        try {
                                            $sRawMig = [System.IO.File]::ReadAllText($migSynthNew, [System.Text.Encoding]::UTF8)
                                            if ($sRawMig -like '*circular:fails=1:time=60:reset:retrans=2*') {
                                                $sRawMig = $sRawMig.Replace('circular:fails=1:time=60:reset:retrans=2', 'circular:fails=3:time=60:reset:retrans=4')
                                                [System.IO.File]::WriteAllText($migSynthNew, $sRawMig, (New-Object System.Text.UTF8Encoding($false)))
                                            }
                                        } catch {}
                                    }
                                    foreach ($df in @('utils\autohostlist.enabled', 'utils\warp_unblock.enabled', 'utils\kernel_filter.enabled')) {
                                        $sDf = Join-Path $OldRoot $df
                                        $dDf = Join-Path $NewRoot $df
                                        if (Test-Path -LiteralPath $sDf) {
                                            Copy-Item -LiteralPath $sDf -Destination $dDf -Force -ErrorAction SilentlyContinue
                                        } elseif (Test-Path -LiteralPath $dDf) {
                                            Remove-Item -LiteralPath $dDf -Force -ErrorAction SilentlyContinue
                                        }
                                    }
                                }

                                $batUse = ''
                                if ($oldStrat) {
                                    foreach ($cand in @((Join-Path $NewRoot "strategies\$oldStrat.bat"), (Join-Path $NewRoot "configs_archive\$oldStrat.bat"))) {
                                        if (Test-Path -LiteralPath $cand) { $batUse = $cand; break }
                                    }
                                }
                                if (-not $batUse) { $batUse = Join-Path $NewRoot 'strategies\general (ALT).bat' }
                                $applyOk = $true
                                if (Test-Path -LiteralPath $batUse) {
                                    $global:LASTEXITCODE = 0
                                    & (Join-Path $NewRoot 'utils\apply_strategy.ps1') -Root $NewRoot -BatPath $batUse | Out-Null
                                    if ($LASTEXITCODE -ne 0) { $applyOk = $false }
                                }
                                if ($wasTg) {
                                    $tgH = Join-Path $NewRoot 'utils\tgws_helper.ps1'
                                    if (Test-Path -LiteralPath $tgH) { $env:Z2_ROOT = $NewRoot; & $tgH ensure-service-silent | Out-Null }
                                }
                                Register-Z2UninstallEntry $NewRoot
                                if (Test-Path -LiteralPath (Join-Path $NewRoot 'utils\tray_mode.enabled')) { [void](Register-Z2TrayStartupTask $NewRoot) }
                                if ($null -ne (Get-Z2AutoUpdateTask)) {
                                    $auNew = Join-Path $NewRoot 'utils\autoupdate_task.ps1'
                                    if (Test-Path -LiteralPath $auNew) {
                                        $auM = 'twiceweekly'
                                        $auMf = Join-Path $NewRoot 'utils\autoupdate.mode'
                                        if (Test-Path -LiteralPath $auMf) { $mTmp = ([string](Get-Content -LiteralPath $auMf -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim(); if ($mTmp) { $auM = $mTmp } }
                                        try { & $auNew -Action enable -Root $NewRoot -Mode $auM | Out-Null } catch {}
                                    }
                                }
                                return $applyOk
                            } catch { return $false }
                        } @{ OldRoot = $svcRoot; NewRoot = $curRoot } {
                            param($res, $err)
                            Refresh-Dashboard
                            Load-Strategies $script:CurrentTab
                            $ok = ($res -is [System.Collections.IList] -and $res.Count -gt 0 -and [bool]$res[0]) -or ($res -eq $true)
                            if ($ok) { Show-Toast 'Настройки перенесены — запускаю обязательный начальный тест...' $false }
                            else { Show-Toast 'Перенос завершён с предупреждением — запускаю начальный тест...' $true }
                            Run-ConsoleTool 'utils\auto_setup.ps1' '-NonInteractive -SkipUpdateCheck' $false 'Автонастройка' $BtnAutoSetup 'autosetup'
                        }
                        return
                    }
                }
            }
        }
    } catch {}
    try {
        if ($Root -notmatch '^[A-Za-z]:\\$') {
            $fIcoChk = Join-Path $Root 'utils\kotek_folder.ico'
            $fIniChk = Join-Path $Root 'desktop.ini'
            if ((-not (Test-Path -LiteralPath $fIcoChk)) -or (-not (Test-Path -LiteralPath $fIniChk))) {
                if (Get-Command Set-Z2DesktopAndFolderIcons -ErrorAction SilentlyContinue) {
                    Set-Z2DesktopAndFolderIcons $Root -FolderOnly
                }
            }
        }
    } catch {}
    try {
        $fPromptStart = Join-Path $Root 'utils\telemetry.prompted'
        if (-not (Test-Path -LiteralPath $fPromptStart)) {
            Invoke-Z2TelemetryPromptOnce
        }
    } catch {}
    Invoke-Z2TelemetrySoftRemind
})

# Lightweight wake timer: restores window from tray when second GUI instance signals EventWaitHandle
$script:WakeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WakeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:WakeTimer.Add_Tick({
    if ($null -ne $script:ShowWindowEvent) {
        try {
            if ($script:ShowWindowEvent.WaitOne(0)) {
                $win.ShowInTaskbar = $true
                $win.Show()
                Fit-Z2WindowToScreen
                $win.Activate()
                $script:CatTimer.Start()
                Refresh-Dashboard
            }
        } catch {}
    }
    $script:VpnWatchTick++
    if (($script:VpnWatchTick % 10) -eq 0 -and -not $script:BgOpBusy -and ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited)) {
        if (Get-Command Get-Z2ActiveVpnInfo -ErrorAction SilentlyContinue) {
            try {
                if ($script:AiBypassActiveNow -and -not $script:AiPausedByVpn -and -not $script:AiVpnOverride) {
                    $vpnTick = Get-Z2ActiveVpnInfo
                    if ($vpnTick.Active) {
                        $aiSnap = Get-Z2AiBypassState $Root
                        if ($aiSnap.Active -and $aiSnap.Domains.Count -gt 0 -and $aiSnap.IpsList.Count -gt 0) {
                            $script:AiPausedByVpnInfo = @{
                                Domains = [string[]]@($aiSnap.Domains)
                                Ips     = [string[]]@($aiSnap.IpsList)
                            }
                            [void](Disable-Z2AiBypass $Root)
                            $script:AiPausedByVpn = $true
                            Refresh-Dashboard
                            Show-Toast "Обход ИИ поставлен на паузу (активен VPN: $($vpnTick.Label)) — вернётся сам после отключения VPN." $false
                        }
                    }
                } elseif ($script:AiPausedByVpn) {
                    $vpnTick = Get-Z2ActiveVpnInfo
                    if (-not $vpnTick.Active) {
                        $restoredOk = $true
                        if ($null -ne $script:AiPausedByVpnInfo -and $script:AiPausedByVpnInfo.Domains.Count -gt 0 -and $script:AiPausedByVpnInfo.Ips.Count -gt 0) {
                            $restoredOk = [bool](Restore-Z2AiBypassFast $Root $script:AiPausedByVpnInfo.Domains $script:AiPausedByVpnInfo.Ips)
                        }
                        $script:AiPausedByVpn     = $false
                        $script:AiPausedByVpnInfo = $null
                        Refresh-Dashboard
                        if ($restoredOk) { Show-Toast 'VPN отключён — «Обход ИИ» автоматически восстановлен.' $false }
                        else { Show-Toast 'VPN отключён, но не удалось восстановить «Обход ИИ» — включи его вручную.' $true }
                    }
                } elseif ($script:AiVpnOverride) {
                    $vpnTick = Get-Z2ActiveVpnInfo
                    if (-not $vpnTick.Active) { $script:AiVpnOverride = $false }
                }
            } catch {}
        }
    }
})
$script:WakeTimer.Start()

$trayOn      = (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_mode.enabled'))
$trayMinOn   = $trayOn -and (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_start_minimized.enabled'))
# Manual launch from folder (without -StartInTray) ALWAYS opens in windowed mode; only startup task (-StartInTray) starts hidden
$startHidden = (-not $AutoStart) -and [bool]$StartInTray -and $trayMinOn
function Fit-Z2WindowToScreen {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $scr = if ($hwnd -ne [IntPtr]::Zero) {
            [System.Windows.Forms.Screen]::FromHandle($hwnd)
        } else {
            [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        }
        if ($null -eq $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
        $waPx = $scr.WorkingArea
        $scaleX = 1.0; $scaleY = 1.0
        $srcVis = [System.Windows.PresentationSource]::FromVisual($win)
        if ($null -ne $srcVis -and $null -ne $srcVis.CompositionTarget) {
            $m = $srcVis.CompositionTarget.TransformFromDevice
            if ($m.M11 -gt 0) { $scaleX = $m.M11 }
            if ($m.M22 -gt 0) { $scaleY = $m.M22 }
        } else {
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
                try {
                    if ($g.DpiX -gt 0) { $scaleX = 96.0 / $g.DpiX }
                    if ($g.DpiY -gt 0) { $scaleY = 96.0 / $g.DpiY }
                } finally { $g.Dispose() }
            } catch {}
        }
        $waL = $waPx.Left * $scaleX
        $waT = $waPx.Top * $scaleY
        $waW = $waPx.Width * $scaleX
        $waH = $waPx.Height * $scaleY
        if ($waW -le 0 -or $waH -le 0) { return }

        $targetW = if ($win.Width -gt 0 -and -not [double]::IsNaN($win.Width)) { $win.Width } else { 1020 }
        $targetH = if ($win.Height -gt 0 -and -not [double]::IsNaN($win.Height)) { $win.Height } else { 700 }

        if ($targetW -ge ($waW - 12) -or $targetH -ge ($waH - 12) -or $win.MinWidth -ge ($waW - 12) -or $win.MinHeight -ge ($waH - 12)) {
            $win.WindowStartupLocation = 'Manual'
            $win.Left = $waL
            $win.Top  = $waT
            $win.WindowState = 'Maximized'
        } else {
            $win.WindowState = 'Normal'
            $win.WindowStartupLocation = 'Manual'
            $newL = $waL + [Math]::Max(0, [Math]::Floor(($waW - $targetW) / 2))
            $newT = $waT + [Math]::Max(0, [Math]::Floor(($waH - $targetH) / 2))
            $win.Left = [Math]::Max($waL, [Math]::Min($newL, $waL + $waW - $targetW))
            $win.Top  = [Math]::Max($waT, [Math]::Min($newT, $waT + $waH - $targetH))
        }
    } catch {}
}

# Allow dragging the window by grabbing any empty non-interactive background area
$win.Add_MouseLeftButtonDown({
    param($s, $e)
    try {
        if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $dep = $e.OriginalSource -as [System.Windows.DependencyObject]
        while ($null -ne $dep) {
            if (($dep -is [System.Windows.Controls.Primitives.ButtonBase]) -or
                ($dep -is [System.Windows.Controls.Primitives.TextBoxBase]) -or
                ($dep -is [System.Windows.Controls.Primitives.Selector]) -or
                ($dep -is [System.Windows.Controls.Primitives.ScrollBar]) -or
                ($dep -is [System.Windows.Controls.Primitives.Thumb]) -or
                ($dep -is [System.Windows.Controls.Slider]) -or
                ($dep -is [System.Windows.Controls.ComboBoxItem]) -or
                ($dep -is [System.Windows.Controls.ListBoxItem])) {
                return
            }
            if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
            } else {
                $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
            }
        }
        if ($win.WindowState -eq 'Maximized') { $win.WindowState = 'Normal' }
        $win.DragMove()
    } catch {}
})

Fit-Z2WindowToScreen

if ($trayOn -or $StartInTray) {
    Ensure-Z2TrayIcon
    if ($trayOn) { [void](Register-Z2TrayStartupTask $Root) }
}

if ($startHidden) {
    $win.ShowInTaskbar = $false
    $script:CatTimer.Stop()
} else {
    $win.Show()
}
[void]$script:WpfApp.Run()
$script:WakeTimer.Stop()
$script:CatTimer.Stop()
Dispose-Z2TrayIcon
if ($null -ne $script:ShowWindowEvent) {
    try { $script:ShowWindowEvent.Dispose() } catch {}
    $script:ShowWindowEvent = $null
}
Exit-Z2GuiMutex
