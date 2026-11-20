param(
    [string]$Root = '',
    [switch]$AutoStart
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
if (-not (Enter-Z2GuiMutex)) { exit 0 }
$Root = Resolve-Z2Root $Root
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
    $win = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    $errMsg = $_.Exception.ToString()
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'z2_gui_crash.log'), $errMsg, [System.Text.Encoding]::UTF8) } catch {}
    [System.Windows.MessageBox]::Show("Ошибка запуска окна Zapret2 Kotek:`n`n$($_.Exception.Message)`n`nЛог: $env:TEMP\z2_gui_crash.log", 'Zapret2 Kotek — Ошибка', 'OK', 'Error') | Out-Null
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
$TxtActiveStrat  = $win.FindName('TxtActiveStrat')
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
$BtnAutoDoneClose   = $win.FindName('BtnAutoDoneClose')
$BtnAutoDoneStay    = $win.FindName('BtnAutoDoneStay')
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
$TxtBrowserFixState = $win.FindName('TxtBrowserFixState')
$BtnBrowserFix   = $win.FindName('BtnBrowserFix')
$BtnBrowserRevert= $win.FindName('BtnBrowserRevert')
$BtnEditGenUser  = $win.FindName('BtnEditGenUser')
$BtnEditExUser   = $win.FindName('BtnEditExUser')
$ChkAutoUpdate   = $win.FindName('ChkAutoUpdate')
$CmbAutoUpdMode  = $win.FindName('CmbAutoUpdMode')
$CmbIpsetMode    = $win.FindName('CmbIpsetMode')
$TxtAutoUpdDesc  = $win.FindName('TxtAutoUpdDesc')

