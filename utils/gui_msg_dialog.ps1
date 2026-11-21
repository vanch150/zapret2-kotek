# Zapret2 Kotek — Dark WPF Message Dialog (utils/gui_msg_dialog.ps1)

function Show-Z2MessageDialog {
    param(
        $Owner = $null,
        [string]$Title = 'Zapret2 Kotek',
        [string]$Message = '',
        [ValidateSet('Info','Warning','Error','Question')][string]$Kind = 'Info',
        [ValidateSet('OK','YesNo')][string]$Buttons = 'OK',
        [string]$AccentHex = '#7BC4A4'
    )

    try { Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue } catch {}
    try { Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue } catch {}
    try { Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue } catch {}

    if (-not ('WinDwmHelper' -as [type])) {
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
    }

    $accent = if ($AccentHex -match '^#[0-9A-Fa-f]{6}$') { $AccentHex } else { '#7BC4A4' }
    $badgeColor = $accent
    $badgeBg    = '#1D2B26'
    $badgeText  = 'i'
    if ($Kind -eq 'Error') {
        $badgeColor = '#E06C75'
        $badgeBg    = '#3A2024'
        $badgeText  = '!'
    } elseif ($Kind -eq 'Warning') {
        $badgeColor = '#D9B066'
        $badgeBg    = '#382F1E'
        $badgeText  = '!'
    } elseif ($Kind -eq 'Question') {
        $badgeColor = $accent
        $badgeBg    = '#1D2B26'
        $badgeText  = '?'
    }

    $dlgXamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zapret2 Kotek"
        Width="460" SizeToContent="Height" MinWidth="360" MaxWidth="560"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#121316" Foreground="#D4D7DD" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="MsgPrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="__ACCENT__"/>
            <Setter Property="Foreground" Value="#121316"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="MinWidth" Value="88"/>
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
        <Style x:Key="MsgSecBtn" TargetType="Button">
            <Setter Property="Background" Value="#1E2026"/>
            <Setter Property="Foreground" Value="#D4D7DD"/>
            <Setter Property="BorderBrush" Value="#2E323B"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="MinWidth" Value="88"/>
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

    <Border Margin="14" Background="#16181D" BorderBrush="#262A33" BorderThickness="1" CornerRadius="8" Padding="18,16">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,16">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="BdMsgBadge" Grid.Column="0" Width="34" Height="34" CornerRadius="17"
                        Background="__BADGE_BG__" BorderBrush="__BADGE_FG__" BorderThickness="1.2"
                        VerticalAlignment="Top" Margin="0,2,14,0">
                    <TextBlock x:Name="TxtMsgBadge" Text="__BADGE_TXT__" Foreground="__BADGE_FG__"
                               FontSize="16" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>

                <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="340">
                    <TextBlock x:Name="TxtMsgBody" Text="" Foreground="#D4D7DD" FontSize="13" LineHeight="19"
                               TextWrapping="Wrap" VerticalAlignment="Center"/>
                </ScrollViewer>
            </Grid>

            <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnMsgNo" Content="Нет" Style="{StaticResource MsgSecBtn}" Margin="0,0,8,0" Visibility="Collapsed"/>
                <Button x:Name="BtnMsgYesOk" Content="OK" Style="{StaticResource MsgPrimaryBtn}"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@

    $dlgXamlStr = $dlgXamlStr.Replace('__ACCENT__', $accent).Replace('__BADGE_BG__', $badgeBg).Replace('__BADGE_FG__', $badgeColor).Replace('__BADGE_TXT__', $badgeText)

    [xml]$xmlDoc = $dlgXamlStr
    $reader = New-Object System.Xml.XmlNodeReader $xmlDoc
    $dlg = $null
    try {
        $dlg = [Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }

    $dlg.Title = if ([string]::IsNullOrWhiteSpace($Title)) { 'Zapret2 Kotek' } else { $Title }
    if ($null -ne $Owner) {
        try {
            $dlg.Owner = $Owner
            $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
            if ($null -ne $Owner.Icon) { $dlg.Icon = $Owner.Icon }
        } catch {}
    }

    $dlg.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($dlg)).Handle
            $dark = 1
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) | Out-Null
            $capColor = 0x00161312
            [WinDwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$capColor, 4) | Out-Null
        } catch {}
    })

    $TxtMsgBody  = $dlg.FindName('TxtMsgBody')
    $BtnMsgNo    = $dlg.FindName('BtnMsgNo')
    $BtnMsgYesOk = $dlg.FindName('BtnMsgYesOk')

    $TxtMsgBody.Text = $Message

    $resState = [PSCustomObject]@{
        Result = if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' }
    }

    if ($Buttons -eq 'YesNo') {
        $BtnMsgYesOk.Content   = 'Да'
        $BtnMsgYesOk.IsDefault = $true
        $BtnMsgNo.Visibility   = 'Visible'
        $BtnMsgNo.IsCancel     = $true
        $BtnMsgYesOk.Add_Click({
            $resState.Result = 'Yes'
            $dlg.Close()
        })
        $BtnMsgNo.Add_Click({
            $resState.Result = 'No'
            $dlg.Close()
        })
    } else {
        $BtnMsgYesOk.Content   = 'OK'
        $BtnMsgYesOk.IsDefault = $true
        $BtnMsgYesOk.IsCancel  = $true
        $BtnMsgNo.Visibility   = 'Collapsed'
        $BtnMsgYesOk.Add_Click({
            $resState.Result = 'OK'
            $dlg.Close()
        })
    }

    [void]$dlg.ShowDialog()
    return $resState.Result
}
