# Zapret2 Kotek — Built-in Modal Browser QUIC/DoH Selector (utils/gui_browser_dialog.ps1)

function Show-Z2BrowserDialog([string]$Root, $OwnerWin, [string]$AccentHex = '#7BC4A4') {
    if (-not (Get-Command Show-Z2MessageDialog -ErrorAction SilentlyContinue)) {
        $msgDlgPath = Join-Path $Root 'utils\gui_msg_dialog.ps1'
        if (Test-Path -LiteralPath $msgDlgPath) { . $msgDlgPath }
    }

    $accent = if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $AccentHex } else { '#7BC4A4' }
    $bhPath = Join-Path $Root 'utils\browser_helper.ps1'
    if (-not (Test-Path -LiteralPath $bhPath)) { return $false }
    . $bhPath -Root $Root

    $dlgXamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Фикс браузеров (QUIC / DoH) — Zapret2 Kotek"
        Width="560" Height="450" MinWidth="460" MinHeight="380"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="BrPrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="__ACCENT__"/>
            <Setter Property="Foreground" Value="#121316"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="FontSize" Value="12.5"/>
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
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="BrSecBtn" TargetType="Button">
            <Setter Property="Background" Value="#1E2026"/>
            <Setter Property="Foreground" Value="#D4D7DD"/>
            <Setter Property="BorderBrush" Value="#2E323B"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2E37"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DarkCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E5E7EB"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="Transparent">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="box" Grid.Column="0" Width="18" Height="18" CornerRadius="4"
                                    Background="#181B22" BorderBrush="#3D4352" BorderThickness="1.5"
                                    VerticalAlignment="Center" Margin="0,0,10,0">
                                <Path x:Name="checkMark" Data="M 0,4.2 L 3.2,7.4 L 9.4,0.8" Width="10" Height="8.5" Stretch="Uniform"
                                      Stroke="#111316" StrokeThickness="2.1"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                      Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ContentPresenter Grid.Column="1" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="box" Property="BorderBrush" Value="__ACCENT__"/>
                                <Setter TargetName="box" Property="Background" Value="#20242E"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="box" Property="Background" Value="__ACCENT__"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="__ACCENT__"/>
                                <Setter TargetName="checkMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="18,16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock Text="Выбери браузеры для настройки QUIC / DoH" FontSize="14.5" FontWeight="SemiBold" Foreground="#F1F3F5"/>
            <TextBlock Text="Опционально: отключает QUIC (HTTP/3) и включает DoH в выбранных браузерах. После изменения перезапусти браузер." FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="8">
            <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel x:Name="PnlBrowserItems"/>
                </ScrollViewer>
                <TextBlock x:Name="TxtBrowserEmpty" Text="Установленные браузеры (Chrome, Edge, Firefox, Яндекс, Brave, Vivaldi, Opera) не найдены." Foreground="#737A86" FontSize="12.5" HorizontalAlignment="Center" VerticalAlignment="Center" TextWrapping="Wrap" Visibility="Collapsed"/>
            </Grid>
        </Border>

        <TextBlock x:Name="TxtBrowserHint" Grid.Row="2" Text="" FontSize="12" Foreground="#9CA3AF" Margin="2,8,2,8" TextWrapping="Wrap"/>

        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnBrApply" Content="Применить выбранные" Style="{StaticResource BrPrimaryBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnBrRevert" Content="Сбросить выбранные" Style="{StaticResource BrSecBtn}"/>
            </StackPanel>
            <Button x:Name="BtnBrClose" Grid.Column="2" Content="Закрыть" Style="{StaticResource BrSecBtn}"/>
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
    if ($null -ne $OwnerWin) { try { $dlg.Owner = $OwnerWin; if ($null -ne $OwnerWin.Icon) { $dlg.Icon = $OwnerWin.Icon } } catch { $dlg.WindowStartupLocation = 'CenterScreen' } }

    $dlg.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($dlg)).Handle
            $dark = 1
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) | Out-Null
            $capColor = 0x00161312
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$capColor, 4) | Out-Null
        } catch {}
    })

    $PnlBrowserItems = $dlg.FindName('PnlBrowserItems')
    $TxtBrowserEmpty = $dlg.FindName('TxtBrowserEmpty')
    $TxtBrowserHint  = $dlg.FindName('TxtBrowserHint')
    $BtnBrApply      = $dlg.FindName('BtnBrApply')
    $BtnBrRevert     = $dlg.FindName('BtnBrRevert')
    $BtnBrClose      = $dlg.FindName('BtnBrClose')

    $bc = New-Object System.Windows.Media.BrushConverter
    $checkMap = @{}
    $brState = [PSCustomObject]@{ Changed = $false }

    $renderBrowsers = {
        $PnlBrowserItems.Children.Clear()
        $list = Get-Z2BrowserStates
        $TxtBrowserEmpty.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        foreach ($b in $list) {
            if (-not $checkMap.ContainsKey($b.Id)) {
                $checkMap[$b.Id] = ($b.Kind -ne 'manual')
            }
            $row = New-Object System.Windows.Controls.Border
            $row.Background = $bc.ConvertFromString('#14161B')
            $row.BorderBrush = $bc.ConvertFromString('#262A33')
            $row.BorderThickness = New-Object System.Windows.Thickness(1)
            $row.CornerRadius = New-Object System.Windows.CornerRadius(6)
            $row.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
            $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)

            if ($b.Kind -eq 'manual') {
                $sp = New-Object System.Windows.Controls.StackPanel
                $tb1 = New-Object System.Windows.Controls.TextBlock
                $tb1.Text = "$($b.Name)  (ручная настройка)"
                $tb1.FontSize = 13
                $tb1.Foreground = $bc.ConvertFromString('#D4D7DD')
                $tb2 = New-Object System.Windows.Controls.TextBlock
                $tb2.Text = "Opera не читает политики реестра Windows. Открой $($b.ManualTip) и выбери Disabled."
                $tb2.FontSize = 11.5
                $tb2.Foreground = $bc.ConvertFromString('#9CA3AF')
                $tb2.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
                $tb2.TextWrapping = [System.Windows.TextWrapping]::Wrap
                [void]$sp.Children.Add($tb1)
                [void]$sp.Children.Add($tb2)
                $row.Child = $sp
            } else {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Style = $dlg.Resources['DarkCheckBox']
                $cb.IsChecked = [bool]$checkMap[$b.Id]
                $cb.Tag = $b.Id
                $cb.Cursor = [System.Windows.Input.Cursors]::Hand
                $sp = New-Object System.Windows.Controls.StackPanel
                $tb1 = New-Object System.Windows.Controls.TextBlock
                $tb1.Text = $b.Name
                $tb1.FontSize = 13
                $tb1.FontWeight = [System.Windows.FontWeights]::SemiBold
                $tb1.Foreground = $bc.ConvertFromString('#F1F3F5')
                $tb2 = New-Object System.Windows.Controls.TextBlock
                $tb2.Text = "Текущий статус: $($b.StatusText)"
                $tb2.FontSize = 11.5
                $tb2.Foreground = if ($b.Applied) { $bc.ConvertFromString($accent) } else { $bc.ConvertFromString('#9CA3AF') }
                $tb2.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
                [void]$sp.Children.Add($tb1)
                [void]$sp.Children.Add($tb2)
                $cb.Content = $sp
                $cb.Add_Click({
                    param($s, $e)
                    $checkMap[[string]$s.Tag] = [bool]$s.IsChecked
                })
                $row.Child = $cb
            }
            [void]$PnlBrowserItems.Children.Add($row)
        }
    }

    $BtnBrApply.Add_Click({
        $sel = New-Object System.Collections.Generic.List[string]
        foreach ($k in $checkMap.Keys) { if ($checkMap[$k]) { $sel.Add([string]$k) } }
        if ($sel.Count -eq 0) {
            $TxtBrowserHint.Text = 'Отметь хотя бы один браузер галочкой.'
            $TxtBrowserHint.Foreground = $bc.ConvertFromString('#D9B066')
            return
        }

        $setQuic = $true
        $setDoh  = $true
        if (-not (Get-Command Get-Z2AiBypassState -ErrorAction SilentlyContinue)) {
            $aiPath = Join-Path $Root 'utils\ai_bypass_helper.ps1'
            if (Test-Path -LiteralPath $aiPath) {
                try { . $aiPath -Root $Root } catch {}
            }
        }
        if (Get-Command Get-Z2AiBypassState -ErrorAction SilentlyContinue) {
            $aiState = $null
            try { $aiState = Get-Z2AiBypassState $Root } catch {}
            if ($null -ne $aiState -and $aiState.Active -and $setDoh) {
                $ans = 'No'
                if (Get-Command Show-Z2MessageDialog -ErrorAction SilentlyContinue) {
                    $ans = Show-Z2MessageDialog -Owner $dlg -Title 'Конфликт DoH и обхода ИИ' -Message "Сейчас активен обход ИИ через SmartDNS (NRPT). Включение DoH в браузере перехватывает DNS и конфликтует с обходом ИИ.`n`nОтключить обход ИИ и включить DoH (Да), или применить только отключение QUIC без DoH (Нет)?" -Kind Warning -Buttons YesNo -AccentHex $accent
                }
                if ($ans -eq 'Yes') {
                    if (Get-Command Disable-Z2AiBypass -ErrorAction SilentlyContinue) {
                        try { [void](Disable-Z2AiBypass $Root) } catch {}
                    }
                    $setDoh = $true
                } else {
                    $setDoh = $false
                }
            }
        }

        try {
            $applied = @(Enable-BrowserFix $sel.ToArray() $Root $setQuic $setDoh | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($applied.Count -gt 0) { $brState.Changed = $true }
            if ($applied.Count -gt 0) {
                if ($setDoh) {
                    $TxtBrowserHint.Text = "Применено для: $($applied -join ', '). Перезапусти браузер."
                } else {
                    $TxtBrowserHint.Text = "Применено (только QUIC, без DoH — обход ИИ сохранён) для: $($applied -join ', '). Перезапусти браузер."
                }
                $TxtBrowserHint.Foreground = $bc.ConvertFromString($accent)
            } else {
                $TxtBrowserHint.Text = 'Не удалось применить политики (проверь права администратора).'
                $TxtBrowserHint.Foreground = $bc.ConvertFromString('#D97777')
            }
        } catch {
            $TxtBrowserHint.Text = "Ошибка применения политик: $($_.Exception.Message)"
            $TxtBrowserHint.Foreground = $bc.ConvertFromString('#D97777')
        }
        & $renderBrowsers
    })

    $BtnBrRevert.Add_Click({
        $sel = New-Object System.Collections.Generic.List[string]
        foreach ($k in $checkMap.Keys) { if ($checkMap[$k]) { $sel.Add([string]$k) } }
        if ($sel.Count -eq 0) {
            $TxtBrowserHint.Text = 'Отметь хотя бы один браузер галочкой.'
            $TxtBrowserHint.Foreground = $bc.ConvertFromString('#D9B066')
            return
        }
        try {
            $cnt = Disable-BrowserFix $true $sel.ToArray() $Root
            if ($cnt -gt 0) { $brState.Changed = $true }
            $TxtBrowserHint.Text = if ($cnt -gt 0) { 'Политики сброшены к стандартным. Перезапусти браузер.' } else { 'В выбранных браузерах политик Zapret2 не было.' }
            $TxtBrowserHint.Foreground = $bc.ConvertFromString('#9CA3AF')
        } catch {
            $TxtBrowserHint.Text = "Ошибка сброса политик: $($_.Exception.Message)"
            $TxtBrowserHint.Foreground = $bc.ConvertFromString('#D97777')
        }
        & $renderBrowsers
    })

    $BtnBrClose.Add_Click({ $dlg.Close() })

    & $renderBrowsers
    [void]$dlg.ShowDialog()
    return $brState.Changed
}
