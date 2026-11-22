# Zapret2 Kotek — WinDivert Interface Selector (utils/gui_nlm_dialog.ps1)

function Show-Z2NlmDialog([string]$Root, $OwnerWin, [string]$AccentHex = '#7BC4A4') {
    $nlmHelperPath = Join-Path $Root 'utils\nlm_helper.ps1'
    if (Test-Path -LiteralPath $nlmHelperPath) {
        try { . $nlmHelperPath -Root $Root } catch {}
    }

    $accent    = if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $AccentHex } else { '#7BC4A4' }
    $flagFile  = Join-Path $Root 'utils\vpn_ifidx.enabled'
    $custFile  = Join-Path $Root 'utils\vpn_ifidx.custom'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $allAds = if (Get-Command Get-Z2NetAdaptersInfo -ErrorAction SilentlyContinue) { @(Get-Z2NetAdaptersInfo) } else { @() }

    $customSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $hasCustom = (Test-Path -LiteralPath $custFile)
    if ($hasCustom) {
        foreach ($l in (Get-Content -LiteralPath $custFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = $l.Trim()
            if ($t -and -not $t.StartsWith('#')) { [void]$customSet.Add($t) }
        }
    }

    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Сетевые интерфейсы (WinDivert) — Zapret2 Kotek"
        Width="580" Height="480" MinWidth="480" MinHeight="380"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="NlmPrimaryBtn" TargetType="Button">
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
        <Style x:Key="NlmSecBtn" TargetType="Button">
            <Setter Property="Background" Value="#202228"/>
            <Setter Property="Foreground" Value="#D4D7DD"/>
            <Setter Property="BorderBrush" Value="#2E323B"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,7"/>
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
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="На каких интерфейсах работает обход Zapret2?" FontSize="15" FontWeight="SemiBold" Foreground="#F1F3F5"/>
            <TextBlock Text="Отмеченные галочкой адаптеры (Ethernet, Wi-Fi, PPPoE, ExitLag) идут через обход. Снятые (WARP, Happ, WireGuard, Radmin и т.д.) полностью исключаются на уровне пакетов — основной интернет работает 24/7 без пауз." FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <Border Grid.Row="1" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="8">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="PnlNlmItems"/>
            </ScrollViewer>
        </Border>
        <Grid Grid.Row="2" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnNlmAutoSelect" Grid.Column="0" Content="Авто (физ. карты + PPPoE)" Style="{StaticResource NlmSecBtn}" FontSize="12"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button x:Name="BtnNlmCancel" Content="Отмена" Style="{StaticResource NlmSecBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnNlmSave" Content="Применить" Style="{StaticResource NlmPrimaryBtn}"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

    $dlgXaml = $dlgXaml.Replace('__ACCENT__', $accent)
    [xml]$dx = $dlgXaml
    $dr = New-Object System.Xml.XmlNodeReader $dx
    $dlg = $null
    try { $dlg = [Windows.Markup.XamlReader]::Load($dr) } finally { $dr.Close() }
    if ($null -ne $OwnerWin) { try { $dlg.Owner = $OwnerWin; if ($null -ne $OwnerWin.Icon) { $dlg.Icon = $OwnerWin.Icon } } catch {} }

    $PnlItems   = $dlg.FindName('PnlNlmItems')
    $BtnAuto    = $dlg.FindName('BtnNlmAutoSelect')
    $BtnCancel  = $dlg.FindName('BtnNlmCancel')
    $BtnSave    = $dlg.FindName('BtnNlmSave')
    $bc         = New-Object System.Windows.Media.BrushConverter
    $state      = @{ Saved = $false }
    $rowChecks  = New-Object System.Collections.Generic.List[object]

    foreach ($ad in $allAds) {
        $isChecked = if ($hasCustom) {
            ($ad.Guid -and $customSet.Contains($ad.Guid)) -or ($ad.Name -and $customSet.Contains($ad.Name))
        } else {
            [bool]$ad.DefaultAllow
        }
        $cb = New-Object System.Windows.Controls.CheckBox
        $stTxt = if ($ad.Status -eq 'Up') { 'Активен' } else { 'Отключён' }
        $cb.Content = "$($ad.Name)  [$($ad.KindLabel) · $stTxt · ifIdx=$($ad.IfIndex)]`n$($ad.Desc)"
        $cb.IsChecked = $isChecked
        $cb.Foreground = if ($ad.DefaultAllow) { $bc.ConvertFromString('#E5E7EB') } else { $bc.ConvertFromString('#9CA3AF') }
        $cb.FontSize = 12.5
        $cb.Margin = New-Object System.Windows.Thickness(6, 5, 6, 5)
        $cb.Tag = $ad
        [void]$PnlItems.Children.Add($cb)
        $rowChecks.Add($cb)
    }

    $BtnAuto.Add_Click({
        foreach ($cb in $rowChecks) {
            $cb.IsChecked = [bool]$cb.Tag.DefaultAllow
        }
    })

    $BtnCancel.Add_Click({ $dlg.Close() })

    $BtnSave.Add_Click({
        $picked = New-Object System.Collections.Generic.List[string]
        $matchesDefault = $true
        foreach ($cb in $rowChecks) {
            $a = $cb.Tag
            $chk = [bool]$cb.IsChecked
            if ($chk -ne [bool]$a.DefaultAllow) { $matchesDefault = $false }
            if ($chk) {
                $key = if ($a.Guid) { $a.Guid } else { $a.Name }
                if ($key) { $picked.Add($key) }
            }
        }
        if ($picked.Count -eq 0) {
            if (Get-Command Clear-Z2VpnIfIdxFilter -ErrorAction SilentlyContinue) { Clear-Z2VpnIfIdxFilter $Root }
        } else {
            foreach ($lf in @('utils\nlm_auto.enabled', 'utils\nlm_filter.enabled', 'utils\nlm_filter.names')) {
                $lfp = Join-Path $Root $lf
                if (Test-Path -LiteralPath $lfp) { Remove-Item -LiteralPath $lfp -Force -ErrorAction SilentlyContinue }
            }
            [System.IO.File]::WriteAllText($flagFile, "1`r`n", $utf8NoBom)
            if ($matchesDefault) {
                if (Test-Path -LiteralPath $custFile) { Remove-Item -LiteralPath $custFile -Force -ErrorAction SilentlyContinue }
            } else {
                [System.IO.File]::WriteAllLines($custFile, $picked.ToArray(), $utf8NoBom)
            }
            if (Get-Command Update-Z2VpnIfIdxFilter -ErrorAction SilentlyContinue) {
                [void](Update-Z2VpnIfIdxFilter $Root)
            }
        }
        $state.Saved = $true
        $dlg.Close()
    })

    [void]$dlg.ShowDialog()
    return [bool]$state.Saved
}
