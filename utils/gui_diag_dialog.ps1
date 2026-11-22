# Zapret2 Kotek — Built-in Modal Diagnostics Viewer (utils/gui_diag_dialog.ps1)

function Show-Z2DiagDialog([string]$Root, $OwnerWin, [string]$AccentHex = '#7BC4A4') {
    if (-not (Get-Command Show-Z2MessageDialog -ErrorAction SilentlyContinue)) {
        $msgDlgPath = Join-Path $Root 'utils\gui_msg_dialog.ps1'
        if (Test-Path -LiteralPath $msgDlgPath) { . $msgDlgPath }
    }

    $accent   = if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $AccentHex } else { '#7BC4A4' }
    $jsonPath = Join-Path $Root 'utils\diag_report.json'
    $txtPath  = Join-Path $Root 'utils\diag_report.txt'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return $false }

    $data = $null
    try {
        $data = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $false }
    if ($null -eq $data) { return $false }

    $dlgXamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Диагностика — Zapret2 Kotek"
        Width="660" Height="560" MinWidth="540" MinHeight="440"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="DiagPrimaryBtn" TargetType="Button">
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
        <Style x:Key="DiagSecBtn" TargetType="Button">
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
    </Window.Resources>

    <Grid Margin="18,16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Summary banner -->
        <Border x:Name="BdDiagBanner" Grid.Row="0" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock x:Name="TxtDiagSummary" Text="Диагностика завершена" FontSize="14.5" FontWeight="SemiBold" Foreground="#F1F3F5"/>
                    <TextBlock x:Name="TxtDiagSub" Text="" FontSize="12" Foreground="#9CA3AF" Margin="0,3,0,0"/>
                </StackPanel>
                <TextBlock x:Name="TxtDiagCounts" Grid.Column="1" Text="" FontSize="12" Foreground="#9CA3AF" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Checks list -->
        <Border Grid.Row="1" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="6">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="PnlDiagItems" Margin="4"/>
            </ScrollViewer>
        </Border>

        <!-- Quick symptom tags -->
        <Border Grid.Row="2" Background="#17191F" BorderBrush="#282C34" BorderThickness="1" CornerRadius="6" Padding="10,7" Margin="0,8,0,0">
            <StackPanel>
                <TextBlock Text="Что именно не работает? (отметь перед отправкой, по желанию)" FontSize="11.5" Foreground="#9CA3AF" Margin="0,0,0,5"/>
                <WrapPanel Orientation="Horizontal">
                    <CheckBox x:Name="ChkSymYtDown" Content="YouTube не грузит" Foreground="#D4D7DD" FontSize="12" Margin="0,0,12,3"/>
                    <CheckBox x:Name="ChkSymYtSlow" Content="YouTube тормозит / качество" Foreground="#D4D7DD" FontSize="12" Margin="0,0,12,3"/>
                    <CheckBox x:Name="ChkSymDcVoice" Content="Discord голос / стрим" Foreground="#D4D7DD" FontSize="12" Margin="0,0,12,3"/>
                    <CheckBox x:Name="ChkSymTg" Content="Telegram" Foreground="#D4D7DD" FontSize="12" Margin="0,0,12,3"/>
                    <CheckBox x:Name="ChkSymFlaky" Content="То работает, то нет" Foreground="#D4D7DD" FontSize="12" Margin="0,0,12,3"/>
                    <CheckBox x:Name="ChkSymOther" Content="Другое" Foreground="#D4D7DD" FontSize="12" Margin="0,0,0,3"/>
                </WrapPanel>
            </StackPanel>
        </Border>

        <!-- Hint -->
        <TextBlock x:Name="TxtDiagHint" Grid.Row="3" Text="Отчёт уже скопирован в буфер обмена — при необходимости вставь его в Telegram (Ctrl+V)." FontSize="11.5" Foreground="#9CA3AF" Margin="2,6,2,8" TextWrapping="Wrap"/>

        <!-- Footer -->
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnDiagCopy" Content="Скопировать отчёт" Style="{StaticResource DiagPrimaryBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnDiagSend" Content="Отправить разработчику" Style="{StaticResource DiagSecBtn}" Margin="0,0,8,0" ToolTip="Отправить обезличенный отчёт напрямую разработчику (или открыть GitHub Issue)"/>
                <Button x:Name="BtnDiagOpenTxt" Content="Открыть .txt" Style="{StaticResource DiagSecBtn}"/>
            </StackPanel>
            <Button x:Name="BtnDiagClose" Grid.Column="2" Content="Закрыть" Style="{StaticResource DiagSecBtn}"/>
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

    $BdDiagBanner   = $dlg.FindName('BdDiagBanner')
    $TxtDiagSummary = $dlg.FindName('TxtDiagSummary')
    $TxtDiagSub     = $dlg.FindName('TxtDiagSub')
    $TxtDiagCounts  = $dlg.FindName('TxtDiagCounts')
    $PnlDiagItems   = $dlg.FindName('PnlDiagItems')
    $TxtDiagHint    = $dlg.FindName('TxtDiagHint')
    $BtnDiagCopy    = $dlg.FindName('BtnDiagCopy')
    $BtnDiagSend    = $dlg.FindName('BtnDiagSend')
    $symChecks = @(
        @{ Ctrl = $dlg.FindName('ChkSymYtDown');  Tag = 'yt_down' },
        @{ Ctrl = $dlg.FindName('ChkSymYtSlow');  Tag = 'yt_slow' },
        @{ Ctrl = $dlg.FindName('ChkSymDcVoice'); Tag = 'dc_voice' },
        @{ Ctrl = $dlg.FindName('ChkSymTg');      Tag = 'telegram' },
        @{ Ctrl = $dlg.FindName('ChkSymFlaky');   Tag = 'flaky' },
        @{ Ctrl = $dlg.FindName('ChkSymOther');   Tag = 'other' }
    )
    $getSymptomPrefix = {
        $tags = New-Object System.Collections.Generic.List[string]
        foreach ($sc in $symChecks) {
            if ($null -ne $sc.Ctrl -and $sc.Ctrl.IsChecked) { $tags.Add($sc.Tag) }
        }
        if ($tags.Count -gt 0) { return ("Symptom   : " + ($tags -join ', ') + "`r`n") }
        return ''
    }
    $BtnDiagOpenTxt = $dlg.FindName('BtnDiagOpenTxt')
    $BtnDiagClose   = $dlg.FindName('BtnDiagClose')

    $bc = New-Object System.Windows.Media.BrushConverter
    $okN   = [int]$data.ok
    $warnN = [int]$data.warn
    $failN = [int]$data.fail

    if ($failN -gt 0) {
        $TxtDiagSummary.Text = "Найдены проблемы ($failN)"
        $TxtDiagSummary.Foreground = $bc.ConvertFromString('#D97777')
        $BdDiagBanner.BorderBrush  = $bc.ConvertFromString('#5A2E2E')
        $TxtDiagSub.Text = 'Ниже указано, что именно сломано и как это исправить.'
    } elseif ($warnN -gt 0) {
        $TxtDiagSummary.Text = "Всё работает, но есть предупреждения ($warnN)"
        $TxtDiagSummary.Foreground = $bc.ConvertFromString('#D9B066')
        $BdDiagBanner.BorderBrush  = $bc.ConvertFromString('#5A4A28')
        $TxtDiagSub.Text = 'Критичных ошибок нет — обрати внимание на жёлтые пункты, если что-то работает нестабильно.'
    } else {
        $TxtDiagSummary.Text = 'Всё работает штатно'
        $TxtDiagSummary.Foreground = $bc.ConvertFromString($accent)
        $BdDiagBanner.BorderBrush  = $bc.ConvertFromString('#2B4E40')
        $TxtDiagSub.Text = 'Все проверки пройдены без замечаний.'
    }
    $TxtDiagCounts.Text = "OK: $okN  ·  WARN: $warnN  ·  FAIL: $failN"

    foreach ($chk in @($data.checks)) {
        $st = [string]$chk.status
        $badgeBg = '#20382E'; $badgeFg = $accent; $badgeTxt = 'OK'
        if ($st -eq 'WARN') { $badgeBg = '#3B311D'; $badgeFg = '#D9B066'; $badgeTxt = 'WARN' }
        elseif ($st -eq 'FAIL') { $badgeBg = '#3D2224'; $badgeFg = '#D97777'; $badgeTxt = 'FAIL' }
        elseif ($st -eq 'INFO') { $badgeBg = '#1D2C3A'; $badgeFg = '#7FB3D5'; $badgeTxt = 'INFO' }

        $card = New-Object System.Windows.Controls.Border
        $card.Background = $bc.ConvertFromString('#14161B')
        $card.BorderBrush = $bc.ConvertFromString('#262A33')
        $card.BorderThickness = New-Object System.Windows.Thickness(1)
        $card.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $card.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)

        $sp = New-Object System.Windows.Controls.StackPanel

        $hdrGrid = New-Object System.Windows.Controls.Grid
        $col0 = New-Object System.Windows.Controls.ColumnDefinition; $col0.Width = [System.Windows.GridLength]::Auto
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$hdrGrid.ColumnDefinitions.Add($col0)
        [void]$hdrGrid.ColumnDefinitions.Add($col1)

        $badge = New-Object System.Windows.Controls.Border
        $badge.Background = $bc.ConvertFromString($badgeBg)
        $badge.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $badge.Padding = New-Object System.Windows.Thickness(7, 2, 7, 2)
        $badge.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $tbBadge = New-Object System.Windows.Controls.TextBlock
        $tbBadge.Text = $badgeTxt
        $tbBadge.FontSize = 11
        $tbBadge.FontWeight = [System.Windows.FontWeights]::Bold
        $tbBadge.Foreground = $bc.ConvertFromString($badgeFg)
        $badge.Child = $tbBadge
        [System.Windows.Controls.Grid]::SetColumn($badge, 0)
        [void]$hdrGrid.Children.Add($badge)

        $tbTitle = New-Object System.Windows.Controls.TextBlock
        $tbTitle.Text = [string]$chk.title
        $tbTitle.FontSize = 13
        $tbTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tbTitle.Foreground = $bc.ConvertFromString('#F1F3F5')
        $tbTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $tbTitle.TextWrapping = [System.Windows.TextWrapping]::Wrap
        [System.Windows.Controls.Grid]::SetColumn($tbTitle, 1)
        [void]$hdrGrid.Children.Add($tbTitle)

        [void]$sp.Children.Add($hdrGrid)

        if (-not [string]::IsNullOrWhiteSpace([string]$chk.detail)) {
            $tbDet = New-Object System.Windows.Controls.TextBlock
            $tbDet.Text = [string]$chk.detail
            $tbDet.FontSize = 12
            $tbDet.Foreground = $bc.ConvertFromString('#B5BAC4')
            $tbDet.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
            $tbDet.TextWrapping = [System.Windows.TextWrapping]::Wrap
            [void]$sp.Children.Add($tbDet)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$chk.fix)) {
            $fixBd = New-Object System.Windows.Controls.Border
            $fixBd.Background = $bc.ConvertFromString('#1C2028')
            $fixBd.CornerRadius = New-Object System.Windows.CornerRadius(4)
            $fixBd.Padding = New-Object System.Windows.Thickness(8, 5, 8, 5)
            $fixBd.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
            $tbFix = New-Object System.Windows.Controls.TextBlock
            $tbFix.Text = "Что сделать: $([string]$chk.fix)"
            $tbFix.FontSize = 11.8
            $tbFix.Foreground = $bc.ConvertFromString($badgeFg)
            $tbFix.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $fixBd.Child = $tbFix
            [void]$sp.Children.Add($fixBd)
        }

        $card.Child = $sp
        [void]$PnlDiagItems.Children.Add($card)
    }

    $BtnDiagCopy.Add_Click({
        if (Test-Path -LiteralPath $txtPath) {
            try {
                $rawRep = Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8
                Set-Clipboard -Value $rawRep
                $TxtDiagHint.Text = 'Отчёт скопирован в буфер обмена (Ctrl+V в Telegram).'
                $TxtDiagHint.Foreground = $bc.ConvertFromString($accent)
            } catch {
                $TxtDiagHint.Text = 'Не удалось скопировать в буфер — открой .txt вручную.'
                $TxtDiagHint.Foreground = $bc.ConvertFromString('#D9B066')
            }
        }
    })
    if ($null -ne $BtnDiagSend) {
        $BtnDiagSend.Add_Click({
            if (-not (Test-Path -LiteralPath $txtPath)) { return }
            $rawRep = Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($rawRep)) { return }
            $symPfx = & $getSymptomPrefix
            if ($symPfx) { $rawRep = $symPfx + $rawRep }
            $telPath = Join-Path $Root 'utils\telemetry_helper.ps1'
            if ((Test-Path -LiteralPath $telPath) -and -not (Get-Command Send-Z2TelemetryEvent -ErrorAction SilentlyContinue)) {
                try { . $telPath } catch {}
            }
            $ep = if (Get-Command Get-Z2TelemetryEndpoint -ErrorAction SilentlyContinue) { Get-Z2TelemetryEndpoint $Root } else { '' }
            if ($ep) {
                $BtnDiagSend.IsEnabled = $false
                $sent = $false
                try {
                    $sent = [bool](Send-Z2TelemetryEvent -RootPath $Root -Event 'diag' -Score "OK:$okN WARN:$warnN FAIL:$failN" -Detail $rawRep -ManualDiag)
                } catch {}
                $BtnDiagSend.IsEnabled = $true
                if ($sent) {
                    $TxtDiagHint.Text = 'Обезличенный отчёт отправлен разработчику — спасибо!'
                    $TxtDiagHint.Foreground = $bc.ConvertFromString($accent)
                    return
                }
            }
            # Fallback: copy to clipboard & open GitHub Issues
            try { Set-Clipboard -Value $rawRep } catch {}
            $repo = 'vanch150/zapret2-kotek'
            $rc = Join-Path $Root 'utils\repo.conf'
            if (Test-Path -LiteralPath $rc) {
                foreach ($rl in (Get-Content -LiteralPath $rc -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                    if ($rl -match '^\s*repo\s*=\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*$') { $repo = $matches[1]; break }
                }
            }
            try { Start-Process "https://github.com/$repo/issues/new?title=Diag+Report" } catch {}
            $TxtDiagHint.Text = 'Отчёт скопирован в буфер — вставь его (Ctrl+V) в открытую форму GitHub.'
            $TxtDiagHint.Foreground = $bc.ConvertFromString('#D9B066')
        })
    }
    $BtnDiagOpenTxt.Add_Click({
        if (Test-Path -LiteralPath $txtPath) {
            try {
                Start-Process notepad.exe -ArgumentList "`"$txtPath`""
            } catch {
                if (Get-Command Show-Z2MessageDialog -ErrorAction SilentlyContinue) {
                    [void](Show-Z2MessageDialog -Owner $dlg -Title 'Ошибка' -Message "Не удалось открыть файл отчёта:`n$($_.Exception.Message)" -Kind Error -Buttons OK -AccentHex $accent)
                }
            }
        }
    })
    $BtnDiagClose.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog()
    return $true
}
