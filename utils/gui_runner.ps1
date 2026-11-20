# Zapret2 Kotek — Async Task Runner & Single-Instance Mutex (utils/gui_runner.ps1)

$script:Z2GuiMutex = $null
$script:Z2GuiMutexOwned = $false

function Enter-Z2GuiMutex {
    try {
        $createdNew = $false
        $script:Z2GuiMutex = New-Object System.Threading.Mutex($true, 'Local\Zapret2KotekGuiSingleInstance', [ref]$createdNew)
        $script:Z2GuiMutexOwned = $createdNew
        return $createdNew
    } catch {
        return $true
    }
}

function Exit-Z2GuiMutex {
    if ($null -ne $script:Z2GuiMutex) {
        if ($script:Z2GuiMutexOwned) {
            try { $script:Z2GuiMutex.ReleaseMutex() } catch {}
        }
        try { $script:Z2GuiMutex.Dispose() } catch {}
        $script:Z2GuiMutex = $null
    }
}

function Start-Z2AsyncTask([string]$Root, [string]$ScriptPath, [string]$ExtraArgs, [string]$LogPath) {
    if (Test-Path -LiteralPath $LogPath) {
        Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    }
    $escScript = $ScriptPath.Replace("'", "''")
    $escLog    = $LogPath.Replace("'", "''")
    $runnerCmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; `$enc=New-Object System.Text.UTF8Encoding(`$false); `$global:LASTEXITCODE=0; & '$escScript' $ExtraArgs *>&1 | ForEach-Object { [System.IO.File]::AppendAllText('$escLog', `"`$(`$_)``r``n`", `$enc) }; exit ([int]`$LASTEXITCODE)"
    $encBytes  = [System.Text.Encoding]::Unicode.GetBytes($runnerCmd)
    $b64Cmd    = [System.Convert]::ToBase64String($encBytes)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64Cmd"
    $psi.WorkingDirectory       = $Root
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-Z2TaskLogTail([string]$LogPath, [int]$MaxBytes = 2048) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    $fs = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($len -le 0) { return @{ Length = 0L; LastLine = '' } }
        $tailBytes = [int][Math]::Min([long]$MaxBytes, $len)
        [void]$fs.Seek(-[long]$tailBytes, [System.IO.SeekOrigin]::End)
        $buf = New-Object byte[] $tailBytes
        $readN = $fs.Read($buf, 0, $tailBytes)
        $startOff = 0
        while ($startOff -lt $readN -and (($buf[$startOff] -band 0xC0) -eq 0x80)) { $startOff++ }
        $chunk = [System.Text.Encoding]::UTF8.GetString($buf, $startOff, $readN - $startOff)
        $parts = $chunk -split '[\r\n]+'
        $lastLine = ''
        for ($li = $parts.Length - 1; $li -ge 0; $li--) {
            $cand = $parts[$li].Trim()
            if ($cand.Length -gt 2 -and $cand -notmatch '^[\s=\-]+$' -and $cand -notmatch '^[/\\_()^\s\*~]+$') {
                $lastLine = $cand
                break
            }
        }
        return @{ Length = $len; LastLine = $lastLine }
    } finally {
        $fs.Close()
    }
}

function Stop-Z2ActiveTask($Proc) {
    if ($null -ne $Proc -and -not $Proc.HasExited) {
        try { & "$env:SystemRoot\System32\taskkill.exe" /PID $($Proc.Id) /T /F 2>$null | Out-Null } catch { try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
    }
}
