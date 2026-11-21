# Zapret2 Kotek — Anonymous Opt-In Telemetry Helper (utils/telemetry_helper.ps1)
# Strictly opt-in (requires utils\telemetry.enabled unless explicitly triggered by user in Diagnostics).

function Get-Z2TelemetryEndpoint([string]$RootPath) {
    $cf = Join-Path $RootPath 'utils\telemetry.conf'
    if (-not (Test-Path -LiteralPath $cf)) { return '' }
    foreach ($l in (Get-Content -LiteralPath $cf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*endpoint\s*=\s*(https://\S+)\s*$') {
            return $matches[1].Trim()
        }
    }
    return ''
}

function Test-Z2TelemetryEnabled([string]$RootPath) {
    return (Test-Path -LiteralPath (Join-Path $RootPath 'utils\telemetry.enabled'))
}

function Get-Z2TelemetryAnonId([string]$RootPath) {
    $idFile = Join-Path $RootPath 'utils\telemetry.id'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $idFile) {
        $cur = ([string](Get-Content -LiteralPath $idFile -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($cur -match '^[0-9a-f]{12}$') { return $cur }
    }
    $newId = [Guid]::NewGuid().ToString('N').Substring(0, 12).ToLowerInvariant()
    try { [System.IO.File]::WriteAllText($idFile, "$newId`r`n", $utf8NoBom) } catch {}
    return $newId
}

function Remove-Z2SensitiveText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $r = $Text
    $r = [regex]::Replace($r, '[A-Za-z]:[/\\]Users[/\\][^/\\\r\n"'']+', '<USER_DIR>')
    $r = [regex]::Replace($r, '[0-9a-fA-F]{32,}', '<REDACTED>')
    $r = [regex]::Replace($r, '(?i)(secret\s*[:=]\s*)\S+', '$1<REDACTED>')
    $r = [regex]::Replace($r, '(?i)(cfproxy_(?:worker_)?domain\s*[:=]\s*)\S+', '$1<REDACTED>')
    $r = [regex]::Replace($r, '://[^@\s]+@', '://<REDACTED>@')
    if ($r.Length -gt 3500) { $r = $r.Substring(0, 3500) + "`n...[truncated]" }
    return $r
}

function Get-Z2TelemetryPreview([string]$RootPath) {
    $ver = '1.1.0'
    $vf = Join-Path $RootPath 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = ([string](Get-Content -LiteralPath $vf -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($v) { $ver = $v }
    }
    $osBuild = ''
    try { $osBuild = [string][System.Environment]::OSVersion.Version.Build } catch {}
    $obj = [ordered]@{
        app      = 'zapret2-kotek'
        ver      = $ver
        id       = (Get-Z2TelemetryAnonId $RootPath)
        os       = "Win-$osBuild"
        event    = 'autosetup'
        strategy = 'general (ALT11).bat'
        score    = '15/17 (88%)'
        code     = 0
        detail   = ''
    }
    return ($obj | ConvertTo-Json -Depth 3)
}

function Send-Z2TelemetryEvent {
    param(
        [string]$RootPath,
        [string]$Event,
        [string]$Strategy = '',
        [string]$Score = '',
        [string]$Code = '',
        [string]$Detail = '',
        [switch]$ManualDiag
    )
    if (-not $ManualDiag -and -not (Test-Z2TelemetryEnabled $RootPath)) { return $false }
    $endpoint = Get-Z2TelemetryEndpoint $RootPath
    if (-not $endpoint) { return $false }

    # Rate-limiting via utils\telemetry.state.json (24h routine, 1h per error, 60s manual diag)
    $stateFile = Join-Path $RootPath 'utils\telemetry.state.json'
    $nowUnix = [int64]([DateTime]::UtcNow - (New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc))).TotalSeconds
    $stateMap = @{}
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $loaded = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($null -ne $loaded) {
                foreach ($p in $loaded.PSObject.Properties) { $stateMap[$p.Name] = [int64]$p.Value }
            }
        } catch {}
    }

    $rateKey = if ($ManualDiag) { 'diag' } elseif ($Event -in @('crash', 'error')) { "err_${Event}_${Code}" } else { 'routine' }
    $minInterval = if ($ManualDiag) { 60 } elseif ($Event -in @('crash', 'error')) { 3600 } else { 86400 }
    if ($stateMap.ContainsKey($rateKey) -and (($nowUnix - $stateMap[$rateKey]) -lt $minInterval)) {
        return $false
    }

    $ver = '1.1.0'
    $vf = Join-Path $RootPath 'utils\version.txt'
    if (Test-Path -LiteralPath $vf) {
        $v = ([string](Get-Content -LiteralPath $vf -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
        if ($v) { $ver = $v }
    }
    $osBuild = ''
    try { $osBuild = [string][System.Environment]::OSVersion.Version.Build } catch {}

    $payload = [ordered]@{
        app      = 'zapret2-kotek'
        ver      = $ver
        id       = (Get-Z2TelemetryAnonId $RootPath)
        os       = "Win-$osBuild"
        event    = $Event
        strategy = (Remove-Z2SensitiveText $Strategy)
        score    = (Remove-Z2SensitiveText $Score)
        code     = (Remove-Z2SensitiveText $Code)
        detail   = (Remove-Z2SensitiveText $Detail)
    }
    $jsonBody = $payload | ConvertTo-Json -Compress -Depth 3
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tmpBody = Join-Path $env:TEMP ("z2_tel_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
    $sentOk = $false
    try {
        [System.IO.File]::WriteAllText($tmpBody, $jsonBody, $utf8NoBom)
        $curlExe = "$env:SystemRoot\System32\curl.exe"
        if (Test-Path -LiteralPath $curlExe) {
            $httpCode = & $curlExe --proto =https --proto-redir =https -s -o NUL -w '%{http_code}' --max-time 3 -X POST -H 'Content-Type: application/json' --data-binary "@$tmpBody" $endpoint 2>$null
            if ($httpCode -match '^2\d\d$') { $sentOk = $true }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $r = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { $sentOk = $true }
        }
    } catch {
        $sentOk = $false
    } finally {
        if (Test-Path -LiteralPath $tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    }

    if ($sentOk) {
        $stateMap[$rateKey] = $nowUnix
        try {
            $stateJson = ([PSCustomObject]$stateMap) | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($stateFile, $stateJson, $utf8NoBom)
        } catch {}
    }
    return $sentOk
}
