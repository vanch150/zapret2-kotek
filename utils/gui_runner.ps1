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

function ConvertTo-Z2ArgTokens($RawArgs) {
    $tokens = New-Object System.Collections.Generic.List[string]
    if ($null -eq $RawArgs) { return $tokens }

    if ($RawArgs -is [System.Array]) {
        foreach ($item in $RawArgs) {
            if ($null -ne $item) { $tokens.Add([string]$item) }
        }
        return $tokens
    }

    $str = [string]$RawArgs
    if ([string]::IsNullOrWhiteSpace($str)) { return $tokens }

    $sb = New-Object System.Text.StringBuilder
    $inSingle = $false
    $inDouble = $false
    $hasToken = $false
    $len = $str.Length

    for ($i = 0; $i -lt $len; $i++) {
        $ch = $str[$i]
        if ($inSingle) {
            if ($ch -eq "'") {
                if (($i + 1) -lt $len -and $str[$i + 1] -eq "'") {
                    [void]$sb.Append("'")
                    $i++
                } else {
                    $inSingle = $false
                }
            } else {
                [void]$sb.Append($ch)
            }
        } elseif ($inDouble) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $len -and $str[$i + 1] -eq '"') {
                    [void]$sb.Append('"')
                    $i++
                } else {
                    $inDouble = $false
                }
            } else {
                [void]$sb.Append($ch)
            }
        } else {
            if ([char]::IsWhiteSpace($ch)) {
                if ($hasToken) {
                    $tokens.Add($sb.ToString())
                    [void]$sb.Clear()
                    $hasToken = $false
                }
            } elseif ($ch -eq "'") {
                $inSingle = $true
                $hasToken = $true
            } elseif ($ch -eq '"') {
                $inDouble = $true
                $hasToken = $true
            } else {
                [void]$sb.Append($ch)
                $hasToken = $true
            }
        }
    }
    if ($hasToken) {
        $tokens.Add($sb.ToString())
    }
    return $tokens
}

function Start-Z2AsyncTask([string]$Root, [string]$ScriptPath, $ExtraArgs, [string]$LogPath) {
    if (Test-Path -LiteralPath $LogPath) {
        Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    }

    $b64Script = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptPath))
    $b64Log    = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($LogPath))

    $argLines = New-Object System.Collections.Generic.List[string]
    $argLines.Add('$namedArgs = @{}')
    $argLines.Add('$posArgs = New-Object System.Collections.Generic.List[string]')

    if ($ExtraArgs -is [System.Collections.IDictionary]) {
        foreach ($k in $ExtraArgs.Keys) {
            $kName = [string]$k
            if ($kName -match '^[A-Za-z][A-Za-z0-9_]*$') {
                $v = $ExtraArgs[$k]
                if ($v -is [bool]) {
                    $bVal = if ($v) { '$true' } else { '$false' }
                    $argLines.Add("`$namedArgs['$kName'] = $bVal")
                } else {
                    $b64v = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$v))
                    $argLines.Add("`$namedArgs['$kName'] = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64v'))")
                }
            }
        }
    } else {
        $tokens = @(ConvertTo-Z2ArgTokens $ExtraArgs)
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $tok = $tokens[$i]
            if ($tok -match '^-([A-Za-z][A-Za-z0-9_]*):(.*)$') {
                $pName = $matches[1]
                $pRaw  = $matches[2]
                if ($pRaw -ieq '$true' -or $pRaw -ieq 'true') {
                    $argLines.Add("`$namedArgs['$pName'] = `$true")
                } elseif ($pRaw -ieq '$false' -or $pRaw -ieq 'false') {
                    $argLines.Add("`$namedArgs['$pName'] = `$false")
                } else {
                    $b64v = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pRaw))
                    $argLines.Add("`$namedArgs['$pName'] = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64v'))")
                }
            } elseif ($tok -match '^-([A-Za-z][A-Za-z0-9_]*)$') {
                $pName = $matches[1]
                if (($i + 1) -lt $tokens.Count -and -not ($tokens[$i + 1] -match '^-[A-Za-z][A-Za-z0-9_]*(?::.*)?$')) {
                    $b64v = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tokens[$i + 1]))
                    $argLines.Add("`$namedArgs['$pName'] = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64v'))")
                    $i++
                } else {
                    $argLines.Add("`$namedArgs['$pName'] = `$true")
                }
            } else {
                $b64v = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tok))
                $argLines.Add("[void]`$posArgs.Add([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64v')))")
            }
        }
    }

    $argSetup = $argLines -join "; "
    $runnerCmd = @"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
`$enc = New-Object System.Text.UTF8Encoding(`$false)
`$scriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64Script'))
`$logPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64Log'))
$argSetup
`$posArr = `$posArgs.ToArray()
`$fs = `$null
`$sw = `$null
`$exitCode = 0
`$psFailed = `$false
try {
    `$fs = New-Object System.IO.FileStream(`$logPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    `$sw = New-Object System.IO.StreamWriter(`$fs, `$enc)
    `$sw.AutoFlush = `$true
    `$global:LASTEXITCODE = 0
    try {
        & `$scriptPath @namedArgs @posArr *>&1 | ForEach-Object { `$sw.WriteLine([string]`$_) }
        if (-not `$?) { `$psFailed = `$true }
    } catch {
        `$psFailed = `$true
        try { `$sw.WriteLine([string]`$_); if (`$_.ScriptStackTrace) { `$sw.WriteLine([string]`$_.ScriptStackTrace) } } catch {}
    }
    if (`$null -ne `$global:LASTEXITCODE -and [int]`$global:LASTEXITCODE -ne 0) {
        `$exitCode = [int]`$global:LASTEXITCODE
    } elseif (`$psFailed) {
        `$exitCode = 1
    }
} finally {
    if (`$null -ne `$sw) {
        try { `$sw.Flush() } catch {}
        try { `$sw.Dispose() } catch {}
    }
    if (`$null -ne `$fs) {
        try { `$fs.Dispose() } catch {}
    }
}
exit `$exitCode
"@

    $encBytes = [System.Text.Encoding]::Unicode.GetBytes($runnerCmd)
    $b64Cmd   = [System.Convert]::ToBase64String($encBytes)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments        = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64Cmd"
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Stop-Z2ActiveTask($Proc) {
    if ($null -ne $Proc -and -not $Proc.HasExited) {
        try { & "$env:SystemRoot\System32\taskkill.exe" /PID $($Proc.Id) /T /F 2>$null | Out-Null } catch { try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
    }
}