$TxtFolder.Text = $Root.TrimEnd('\')
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

$ImgKotek.Add_MouseMove({
    param($s, $e)
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
$script:ActiveTaskBtn = $null
$script:ActiveTaskBtnOrigText = ''
$script:ToastHideTick = 0

function Show-Toast([string]$Msg, [bool]$IsError = $false) {
    $bc = New-Object System.Windows.Media.BrushConverter
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
$BtnAutoDoneClose.Add_Click({ $win.Close() })
$BtnAutoDoneStay.Add_Click({ $AutoDoneCard.Visibility = 'Collapsed' })
$BtnAutoDoneDeep.Add_Click({
    $AutoDoneCard.Visibility = 'Collapsed'
    Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Глубокий тест (22 стратегии)' $BtnDeepOpt
})
if ($null -ne $BtnCancelHybrid) {
    $BtnCancelHybrid.Add_Click({
        if ($null -ne $script:WatchedProc) {
            Stop-Z2ActiveTask $script:WatchedProc
            $script:WatchedProc = $null
        }
        $BtnCancelHybrid.Visibility = 'Collapsed'
        $BarProgress.Visibility = 'Collapsed'
        $ActiveTaskCard.Visibility = 'Collapsed'
        $BtnPause.IsEnabled = $true
        if ($null -ne $script:ActiveTaskBtn) {
            $script:ActiveTaskBtn.Content = $script:ActiveTaskBtnOrigText
            $script:ActiveTaskBtn.IsEnabled = $true
            $script:ActiveTaskBtn = $null
        }
        try {
            Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $bakConf = Join-Path $Root 'bin\service.conf.deepbak'
            $liveConf = Join-Path $Root 'bin\service.conf'
            if (Test-Path -LiteralPath $bakConf) {
                Move-Item -LiteralPath $bakConf -Destination $liveConf -Force -ErrorAction SilentlyContinue
            }
            Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 350
        } catch {}
        Refresh-Dashboard
        $keepMsg = "Гибрид отменён — оставлена стратегия $($script:ActiveStratName)"
        Set-Status $keepMsg $AccentLightHex
        Show-Toast $keepMsg $false
    })
}
function Sync-AutoDoneUpdBtn {
    $isOn = [bool]$ChkAutoUpdate.IsChecked
    $bc = New-Object Windows.Media.BrushConverter
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
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    $turnOn = -not [bool]$ChkAutoUpdate.IsChecked
    if ($turnOn) {
        & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
        $ChkAutoUpdate.IsChecked = $true
        $CmbAutoUpdMode.IsEnabled = $true
        $mTxt = switch ($selM) { 'onboot' { 'при включении ПК (через 2 мин)' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
        Show-Toast "Автообновление включено: $mTxt" $false
    } else {
        & $auScript -Action disable -Root $Root | Out-Null
        $ChkAutoUpdate.IsChecked = $false
        $CmbAutoUpdMode.IsEnabled = $false
        Show-Toast 'Автообновление отключено.' $false
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
    $TxtStatusBar.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
}

function Switch-Nav([string]$page) {
    $ViewHome.Visibility     = if ($page -eq 'home')     { 'Visible' } else { 'Collapsed' }
    $ViewStrats.Visibility   = if ($page -eq 'strats')   { 'Visible' } else { 'Collapsed' }
    $ViewSettings.Visibility = if ($page -eq 'settings') { 'Visible' } else { 'Collapsed' }

    $BtnNavHome.Style     = if ($page -eq 'home')     { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    $BtnNavStrats.Style   = if ($page -eq 'strats')   { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    $BtnNavSettings.Style = if ($page -eq 'settings') { $win.Resources['NavBtnActive'] } else { $win.Resources['NavBtn'] }
    if ($ActiveTaskCard.Visibility -eq 'Visible') {
        $StatusRow.Visibility = if ($page -eq 'home') { 'Collapsed' } else { 'Visible' }
    }
}

$BtnGitHub.Add_Click({
    $repoUrl = 'https://github.com/vanch150/zapret2-kotek'
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc)) {
            if ($l -match '^\s*repo\s*=\s*(.+)$') {
                $r = $matches[1].Trim()
                if ($r -and $r -notlike 'OWNER/*') { $repoUrl = "https://github.com/$r" }
            }
        }
    }
    Start-Process $repoUrl
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

    $prevSelName = if ($ListStrategies.SelectedItem -and $ListStrategies.SelectedItem.Name) { [string]$ListStrategies.SelectedItem.Name } else { '' }
    $scores = Get-StrategyScores
    $bc = New-Object System.Windows.Media.BrushConverter
    $ListStrategies.Items.Clear()
    $restoreIdx = 0
    $rowIdx = 0
    foreach ($f in $script:CurrentItems) {
        $stTxt = '—'
        $bdTxt = ''
        $tipTxt = 'Ещё не проверялась — выбери и нажми «Проверить»'
        $stClr = '#646B78'
        if ($scores.ContainsKey($f.Name)) {
            $sc = $scores[$f.Name]
            $okN = [int]$sc.ok; $totN = if ($sc.total) { [int]$sc.total } else { 16 }; $msN = [int]$sc.ms
            $stTxt = "$okN/$totN · ~${msN} мс"
            $ratio = if ($totN -gt 0) { $okN / [double]$totN } else { 0.0 }
            if ($ratio -ge 0.65) { $stClr = $AccentLightHex }
            elseif ($ratio -ge 0.42) { $stClr = '#D9B066' }
            else { $stClr = '#D97777' }
            $ytPart = if ($null -ne $sc.ytHits) { "YT $($sc.ytHits)/$($sc.ytTotal)" } else { if ($sc.yt) { 'YT OK' } else { 'YT ✕' } }
            $dcPart = if ($null -ne $sc.dcHits) { "DC $($sc.dcHits)/$($sc.dcTotal)" } else { if ($sc.dc) { 'DC OK' } else { 'DC ✕' } }
            $bdTxt = "$ytPart · $dcPart"
            $frPart = if ($sc.freeze) { 'OK' } else { 'SLOW' }
            $tsPart = if ($sc.ts) { $sc.ts } else { '—' }
            $tipTxt = "$($f.Name)`nИтог: $okN/$totN (~${msN} мс)`n$ytPart | $dcPart | 16-20KB: $frPart`nТест: $tsPart"
        }
        $rowObj = [PSCustomObject]@{
            Name          = $f.Name
            FullName      = $f.FullName
            BreakdownText = $bdTxt
            ScoreText     = $stTxt
            ScoreTip      = $tipTxt
            ScoreBrush    = $bc.ConvertFromString($stClr)
        }
        [void]$ListStrategies.Items.Add($rowObj)
        if ($prevSelName -and $f.Name -ieq $prevSelName) { $restoreIdx = $rowIdx }
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
    $bc = New-Object System.Windows.Media.BrushConverter
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
    $TxtActiveStrat.Text = "Стратегия: $strat"
    $TxtSideStrat.Text = $strat

    $tgMode = 'smart'; $tgHost = '127.0.0.1'; $tgPort = '1443'
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    if (Test-Path -LiteralPath $tgConf) {
        foreach ($l in (Get-Content -LiteralPath $tgConf)) {
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
        $v = (Get-Content -LiteralPath $ufFile -TotalCount 1).Trim()
        if ($v) { $udpFake = $v }
    }
    $TxtHeroMeta.Text = "$ipTxt  ·  UDP: $udpFake"
    Load-UdpFakes $udpFake

    $ChkAutoHost.IsChecked = (Test-Path -LiteralPath (Join-Path $Root 'utils\autohostlist.enabled'))
    $ChkWarp.IsChecked     = (Test-Path -LiteralPath (Join-Path $Root 'utils\warp_unblock.enabled'))

    $gfOn = $false
    $gfFile = Join-Path $Root 'utils\game_filter.enabled'
    if (Test-Path -LiteralPath $gfFile) {
        foreach ($l in (Get-Content -LiteralPath $gfFile)) {
            if ($l -match '^(?i)mode=(.+)$') {
                $m = $matches[1].Trim().ToLowerInvariant()
                if ($m -ne 'disabled' -and $m -ne 'off') { $gfOn = $true }
            }
        }
    }
    $ChkGameFilter.IsChecked = $gfOn
    $nlmEnFile   = Join-Path $Root 'utils\nlm_filter.enabled'
    $nlmAutoFile = Join-Path $Root 'utils\nlm_auto.enabled'
    $nlmNmFile   = Join-Path $Root 'utils\nlm_filter.names'
    $nlmHasFilter = (Test-Path -LiteralPath $nlmEnFile)
    $nlmOn = $nlmHasFilter -or (Test-Path -LiteralPath $nlmAutoFile)
    $ChkNlmVpn.IsChecked = $nlmOn
    if ($nlmOn) {
        $nmTxt = if (Test-Path -LiteralPath $nlmNmFile) { ([string](Get-Content -LiteralPath $nlmNmFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim() } else { '' }
        if ($nmTxt) {
            $cleanNms = @($nmTxt -split ',' | ForEach-Object { ($_.Trim() -replace '\s*\((?:public|private|domain)\)$', '') } | Where-Object { $_ })
            $shortNms = if ($cleanNms.Count -gt 2) { ($cleanNms[0..1] -join ', ') + " и ещё $($cleanNms.Count - 2)" } else { ($cleanNms -join ', ') }
            $TxtNlmStatus.Text = "Исключены: $shortNms"
            $TxtNlmStatus.ToolTip = "Полный список исключённых VPN: $($cleanNms -join ', ')"
            $TxtNlmStatus.Foreground = $bc.ConvertFromString($AccentLightHex)
        } elseif ($nlmHasFilter) {
            $TxtNlmStatus.Text = 'Активен фильтр NLM — нажми «Настроить», чтобы выбрать VPN по отдельности'
            $TxtNlmStatus.ToolTip = $null
            $TxtNlmStatus.Foreground = $bc.ConvertFromString($AccentLightHex)
        } else {
            $TxtNlmStatus.Text = 'Авто-защита активна — обнаруженные VPN (WireGuard / Amnezia и др.) исключаются автоматически; ExitLag идёт через обход'
            $TxtNlmStatus.ToolTip = $null
            $TxtNlmStatus.Foreground = $bc.ConvertFromString($AccentLightHex)
        }
    } else {
        $TxtNlmStatus.Text = 'Исключает выбранные VPN-адаптеры (WireGuard / Amnezia), позволяя гнать ExitLag через обход'
        $TxtNlmStatus.ToolTip = $null
        $TxtNlmStatus.Foreground = $bc.ConvertFromString('#9CA3AF')
    }
    $ChkKernelFilter.IsChecked = (Test-Path -LiteralPath (Join-Path $Root 'utils\kernel_filter.enabled'))
    $ChkTrayMode.IsChecked = (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_mode.enabled'))
    $bpApplied = (Test-Path -LiteralPath (Join-Path $Root 'utils\browser_policy.applied'))
    if (-not $bpApplied) {
        try { $bpApplied = ((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Zapret2' -Name 'BrowserPolicyApplied' -ErrorAction SilentlyContinue).BrowserPolicyApplied -eq 1) } catch {}
    }
    if ($bpApplied) {
        $TxtBrowserFixState.Text = 'Применён (QUIC отключён, DoH включён — перезапусти браузер)'
        $TxtBrowserFixState.Foreground = $bc.ConvertFromString($AccentLightHex)
    } else {
        $TxtBrowserFixState.Text = 'Помогает, если YouTube тормозит в Chrome / Edge / Яндекс.Браузере'
        $TxtBrowserFixState.Foreground = $bc.ConvertFromString('#9CA3AF')
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
        $mv = (Get-Content -LiteralPath $auModeFile -TotalCount 1).Trim().ToLowerInvariant()
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
    $sel = [string]$CmbUdpFake.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $src = Join-Path (Join-Path $Root 'bin') $sel
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin') -Force
        Copy-Item -LiteralPath $src -Destination (Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin') -Force
        [System.IO.File]::WriteAllText((Join-Path $Root 'utils\active_udp_fake.txt'), $sel, (New-Object System.Text.UTF8Encoding($false)))
        $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $svcZ -and $svcZ.Status -eq 'Running') {
            Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        }
        $TxtHeroMeta.Text = ($TxtHeroMeta.Text -replace 'UDP: .*$', "UDP: $sel")
        Set-Status "Применён UDP-фейк: $sel" $AccentLightHex
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
            $KotekScale.ScaleX = 1.0
            $KotekScale.ScaleY = 1.0
        }
    } elseif ($script:PetUntilTick -gt 0) {
        $script:PetUntilTick = 0
        $TxtKotekPurr.Visibility = 'Collapsed'
        $KotekScale.ScaleX = 1.0
        $KotekScale.ScaleY = 1.0
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
            $BtnPause.IsEnabled = $true
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
            if ($ec -ne 0) {
                $errMsg = if ($errLine) { "$lbl — $errLine" } else { "$lbl завершилась с кодом $ec" }
                Set-Status $errMsg '#D97777'
                Show-Toast $errMsg $true
            } elseif ($lbl -eq "Автонастройка" -and -not $script:ZapretIsRunning) {
                $errMsg = if ($errLine) { "Автонастройка: $errLine" } else { "Автонастройка не смогла запустить службу zapret (проверь диагностику)." }
                Set-Status $errMsg '#D97777'
                Show-Toast $errMsg $true
            } else {
                $okMsg = if ($lbl -eq "Автонастройка") { "Автонастройка завершена — стратегия $($script:ActiveStratName) активна!" } elseif ($summaryLine) { "$lbl — $summaryLine" } else { "$lbl — успешно завершено!" }
                Set-Status $okMsg $AccentLightHex
                Show-Toast $okMsg $false
                if (($lbl -eq 'Автонастройка' -or $lbl -like 'Персональный гибрид*') -and $script:ZapretIsRunning) {
                    $tgSt = if ($TxtTgStatusLine.Text -like 'Активен*') { 'активен' } else { 'готов' }
                    $pct = 100; $okN = 0; $totN = 0
                    $resFile = Join-Path $Root 'utils\last_autosetup.json'
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
                    $bcDone = New-Object Windows.Media.BrushConverter
                    $primStyle = $win.FindResource('PrimaryBtn')
                    $secStyle  = $win.FindResource('SecondaryBtn')
                    if ($lbl -eq 'Автонастройка' -and $totN -gt 0 -and $pct -lt 85) {
                        $warnMsg = "Упс! Быстрый тест набрал $okN из $totN ($pct% — ниже 85%). Автоматически запускаю персональный гибрид..."
                        Set-Status $warnMsg '#F59E0B'
                        Show-Toast $warnMsg $false
                        Switch-Nav 'home'
                        Run-ConsoleTool 'utils\deep_optimize.ps1' '-NonInteractive' $false 'Персональный гибрид (22 стратегии)' $BtnDeepOpt
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
                        $scoreSuffix = if ($lbl -eq 'Автонастройка' -and $totN -gt 0) { " ($okN/$totN · $pct%)" } else { "" }
                        $TxtAutoDoneSummary.Text = "Активная стратегия: $($script:ActiveStratName)$scoreSuffix  ·  Обход DPI: работает  ·  Telegram Proxy: $tgSt"
                        if ($null -ne $TxtAutoDoneHints) {
                            $TxtAutoDoneHints.Text = "• Вкладка «Стратегии» — ручной выбор, быстрая проверка и синтез гибрида`n• Вкладка «Настройки» — авто-хостлист, WARP, UDP-фейк, обновления и удаление`n• Обход работает в фоне сам — это окно можно спокойно закрыть"
                        }
                        if ($lbl -like 'Персональный гибрид*') {
                            $BtnAutoDoneDeep.Visibility = 'Collapsed'
                            $BtnAutoDoneClose.Style = $primStyle
                        } else {
                            $BtnAutoDoneDeep.Visibility = 'Visible'
                            $BtnAutoDoneDeep.Style  = $primStyle
                            $BtnAutoDoneClose.Style = $secStyle
                        }
                    }
                    Sync-AutoDoneUpdBtn
                    $AutoDoneCard.Visibility = 'Visible'
                    Switch-Nav 'home'
                }
            }
        }
        if (-not $isPetted) {
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

function Run-ConsoleTool([string]$ScriptRel, [string]$ExtraArgs = '', [bool]$KeepOpen = $false, [string]$Label = '', $SourceBtn = $null) {
    if ($null -ne $script:WatchedProc -and -not $script:WatchedProc.HasExited) {
        Set-Status 'Дождись завершения текущей задачи перед запуском новой.' '#D9B066'
        return
    }
    $sp = Join-Path $Root $ScriptRel
    $script:ActiveTaskLabel = if ($Label) { $Label } else { [System.IO.Path]::GetFileNameWithoutExtension($ScriptRel) }
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
    $script:ActiveTaskEtaBase  = if ($ScriptRel -match 'deep_optimize') { 'обычно ~2–4 мин' } elseif ($ScriptRel -match 'auto_setup') { 'обычно ~1–2 мин' } elseif ($ScriptRel -match 'probe_one') { 'обычно ~5–10 сек' } else { 'обычно ~5–15 сек' }
    if ($null -ne $TxtActiveTaskEta) { $TxtActiveTaskEta.Text = $script:ActiveTaskEtaBase }
    $TxtActiveTaskTitle.Text = "Выполняется: $($script:ActiveTaskLabel)"
    $TxtActiveTaskStep.Text  = "Запуск задачи..."
    if ($null -ne $TxtTaskLogBox) { $TxtTaskLogBox.Text = "Запуск задачи..." }
    Set-KotekEmotion 'work'
    $AutoDoneCard.Visibility = 'Collapsed'
    if ($null -ne $BtnCancelHybrid) { $BtnCancelHybrid.Visibility = 'Collapsed' }
    $ActiveTaskCard.Visibility = 'Visible'
    if ($ScriptRel -match 'auto_setup|deep_optimize|probe_one|fake_selector|apply_strategy') {
        $bcBusy = New-Object System.Windows.Media.BrushConverter
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
        $BtnPause.IsEnabled = $true
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
$BtnOpenDir.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$Root`"" })
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
    $mi = $CmbTgMode.SelectedIndex
    if ($mi -lt 0 -or $mi -ge $script:TgModeKeys.Count) { return }
    $newMode = $script:TgModeKeys[$mi]
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    if (Test-Path -LiteralPath $tgConf) {
        $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
        if ($rawC -match '(?m)^mode=.*$') { $rawC = [regex]::Replace($rawC, '(?m)^mode=.*$', "mode=$newMode") }
        else { $rawC = $rawC.TrimEnd() + "`r`nmode=$newMode`r`n" }
        [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
    }
    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    if ($null -ne $svcTg -and $svcTg.Status -eq 'Running') {
        Restart-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
    }
    Refresh-Dashboard
    Show-Toast "Telegram Proxy: $($script:TgModeHints[$newMode])" $false
})

$BtnAddStrat.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
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
$BtnDiag.Add_Click({ Run-ConsoleTool 'utils\diag_report.ps1' '' $false 'Диагностика (копируется в буфер)' $BtnDiag })
$BtnUpdateLists.Add_Click({ Run-ConsoleTool 'utils\update_lists.ps1' '' $false 'Обновление IPSet и Hosts' $BtnUpdateLists })

$BtnCheckUpdate.Add_Click({
    $repo = ''
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc)) {
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
        $BtnCheckUpdate.IsEnabled = $true
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
                $ans = [System.Windows.MessageBox]::Show("Вышла новая версия Zapret2 Kotek: v$latestTag.`nСкачать и установить обновление автоматически (с сохранением настроек)?", "Обновление Zapret2 Kotek", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
                    Run-ConsoleTool 'utils\self_update.ps1' "-Repo $($script:PendingUpdRepo)" $false 'Обновление Zapret2 Kotek' $BtnCheckUpdate
                }
            } else {
                $TxtUpdateInfo.Text = "Установлена последняя версия (v$Version)"
                Set-Status "Обновлений нет — у тебя последняя версия (v$Version)." $AccentLightHex
            }
        } finally {
            try { $sender.Dispose() } catch {}
        }
    })
    try { $wc.DownloadStringAsync([Uri]"https://api.github.com/repos/$repo/releases/latest") } catch { $BtnCheckUpdate.IsEnabled = $true; try { $wc.Dispose() } catch {}; Show-Toast "Не удалось подключиться к GitHub." $true }
})

$BtnUninstall.Add_Click({
    $ans = [System.Windows.MessageBox]::Show("Удалить службы Zapret2 Kotek, Telegram Proxy, WinDivert и автообновление?", "Удаление Zapret2 Kotek", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
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
    $tgConf = Join-Path $Root 'utils\tgws_proxy.conf'
    $svcTg = Get-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
    if ($null -ne $svcTg -and $svcTg.Status -eq 'Running') {
        Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
        Get-Process -Name 'tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList 'config zapret-tgws start= demand' -WindowStyle Hidden -Wait | Out-Null
        if (Test-Path -LiteralPath $tgConf) {
            $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
            $rawC = if ($rawC -match '(?m)^enabled=.*$') { [regex]::Replace($rawC, '(?m)^enabled=.*$', 'enabled=0') } else { $rawC.TrimEnd() + "`r`nenabled=0`r`n" }
            [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
        }
        Start-Sleep -Milliseconds 350
        Refresh-Dashboard
        Show-Toast 'TG Proxy выключен — в Telegram переключи Тип соединения на Системный' $false
    } else {
        if (Test-Path -LiteralPath $tgConf) {
            $rawC = [string](Get-Content -LiteralPath $tgConf -Raw -Encoding UTF8)
            $rawC = if ($rawC -match '(?m)^enabled=.*$') { [regex]::Replace($rawC, '(?m)^enabled=.*$', 'enabled=1') } else { $rawC.TrimEnd() + "`r`nenabled=1`r`n" }
            [System.IO.File]::WriteAllText($tgConf, $rawC, (New-Object System.Text.UTF8Encoding($false)))
        }
        if ($null -ne $svcTg) {
            Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList 'config zapret-tgws start= auto' -WindowStyle Hidden -Wait | Out-Null
            Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 450
            Refresh-Dashboard
            Show-Toast 'Telegram Proxy запущен' $false
        } else {
            $env:Z2_ROOT = $Root
            Run-ConsoleTool 'utils\tgws_helper.ps1' 'ensure-service-silent' $false 'Запуск Telegram Proxy' $BtnTgToggle
        }
    }
})

$BtnPause.Add_Click({
    $svcZ = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -eq $svcZ) {
        Set-Status 'Служба zapret не установлена — сначала запусти Автонастройку.' '#D9B066'
        Refresh-Dashboard
        return
    }
    if ($svcZ.Status -eq 'Running') {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        Stop-Service -Name 'zapret-tgws' -Force -ErrorAction SilentlyContinue
        Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Set-Status 'Обход поставлен на паузу.' '#D9B066'
    } else {
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
        $tgEnResume = $true
        $tgConfResume = Join-Path $Root 'utils\tgws_proxy.conf'
        if (Test-Path -LiteralPath $tgConfResume) {
            $rcResume = [string](Get-Content -LiteralPath $tgConfResume -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($rcResume -match '(?m)^enabled=0\s*$') { $tgEnResume = $false }
        }
        if ($tgEnResume) { Start-Service -Name 'zapret-tgws' -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 450
        $svcAfter = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $svcAfter -and $svcAfter.Status -eq 'Running') {
            Set-Status 'Обход возобновлён.' $AccentLightHex
        } else {
            Set-Status 'Не удалось запустить службу zapret — проверь диагностику.' '#D97777'
        }
    }
    Start-Sleep -Milliseconds 250
    Refresh-Dashboard
})

function Apply-SettingsNow([bool]$UpdateGameFilter = $false) {
    $fAuto = Join-Path $Root 'utils\autohostlist.enabled'
    if ($ChkAutoHost.IsChecked) { [IO.File]::WriteAllText($fAuto, "1`n") }
    elseif (Test-Path -LiteralPath $fAuto) { Remove-Item -LiteralPath $fAuto -Force }

    $fWarp = Join-Path $Root 'utils\warp_unblock.enabled'
    if ($ChkWarp.IsChecked) { [IO.File]::WriteAllText($fWarp, "1`n") }
    elseif (Test-Path -LiteralPath $fWarp) { Remove-Item -LiteralPath $fWarp -Force }

    $fKern = Join-Path $Root 'utils\kernel_filter.enabled'
    if ($ChkKernelFilter.IsChecked) { [IO.File]::WriteAllText($fKern, "1`n") }
    elseif (Test-Path -LiteralPath $fKern) { Remove-Item -LiteralPath $fKern -Force }

    if ($UpdateGameFilter) {
        $fGf = Join-Path $Root 'utils\game_filter.enabled'
        $curTcp = '1024-65535'; $curUdp = '1024-65535'; $curMode = 'all'
        if (Test-Path -LiteralPath $fGf) {
            foreach ($gl in (Get-Content -LiteralPath $fGf)) {
                if ($gl -match '^(?i)tcp=(.+)$') { $curTcp = $matches[1].Trim() }
                elseif ($gl -match '^(?i)udp=(.+)$') { $curUdp = $matches[1].Trim() }
                elseif ($gl -match '^(?i)mode=(.+)$') { $m = $matches[1].Trim().ToLowerInvariant(); if ($m -in @('all','tcp','udp')) { $curMode = $m } }
            }
        }
        $gfVal = if ($ChkGameFilter.IsChecked) { $curMode } else { 'disabled' }
        [IO.File]::WriteAllText($fGf, "mode=$gfVal`r`ntcp=$curTcp`r`nudp=$curUdp`r`n")
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
}
$ChkAutoHost.Add_Click({ Apply-SettingsNow $false })
$ChkWarp.Add_Click({ Apply-SettingsNow $false })
$ChkGameFilter.Add_Click({ Apply-SettingsNow $true })
$ChkKernelFilter.Add_Click({ Apply-SettingsNow $false })
$ChkNlmVpn.Add_Click({
    $nlmScript = Join-Path $Root 'utils\nlm_helper.ps1'
    if ($ChkNlmVpn.IsChecked) {
        $global:LASTEXITCODE = 0
        & $nlmScript -Action auto -Root $Root | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $ChkNlmVpn.IsChecked = $false
            Show-Toast 'Не удалось настроить NLM-фильтр.' $true
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'utils\nlm_filter.enabled')) -and -not (Test-Path -LiteralPath (Join-Path $Root 'utils\nlm_auto.enabled'))) {
            $ChkNlmVpn.IsChecked = $false
            Show-Toast 'Не удалось включить авто-исключение VPN (NLM).' $true
            return
        }
    } else {
        & $nlmScript -Action clear -Root $Root | Out-Null
    }
    Apply-SettingsNow $false
})
$BtnNlmConfig.Add_Click({
    if (Get-Command Show-Z2NlmDialog -ErrorAction SilentlyContinue) {
        $saved = Show-Z2NlmDialog $Root $win $AccentHex
        if ($saved) {
            Refresh-Dashboard
            Apply-SettingsNow $false
            Show-Toast 'Список исключённых VPN (NLM) обновлён и применён' $false
        }
    }
})
$BtnBrowserFix.Add_Click({
    & (Join-Path $Root 'utils\browser_helper.ps1') -Action enable -Root $Root | Out-Null
    Refresh-Dashboard
    Show-Toast 'Фикс браузера (QUIC выкл + DoH вкл) применён — перезапусти браузер!' $false
})
$BtnBrowserRevert.Add_Click({
    & (Join-Path $Root 'utils\browser_helper.ps1') -Action revert -Root $Root | Out-Null
    Refresh-Dashboard
    Show-Toast 'Политики QUIC/DoH браузера возвращены к стандартным.' $false
})
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
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    if ($ChkAutoUpdate.IsChecked) {
        & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
        $CmbAutoUpdMode.IsEnabled = $true
        $mTxt = switch ($selM) { 'onboot' { 'при включении ПК (через 2 мин)' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
        Show-Toast "Автообновление включено: $mTxt" $false
    } else {
        & $auScript -Action disable -Root $Root | Out-Null
        $CmbAutoUpdMode.IsEnabled = $false
        Show-Toast 'Автообновление отключено.' $false
    }
    Sync-AutoDoneUpdBtn
})
$CmbAutoUpdMode.Add_SelectionChanged({
    if ($script:SuppressAutoUpdEvent -or -not $ChkAutoUpdate.IsChecked) { return }
    $auScript = Join-Path $Root 'utils\autoupdate_task.ps1'
    $selIdx = [Math]::Max(0, [Math]::Min($CmbAutoUpdMode.SelectedIndex, $script:AutoUpdKeys.Count - 1)); $selM = $script:AutoUpdKeys[$selIdx]
    & $auScript -Action enable -Root $Root -Mode $selM | Out-Null
    $mTxt = switch ($selM) { 'onboot' { 'при включении ПК (через 2 мин)' } 'twiceweekly' { '2 раза в неделю в простое' } 'monthly' { '1 раз в месяц в простое' } default { '1 раз в неделю в простое' } }
    Show-Toast "Режим автообновления: $mTxt" $false
})


# One-time silent VPN (NLM) auto-detection on first GUI launch so toggle is ON out of the box
$nlmInitMarker = Join-Path $Root 'utils\nlm_filter.init'
$nlmEnFileInit = Join-Path $Root 'utils\nlm_filter.enabled'
if (-not (Test-Path -LiteralPath $nlmInitMarker) -and -not (Test-Path -LiteralPath $nlmEnFileInit)) {
    try { & (Join-Path $Root 'utils\nlm_helper.ps1') -Action auto -Root $Root | Out-Null } catch {}
    try { [System.IO.File]::WriteAllText($nlmInitMarker, '1', (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
Load-Strategies 'core'
Refresh-Dashboard
if ($AutoStart) {
    $win.Add_ContentRendered({
        $needsMove = ($Root -notmatch '^(?i)C:\\Zapret2\\?$') -and (
            ($Root -match '(?i)\\(Downloads|Desktop|OneDrive|Temp)\\') -or
            ($Root -match '[\s()]') -or
            ($Root -match '[\u0400-\u04FF]')
        )
        if ($needsMove) {
            $mvAns = [System.Windows.MessageBox]::Show("Папка находится в ненадёжном пути:`n$Root`n`nПути в Загрузках, с пробелами/скобками или кириллицей могут ломать службы Windows.`nПеренести Zapret2 Kotek в чистую папку C:\Zapret2 и продолжить настройку оттуда?", "Перенос в C:\Zapret2", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($mvAns -eq [System.Windows.MessageBoxResult]::Yes) {
                $targetRoot = 'C:\Zapret2\'
                foreach ($s in @('zapret','zapret2','zapret-tgws','WinDivert','WinDivert14')) {
                    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList "stop $s" -WindowStyle Hidden -Wait | Out-Null
                }
                Get-Process -Name 'winws2','winws','tg-ws-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 350
                if (-not (Test-Path -LiteralPath $targetRoot)) { New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null }
                & "$env:SystemRoot\System32\robocopy.exe" ($Root.TrimEnd('\')) ($targetRoot.TrimEnd('\')) /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
                $newGui = Join-Path $targetRoot 'utils\gui_app.ps1'
                $script:ForceExitGui = $true
                Exit-Z2GuiMutex
                $env:Z2_ROOT = $targetRoot
                Start-Process -FilePath 'powershell.exe' -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$newGui`" -Root `"$targetRoot`" -AutoStart" -WorkingDirectory $targetRoot
                $win.Close()
                return
            }
        }
        Run-ConsoleTool 'utils\auto_setup.ps1' '-NonInteractive' $false 'Автонастройка' $BtnAutoSetup
    })
}
$CmbIpsetMode.Add_SelectionChanged({
    if ($script:SuppressIpsetEvent) { return }
    $idx = $CmbIpsetMode.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:IpsetModeKeys.Count) { return }
    $mode = $script:IpsetModeKeys[$idx]
    $ok = Set-Z2IpsetMode $Root $mode
    if (-not $ok) {
        Show-Toast 'Нет резервной копии IPSet — нажми «Обновить» для загрузки списка.' $true
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
        try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch {}
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
            $ni.Icon = New-Object System.Drawing.Icon($msIco)
        } catch {}
    }
    if ($null -eq $ni.Icon) { $ni.Icon = [System.Drawing.SystemIcons]::Shield }

    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $cm.Items.Add('Открыть Zapret2 Kotek')
    $miOpen.Add_Click({
        $win.ShowInTaskbar = $true
        $win.Show()
        $win.WindowState = 'Normal'
        $win.Activate()
        $script:CatTimer.Start()
        Refresh-Dashboard
    })
    $miPause = $cm.Items.Add('Пауза / Возобновить обход')
    $miPause.Add_Click({ $BtnPause.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
    [void]$cm.Items.Add('-')
    $miExit = $cm.Items.Add('Выход')
    $miExit.Add_Click({
        $script:ForceExitGui = $true
        Dispose-Z2TrayIcon
        $win.Close()
    })
    $ni.ContextMenuStrip = $cm
    $ni.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $win.ShowInTaskbar = $true
            $win.Show()
            $win.WindowState = 'Normal'
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
    $fTray = Join-Path $Root 'utils\tray_mode.enabled'
    if ($ChkTrayMode.IsChecked) {
        [IO.File]::WriteAllText($fTray, "1`n")
        Ensure-Z2TrayIcon
        Show-Toast 'Иконка в трее включена — при закрытии окно свернётся к часам' $false
    } else {
        if (Test-Path -LiteralPath $fTray) { Remove-Item -LiteralPath $fTray -Force -ErrorAction SilentlyContinue }
        Dispose-Z2TrayIcon
        Show-Toast 'Иконка в трее отключена — окно будет закрываться полностью' $false
    }
})

if (Test-Path -LiteralPath (Join-Path $Root 'utils\tray_mode.enabled')) {
    Ensure-Z2TrayIcon
}

$win.Add_Closing({
    param($s, $e)
    if (-not $script:ForceExitGui -and $ChkTrayMode.IsChecked -and ($null -eq $script:WatchedProc -or $script:WatchedProc.HasExited)) {
        $e.Cancel = $true
        Ensure-Z2TrayIcon
        $script:CatTimer.Stop()
        $win.Hide()
        $win.ShowInTaskbar = $false
        return
    }
    Stop-Z2ActiveTask $script:WatchedProc
    Dispose-Z2TrayIcon
})
[void]$win.ShowDialog()
$script:CatTimer.Stop()
Dispose-Z2TrayIcon
Exit-Z2GuiMutex
