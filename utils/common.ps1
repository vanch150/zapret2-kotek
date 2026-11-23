# Zapret2 Kotek — Shared Utility Library (utils/common.ps1)

function Resolve-Z2Root([string]$Root = '') {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $env:Z2_ROOT }
    $clean = if ($null -ne $Root) { $Root.Trim().Trim('"').Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = ([string]$env:Z2_ROOT).Trim().Trim('"').Trim() }
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = Split-Path -Parent $PSScriptRoot }
    if ($clean -match '^[A-Za-z]:$') { $clean += '\' }
    try { return ([System.IO.Path]::GetFullPath($clean).TrimEnd('\', '/') + '\') } catch { return ($clean.TrimEnd('\', '/') + '\') }
}

function Format-Z2DirNoSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ($Path -match '^[A-Za-z]:[/\\]?$') { return ($Path.Substring(0, 2) + '\') }
    return $Path.TrimEnd('\', '/')
}

function Format-Z2CliPathArg([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ($Path.EndsWith('\')) { return ($Path + '\') }
    return $Path
}

function Get-Z2Version([string]$Root) {
    $vf = Join-Path $Root 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = (Get-Content -LiteralPath $vf -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($v) { return $v.Trim() }
    }
    return '1.1.1'
}

function Get-Z2Repo([string]$Root) {
    $repo = 'vanch150/zapret2-kotek'
    $rc = Join-Path $Root 'utils\repo.conf'
    if (Test-Path -LiteralPath $rc) {
        foreach ($l in (Get-Content -LiteralPath $rc -ErrorAction SilentlyContinue)) {
            if ($l -match '^\s*repo\s*=\s*(.+)$') {
                $r = $matches[1].Trim()
                if ($r -and $r -notlike 'OWNER/*') { $repo = $r; break }
            }
        }
    }
    return $repo
}

function Get-Z2StrategyScores([string]$Root) {
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

function Get-Z2Strategies([string]$Root, [string]$Group = 'core') {
    $skip = @('1_AUTO_SETUP.bat','2_KOTEK.bat','!_START_KOTEK.bat','KOTEK.bat','AUTO_SETUP.bat','PAUSE_RESUME.bat','UNINSTALL.bat','DEEP_OPTIMIZE.bat','service.bat')
    if ($Group -eq 'arch') {
        $archDir = Join-Path $Root 'configs_archive'
        if (Test-Path -LiteralPath $archDir) {
            return @(Get-ChildItem -LiteralPath $archDir -Filter '*.bat' -File | Sort-Object Name)
        }
        return @()
    }
    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @((Join-Path $Root 'strategies'), $Root)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Filter '*.bat' -File | Sort-Object Name | ForEach-Object {
            if ($skip -notcontains $_.Name -and $seen.Add($_.Name)) { $list.Add($_) }
        }
    }
    return @($list | Sort-Object Name)
}

function Get-Z2IpsetMode([string]$Root) {
    $ipFile = Join-Path $Root 'lists\ipset-all.txt'
    if (-not (Test-Path -LiteralPath $ipFile)) { return 'none' }
    $len = (Get-Item -LiteralPath $ipFile).Length
    if ($len -eq 0) { return 'any' }
    if ($len -lt 64) {
        $raw = (Get-Content -LiteralPath $ipFile -Raw -ErrorAction SilentlyContinue)
        if ($raw -and $raw.Trim() -eq '203.0.113.113/32') { return 'none' }
    }
    return 'loaded'
}

function Set-Z2IpsetMode([string]$Root, [string]$Mode) {
    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $isRunning = $false
    if ($null -ne $svc) {
        try {
            $isRunning = ($svc.Status -eq 'Running')
        } finally {
            try { $svc.Dispose() } catch {}
        }
    }
    if ($isRunning -and (-not (Test-Z2IsAdmin))) {
        return $false
    }
    $ipFile = Join-Path $Root 'lists\ipset-all.txt'
    $bakFile = Join-Path $Root 'lists\ipset-all.txt.backup'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $curMode = Get-Z2IpsetMode $Root
    try {
        if ($curMode -eq 'loaded' -and $Mode -ne 'loaded') {
            Copy-Item -LiteralPath $ipFile -Destination $bakFile -Force -ErrorAction Stop
        }
        if ($Mode -eq 'none') {
            [System.IO.File]::WriteAllText($ipFile, "203.0.113.113/32`r`n", $utf8NoBom)
        } elseif ($Mode -eq 'any') {
            [System.IO.File]::WriteAllText($ipFile, '', $utf8NoBom)
        } elseif ($Mode -eq 'loaded') {
            if ($curMode -ne 'loaded') {
                if (Test-Path -LiteralPath $bakFile) {
                    Copy-Item -LiteralPath $bakFile -Destination $ipFile -Force -ErrorAction Stop
                } else {
                    return $false
                }
            }
        }
    } catch {
        return $false
    }
    $svcAfter = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($null -ne $svcAfter) {
        try {
            if ($svcAfter.Status -eq 'Running') {
                Restart-Service -Name 'zapret' -Force -ErrorAction Stop
            }
        } catch {
            return $false
        } finally {
            try { $svcAfter.Dispose() } catch {}
        }
    }
    return $true
}

function Get-Z2AutoUpdateTask {
    try {
        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        $task = $folder.GetTask('Zapret2KotekAutoUpdate')
        if ($null -ne $task) { return $task }
    } catch {}
    try {
        return (Get-ScheduledTask -TaskName 'Zapret2KotekAutoUpdate' -ErrorAction SilentlyContinue)
    } catch { return $null }
}


function Build-Z2PerchFolderIcon {
    param(
        [string]$PerchPngPath,
        [string]$OutIcoPath,
        [string]$BadgePngPath = ''
    )
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        if (-not ('Z2ShellFolderIcon' -as [type])) {
            $csCode = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class Z2ShellFolderIcon {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    [ComImport]
    [Guid("46EB5926-582E-4017-9FDF-E8998DAA0950")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IImageList {
        int Add(IntPtr hbmImage, IntPtr hbmMask, ref int pi);
        int ReplaceIcon(int i, IntPtr hicon, ref int pi);
        int SetOverlayImage(int iImage, int iOverlay);
        int Replace(int i, IntPtr hbmImage, IntPtr hbmMask);
        int AddMasked(IntPtr hbmImage, int crMask, ref int pi);
        int Draw(IntPtr pimldp);
        int Remove(int i);
        int GetIcon(int i, int flags, ref IntPtr picon);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("shell32.dll", EntryPoint = "#727")]
    private static extern int SHGetImageList(int iImageList, ref Guid riid, out IImageList ppv);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public static Bitmap GetSystemFolderBitmap(string sampleFolderPath) {
        SHFILEINFO shfi = new SHFILEINFO();
        const uint SHGFI_SYSICONINDEX = 0x000004000;
        const uint SHGFI_USEFILEATTRIBUTES = 0x000000010;
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        IntPtr res = SHGetFileInfo(sampleFolderPath, FILE_ATTRIBUTE_DIRECTORY, ref shfi, (uint)Marshal.SizeOf(shfi), SHGFI_SYSICONINDEX | SHGFI_USEFILEATTRIBUTES);
        if (res == IntPtr.Zero) return null;
        Guid iid = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950");
        IImageList iml;
        // 4 = SHIL_JUMBO (256x256), fallback 2 = SHIL_EXTRALARGE (48x48)
        int hr = SHGetImageList(4, ref iid, out iml);
        if (hr != 0 || iml == null) {
            hr = SHGetImageList(2, ref iid, out iml);
            if (hr != 0 || iml == null) return null;
        }
        IntPtr hIcon = IntPtr.Zero;
        try {
            hr = iml.GetIcon(shfi.iIcon, 1, ref hIcon);
            if (hr != 0 || hIcon == IntPtr.Zero) return null;
            using (Icon ic = Icon.FromHandle(hIcon)) {
                return ic.ToBitmap();
            }
        } finally {
            if (hIcon != IntPtr.Zero) DestroyIcon(hIcon);
        }
    }
}
'@
            Add-Type -TypeDefinition $csCode -ReferencedAssemblies System.Drawing -ErrorAction Stop
        }

        $folderBmp = [Z2ShellFolderIcon]::GetSystemFolderBitmap($env:SystemRoot)
        if ($null -eq $folderBmp) { return $false }

        $perchBytes = [System.IO.File]::ReadAllBytes($PerchPngPath)
        $perchMs = New-Object System.IO.MemoryStream(,$perchBytes)
        $perchBmp = New-Object System.Drawing.Bitmap($perchMs)

        try {
            $fw = $folderBmp.Width; $fh = $folderBmp.Height
            # Scan folder bounding box & right-half top edge (past the top-left tab)
            $minX = $fw; $maxX = 0; $minY = $fh; $maxY = 0
            for ($y = 0; $y -lt $fh; $y++) {
                for ($x = 0; $x -lt $fw; $x++) {
                    if ($folderBmp.GetPixel($x, $y).A -gt 40) {
                        if ($x -lt $minX) { $minX = $x }
                        if ($x -gt $maxX) { $maxX = $x }
                        if ($y -lt $minY) { $minY = $y }
                        if ($y -gt $maxY) { $maxY = $y }
                    }
                }
            }
            if ($maxX -le $minX -or $maxY -le $minY) { return $false }

            $scanX0 = $minX + [int](($maxX - $minX) * 0.45)
            $scanX1 = $minX + [int](($maxX - $minX) * 0.85)
            $topEdgeY = $minY
            $foundEdge = $false
            for ($y = $minY; $y -le $maxY -and -not $foundEdge; $y++) {
                for ($x = $scanX0; $x -le $scanX1; $x++) {
                    if ($folderBmp.GetPixel($x, $y).A -gt 40) {
                        $topEdgeY = $y
                        $foundEdge = $true
                        break
                    }
                }
            }

            $canvasSize = 256
            $comp256 = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($comp256)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)

            # Scale native folder to fit lower 80% of 256x256 so Kotek has room on top
            $boxW = $maxX - $minX + 1
            $boxH = $maxY - $minY + 1
            $scale = [Math]::Min((232.0 / $boxW), (186.0 / $boxH))
            $drawFW = [int][Math]::Round($boxW * $scale)
            $drawFH = [int][Math]::Round($boxH * $scale)
            $drawFX = [int][Math]::Round(($canvasSize - $drawFW) / 2.0)
            $drawFY = $canvasSize - 8 - $drawFH

            $srcRect = New-Object System.Drawing.Rectangle($minX, $minY, $boxW, $boxH)
            $dstRect = New-Object System.Drawing.Rectangle($drawFX, $drawFY, $drawFW, $drawFH)
            $g.DrawImage($folderBmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

            # Compute exact mapped topEdgeY and place Kotek perched right on it (bellyRatio = 0.6154)
            $mappedEdgeY = $drawFY + (($topEdgeY - $minY) * $scale)
            $catW = [int][Math]::Round($drawFW * 0.72)
            $catH = [int][Math]::Round($catW * ($perchBmp.Height / [double]$perchBmp.Width))
            $catX = $drawFX + [int][Math]::Round($drawFW * 0.24)
            $catY = [int][Math]::Round($mappedEdgeY - (0.6154 * $catH))
            if ($catY -lt 2) { $catY = 2 }
            $g.DrawImage($perchBmp, (New-Object System.Drawing.Rectangle($catX, $catY, $catW, $catH)))
            $g.Dispose()

            # Build crisp small-icon composite (folder + Kotek badge in bottom-right) for 16/20/24px table/list views
            $smallComp = New-Object System.Drawing.Bitmap(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $sg = [System.Drawing.Graphics]::FromImage($smallComp)
            $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $sg.Clear([System.Drawing.Color]::Transparent)
            $sg.DrawImage($folderBmp, (New-Object System.Drawing.Rectangle(0, 0, 58, 58)), $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

            $badgeMs = $null
            $badgeBmp = $null
            try {
                if ($BadgePngPath -and (Test-Path -LiteralPath $BadgePngPath -PathType Leaf)) {
                    $bBytes = [System.IO.File]::ReadAllBytes($BadgePngPath)
                    $badgeMs = New-Object System.IO.MemoryStream(,$bBytes)
                    $badgeBmp = New-Object System.Drawing.Bitmap($badgeMs)
                }
                $bSrc = if ($null -ne $badgeBmp) { $badgeBmp } else { $perchBmp }
                # Trim transparent margins around badge sprite so Kotek fills the corner crisply
                $bMinX = $bSrc.Width; $bMaxX = 0; $bMinY = $bSrc.Height; $bMaxY = 0
                for ($by = 0; $by -lt $bSrc.Height; $by++) {
                    for ($bx = 0; $bx -lt $bSrc.Width; $bx++) {
                        if ($bSrc.GetPixel($bx, $by).A -gt 35) {
                            if ($bx -lt $bMinX) { $bMinX = $bx }
                            if ($bx -gt $bMaxX) { $bMaxX = $bx }
                            if ($by -lt $bMinY) { $bMinY = $by }
                            if ($by -gt $bMaxY) { $bMaxY = $by }
                        }
                    }
                }
                if ($bMaxX -gt $bMinX -and $bMaxY -gt $bMinY) {
                    $bRect = New-Object System.Drawing.Rectangle($bMinX, $bMinY, ($bMaxX - $bMinX + 1), ($bMaxY - $bMinY + 1))
                    $bTarget = 42
                    $bScale = [Math]::Min(($bTarget / [double]$bRect.Width), ($bTarget / [double]$bRect.Height))
                    $bw = [int][Math]::Round($bRect.Width * $bScale)
                    $bh = [int][Math]::Round($bRect.Height * $bScale)
                    $bxDst = 64 - $bw
                    $byDst = 64 - $bh
                    $sg.DrawImage($bSrc, (New-Object System.Drawing.Rectangle($bxDst, $byDst, $bw, $bh)), $bRect, [System.Drawing.GraphicsUnit]::Pixel)
                }
            } finally {
                if ($null -ne $badgeBmp) { $badgeBmp.Dispose() }
                if ($null -ne $badgeMs) { $badgeMs.Dispose() }
                $sg.Dispose()
            }

            # Build multi-size PNG-compressed ICO (256/64/48/32 = perched Kotek, 24/20/16 = folder + Kotek badge)
            $sizes = @(256, 64, 48, 32, 24, 20, 16)
            $pngBlobs = New-Object System.Collections.Generic.List[byte[]]
            foreach ($sz in $sizes) {
                $layer = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $lg = [System.Drawing.Graphics]::FromImage($layer)
                $lg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $lg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $lg.Clear([System.Drawing.Color]::Transparent)
                if ($sz -le 24) {
                    $lg.DrawImage($smallComp, (New-Object System.Drawing.Rectangle(0, 0, $sz, $sz)))
                } else {
                    $lg.DrawImage($comp256, (New-Object System.Drawing.Rectangle(0, 0, $sz, $sz)))
                }
                $lg.Dispose()
                $ms = New-Object System.IO.MemoryStream
                $layer.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $pngBlobs.Add($ms.ToArray())
                $ms.Dispose()
                $layer.Dispose()
            }
            $smallComp.Dispose()
            $comp256.Dispose()

            # Write ICO binary
            $icoMs = New-Object System.IO.MemoryStream
            $bw = New-Object System.IO.BinaryWriter($icoMs)
            $bw.Write([UInt16]0) # Reserved
            $bw.Write([UInt16]1) # Type = ICO
            $bw.Write([UInt16]$sizes.Count)
            $offset = 6 + (16 * $sizes.Count)
            for ($i = 0; $i -lt $sizes.Count; $i++) {
                $dimByte = if ($sizes[$i] -ge 256) { [byte]0 } else { [byte]$sizes[$i] }
                $bw.Write($dimByte)
                $bw.Write($dimByte)
                $bw.Write([byte]0)
                $bw.Write([byte]0)
                $bw.Write([UInt16]1)
                $bw.Write([UInt16]32)
                $bw.Write([UInt32]$pngBlobs[$i].Length)
                $bw.Write([UInt32]$offset)
                $offset += $pngBlobs[$i].Length
            }
            foreach ($blob in $pngBlobs) { $bw.Write($blob) }
            $bw.Flush()
            [System.IO.File]::WriteAllBytes($OutIcoPath, $icoMs.ToArray())
            $bw.Dispose()
            $icoMs.Dispose()
            return $true
        } finally {
            $perchBmp.Dispose()
            $perchMs.Dispose()
            $folderBmp.Dispose()
        }
    } catch {
        return $false
    }
}

function Set-Z2DesktopAndFolderIcons([string]$Root, [switch]$FolderOnly) {
    $Root = Resolve-Z2Root $Root
    $icoPath = Join-Path $Root 'utils\kotek.ico'
    if (-not $FolderOnly -and (Test-Path -LiteralPath $icoPath)) {
    # 1. Create Desktop & Start Menu shortcuts "Zapret2 Kotek.lnk" pointing to !_START_KOTEK.bat
    try {
        $targetBat = Join-Path $Root '!_START_KOTEK.bat'
        if (-not (Test-Path -LiteralPath $targetBat)) { $targetBat = Join-Path $Root 'utils\service.bat' }
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($lnkDir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            if ($lnkDir -and (Test-Path -LiteralPath $lnkDir)) {
                $lnkPath = Join-Path $lnkDir 'Zapret2 Kotek.lnk'
                $sc = $wsh.CreateShortcut($lnkPath)
                $sc.TargetPath = $targetBat
                $sc.WorkingDirectory = Format-Z2DirNoSlash $Root
                $sc.IconLocation = "$icoPath,0"
                $sc.WindowStyle = 7
                $sc.Description = 'Zapret2 Kotek — обход DPI и Telegram Proxy'
                $sc.Save()
            }
        }
    } catch {}
    }
    # 2. Build adaptive folder icon (native Windows folder + Kotek perched on top) and apply via desktop.ini
    if ($Root -match '^[A-Za-z]:\\$') { return }
    try {
        $perchPng = Join-Path $Root 'utils\kotek_perch.png'
        $folderIco = Join-Path $Root 'utils\kotek_folder.ico'
        $builtIco = $false
        if (Test-Path -LiteralPath $perchPng) {
            $happyPng = Join-Path $Root 'utils\kotek_happy.png'
            $builtIco = Build-Z2PerchFolderIcon -PerchPngPath $perchPng -OutIcoPath $folderIco -BadgePngPath $happyPng
        }
        $iconRel = $null
        if ($builtIco -and (Test-Path -LiteralPath $folderIco)) {
            $iconRel = 'utils\kotek_folder.ico'
        } elseif (Test-Path -LiteralPath $icoPath) {
            $iconRel = 'utils\kotek.ico'
        }
        if ($iconRel) {
            $rootClean = Format-Z2DirNoSlash $Root
            $iniPath = Join-Path $Root 'desktop.ini'
            $iniText = "[.ShellClassInfo]`r`nIconResource=$iconRel,0`r`nInfoTip=Zapret2 Kotek`r`n"
            if (Test-Path -LiteralPath $iniPath) {
                $iniItem = Get-Item -LiteralPath $iniPath -Force
                $iniItem.Attributes = $iniItem.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::ReadOnly))
            }
            [System.IO.File]::WriteAllText($iniPath, $iniText, (New-Object System.Text.UTF8Encoding($false)))
            $iniItem = Get-Item -LiteralPath $iniPath -Force
            $iniItem.Attributes = $iniItem.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
            $dirItem = Get-Item -LiteralPath $rootClean -Force
            $dirItem.Attributes = $dirItem.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        }
    } catch {}
}

function Register-Z2UninstallEntry([string]$Root) {
    try {
        $Root = Resolve-Z2Root $Root
        $rootClean = Format-Z2DirNoSlash $Root
        $uninstBat = Join-Path $Root 'UNINSTALL.bat'
        if (-not (Test-Path -LiteralPath $uninstBat)) { $uninstBat = Join-Path $Root 'utils\UNINSTALL.bat' }
        if (-not (Test-Path -LiteralPath $uninstBat)) { return }
        $ver = Get-Z2Version $Root
        $ico = Join-Path $Root 'utils\kotek.ico'
        $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Zapret2Kotek'
        if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        $uninstBatEsc = $uninstBat -replace '%', '"^%"'
        $uninstCmd = "`"$env:SystemRoot\System32\cmd.exe`" /d /s /c `"`"$uninstBatEsc`"`""
        New-ItemProperty -Path $regKey -Name 'DisplayName'     -Value 'Zapret2 Kotek' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'DisplayVersion'  -Value $ver -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'Publisher'       -Value 'vanch150' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'InstallLocation' -Value $rootClean -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'UninstallString' -Value $uninstCmd -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'URLInfoAbout'    -Value ('https://github.com/' + (Get-Z2Repo $Root)) -PropertyType String -Force | Out-Null
        if (Test-Path -LiteralPath $ico) {
            New-ItemProperty -Path $regKey -Name 'DisplayIcon' -Value "$ico,0" -PropertyType String -Force | Out-Null
        }
        New-ItemProperty -Path $regKey -Name 'NoModify'      -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'NoRepair'      -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $regKey -Name 'EstimatedSize' -Value 12288 -PropertyType DWord -Force | Out-Null
    } catch {}
}

function Register-Z2TrayStartupTask([string]$Root) {
    try {
        $rootClean = Resolve-Z2Root $Root
        $guiScript = Join-Path $rootClean 'utils\gui_app.ps1'
        if (-not (Test-Path -LiteralPath $guiScript)) { return $false }
        $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $rootNoSlash = Format-Z2DirNoSlash $rootClean
        $rootCliArg = Format-Z2CliPathArg $rootNoSlash
        $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$guiScript`" -Root `"$rootCliArg`" -StartInTray"

        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        $td = $sched.NewTask(0)
        $td.RegistrationInfo.Description = 'Zapret2 Kotek — тихий запуск иконки в трее при входе в Windows (без UAC)'
        $td.RegistrationInfo.Author = 'Zapret2 Kotek'
        $td.Principal.LogonType = 3
        $td.Principal.RunLevel  = 1
        $td.Settings.Enabled = $true
        $td.Settings.Hidden  = $false
        $td.Settings.DisallowStartIfOnBatteries = $false
        $td.Settings.StopIfGoingOnBatteries     = $false
        $td.Settings.ExecutionTimeLimit         = 'PT0S'
        $td.Settings.MultipleInstances          = 2
        $td.Settings.AllowDemandStart           = $true

        $trig = $td.Triggers.Create(9)
        $trig.Enabled = $true
        $trig.Delay   = 'PT5S'

        $act = $td.Actions.Create(0)
        $act.Path             = $psExe
        $act.Arguments        = $taskArgs
        $act.WorkingDirectory = $rootNoSlash

        $folder.RegisterTaskDefinition('Zapret2KotekTray', $td, 6, $null, $null, 3, $null) | Out-Null
        return $true
    } catch { return $false }
}

function Unregister-Z2TrayStartupTask {
    $ok = $false
    try {
        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        try {
            $folder.DeleteTask('Zapret2KotekTray', 0)
            $ok = $true
        } catch {
            if ($_.Exception.HResult -eq -2147024894) {
                $ok = $true
            }
        }
    } catch {}
    if (-not $ok) {
        try {
            $global:LASTEXITCODE = 0
            & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN 'Zapret2KotekTray' /F >$null 2>&1
            if ($LASTEXITCODE -eq 0) { $ok = $true }
        } catch {}
    }
    return $ok
}
function Test-Z2IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Stop-Z2ServiceAndProcess {
    param(
        [string]$ServiceName = 'zapret',
        [int]$ServiceTimeoutSec = 5,
        [int]$ProcessTimeoutMs = 3000
    )
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        try {
            if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                try {
                    if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                        $svc.Stop()
                    }
                } catch {}
                try {
                    $svc.WaitForStatus(
                        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                        [TimeSpan]::FromSeconds($ServiceTimeoutSec)
                    )
                } catch {}
            }
        } finally {
            try { $svc.Dispose() } catch {}
        }
    }
    foreach ($pn in @('winws2', 'winws')) {
        $procs = @(Get-Process -Name $pn -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            try {
                if (-not $p.HasExited) {
                    $p.Kill()
                    [void]$p.WaitForExit($ProcessTimeoutMs)
                }
            } catch {}
        }
    }
}
function Get-Z2Targets {
    param(
        [string]$Root = '',
        [ValidateSet('CORE', 'ALL')]
        [string]$Mode = 'CORE'
    )
    $list = New-Object System.Collections.Generic.List[object]
    $tFile = Join-Path (Resolve-Z2Root $Root) 'utils\targets.txt'
    if (Test-Path -LiteralPath $tFile) {
        foreach ($tl in (Get-Content -LiteralPath $tFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $tt = $tl.Trim()
            if (-not $tt -or $tt.StartsWith('#')) { continue }
            $tp = $tt -split '\|'
            if ($tp.Count -ge 3) {
                $cat  = $tp[0].Trim().ToUpperInvariant()
                $tmod = $tp[1].Trim().ToUpperInvariant()
                $url  = $tp[2].Trim()
                if ($url -and ($Mode -eq 'ALL' -or $tmod -eq 'CORE')) {
                    $list.Add([PSCustomObject]@{ Cat = $cat; Mode = $tmod; Url = $url })
                }
            }
        }
    }
    if ($list.Count -eq 0) {
        $fallback = @(
            @{ Cat='YT';  Mode='CORE'; Url='https://www.youtube.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg' },
            @{ Cat='YT';  Mode='CORE'; Url='https://yt3.ggpht.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://jnn-pa.googleapis.com' },
            @{ Cat='YT';  Mode='CORE'; Url='https://redirector.googlevideo.com' },
            @{ Cat='YT';  Mode='EXT';  Url='https://m.youtube.com' },
            @{ Cat='YT';  Mode='EXT';  Url='https://play.google.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.com/api/v10/gateway' },
            @{ Cat='DC';  Mode='CORE'; Url='https://cdn.discordapp.com' },
            @{ Cat='DC';  Mode='CORE'; Url='https://discord.gg' },
            @{ Cat='DC';  Mode='EXT';  Url='https://media.discordapp.net' },
            @{ Cat='DC';  Mode='EXT';  Url='https://status.discord.com' },
            @{ Cat='TG';  Mode='EXT';  Url='https://web.telegram.org' },
            @{ Cat='TG';  Mode='EXT';  Url='https://t.me' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://cloudflare-dns.com' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://one.one.one.one' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://speed.cloudflare.com/__down?bytes=262144' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://7tv.io' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://cdn.7tv.app' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://betterttv.net' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://frankerfacez.com' },
            @{ Cat='WEB'; Mode='CORE'; Url='https://raw.githubusercontent.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://github.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://soundcloud.com' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://rutracker.org' },
            @{ Cat='WEB'; Mode='EXT';  Url='https://ntc.party' }
        )
        foreach ($fb in $fallback) {
            if ($Mode -eq 'ALL' -or $fb.Mode -eq 'CORE') {
                $list.Add([PSCustomObject]$fb)
            }
        }
    }
    return $list.ToArray()
}

function Get-Z2ZapretDepend {
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc'
        if (Test-Path -LiteralPath $regPath) {
            $st = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction SilentlyContinue).Start
            if ($null -ne $st -and [int]$st -ne 4) { return 'BFE/nlasvc' }
        }
    } catch {}
    return 'BFE'
}
