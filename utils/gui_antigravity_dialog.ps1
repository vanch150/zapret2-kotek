# Zapret2 Kotek — Interactive 4-Step Google Antigravity Wizard (utils/gui_antigravity_dialog.ps1)

function Find-Z2AntigravityModuleScript([string]$Root) {
    $modRoot = Join-Path $Root 'modules'
    if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) { return '' }
    $direct = Join-Path $modRoot 'antigravity\antigravity_helper.ps1'
    if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    foreach ($f in (Get-ChildItem -LiteralPath $modRoot -Recurse -Filter 'antigravity_helper.ps1' -File -ErrorAction SilentlyContinue)) {
        return $f.FullName
    }
    return ''
}

function Start-Z2AgAsyncCmd([string]$ScriptPath, [string]$ActionArgs) {
    $outFile = Join-Path $env:TEMP ("z2_ag_out_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $escScript = $ScriptPath.Replace("'", "''")
    $escOut    = $outFile.Replace("'", "''")
    $innerCmd  = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; `$OutputEncoding=[System.Text.Encoding]::UTF8; & '$escScript' -Action $ActionArgs *>&1 | Out-File -LiteralPath '$escOut' -Encoding UTF8"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerCmd))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    return [PSCustomObject]@{ Proc = $proc; OutFile = $outFile }
}

function Get-Z2DownloadsDir {
    try {
        $usf = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
        $raw = if ($null -ne $usf) { [string]$usf.'{374DE290-123F-4565-9164-39C4925E467B}' } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $exp = [Environment]::ExpandEnvironmentVariables($raw)
            if (Test-Path -LiteralPath $exp -PathType Container) { return $exp }
        }
    } catch {}
    try {
        $sf = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue
        $raw2 = if ($null -ne $sf) { [string]$sf.'{374DE290-123F-4565-9164-39C4925E467B}' } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($raw2) -and (Test-Path -LiteralPath $raw2 -PathType Container)) { return $raw2 }
    } catch {}
    $fb = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $fb -PathType Container) { return $fb }
    return $env:USERPROFILE
}

function Show-Z2AntigravityDialog([string]$Root, $OwnerWin, [string]$AccentHex = '#7BC4A4') {
    if (-not (Get-Command Get-Z2AiBypassState -ErrorAction SilentlyContinue) -or -not (Get-Command Get-Z2AiBypassConf -ErrorAction SilentlyContinue)) {
        $aiHelperPath = Join-Path $Root 'utils\ai_bypass_helper.ps1'
        if (Test-Path -LiteralPath $aiHelperPath) {
            try { . $aiHelperPath -Root $Root } catch {}
        }
    }
    $accent = if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $AccentHex } else { '#7BC4A4' }
    $accentFg = '#121316'
    try {
        $ar = [Convert]::ToInt32($accent.Substring(1, 2), 16)
        $ag = [Convert]::ToInt32($accent.Substring(3, 2), 16)
        $ab = [Convert]::ToInt32($accent.Substring(5, 2), 16)
        $lum = (0.299 * $ar) + (0.587 * $ag) + (0.114 * $ab)
        if ($lum -lt 145) { $accentFg = '#FFFFFF' }
    } catch {}
    $releaseUrl = 'https://github.com/vanch150/kotek-antigravity-helper/releases/latest'

    $dlgXamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Мастер настройки Google Antigravity — Zapret2 Kotek"
        Width="650" Height="510" MinWidth="600" MinHeight="470"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="AgPrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="__ACCENT__"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="15,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.38"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AgSecBtn" TargetType="Button">
            <Setter Property="Background" Value="#1E2026"/>
            <Setter Property="Foreground" Value="#D4D7DD"/>
            <Setter Property="BorderBrush" Value="#2E323B"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="13,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2E37"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.38"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="20,18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Stepper Header -->
        <StackPanel Grid.Row="0" Margin="0,0,0,14">
            <TextBlock Text="Настройка Google Antigravity" FontSize="16" FontWeight="SemiBold" Foreground="#F1F3F5"/>
            <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="PillStep1" Grid.Column="0" Background="#1E2026" BorderBrush="__ACCENT__" BorderThickness="1" CornerRadius="6" Padding="8,5" Margin="0,0,6,0">
                    <TextBlock x:Name="LblPill1" Text="1. Сеть" FontSize="12" FontWeight="SemiBold" Foreground="#F1F3F5" HorizontalAlignment="Center"/>
                </Border>
                <Border x:Name="PillStep2" Grid.Column="1" Background="#16181D" BorderBrush="#262A33" BorderThickness="1" CornerRadius="6" Padding="8,5" Margin="0,0,6,0">
                    <TextBlock x:Name="LblPill2" Text="2. Модуль" FontSize="12" Foreground="#737A86" HorizontalAlignment="Center"/>
                </Border>
                <Border x:Name="PillStep3" Grid.Column="2" Background="#16181D" BorderBrush="#262A33" BorderThickness="1" CornerRadius="6" Padding="8,5" Margin="0,0,6,0">
                    <TextBlock x:Name="LblPill3" Text="3. Патч" FontSize="12" Foreground="#737A86" HorizontalAlignment="Center"/>
                </Border>
                <Border x:Name="PillStep4" Grid.Column="3" Background="#16181D" BorderBrush="#262A33" BorderThickness="1" CornerRadius="6" Padding="8,5">
                    <TextBlock x:Name="LblPill4" Text="4. Готово" FontSize="12" Foreground="#737A86" HorizontalAlignment="Center"/>
                </Border>
            </Grid>
        </StackPanel>

        <!-- Main Step Content Area -->
        <Border Grid.Row="1" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="10" Padding="18,16" Margin="0,0,0,14">
            <Grid>
                <!-- PAGE 1: Network Bypass -->
                <StackPanel x:Name="PageStep1" Visibility="Visible">
                    <TextBlock Text="Шаг 1 · Сетевой обход (SmartDNS)" FontSize="15" FontWeight="SemiBold" Foreground="#F1F3F5"/>
                    <TextBlock Text="Направляет домены Antigravity (antigravity.google, cloudcode-pa.googleapis.com) через SmartDNS без VPN. Если у тебя зарубежный Google-аккаунт — этого шага уже достаточно." FontSize="12.5" Foreground="#9CA3AF" Margin="0,6,0,14" TextWrapping="Wrap"/>

                    <Border Background="#14161B" BorderBrush="#262A33" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="TxtStep1Status" Text="Проверяю статус «Обхода ИИ»..." FontSize="13.5" FontWeight="SemiBold" Foreground="#D9B066" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtStep1Sub" Text="" FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnStep1Enable" Content="Включить сетевой обход" Style="{StaticResource AgPrimaryBtn}" Margin="0,0,10,0"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtStep1Err" Text="" FontSize="12" Foreground="#D97777" Margin="0,10,0,0" TextWrapping="Wrap"/>
                </StackPanel>

                <!-- PAGE 2: Install Module -->
                <StackPanel x:Name="PageStep2" Visibility="Collapsed">
                    <TextBlock Text="Шаг 2 · Подключение модуля для РФ-аккаунта" FontSize="15" FontWeight="SemiBold" Foreground="#F1F3F5"/>
                    <TextBlock Text="Модуль живёт в отдельном репозитории, чтобы основной Zapret2 Kotek оставался чистым для антивирусов. Скачай ZIP с GitHub и укажи его ниже — Котек сам распакует его в modules\antigravity\." FontSize="12.5" Foreground="#9CA3AF" Margin="0,6,0,14" TextWrapping="Wrap"/>

                    <Border Background="#14161B" BorderBrush="#262A33" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="TxtStep2Status" Text="Модуль пока не установлен" FontSize="13.5" FontWeight="SemiBold" Foreground="#D9B066" TextWrapping="Wrap"/>
                            <TextBlock x:Name="TxtStep2Path" Text="Ожидаю распаковку в modules\antigravity\ (проверяется автоматически)..." FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnStep2Download" Content="1. Скачать ZIP ↗" Style="{StaticResource AgPrimaryBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnStep2PickZip" Content="2. Указать ZIP..." Style="{StaticResource AgSecBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnStep2OpenDir" Content="Папка modules\" Style="{StaticResource AgSecBtn}"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtStep2Msg" Text="" FontSize="12" Foreground="#9CA3AF" Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>

                <!-- PAGE 3: Apply / Restore Patch -->
                <Grid x:Name="PageStep3" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Margin="0,0,0,10">
                        <TextBlock Text="Шаг 3 · Применение патча (с бэкапом *.agybak)" FontSize="15" FontWeight="SemiBold" Foreground="#F1F3F5"/>
                        <TextBlock x:Name="TxtStep3ProcWarn" Text="Проверяю запущенные процессы Antigravity..." FontSize="12.5" Foreground="#9CA3AF" Margin="0,5,0,0" TextWrapping="Wrap"/>
                    </StackPanel>

                    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
                        <Button x:Name="BtnStep3Patch" Content="Применить патч" Style="{StaticResource AgPrimaryBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnStep3Status" Content="Проверить статус" Style="{StaticResource AgSecBtn}" Margin="0,0,8,0"/>
                        <Button x:Name="BtnStep3Restore" Content="Откатить (.agybak)" Style="{StaticResource AgSecBtn}"/>
                    </StackPanel>

                    <TextBlock x:Name="TxtStep3Hint" Grid.Row="2" Text="" FontSize="12" Foreground="#9CA3AF" Margin="0,0,0,6" TextWrapping="Wrap"/>

                    <Border Grid.Row="3" Background="#14161B" BorderBrush="#262A33" BorderThickness="1" CornerRadius="8" Padding="10,8">
                        <TextBox x:Name="TxtAgLog" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#CBD5E1" FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True" Text="Нажми «Применить патч» или «Проверить статус»."/>
                    </Border>
                </Grid>

                <!-- PAGE 4: Done -->
                <StackPanel x:Name="PageStep4" Visibility="Collapsed" VerticalAlignment="Center">
                    <TextBlock Text="✓ Настройка завершена!" FontSize="18" FontWeight="SemiBold" Foreground="__ACCENT__"/>
                    <TextBlock Text="Сеть Antigravity идёт через SmartDNS, а локальная проверка региона снята (оригиналы сохранены в *.agybak)." FontSize="13" Foreground="#E5E7EB" Margin="0,8,0,14" TextWrapping="Wrap"/>
                    <Border Background="#14161B" BorderBrush="#262A33" BorderThickness="1" CornerRadius="8" Padding="14,12">
                        <StackPanel>
                            <TextBlock Text="Что делать дальше:" FontSize="13" FontWeight="SemiBold" Foreground="#F1F3F5" Margin="0,0,0,6"/>
                            <TextBlock Text="1. Запусти Google Antigravity и войди в свой Google-аккаунт." FontSize="12.5" Foreground="#CBD5E1" Margin="0,0,0,4" TextWrapping="Wrap"/>
                            <TextBlock Text="2. Если после будущего обновления IDE снова появится ошибка региона — просто открой этот мастер и нажми «Применить патч» на Шаге 3 (свежие сигнатуры подтянутся сами)." FontSize="12.5" Foreground="#9CA3AF" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Wizard Navigation Footer -->
        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnWizBack" Grid.Column="0" Content="← Назад" Style="{StaticResource AgSecBtn}" Visibility="Collapsed"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button x:Name="BtnWizCancel" Content="Закрыть" Style="{StaticResource AgSecBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnWizNext" Content="Далее →" Style="{StaticResource AgPrimaryBtn}"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

    $dlgXamlStr = $dlgXamlStr.Replace('__ACCENT__', $accent)
    [xml]$dx = $dlgXamlStr
    $dr = New-Object System.Xml.XmlNodeReader $dx
    $dlg = $null
    try {
        $dlg = [Windows.Markup.XamlReader]::Load($dr)
    } finally {
        $dr.Close()
    }
    if ($null -ne $OwnerWin) {
        try {
            $dlg.Owner = $OwnerWin
            if ($null -ne $OwnerWin.Icon) { $dlg.Icon = $OwnerWin.Icon }
        } catch {
            $dlg.WindowStartupLocation = 'CenterScreen'
        }
    }

    $dlg.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($dlg)).Handle
            if ($hwnd -ne [IntPtr]::Zero -and ('WinDwmHelper' -as [type])) {
                $dark = 1
                [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) | Out-Null
                $capColor = 0x00161312
                [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$capColor, 4) | Out-Null
            }
        } catch {}
    })

    $bc = New-Object System.Windows.Media.BrushConverter
    $PillStep1 = $dlg.FindName('PillStep1'); $LblPill1 = $dlg.FindName('LblPill1')
    $PillStep2 = $dlg.FindName('PillStep2'); $LblPill2 = $dlg.FindName('LblPill2')
    $PillStep3 = $dlg.FindName('PillStep3'); $LblPill3 = $dlg.FindName('LblPill3')
    $PillStep4 = $dlg.FindName('PillStep4'); $LblPill4 = $dlg.FindName('LblPill4')

    $PageStep1 = $dlg.FindName('PageStep1')
    $PageStep2 = $dlg.FindName('PageStep2')
    $PageStep3 = $dlg.FindName('PageStep3')
    $PageStep4 = $dlg.FindName('PageStep4')

    $TxtStep1Status   = $dlg.FindName('TxtStep1Status')
    $TxtStep1Sub      = $dlg.FindName('TxtStep1Sub')
    $BtnStep1Enable   = $dlg.FindName('BtnStep1Enable')
    $TxtStep1Err      = $dlg.FindName('TxtStep1Err')

    $TxtStep2Status   = $dlg.FindName('TxtStep2Status')
    $TxtStep2Path     = $dlg.FindName('TxtStep2Path')
    $BtnStep2Download = $dlg.FindName('BtnStep2Download')
    $BtnStep2PickZip  = $dlg.FindName('BtnStep2PickZip')
    $BtnStep2OpenDir  = $dlg.FindName('BtnStep2OpenDir')
    $TxtStep2Msg      = $dlg.FindName('TxtStep2Msg')

    $TxtStep3ProcWarn = $dlg.FindName('TxtStep3ProcWarn')
    $BtnStep3Patch    = $dlg.FindName('BtnStep3Patch')
    $BtnStep3Status   = $dlg.FindName('BtnStep3Status')
    $BtnStep3Restore  = $dlg.FindName('BtnStep3Restore')
    $TxtStep3Hint     = $dlg.FindName('TxtStep3Hint')
    $TxtAgLog         = $dlg.FindName('TxtAgLog')

    $BtnWizBack   = $dlg.FindName('BtnWizBack')
    $BtnWizCancel = $dlg.FindName('BtnWizCancel')
    $BtnWizNext   = $dlg.FindName('BtnWizNext')
    $fgBrush = $bc.ConvertFromString($accentFg)
    foreach ($pb in @($BtnStep1Enable, $BtnStep2Download, $BtnStep3Patch, $BtnWizNext)) {
        if ($null -ne $pb) { $pb.Foreground = $fgBrush }
    }

    $state = [PSCustomObject]@{
        Step       = 1
        Changed    = $false
        AiOk       = $false
        ModulePath = ''
        PatchedOk  = $false
        Busy       = $false
        JobProc    = $null
        JobOutFile = ''
        JobKind    = ''
        JobAct     = ''
    }

    $pills = @($PillStep1, $PillStep2, $PillStep3, $PillStep4)
    $lbls  = @($LblPill1, $LblPill2, $LblPill3, $LblPill4)
    $pages = @($PageStep1, $PageStep2, $PageStep3, $PageStep4)

    $refreshChecks = {
        # Step 1 check
        $state.AiOk = $false
        if (Get-Command Get-Z2AiBypassState -ErrorAction SilentlyContinue) {
            try {
                $aiSt = Get-Z2AiBypassState $Root
                if ($null -ne $aiSt -and $aiSt.Active -and (@($aiSt.Services) -contains 'antigravity')) {
                    $state.AiOk = $true
                    $TxtStep1Status.Text = "✓ Сетевой обход активен ($($aiSt.ActiveName))"
                    $TxtStep1Status.Foreground = $bc.ConvertFromString($accent)
                    $TxtStep1Sub.Text = 'Домены Google Antigravity уже идут через SmartDNS. Можно переходить к Шагу 2.'
                    $BtnStep1Enable.Content = 'Перезапустить обход'
                } else {
                    $TxtStep1Status.Text = 'Сетевой обход Antigravity пока выключен'
                    $TxtStep1Status.Foreground = $bc.ConvertFromString('#D9B066')
                    $TxtStep1Sub.Text = 'Нажми кнопку ниже — Котек добавит Google Antigravity в «Обход ИИ» и включит SmartDNS.'
                    $BtnStep1Enable.Content = 'Включить сетевой обход'
                }
            } catch {}
        }

        # Step 2 check
        $modPath = Find-Z2AntigravityModuleScript $Root
        $state.ModulePath = $modPath
        if ($modPath) {
            $TxtStep2Status.Text = '✓ Модуль найден и готов к работе'
            $TxtStep2Status.Foreground = $bc.ConvertFromString($accent)
            $TxtStep2Path.Text = $modPath
        } else {
            $TxtStep2Status.Text = 'Модуль пока не установлен'
            $TxtStep2Status.Foreground = $bc.ConvertFromString('#D9B066')
            $TxtStep2Path.Text = 'Ожидаю распаковку в modules\antigravity\ (проверяется автоматически каждые 1.5 сек)...'
        }

        # Step 3 process check
        $running = New-Object System.Collections.Generic.List[string]
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.ProcessName -like 'Antigravity*' -or $p.ProcessName -ieq 'agy' -or $p.ProcessName -like 'language_server*') {
                $running.Add($p.ProcessName)
            }
        }
        if ($running.Count -gt 0) {
            $TxtStep3ProcWarn.Text = "⚠ Сначала закрой процессы: $(($running | Select-Object -Unique) -join ', ') (обновится само)."
            $TxtStep3ProcWarn.Foreground = $bc.ConvertFromString('#D9B066')
        } else {
            $TxtStep3ProcWarn.Text = '✓ Процессы Antigravity закрыты — можно безопасно применять патч.'
            $TxtStep3ProcWarn.Foreground = $bc.ConvertFromString($accent)
        }
    }

    $renderStep = {
        & $refreshChecks
        $s = $state.Step
        for ($i = 0; $i -lt 4; $i++) {
            $pages[$i].Visibility = if (($i + 1) -eq $s) { 'Visible' } else { 'Collapsed' }
            if (($i + 1) -eq $s) {
                $pills[$i].Background  = $bc.ConvertFromString('#1E2026')
                $pills[$i].BorderBrush = $bc.ConvertFromString($accent)
                $lbls[$i].Foreground   = $bc.ConvertFromString('#F1F3F5')
                $lbls[$i].FontWeight   = [System.Windows.FontWeights]::SemiBold
            } elseif (($i + 1) -lt $s) {
                $pills[$i].Background  = $bc.ConvertFromString('#161B19')
                $pills[$i].BorderBrush = $bc.ConvertFromString('#2B3A33')
                $lbls[$i].Foreground   = $bc.ConvertFromString($accent)
                $lbls[$i].FontWeight   = [System.Windows.FontWeights]::Normal
            } else {
                $pills[$i].Background  = $bc.ConvertFromString('#16181D')
                $pills[$i].BorderBrush = $bc.ConvertFromString('#262A33')
                $lbls[$i].Foreground   = $bc.ConvertFromString('#737A86')
                $lbls[$i].FontWeight   = [System.Windows.FontWeights]::Normal
            }
        }

        $BtnWizBack.Visibility = if ($s -gt 1) { 'Visible' } else { 'Collapsed' }
        if ($s -eq 1) {
            $BtnWizNext.Content   = 'Далее →'
            $BtnWizNext.IsEnabled = $true
        } elseif ($s -eq 2) {
            $BtnWizNext.Content   = 'Далее →'
            $BtnWizNext.IsEnabled = (-not [string]::IsNullOrWhiteSpace($state.ModulePath))
        } elseif ($s -eq 3) {
            $BtnWizNext.Content   = 'Завершить →'
            $BtnWizNext.IsEnabled = $true
        } else {
            $BtnWizNext.Content   = 'Готово'
            $BtnWizNext.IsEnabled = $true
        }
    }

    $setBusyUi = {
        param([bool]$IsBusy)
        $state.Busy = $IsBusy
        $BtnStep1Enable.IsEnabled  = (-not $IsBusy)
        $BtnStep3Patch.IsEnabled   = (-not $IsBusy)
        $BtnStep3Status.IsEnabled  = (-not $IsBusy)
        $BtnStep3Restore.IsEnabled = (-not $IsBusy)
        $BtnWizBack.IsEnabled      = (-not $IsBusy)
        if ($IsBusy) { $BtnWizNext.IsEnabled = $false }
    }

    # Fast 250ms UI timer: polls non-blocking background job + refreshes Step 2/3 every ~1.5s
    $tickCounter = [PSCustomObject]@{ N = 0 }
    $wizTimer = New-Object System.Windows.Threading.DispatcherTimer
    $wizTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $wizTimer.Add_Tick({
        if ($state.Busy -and $null -ne $state.JobProc) {
            if ($state.JobProc.HasExited) {
                $exitCode = 0
                try { $exitCode = $state.JobProc.ExitCode } catch {}
                $outTxt = ''
                if ($state.JobOutFile -and (Test-Path -LiteralPath $state.JobOutFile -PathType Leaf)) {
                    try { $outTxt = ([System.IO.File]::ReadAllText($state.JobOutFile, [System.Text.Encoding]::UTF8)).Trim() } catch {}
                    Remove-Item -LiteralPath $state.JobOutFile -Force -ErrorAction SilentlyContinue
                }
                $kind = $state.JobKind
                $act  = $state.JobAct
                try { $state.JobProc.Dispose() } catch {}
                $state.JobProc = $null
                $state.JobOutFile = ''
                & $setBusyUi $false

                if ($kind -eq 'step1') {
                    $state.Changed = $true
                    if ($exitCode -ne 0 -and $outTxt) { $TxtStep1Err.Text = $outTxt }
                    & $renderStep
                } elseif ($kind -eq 'step3') {
                    $TxtAgLog.Text = if ($outTxt) { $outTxt } else { '(пустой вывод)' }
                    if ($act -eq 'patch' -and $outTxt -match '\[OK\]') {
                        $state.PatchedOk = $true
                        $TxtStep3Hint.Text = 'Патч успешно применён! Нажми «Завершить →».'
                        $TxtStep3Hint.Foreground = $bc.ConvertFromString($accent)
                    } elseif ($act -eq 'restore' -and $outTxt -match '\[OK\]') {
                        $TxtStep3Hint.Text = 'Оригинальные файлы восстановлены из бэкапов *.agybak.'
                        $TxtStep3Hint.Foreground = $bc.ConvertFromString($accent)
                    } elseif ($outTxt -match '\[X\]') {
                        $TxtStep3Hint.Text = 'Операция остановлена — смотри лог ниже.'
                        $TxtStep3Hint.Foreground = $bc.ConvertFromString('#D97777')
                    } else {
                        $TxtStep3Hint.Text = 'Проверка завершена.'
                        $TxtStep3Hint.Foreground = $bc.ConvertFromString('#9CA3AF')
                    }
                    & $renderStep
                }
            }
            return
        }

        $tickCounter.N++
        if (($tickCounter.N % 6) -ne 0) { return }
        if ($state.Step -eq 2 -or $state.Step -eq 3) {
            $hadMod = (-not [string]::IsNullOrWhiteSpace($state.ModulePath))
            & $refreshChecks
            if ($state.Step -eq 2) {
                $BtnWizNext.IsEnabled = (-not [string]::IsNullOrWhiteSpace($state.ModulePath))
                if (-not $hadMod -and $state.ModulePath) {
                    $TxtStep2Msg.Text = 'Модуль обнаружен автоматически! Нажми «Далее →».'
                    $TxtStep2Msg.Foreground = $bc.ConvertFromString($accent)
                }
            }
        }
    })
    $dlg.Add_Closed({
        try { $wizTimer.Stop() } catch {}
        try {
            if ($null -ne $state.JobProc -and -not $state.JobProc.HasExited) { $state.JobProc.Kill() }
        } catch {}
    })

    $BtnStep1Enable.Add_Click({
        if ($state.Busy) { return }
        $aiP = Join-Path $Root 'utils\ai_bypass_helper.ps1'
        if (-not (Test-Path -LiteralPath $aiP -PathType Leaf)) { return }
        $TxtStep1Err.Text = ''
        $TxtStep1Status.Text = 'Включаю сетевой обход Antigravity (подожди 3–5 сек)...'
        $TxtStep1Status.Foreground = $bc.ConvertFromString('#9CA3AF')
        try {
            $cfg = Get-Z2AiBypassConf $Root
            $svcs = New-Object System.Collections.Generic.List[string]
            foreach ($s in ($cfg.Services -split '[,;\s]+')) {
                $t = $s.Trim().ToLowerInvariant()
                if ($t -and -not ($svcs -contains $t)) { $svcs.Add($t) }
            }
            if (-not ($svcs -contains 'antigravity')) { $svcs.Add('antigravity') }
            $svcStr = ($svcs -join ',')
            $modeArg = if ($cfg.Mode) { $cfg.Mode } else { 'auto' }
            $escMode = ([string]$modeArg).Replace("'", "''")
            $escSvc  = ([string]$svcStr).Replace("'", "''")
            $job = Start-Z2AgAsyncCmd $aiP "enable -Provider '$escMode' -Services '$escSvc'"
            $state.JobProc    = $job.Proc
            $state.JobOutFile = $job.OutFile
            $state.JobKind    = 'step1'
            $state.JobAct     = 'enable'
            & $setBusyUi $true
        } catch {
            $TxtStep1Err.Text = "Ошибка: $($_.Exception.Message)"
            & $setBusyUi $false
            & $renderStep
        }
    })

    $BtnStep2Download.Add_Click({
        try { Start-Process $releaseUrl } catch {}
    })

    $BtnStep2PickZip.Add_Click({
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Title = 'Выбери скачанный архив kotek-antigravity-helper*.zip'
            $ofd.Filter = 'ZIP архивы (*.zip)|*.zip|Все файлы (*.*)|*.*'
            $dlDir = Get-Z2DownloadsDir
            if ($dlDir -and (Test-Path -LiteralPath $dlDir)) { $ofd.InitialDirectory = $dlDir }
            if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $destDir = Join-Path $Root 'modules\antigravity'
                if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Expand-Archive -LiteralPath $ofd.FileName -DestinationPath $destDir -Force
                & $refreshChecks
                if ($state.ModulePath) {
                    $TxtStep2Msg.Text = 'Архив успешно распакован! Перехожу к Шагу 3...'
                    $TxtStep2Msg.Foreground = $bc.ConvertFromString($accent)
                    $state.Step = 3
                    & $renderStep
                } else {
                    $TxtStep2Msg.Text = 'В выбранном архиве не найден antigravity_helper.ps1.'
                    $TxtStep2Msg.Foreground = $bc.ConvertFromString('#D97777')
                }
            }
        } catch {
            $TxtStep2Msg.Text = "Не удалось распаковать архив: $($_.Exception.Message)"
            $TxtStep2Msg.Foreground = $bc.ConvertFromString('#D97777')
        }
    })

    $BtnStep2OpenDir.Add_Click({
        $targetDir = Join-Path $Root 'modules\antigravity'
        try {
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$targetDir`""
        } catch {}
    })

    $runStep3 = {
        param([string]$Act)
        if ($state.Busy) { return }
        & $refreshChecks
        if (-not $state.ModulePath) { return }
        $TxtStep3Hint.Text = 'Выполняю в фоне (обновляю сигнатуры и сканирую файлы, подожди пару секунд)...'
        $TxtStep3Hint.Foreground = $bc.ConvertFromString('#9CA3AF')
        $TxtAgLog.Text = 'Выполняется операция...'
        try {
            $job = Start-Z2AgAsyncCmd $state.ModulePath $Act
            $state.JobProc    = $job.Proc
            $state.JobOutFile = $job.OutFile
            $state.JobKind    = 'step3'
            $state.JobAct     = $Act
            & $setBusyUi $true
        } catch {
            $TxtStep3Hint.Text = "Ошибка запуска: $($_.Exception.Message)"
            $TxtStep3Hint.Foreground = $bc.ConvertFromString('#D97777')
            & $setBusyUi $false
        }
    }

    $BtnStep3Patch.Add_Click({   & $runStep3 'patch'   })
    $BtnStep3Status.Add_Click({  & $runStep3 'status'  })
    $BtnStep3Restore.Add_Click({ & $runStep3 'restore' })

    $BtnWizBack.Add_Click({
        if ($state.Step -gt 1) { $state.Step--; & $renderStep }
    })

    $BtnWizNext.Add_Click({
        if ($state.Step -lt 4) {
            $state.Step++
            & $renderStep
        } else {
            $dlg.Close()
        }
    })

    $BtnWizCancel.Add_Click({ $dlg.Close() })

    & $renderStep
    $wizTimer.Start()
    [void]$dlg.ShowDialog()
    return $state.Changed
}
