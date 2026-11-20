# Zapret2 Kotek — Per-VPN NLM Exclusion Selector (utils/gui_nlm_dialog.ps1)

function Get-Z2NlmNetworks([string]$Root) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $winwsExe = Join-Path $Root 'bin\winws2.exe'
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $winwsExe)) { return $list }
    $vpnRx = 'WARP|Cloudflare|WireGuard|Amnezia|OpenVPN|TAP|TUN|Wintun|Sing-box|Hiddify|Nekoray|v2ray|Outline|Radmin|Hamachi|ZeroTier|Tailscale|Proton|Nord|Mullvad|Cisco|Fortinet|VPN'
    $rawOut = & $winwsExe '--nlm-list=all' 2>$null
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $curName = ''
    foreach ($line in $rawOut) {
        if ($line -match '^Name\s*:\s*(.+)$') {
            $curName = $matches[1].Trim()
        } elseif ($line -match '^NetID\s*:\s*(\{?[0-9A-Fa-f\-]+\}?)' -and $curName) {
            $gid = $matches[1].Trim()
            if ($seen.Add($gid)) {
                $isVpn = ($curName -match $vpnRx)
                $list.Add([PSCustomObject]@{
                    Name  = $curName
                    NetId = $gid
                    IsVpn = $isVpn
                })
            }
            $curName = ''
        }
    }
    return $list
}

