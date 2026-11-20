# Zapret2 Kotek — Built-in Modal Domain Lists Editor (utils/gui_lists_dialog.ps1)

function Normalize-Z2Domain([string]$RawInput) {
    if ([string]::IsNullOrWhiteSpace($RawInput)) { return '' }
    $s = $RawInput.Trim().ToLowerInvariant()
    $neg = ''
    if ($s.StartsWith('!')) {
        $neg = '!'
        $s = $s.Substring(1).Trim()
    }
    $s = $s -replace '^[a-z][a-z0-9+\-.]*://', ''
    $s = $s -replace '^//+', ''
    $s = ($s -split '[/?#]')[0]
    $s = ($s -split ':')[0]
    $s = $s.Trim().Trim('.')
    if ($s -match '^www\.[^.]+\..+') { $s = $s.Substring(4) }
    if ($s -match '[^\x00-\x7F]') { try { $s = (New-Object System.Globalization.IdnMapping).GetAscii($s) } catch {} }
    if ($s -notmatch '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$') {
        return ''
    }
    return ($neg + $s)
}

function Show-Z2ListsDialog([string]$Root, $OwnerWin, [string]$InitialTab = 'general', [string]$AccentHex = '#9FC7B8') {
    $genPath = Join-Path $Root 'lists\list-general-user.txt'
    $exPath  = Join-Path $Root 'lists\list-exclude-user.txt'
    $autoPath = Join-Path $Root 'lists\list-auto.txt'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if (-not (Test-Path -LiteralPath $genPath)) { [System.IO.File]::WriteAllText($genPath, "# Свои домены для обхода (по одному в строке)`r`n", $utf8NoBom) }
    if (-not (Test-Path -LiteralPath $exPath))  { [System.IO.File]::WriteAllText($exPath,  "# Исключения (по одному домену в строке)`r`n", $utf8NoBom) }
    if (-not (Test-Path -LiteralPath $autoPath)) { [System.IO.File]::WriteAllText($autoPath, '', $utf8NoBom) }

    $dlgXamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Списки сайтов и исключений — Zapret2 Kotek"
        Width="590" Height="520" MinWidth="500" MinHeight="420"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="DlgTabActive" TargetType="Button">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="Foreground" Value="#F1F3F5"/>
            <Setter Property="BorderBrush" Value="#7BC4A4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgTabInactive" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#9CA3AF"/>
            <Setter Property="BorderBrush" Value="#282C34"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgPrimaryBtn" TargetType="Button">
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
        <Style x:Key="DlgSecBtn" TargetType="Button">
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
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Tabs -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="BtnDlgTabGen" Content="Обходить (0)" Style="{StaticResource DlgTabActive}" Margin="0,0,8,0"/>
            <Button x:Name="BtnDlgTabEx"  Content="Исключения (0)" Style="{StaticResource DlgTabInactive}" Margin="0,0,8,0"/>
            <Button x:Name="BtnDlgTabAuto" Content="Авто-найденные (0)" Style="{StaticResource DlgTabInactive}"/>
        </StackPanel>

        <!-- Input Bar -->
        <Grid x:Name="PnlDlgInput" Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#1A1C21" BorderBrush="#2E323B" BorderThickness="1" CornerRadius="6" Padding="10,0" Margin="0,0,8,0">
                <Grid>
                    <TextBox x:Name="TxtDlgDomain" Background="Transparent" Foreground="#F1F3F5" CaretBrush="#7BC4A4" BorderThickness="0" FontSize="13" VerticalContentAlignment="Center" Height="34"/>
                    <TextBlock x:Name="TxtDlgPlaceholder" Text="Вставь ссылку или домен (например: https://www.site.com/page)" Foreground="#737A86" FontSize="12" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <Button x:Name="BtnDlgAdd" Grid.Column="1" Content="+ Добавить" Style="{StaticResource DlgPrimaryBtn}" Height="36"/>
        </Grid>

        <!-- Domain List -->
        <Border Grid.Row="2" Background="#1A1C21" BorderBrush="#282C34" BorderThickness="1" CornerRadius="8" Padding="6">
            <Grid>
                <ListBox x:Name="LstDlgDomains" Background="Transparent" BorderThickness="0" Foreground="#D4D7DD" ScrollViewer.HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Stretch">
                    <ListBox.ItemContainerStyle>
                        <Style TargetType="ListBoxItem">
                            <Setter Property="Padding" Value="0"/>
                            <Setter Property="Margin" Value="0,1"/>
                            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="ListBoxItem">
                                        <Border x:Name="rowBd" Background="Transparent" CornerRadius="6" Padding="10,6">
                                            <ContentPresenter/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="rowBd" Property="Background" Value="#222C28"/></Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </ListBox.ItemContainerStyle>
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="{Binding}" FontSize="13" Foreground="#D4D7DD" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                                <Button Grid.Column="1" Content="×" Tag="{Binding}" Width="24" Height="24" Background="Transparent" BorderThickness="0" Foreground="#9CA3AF" FontSize="15" FontWeight="Bold" Cursor="Hand" ToolTip="Удалить из списка"/>
                            </Grid>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                </ListBox>
                <TextBlock x:Name="TxtDlgEmpty" Text="Список пока пуст — добавь первый сайт выше" Foreground="#737A86" FontSize="12.5" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" IsHitTestVisible="False"/>
            </Grid>
        </Border>

        <!-- Feedback line -->
        <TextBlock x:Name="TxtDlgHint" Grid.Row="3" Text="" FontSize="12" Foreground="#9CA3AF" Margin="2,8,2,8" TextWrapping="Wrap"/>

        <!-- Footer -->
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnDlgOpenTxt" Content="Открыть .txt" Style="{StaticResource DlgSecBtn}" Foreground="#9CA3AF" Padding="10,6" FontSize="11.5" ToolTip="Открыть файл напрямую в Блокноте"/>
                <Button x:Name="BtnDlgClearAuto" Content="Очистить авто" Style="{StaticResource DlgSecBtn}" Foreground="#D97777" Padding="10,6" FontSize="11.5" Margin="8,0,0,0" Visibility="Collapsed" ToolTip="Очистить все автоматически найденные домены в list-auto.txt"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
                <Button x:Name="BtnDlgClose" Content="Закрыть" Style="{StaticResource DlgSecBtn}" Margin="0,0,8,0"/>
                <Button x:Name="BtnDlgApply" Content="Применить" Style="{StaticResource DlgPrimaryBtn}"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

    if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $dlgXamlStr = $dlgXamlStr.Replace('#9FC7B8', $AccentHex) }
    [xml]$dx = $dlgXamlStr
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

    $BtnDlgTabGen      = $dlg.FindName('BtnDlgTabGen')
    $BtnDlgTabEx       = $dlg.FindName('BtnDlgTabEx')
    $BtnDlgTabAuto     = $dlg.FindName('BtnDlgTabAuto')
    $PnlDlgInput       = $dlg.FindName('PnlDlgInput')
    $BtnDlgClearAuto   = $dlg.FindName('BtnDlgClearAuto')
    $TxtDlgDomain      = $dlg.FindName('TxtDlgDomain')
    $TxtDlgPlaceholder = $dlg.FindName('TxtDlgPlaceholder')
    $BtnDlgAdd         = $dlg.FindName('BtnDlgAdd')
    $LstDlgDomains     = $dlg.FindName('LstDlgDomains')
    $TxtDlgEmpty       = $dlg.FindName('TxtDlgEmpty')
    $TxtDlgHint        = $dlg.FindName('TxtDlgHint')
    $BtnDlgOpenTxt     = $dlg.FindName('BtnDlgOpenTxt')
    $BtnDlgClose       = $dlg.FindName('BtnDlgClose')
    $BtnDlgApply       = $dlg.FindName('BtnDlgApply')

    $state = [PSCustomObject]@{
        Tab     = if ($InitialTab -eq 'exclude') { 'exclude' } elseif ($InitialTab -eq 'auto') { 'auto' } else { 'general' }
        Changed = $false
        AutoChanged = $false
        Applied = $false
        GenList = New-Object System.Collections.Generic.List[string]
        ExList  = New-Object System.Collections.Generic.List[string]
        GenHdr  = New-Object System.Collections.Generic.List[string]
        ExHdr   = New-Object System.Collections.Generic.List[string]
        AutoList = New-Object System.Collections.Generic.List[string]
        AutoHdr  = New-Object System.Collections.Generic.List[string]
    }

    $loadFile = {
        param([string]$Path, $ListObj, $HdrObj)
        $ListObj.Clear(); $HdrObj.Clear()
        $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $Path) {
            foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if ($null -eq $line) { continue }
                $tr = $line.Trim()
                if ($tr.StartsWith('#')) { $HdrObj.Add($tr); continue }
                if (-not $tr) { continue }
                if ($seen.Add($tr)) { $ListObj.Add($tr) }
            }
        }
    }
    & $loadFile $genPath $state.GenList $state.GenHdr
    & $loadFile $exPath  $state.ExList  $state.ExHdr
    & $loadFile $autoPath $state.AutoList $state.AutoHdr

    $bc = New-Object System.Windows.Media.BrushConverter
    $renderTab = {
        $BtnDlgTabGen.Content  = "Обходить ($($state.GenList.Count))"
        $BtnDlgTabEx.Content   = "Исключения ($($state.ExList.Count))"
        $BtnDlgTabAuto.Content = "Авто-найденные ($($state.AutoList.Count))"
        $BtnDlgTabGen.Style  = if ($state.Tab -eq 'general') { $dlg.Resources['DlgTabActive'] } else { $dlg.Resources['DlgTabInactive'] }
        $BtnDlgTabEx.Style   = if ($state.Tab -eq 'exclude') { $dlg.Resources['DlgTabActive'] } else { $dlg.Resources['DlgTabInactive'] }
        $BtnDlgTabAuto.Style = if ($state.Tab -eq 'auto')    { $dlg.Resources['DlgTabActive'] } else { $dlg.Resources['DlgTabInactive'] }
        if ($state.Tab -eq 'general') {
            $cur = $state.GenList
            $PnlDlgInput.Visibility = 'Visible'
            $BtnDlgClearAuto.Visibility = 'Collapsed'
            $TxtDlgEmpty.Text = 'Список пока пуст — добавь первый сайт выше'
        } elseif ($state.Tab -eq 'exclude') {
            $cur = $state.ExList
            $PnlDlgInput.Visibility = 'Visible'
            $BtnDlgClearAuto.Visibility = 'Collapsed'
            $TxtDlgEmpty.Text = 'Исключений пока нет — добавь сайт, который обход не должен трогать'
        } else {
            $cur = $state.AutoList
            $PnlDlgInput.Visibility = 'Collapsed'
            $BtnDlgClearAuto.Visibility = if ($cur.Count -gt 0) { 'Visible' } else { 'Collapsed' }
            $TxtDlgEmpty.Text = 'Авто-список пока пуст — winws2 пополняет его сам при сбоях доступа'
        }
        $LstDlgDomains.Items.Clear()
        foreach ($d in $cur) { [void]$LstDlgDomains.Items.Add($d) }
        $TxtDlgEmpty.Visibility = if ($cur.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    }

    $saveBoth = {
        $gOut = New-Object System.Collections.Generic.List[string]
        if ($state.GenHdr.Count -gt 0) { foreach ($h in $state.GenHdr) { $gOut.Add($h) } } else { $gOut.Add('# Свои домены для обхода (по одному в строке)') }
        foreach ($d in $state.GenList) { $gOut.Add($d) }
        [System.IO.File]::WriteAllLines($genPath, $gOut, $utf8NoBom)

        $eOut = New-Object System.Collections.Generic.List[string]
        if ($state.ExHdr.Count -gt 0) { foreach ($h in $state.ExHdr) { $eOut.Add($h) } } else { $eOut.Add('# Исключения (по одному домену в строке)') }
        foreach ($d in $state.ExList) { $eOut.Add($d) }
        [System.IO.File]::WriteAllLines($exPath, $eOut, $utf8NoBom)

        if ($state.AutoChanged) {
            $aOut = New-Object System.Collections.Generic.List[string]
            foreach ($h in $state.AutoHdr) { $aOut.Add($h) }
            foreach ($d in $state.AutoList) { $aOut.Add($d) }
            [System.IO.File]::WriteAllLines($autoPath, $aOut, $utf8NoBom)
        }
    }

    $addDomainAction = {
        $norm = Normalize-Z2Domain $TxtDlgDomain.Text
        if (-not $norm) {
            $TxtDlgHint.Text = 'Введи корректный домен или ссылку, например: site.com или https://www.site.com/path'
            $TxtDlgHint.Foreground = $bc.ConvertFromString('#D9B066')
            return
        }
        $cur = if ($state.Tab -eq 'general') { $state.GenList } else { $state.ExList }
        $exists = $false
        foreach ($item in $cur) { if ($item -ieq $norm) { $exists = $true; break } }
        if ($exists) {
            $TxtDlgHint.Text = "Домен $norm уже есть в этом списке."
            $TxtDlgHint.Foreground = $bc.ConvertFromString('#D9B066')
            return
        }
        $cur.Add($norm)
        $state.Changed = $true
        $TxtDlgDomain.Text = ''
        $TxtDlgHint.Text = "Добавлен: $norm"
        $TxtDlgHint.Foreground = $bc.ConvertFromString('#7BC4A4')
        & $renderTab
    }

    $TxtDlgDomain.Add_TextChanged({
        $TxtDlgPlaceholder.Visibility = if ([string]::IsNullOrEmpty($TxtDlgDomain.Text)) { 'Visible' } else { 'Collapsed' }
    })
    $TxtDlgDomain.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            $e.Handled = $true
            & $addDomainAction
        }
    })
    $BtnDlgAdd.Add_Click({ & $addDomainAction })
    $BtnDlgTabGen.Add_Click({ $state.Tab = 'general'; $TxtDlgHint.Text = ''; & $renderTab })
    $BtnDlgTabEx.Add_Click({ $state.Tab = 'exclude'; $TxtDlgHint.Text = ''; & $renderTab })
    $BtnDlgTabAuto.Add_Click({ $state.Tab = 'auto'; $TxtDlgHint.Text = 'Домены, автоматически найденные winws2 (list-auto.txt). Лишнее можно удалить крестиком.'; $TxtDlgHint.Foreground = $bc.ConvertFromString('#9CA3AF'); & $renderTab })
    $BtnDlgClearAuto.Add_Click({
        $state.AutoList.Clear()
        $state.Changed = $true
        $state.AutoChanged = $true
        $TxtDlgHint.Text = 'Авто-список очищен (нажми «Применить» для перезапуска).'
        $TxtDlgHint.Foreground = $bc.ConvertFromString('#D9B066')
        & $renderTab
    })

    # Delete row via routed Button.Click event inside ListBox
    $LstDlgDomains.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
        if ($null -ne $btn -and $null -ne $btn.Tag) {
            $dom = [string]$btn.Tag
            $cur = if ($state.Tab -eq 'general') { $state.GenList } elseif ($state.Tab -eq 'exclude') { $state.ExList } else { $state.AutoList }
            if ($cur.Remove($dom)) {
                $state.Changed = $true
                if ($state.Tab -eq 'auto') { $state.AutoChanged = $true }
                $TxtDlgHint.Text = "Удалён: $dom"
                $TxtDlgHint.Foreground = $bc.ConvertFromString('#9CA3AF')
                & $renderTab
            }
        }
    })

    $BtnDlgOpenTxt.Add_Click({
        if ($state.Changed) { & $saveBoth }
        $fp = if ($state.Tab -eq 'general') { $genPath } elseif ($state.Tab -eq 'exclude') { $exPath } else { $autoPath }
        Start-Process notepad.exe -ArgumentList "`"$fp`""
    })

    $applyAndRestart = {
        & $saveBoth
        $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        }
        $state.Applied = $true
        $state.Changed = $false
    }

    $BtnDlgApply.Add_Click({
        & $applyAndRestart
        $dlg.Close()
    })
    $BtnDlgClose.Add_Click({ $dlg.Close() })

    & $renderTab
    [void]$dlg.ShowDialog()
    return $state.Applied
}