function Show-Z2NlmDialog([string]$Root, $OwnerWin, [string]$AccentHex = '#9FC7B8') {
    $nlmFile   = Join-Path $Root 'utils\nlm_filter.enabled'
    $namesFile = Join-Path $Root 'utils\nlm_filter.names'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $excludedSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $nlmFile) {
        $raw = (Get-Content -LiteralPath $nlmFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($raw -and $raw.Trim() -match '^(?i)(?:NEG:|!)(.+)$') {
            foreach ($g in ($matches[1] -split ',')) {
                $gt = $g.Trim()
                if ($gt) { [void]$excludedSet.Add($gt) }
            }
        }
    }

    $allNets = Get-Z2NlmNetworks $Root

    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Исключения VPN (NLM) — Zapret2 Kotek"
        Width="540" Height="470" MinWidth="460" MinHeight="380"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="NlmPrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#9FC7B8"/>
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
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#B4D6C9"/></Trigger>
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
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="Какие VPN исключить из обхода Zapret2?" FontSize="15" FontWeight="SemiBold" Foreground="#F1F3F5"/>
            <TextBlock Text="Отметь галочкой VPN, которым Zapret не должен мешать. Сними галочку (например, с ExitLag), если хочешь гнать этот адаптер через обход." FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <CheckBox x:Name="ChkShowAllNets" Grid.Row="1" Content="Показать все сети Windows (не только VPN)" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,10" Cursor="Hand"/>
        <Border Grid.Row="2" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="8">
            <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="PnlNlmItems"/>
                </ScrollViewer>
                <TextBlock x:Name="TxtNlmEmpty" Text="VPN-адаптеры в Windows не найдены.&#10;Включи «Показать все сети» выше, если твой VPN называется нестандартно." Foreground="#737A86" FontSize="12.5" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" TextWrapping="Wrap"/>
            </Grid>
        </Border>
        <Grid Grid.Row="3" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnNlmAutoSelect" Grid.Column="0" Content="Отметить все VPN" Style="{StaticResource NlmSecBtn}" FontSize="12"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button x:Name="BtnNlmCancel" Content="Отмена" Style="{StaticResource NlmSecBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnNlmSave" Content="Применить" Style="{StaticResource NlmPrimaryBtn}"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

    if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $dlgXaml = $dlgXaml.Replace('#9FC7B8', $AccentHex) }
    [xml]$dx = $dlgXaml
    $dr = New-Object System.Xml.XmlNodeReader $dx
    $dlg = [Windows.Markup.XamlReader]::Load($dr)
    if ($null -ne $OwnerWin) { $dlg.Owner = $OwnerWin; if ($null -ne $OwnerWin.Icon) { $dlg.Icon = $OwnerWin.Icon } }
    $dlg.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($dlg)).Handle
            $dark = 1
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) | Out-Null
            $capColor = 0x00141611
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$capColor, 4) | Out-Null
        } catch {}
    })

    $ChkShowAllNets   = $dlg.FindName('ChkShowAllNets')
    $PnlNlmItems      = $dlg.FindName('PnlNlmItems')
    $TxtNlmEmpty      = $dlg.FindName('TxtNlmEmpty')
    $BtnNlmAutoSelect = $dlg.FindName('BtnNlmAutoSelect')
    $BtnNlmCancel     = $dlg.FindName('BtnNlmCancel')
    $BtnNlmSave       = $dlg.FindName('BtnNlmSave')

    $bc = New-Object System.Windows.Media.BrushConverter
    $checkMap = @{}
    foreach ($n in $allNets) {
        $checkMap[$n.NetId] = $excludedSet.Contains($n.NetId)
    }

    $renderList = {
        $PnlNlmItems.Children.Clear()
        $showAll = [bool]$ChkShowAllNets.IsChecked
        $visible = 0
        foreach ($n in $allNets) {
            if (-not $showAll -and -not $n.IsVpn -and -not $checkMap[$n.NetId]) { continue }
            $visible++
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = [bool]$checkMap[$n.NetId]
            $cb.Tag = $n.NetId
            $cb.Margin = New-Object System.Windows.Thickness(4, 5, 4, 5)
            $cb.Cursor = [System.Windows.Input.Cursors]::Hand
            $sp = New-Object System.Windows.Controls.StackPanel
            $tb1 = New-Object System.Windows.Controls.TextBlock
            $tb1.Text = if ($n.IsVpn) { "$($n.Name)  [VPN]" } else { $n.Name }
            $tb1.FontSize = 13
            $tb1.Foreground = $bc.ConvertFromString('#F1F3F5')
            $tb2 = New-Object System.Windows.Controls.TextBlock
            $tb2.Text = $n.NetId
            $tb2.FontSize = 11
            $tb2.Foreground = $bc.ConvertFromString('#737A86')
            [void]$sp.Children.Add($tb1)
            [void]$sp.Children.Add($tb2)
            $cb.Content = $sp
            $cb.Add_Click({
                param($s, $e)
                $checkMap[[string]$s.Tag] = [bool]$s.IsChecked
            })
            [void]$PnlNlmItems.Children.Add($cb)
        }
        $TxtNlmEmpty.Visibility = if ($visible -eq 0) { 'Visible' } else { 'Collapsed' }
    }

    $ChkShowAllNets.Add_Click({ & $renderList })
    $BtnNlmAutoSelect.Add_Click({
        foreach ($n in $allNets) {
            if ($n.IsVpn) { $checkMap[$n.NetId] = $true }
        }
        & $renderList
    })

    $script:NlmDialogSaved = $false
    $BtnNlmCancel.Add_Click({ $dlg.Close() })
    $BtnNlmSave.Add_Click({
        $selGuids = New-Object System.Collections.Generic.List[string]
        $selNames = New-Object System.Collections.Generic.List[string]
        foreach ($n in $allNets) {
            if ($checkMap[$n.NetId]) {
                $selGuids.Add($n.NetId)
                $selNames.Add($n.Name)
            }
        }
        if ($selGuids.Count -gt 0) {
            [System.IO.File]::WriteAllText($nlmFile, ('NEG:' + ($selGuids -join ',')), $utf8NoBom)
            [System.IO.File]::WriteAllText($namesFile, ($selNames -join ', '), $utf8NoBom)
        } else {
            if (Test-Path -LiteralPath $nlmFile)   { Remove-Item -LiteralPath $nlmFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $namesFile) { Remove-Item -LiteralPath $namesFile -Force -ErrorAction SilentlyContinue }
        }
        $script:NlmDialogSaved = $true
        $dlg.Close()
    })

    & $renderList
    [void]$dlg.ShowDialog()
    return $script:NlmDialogSaved
}
