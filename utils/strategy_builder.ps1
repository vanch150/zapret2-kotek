#Requires -Version 5.1
param(
    [string]$Root = '',
    [switch]$NonInteractive,
    [switch]$DryRun
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Continue'

$commonPath = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
$Root = Resolve-Z2Root $Root

if (-not $DryRun -and -not (Test-Z2IsAdmin)) {
    Write-Host '  [X] Требуются права администратора — запустите от имени администратора.' -ForegroundColor Red
    exit 1
}

$verHdr = Get-Z2Version $Root
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "     ZAPRET2 KOTEK v$verHdr — КОНСТРУКТОР СТРАТЕГИИ С НУЛЯ (5 МИН)   " -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '  Пошаговый подбор под сложного провайдера (альтернатива blockcheck2):' -ForegroundColor Gray
Write-Host '   1) Разведка fooling-механик (clean, badsum, tcp_ts, tcp_md5, badseq, autottl)' -ForegroundColor Gray
Write-Host '   2) Нативные техники zapret2 на топ-2 fooling + авто-антифриз wssize' -ForegroundColor Gray
Write-Host '   3) Сравнение UDP (fake vs udplen), сборка custom_built_for_me.bat и тест CORE' -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray

$curlExe = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path -LiteralPath $curlExe)) { $curlExe = 'curl.exe' }

$curlHasParallel = $false
try {
    $curlHelp = & $curlExe --help all 2>$null | Out-String
    if ($curlHelp -match '--parallel') { $curlHasParallel = $true }
} catch {}

$winwsExe = Join-Path $Root 'bin\winws2.exe'
$buildConfScript = Join-Path $Root 'utils\build_service_conf.ps1'
$applyScript = Join-Path $Root 'utils\apply_strategy.ps1'
$tmpBatPath = Join-Path $env:TEMP "z2_builder_$PID.bat"
$tmpConfPath = Join-Path $env:TEMP "z2_builder_$PID.conf"
$outBatPath = Join-Path $Root 'strategies\custom_built_for_me.bat'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$invCulture = [System.Globalization.CultureInfo]::InvariantCulture
$padHdr = 'X-Pad: ' + ('A' * 3072)

# Key 4 targets for fast Stage 1 / Stage 2 reconnaissance (YT, YT-media/freeze, Discord, Cloudflare 16KB)
$FastTargets = @(
    [PSCustomObject]@{ Cat = 'YT';  Mode = 'CORE'; Url = 'https://www.youtube.com' },
    [PSCustomObject]@{ Cat = 'YT';  Mode = 'CORE'; Url = 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg' },
    [PSCustomObject]@{ Cat = 'DC';  Mode = 'CORE'; Url = 'https://discord.com' },
    [PSCustomObject]@{ Cat = 'WEB'; Mode = 'CORE'; Url = 'https://speed.cloudflare.com/__down?bytes=262144' }
)

$CoreTargets = @(Get-Z2Targets -Root $Root -Mode 'CORE')

# Stage 1 fooling definitions
$FoolingDefs = @(
    [PSCustomObject]@{ Id = 'clean';   Label = 'clean (без фейков)';               Opt = '';                             NeedsTcpIn = $false },
    [PSCustomObject]@{ Id = 'badsum';  Label = 'badsum';                           Opt = 'badsum';                       NeedsTcpIn = $false },
    [PSCustomObject]@{ Id = 'tcp_ts';  Label = 'tcp_ts';                           Opt = 'tcp_ts=-600000';               NeedsTcpIn = $false },
    [PSCustomObject]@{ Id = 'tcp_md5'; Label = 'tcp_md5';                          Opt = 'tcp_md5';                      NeedsTcpIn = $false },
    [PSCustomObject]@{ Id = 'badseq';  Label = 'tcp_seq=-10000:tcp_ack=-66000';    Opt = 'tcp_seq=-10000:tcp_ack=-66000'; NeedsTcpIn = $false },
    [PSCustomObject]@{ Id = 'autottl'; Label = 'ip_autottl=-2,3-20';               Opt = 'ip_autottl=-2,3-20:ip6_autottl=-2,3-20'; NeedsTcpIn = $true }
)

$FoolingById = @{}
foreach ($fd in $FoolingDefs) { $FoolingById[$fd.Id] = $fd }

# Stage 2 native zapret2 techniques
$TechDefs = @(
    [PSCustomObject]@{ Id = 'multisplit_seqovl';    Label = 'multisplit:seqovl=681';       NeedsFooling = $false },
    [PSCustomObject]@{ Id = 'multidisorder_seqovl'; Label = 'multidisorder:seqovl=host';   NeedsFooling = $false },
    [PSCustomObject]@{ Id = 'hostfakesplit';        Label = 'hostfakesplit:disorder_after'; NeedsFooling = $true },
    [PSCustomObject]@{ Id = 'fakeddisorder';        Label = 'fakeddisorder:pos=midsld';    NeedsFooling = $true },
    [PSCustomObject]@{ Id = 'tls_clone';            Label = 'tls_client_hello_clone';      NeedsFooling = $true }
)

$TechById = @{}
foreach ($td in $TechDefs) { $TechById[$td.Id] = $td }

function Get-Z2BuilderTcpChain {
    param(
        [string]$FoolingId,
        [string]$TechId,
        [bool]$IncludeHttp = $false,
        [bool]$IsGoogle = $false,
        [bool]$UseWssize = $false
    )
    $fDef = $FoolingById[$FoolingId]
    $fOpt = if ($null -ne $fDef) { [string]$fDef.Opt } else { '' }
    $isClean = [string]::IsNullOrEmpty($fOpt)
    $ipIdSuffix = if ($IsGoogle) { ':ip_id=zero' } else { '' }
    $sniFakeHost = if ($IncludeHttp) { 'max.ru' } else { 'google.com' }

    if ($UseWssize) {
        $wsPrefix = '--out-range=-d1 --payload=empty,tls_client_hello,http_req --lua-desync=wssize:wsize=1:scale=6:forced_cutoff=tls_client_hello,http_req '
        if ($isClean) {
            return ($wsPrefix + '--out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_max --payload=http_req --lua-desync=multisplit:pos=1,midsld')
        }
        return ($wsPrefix + "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}:repeats=4 --lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_max --payload=http_req --lua-desync=fake:blob=fake_default_http:${fOpt}:repeats=4 --lua-desync=multisplit:pos=1,midsld")
    }

    switch ($TechId) {
        'base_split' {
            if ($isClean) {
                if ($IncludeHttp) {
                    return '--out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=multidisorder:pos=1,midsld'
                }
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld${ipIdSuffix}"
            }
            if ($IncludeHttp) {
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}:repeats=4 --payload=http_req --lua-desync=fake:blob=fake_default_http:${fOpt}:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}${ipIdSuffix}:repeats=4 --lua-desync=multisplit:pos=1,midsld${ipIdSuffix}"
        }
        'multisplit_seqovl' {
            if ($isClean) {
                if ($IncludeHttp) {
                    return '--out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google --payload=http_req --lua-desync=multisplit:pos=1,midsld'
                }
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google${ipIdSuffix}"
            }
            if ($IncludeHttp) {
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}:repeats=4 --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google --payload=http_req --lua-desync=fake:blob=fake_default_http:${fOpt}:repeats=4 --lua-desync=multisplit:pos=1,midsld"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}${ipIdSuffix}:repeats=4 --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google${ipIdSuffix}"
        }
        'multidisorder_seqovl' {
            if ($isClean) {
                if ($IncludeHttp) {
                    return '--out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=multidisorder:pos=midsld:seqovl=host'
                }
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=multidisorder:pos=midsld:seqovl=host${ipIdSuffix}"
            }
            if ($IncludeHttp) {
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}:repeats=4 --payload=http_req --lua-desync=fake:blob=fake_default_http:${fOpt}:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multidisorder:pos=midsld:seqovl=host"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:${fOpt}${ipIdSuffix}:repeats=4 --lua-desync=multidisorder:pos=midsld:seqovl=host${ipIdSuffix}"
        }
        'hostfakesplit' {
            $hfFool = if ($isClean) { '' } else { ":${fOpt}" }
            if ($IncludeHttp) {
                $httpPart = if ($isClean) {
                    '--payload=http_req --lua-desync=multisplit:pos=1,midsld'
                } else {
                    "--payload=http_req --lua-desync=fake:blob=fake_default_http:${fOpt}:repeats=4 --lua-desync=multisplit:pos=1,midsld"
                }
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=hostfakesplit:host=google.com:midhost=midsld:disorder_after${hfFool} $httpPart"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=hostfakesplit:host=google.com:midhost=midsld:disorder_after${hfFool}${ipIdSuffix}"
        }
        'fakeddisorder' {
            $fdFool = if ($isClean) { '' } else { ":${fOpt}" }
            if ($IncludeHttp) {
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fakeddisorder:pos=midsld:blob=tls_google:tls_mod=rnd,dupsid${fdFool} --payload=http_req --lua-desync=fakeddisorder:pos=midsld:blob=fake_default_http${fdFool}"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=fakeddisorder:pos=midsld:blob=tls_google:tls_mod=rnd,dupsid${fdFool}${ipIdSuffix}"
        }
        'tls_clone' {
            $clFool = if ($isClean) { '' } else { ":${fOpt}" }
            if ($IncludeHttp) {
                return "--out-range=-d10 --payload=tls_client_hello --lua-desync=tls_client_hello_clone:blob=tls_cloned:fallback=tls_google:sni_del:sni_first=${sniFakeHost} --lua-desync=fake:blob=tls_cloned:tls_mod=rnd,dupsid${clFool}:repeats=4 --payload=http_req --lua-desync=fake:blob=fake_default_http${clFool}:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld"
            }
            return "--out-range=-d10 --payload=tls_client_hello --lua-desync=tls_client_hello_clone:blob=tls_cloned:fallback=tls_google:sni_del:sni_first=${sniFakeHost} --lua-desync=fake:blob=tls_cloned:tls_mod=rnd,dupsid${clFool}${ipIdSuffix}:repeats=4 --lua-desync=multisplit:pos=1,midsld${ipIdSuffix}"
        }
        default {
            return '--out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=multidisorder:pos=1,midsld'
        }
    }
}

function Build-Z2BuilderBatContent {
    param(
        [string]$FoolingId,
        [string]$TechId,
        [bool]$UseWssize = $false,
        [string]$UdpMode = 'fake',
        [string]$RecipeNote = ''
    )
    $fDef = $FoolingById[$FoolingId]
    $needsTcpIn = ($UseWssize -or ($null -ne $fDef -and [bool]$fDef.NeedsTcpIn))
    $tcpEmptyFlag = if ($UseWssize) { '--wf-tcp-empty=1 ' } else { '' }
    $tcpInFlag = if ($needsTcpIn) { '--wf-tcp-in=80,443,2053,2083,2087,2096,8443 ' } else { '' }
    $inRangePrefix = if ($needsTcpIn) { '--in-range=-s4096 ' } else { '' }

    $udpQuicDesync = if ($UdpMode -eq 'udplen') { '--lua-desync=udplen:increment=4' } else { '--lua-desync=fake:blob=quic_google:repeats=6' }
    $udpDiscDesync = if ($UdpMode -eq 'udplen') { '--lua-desync=udplen:increment=4' } else { '--lua-desync=fake:blob=discord_udp:repeats=6' }

    $dcMediaChain = Get-Z2BuilderTcpChain -FoolingId $FoolingId -TechId $TechId -IncludeHttp $false -IsGoogle $false -UseWssize $false
    $googleChain  = Get-Z2BuilderTcpChain -FoolingId $FoolingId -TechId $TechId -IncludeHttp $false -IsGoogle $true  -UseWssize $false
    $generalChain = Get-Z2BuilderTcpChain -FoolingId $FoolingId -TechId $TechId -IncludeHttp $true  -IsGoogle $false -UseWssize $false
    $ipsetChain   = Get-Z2BuilderTcpChain -FoolingId $FoolingId -TechId $TechId -IncludeHttp $true  -IsGoogle $false -UseWssize $UseWssize
    $ipsetL7Flag  = if ($UseWssize) { '' } else { '--filter-l7=http,tls ' }

    $tsNow = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $wsLbl = if ($UseWssize) { 'on' } else { 'off' }
    $hdrNote = if ([string]::IsNullOrWhiteSpace($RecipeNote)) {
        "fooling=$FoolingId | tech=$TechId | wssize=$wsLbl | udp=$UdpMode"
    } else {
        $RecipeNote
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    $lines.Add('chcp 65001 > nul')
    $lines.Add(":: Custom strategy built by Zapret2 Kotek Strategy Builder ($tsNow)")
    $lines.Add(":: Recipe: $hdrNote")
    $lines.Add('')
    $lines.Add('if not defined ROOT set "ROOT=%~dp0"')
    $lines.Add('if exist "%~dp0..\utils\service.bat" set "ROOT=%~dp0..\"')
    $lines.Add('if exist "%~dp0..\utils\service.bat" cd /d "%ROOT%"')
    $lines.Add('call "%ROOT%utils\service.bat" status_zapret')
    $lines.Add('call "%ROOT%utils\service.bat" check_updates')
    $lines.Add('call "%ROOT%utils\service.bat" load_game_filter')
    $lines.Add('call "%ROOT%utils\service.bat" load_user_lists')
    $lines.Add('echo:')
    $lines.Add('')
    $lines.Add('chcp 65001 > nul')
    $lines.Add('if not defined GameFilterTCP set "GameFilterTCP=12"')
    $lines.Add('if not defined GameFilterUDP set "GameFilterUDP=12"')
    $lines.Add('set "BIN=%ROOT%bin\"')
    $lines.Add('set "LISTS=%ROOT%lists\"')
    $lines.Add('set "LUA=%ROOT%lua\"')
    $lines.Add('if not exist "%LUA%zapret-lib.lua" if exist "%BIN%lua\zapret-lib.lua" set "LUA=%BIN%lua\"')
    $lines.Add('if not exist "%LUA%zapret-lib.lua" if exist "%BIN%zapret-lib.lua" set "LUA=%BIN%"')
    $lines.Add('set "DISCORD_FAKE=%BIN%ACTIVE_DISCORD_UDP.bin"')
    $lines.Add('if not exist "%DISCORD_FAKE%" set "DISCORD_FAKE=%BIN%quic_initial_www_google_com.bin"')
    $lines.Add('set "GAME_FAKE=%BIN%ACTIVE_GAME_UDP.bin"')
    $lines.Add('if not exist "%GAME_FAKE%" set "GAME_FAKE=%BIN%quic_initial_www_google_com.bin"')
    $lines.Add('cd /d "%BIN%"')
    $lines.Add('')
    $lines.Add(('start "zapret2: %~n0" /min "%BIN%winws2.exe" ' + $tcpEmptyFlag + $tcpInFlag + '--wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,500,1701,2408,4500,19294-19344,50000-50100,%GameFilterUDP% ^'))
    $lines.Add('--lua-init=@"%LUA%zapret-lib.lua" --lua-init=@"%LUA%zapret-antidpi.lua" ^')
    $lines.Add('--blob=quic_google:@"%BIN%quic_initial_www_google_com.bin" --blob=wg_init:@"%BIN%wireguard_initiation.bin" --blob=discord_udp:@"%DISCORD_FAKE%" --blob=tls_google:@"%BIN%tls_clienthello_www_google_com.bin" --blob=tls_max:@"%BIN%tls_clienthello_max_ru.bin" --blob=game_udp:@"%GAME_FAKE%" ^')
    $lines.Add("--filter-udp=443 --filter-l7=quic --hostlist=`"%LISTS%list-general.txt`" --hostlist=`"%LISTS%list-general-user.txt`" --hostlist-exclude=`"%LISTS%list-exclude.txt`" --hostlist-exclude=`"%LISTS%list-exclude-user.txt`" --ipset-exclude=`"%LISTS%ipset-exclude.txt`" --ipset-exclude=`"%LISTS%ipset-exclude-user.txt`" --out-range=-d10 --payload=quic_initial $udpQuicDesync --new ^")
    $lines.Add('--filter-udp=500,1701,2408,4500 --filter-l7=wireguard,stun,unknown --out-range=-d4 --payload=wireguard_initiation,wireguard_keepalive,stun,unknown --lua-desync=fake:blob=wg_init:payload=all:repeats=6 --new ^')
    $lines.Add("--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --out-range=-d4 --payload=discord_ip_discovery,stun $udpDiscDesync --new ^")
    $lines.Add("--filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --hostlist-domains=discord.media ${inRangePrefix}${dcMediaChain} --new ^")
    $lines.Add("--filter-tcp=443 --filter-l7=tls --hostlist=`"%LISTS%list-google.txt`" ${inRangePrefix}${googleChain} --new ^")
    $lines.Add("--filter-tcp=80,443 --filter-l7=http,tls --hostlist=`"%LISTS%list-general.txt`" --hostlist=`"%LISTS%list-general-user.txt`" --hostlist-exclude=`"%LISTS%list-exclude.txt`" --hostlist-exclude=`"%LISTS%list-exclude-user.txt`" --ipset-exclude=`"%LISTS%ipset-exclude.txt`" --ipset-exclude=`"%LISTS%ipset-exclude-user.txt`" ${inRangePrefix}${generalChain} --new ^")
    $lines.Add("--filter-udp=443 --filter-l7=quic --ipset=`"%LISTS%ipset-all.txt`" --hostlist-exclude=`"%LISTS%list-exclude.txt`" --hostlist-exclude=`"%LISTS%list-exclude-user.txt`" --ipset-exclude=`"%LISTS%ipset-exclude.txt`" --ipset-exclude=`"%LISTS%ipset-exclude-user.txt`" --out-range=-d10 --payload=quic_initial $udpQuicDesync --new ^")
    $lines.Add("--filter-tcp=80,443,8443 ${ipsetL7Flag}--ipset=`"%LISTS%ipset-all.txt`" --hostlist-exclude=`"%LISTS%list-exclude.txt`" --hostlist-exclude=`"%LISTS%list-exclude-user.txt`" --ipset-exclude=`"%LISTS%ipset-exclude.txt`" --ipset-exclude=`"%LISTS%ipset-exclude-user.txt`" ${inRangePrefix}${ipsetChain} --new ^")
    $lines.Add("--filter-tcp=%GameFilterTCP% --ipset=`"%LISTS%ipset-all.txt`" --ipset-exclude=`"%LISTS%ipset-exclude.txt`" --ipset-exclude=`"%LISTS%ipset-exclude-user.txt`" ${inRangePrefix}--out-range=-d4 --payload=known,unknown --lua-desync=multisplit:pos=2,midsld:payload=all --new ^")
    $lines.Add('--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d3 --payload=known,unknown --lua-desync=fake:blob=game_udp:payload=all:repeats=8')

    return (($lines -join "`r`n") + "`r`n")
}

function Invoke-Z2BuilderBuildConf {
    param(
        [string]$BatFile,
        [string]$ConfOut
    )
    if (Test-Path -LiteralPath $ConfOut) {
        Remove-Item -LiteralPath $ConfOut -Force -ErrorAction SilentlyContinue
    }
    $env:Z2_ROOT = $Root
    $env:Z2_BAT = $BatFile
    $env:Z2_CONF = $ConfOut
    $env:Z2_AUTOHOST = '0'
    $env:Z2_SKIP_NLM_AUTO = '1'
    $env:BIN = Join-Path $Root 'bin\'
    $env:LISTS = Join-Path $Root 'lists\'
    $env:LUA = Join-Path $Root 'lua\'
    $env:DISCORD_FAKE = Join-Path $Root 'bin\ACTIVE_DISCORD_UDP.bin'
    $env:GAME_FAKE = Join-Path $Root 'bin\ACTIVE_GAME_UDP.bin'
    $env:GameFilter = '12'
    $env:GameFilterTCP = '12'
    $env:GameFilterUDP = '12'

    try {
        $global:LASTEXITCODE = 0
        & $buildConfScript
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ConfOut)) {
            return $false
        }
        $sz = (Get-Item -LiteralPath $ConfOut).Length
        return ($sz -gt 100)
    } catch {
        return $false
    }
}

function Test-Z2BuilderQuicUdp {
    $quicFile = Join-Path $Root 'bin\quic_initial_www_google_com.bin'
    if (-not (Test-Path -LiteralPath $quicFile)) {
        return [PSCustomObject]@{ Ok = 0; Total = 0; AvgMs = 3000 }
    }
    $payload = $null
    try { $payload = [System.IO.File]::ReadAllBytes($quicFile) } catch { return [PSCustomObject]@{ Ok = 0; Total = 0; AvgMs = 3000 } }
    if ($null -eq $payload -or $payload.Length -lt 64) {
        return [PSCustomObject]@{ Ok = 0; Total = 0; AvgMs = 3000 }
    }

    $hosts = @('www.youtube.com', 'www.google.com')
    $okN = 0
    $sumMs = 0.0
    foreach ($h in $hosts) {
        $udp = $null
        try {
            $addrs = @([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($addrs.Count -eq 0) { continue }
            $ep = New-Object System.Net.IPEndPoint($addrs[0], 443)
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 1600
            $udp.Client.SendTimeout = 1000
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$udp.Send($payload, $payload.Length, $ep)
            $remEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$remEp)
            $sw.Stop()
            if ($null -ne $resp -and $resp.Length -gt 0) {
                $okN++
                $sumMs += $sw.Elapsed.TotalMilliseconds
            }
        } catch {
        } finally {
            if ($null -ne $udp) { try { $udp.Close() } catch {} }
        }
    }
    $avg = if ($okN -gt 0) { [int][Math]::Round($sumMs / $okN) } else { 3000 }
    return [PSCustomObject]@{ Ok = $okN; Total = $hosts.Count; AvgMs = $avg }
}

$script:ActiveWinwsProc = $null

function Invoke-Z2BuilderProbe {
    param(
        [string]$BatFile,
        [object[]]$Targets,
        [string]$Label,
        [switch]$IncludeUdpTest
    )
    if (-not (Invoke-Z2BuilderBuildConf -BatFile $BatFile -ConfOut $tmpConfPath)) {
        Write-Host ("  [X] {0,-38} : ошибка build_service_conf.ps1" -f $Label) -ForegroundColor Red
        return $null
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath $winwsExe -ArgumentList "@`"$tmpConfPath`"" -WindowStyle Hidden -PassThru
        $script:ActiveWinwsProc = $proc
    } catch {
        return $null
    }
    Start-Sleep -Milliseconds 650
    if ($null -eq $proc -or $proc.HasExited) {
        $script:ActiveWinwsProc = $null
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
        Write-Host ("  [X] {0,-38} : winws2.exe завершился сразу" -f $Label) -ForegroundColor Red
        return $null
    }

    $urls = @($Targets | ForEach-Object { $_.Url })
    $ytTotal = @($Targets | Where-Object { $_.Cat -eq 'YT' }).Count
    $dcTotal = @($Targets | Where-Object { $_.Cat -eq 'DC' }).Count
    $heavyRx = 'speed\.cloudflare\.com|^https?://www\.youtube\.com/?$|i\.ytimg\.com/.+maxresdefault\.jpg'
    $curlFmt = '%{url_effective}|%{http_code}|%{time_total}|%{size_download}|%{exitcode}|%{speed_download}'

    $rawLines = @()
    $udpRes = $null
    try {
        if ($curlHasParallel) {
            $cArgs = @('-Z', '--parallel-max', '20')
            for ($ui = 0; $ui -lt $urls.Count; $ui++) {
                if ($ui -gt 0) { $cArgs += '-:' }
                $u = $urls[$ui]
                $tLim = if ($u -match $heavyRx) { '6' } else { '4' }
                $cArgs += @('-4', '-s', '--max-time', $tLim, '-w', ($curlFmt + '\n'), '-o', 'NUL')
                if ($u -eq 'https://one.one.one.one' -or $u -eq 'https://cloudflare-dns.com') {
                    $cArgs += @('-H', $padHdr)
                }
                $cArgs += $u
            }
            try {
                $codesOut = & $curlExe @cArgs 2>$null
                $rawLines = ($codesOut -split "`r?`n")
            } catch {}
        } else {
            foreach ($u in $urls) {
                try {
                    $tLim = if ($u -match $heavyRx) { '6' } else { '4' }
                    $one = if ($u -eq 'https://one.one.one.one' -or $u -eq 'https://cloudflare-dns.com') {
                        & $curlExe -4 -s -H $padHdr -o NUL -w $curlFmt --max-time $tLim $u 2>$null
                    } else {
                        & $curlExe -4 -s -o NUL -w $curlFmt --max-time $tLim $u 2>$null
                    }
                    if ($one) { $rawLines += $one }
                } catch {}
            }
        }
        if ($IncludeUdpTest) {
            $udpRes = Test-Z2BuilderQuicUdp
        }
    } finally {
        if ($null -ne $proc -and -not $proc.HasExited) {
            try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch {}
        }
        $script:ActiveWinwsProc = $null
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
    }

    $okCount = 0
    $ytHits = 0
    $dcHits = 0
    $totalMs = 0.0
    $ytFreezeOk = $false
    $cfFreezeOk = $false

    foreach ($line in $rawLines) {
        $tr = $line.Trim()
        if (-not $tr) { continue }
        $parts = $tr -split '\|'
        if ($parts.Count -lt 3) { continue }
        $uEff = $parts[0].ToLowerInvariant()
        $code = $parts[1].Trim()
        $tStr = $parts[2].Trim().Replace(',', '.')
        $dlBytes = 0L
        if ($parts.Count -ge 4) { [void][long]::TryParse($parts[3].Trim(), [ref]$dlBytes) }
        $secVal = 0.0
        $ms = 500.0
        if ([double]::TryParse($tStr, [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$secVal)) {
            $ms = $secVal * 1000.0
        }
        $isHeavy = ($uEff -match $heavyRx)
        $targetMax = if ($isHeavy) { 6.0 } else { 4.0 }
        $exitOk = $true
        if ($parts.Count -ge 5 -and $parts[4].Trim() -match '^\d+$') {
            $exitOk = ($parts[4].Trim() -eq '0')
        } elseif ($secVal -ge ($targetMax - 0.15)) {
            $exitOk = $false
        }
        $spdBytes = 0.0
        if ($parts.Count -ge 6) {
            [void][double]::TryParse($parts[5].Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $invCulture, [ref]$spdBytes)
        }
        if (-not $exitOk) { continue }
        if ($code -match '^(200|204|301|302|307|308|400|403|404)$') {
            if ($uEff -match '^https?://www\.youtube\.com/?$' -and $code -eq '200' -and $dlBytes -lt 65536) { continue }
            if ($uEff -match 'speed\.cloudflare\.com') {
                $cfMin = if ($uEff -match '262144') { 200000L } else { 50000L }
                if ($dlBytes -lt $cfMin) { continue }
                $cfFreezeOk = $true
            }
            $okCount++
            $totalMs += $ms
            if (($uEff -match 'i\.ytimg\.com/.+maxresdefault\.jpg' -or $uEff -match '^https?://www\.youtube\.com/?$') -and $code -eq '200' -and $dlBytes -ge 65536 -and $spdBytes -ge 40000) {
                $ytFreezeOk = $true
            }
            if ($uEff -match 'youtube\.com|ytimg\.com|ggpht\.com|googleapis\.com|googlevideo\.com|play\.google\.com') { $ytHits++ }
            if ($uEff -match 'discord\.com|discordapp\.com|discordapp\.net|discord\.gg') { $dcHits++ }
        }
    }

    $freezeOk = ($ytFreezeOk -and $cfFreezeOk)
    $avgMs = if ($okCount -gt 0) { [int][Math]::Round($totalMs / $okCount) } else { 3000 }
    $score = ($okCount * 100) + ($(if ($ytFreezeOk) { 60 } else { 0 })) + ($(if ($cfFreezeOk) { 50 } else { 0 })) + ($(if ($dcHits -ge 1) { 25 } else { 0 })) + [Math]::Max(0, [int](40 - ($avgMs / 60.0)))

    $ytFLbl = if ($ytFreezeOk) { 'OK' } else { 'SLOW' }
    $cfFLbl = if ($cfFreezeOk) { 'OK' } else { 'SLOW' }
    $udpSuffix = ''
    if ($null -ne $udpRes -and $udpRes.Total -gt 0) {
        $udpSuffix = " | QUIC:$($udpRes.Ok)/$($udpRes.Total)"
    }
    Write-Host ("  - {0,-38} : {1,2}/{2} | YT-F:{3,-4} CF-16K:{4,-4} | ~{5,4} мс{6}" -f $Label, $okCount, $urls.Count, $ytFLbl, $cfFLbl, $avgMs, $udpSuffix) -ForegroundColor Gray

    return [PSCustomObject]@{
        Label      = $Label
        OkCount    = $okCount
        Total      = $urls.Count
        YtHits     = $ytHits
        YtTotal    = $ytTotal
        DcHits     = $dcHits
        DcTotal    = $dcTotal
        AvgMs      = $avgMs
        YtFreezeOk = $ytFreezeOk
        CfFreezeOk = $cfFreezeOk
        FreezeOk   = $freezeOk
        Score      = $score
        UdpOk      = if ($null -ne $udpRes) { [int]$udpRes.Ok } else { 0 }
        UdpTotal   = if ($null -ne $udpRes) { [int]$udpRes.Total } else { 0 }
        UdpAvgMs   = if ($null -ne $udpRes) { [int]$udpRes.AvgMs } else { 3000 }
    }
}

# ==============================================================================
# DRY-RUN MODE (Safe automated validation: no service stop, no winws2.exe launch)
# ==============================================================================
if ($DryRun) {
    $dryErrs = 0
    try {
        Write-Host "`n  [DRY-RUN] Проверка тестовой матрицы и сборки конфигов в `$env:TEMP (без остановки службы и без winws2.exe)..." -ForegroundColor Yellow

        $dryMatrix = @(
            @{ Stage = 'Stage1'; Fooling = 'clean';   Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @('multidisorder:pos=1,midsld') },
            @{ Stage = 'Stage1'; Fooling = 'badsum';  Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @(':badsum:', 'fake_default_http') },
            @{ Stage = 'Stage1'; Fooling = 'tcp_ts';  Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @('tcp_ts=-600000', 'fake_default_http') },
            @{ Stage = 'Stage1'; Fooling = 'tcp_md5'; Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @(':tcp_md5:', 'fake_default_http') },
            @{ Stage = 'Stage1'; Fooling = 'badseq';  Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @('tcp_seq=-10000:tcp_ack=-66000') },
            @{ Stage = 'Stage1'; Fooling = 'autottl'; Tech = 'base_split';           Wssize = $false; Udp = 'fake';   Expect = @('--wf-tcp-in=', '--in-range=-s4096', 'ip_autottl=-2,3-20') },
            @{ Stage = 'Stage2'; Fooling = 'badsum';  Tech = 'multisplit_seqovl';    Wssize = $false; Udp = 'fake';   Expect = @('multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google') },
            @{ Stage = 'Stage2'; Fooling = 'tcp_ts';  Tech = 'multidisorder_seqovl'; Wssize = $false; Udp = 'fake';   Expect = @('multidisorder:pos=midsld:seqovl=host') },
            @{ Stage = 'Stage2'; Fooling = 'tcp_md5'; Tech = 'hostfakesplit';        Wssize = $false; Udp = 'fake';   Expect = @('hostfakesplit:host=google.com:midhost=midsld:disorder_after') },
            @{ Stage = 'Stage2'; Fooling = 'badseq';  Tech = 'fakeddisorder';        Wssize = $false; Udp = 'fake';   Expect = @('fakeddisorder:pos=midsld') },
            @{ Stage = 'Stage2'; Fooling = 'autottl'; Tech = 'tls_clone';            Wssize = $false; Udp = 'fake';   Expect = @('tls_client_hello_clone:', 'fallback=tls_google', '--wf-tcp-in=') },
            @{ Stage = 'Stage2w'; Fooling = 'badsum'; Tech = 'multisplit_seqovl';    Wssize = $true;  Udp = 'fake';   Expect = @('--wf-tcp-empty=1', 'wssize:wsize=1:scale=6:forced_cutoff=tls_client_hello,http_req', '--wf-tcp-in=') },
            @{ Stage = 'Stage3'; Fooling = 'autottl'; Tech = 'tls_clone';            Wssize = $false; Udp = 'udplen'; Expect = @('udplen:increment=4', 'fake_default_http') }
        )

        Write-Host ("  [*] Матрица конструктора: Stage 1 = {0} fooling, Stage 2 = до 7-8 прогонов (5 техник + wssize), Stage 3 = UDP + CORE (итого <= 16 прогонов)" -f $FoolingDefs.Count) -ForegroundColor Cyan
        Write-Host ("  [*] Быстрых целей: {0}, CORE целей: {1}" -f $FastTargets.Count, $CoreTargets.Count) -ForegroundColor Gray

        $idx = 0
        foreach ($dm in $dryMatrix) {
            $idx++
            $lbl = "$($dm.Stage):$($dm.Fooling)+$($dm.Tech)" + $(if ($dm.Wssize) { '+wssize' } else { '' }) + $(if ($dm.Udp -eq 'udplen') { '+udplen' } else { '' })
            $batContent = Build-Z2BuilderBatContent -FoolingId $dm.Fooling -TechId $dm.Tech -UseWssize ([bool]$dm.Wssize) -UdpMode $dm.Udp -RecipeNote "DryRun $lbl"
            [System.IO.File]::WriteAllText($tmpBatPath, $batContent, $utf8NoBom)

            $okConf = Invoke-Z2BuilderBuildConf -BatFile $tmpBatPath -ConfOut $tmpConfPath
            if (-not $okConf) {
                Write-Host ("  [FAIL] [{0}/{1}] {2} — ошибка build_service_conf.ps1" -f $idx, $dryMatrix.Count, $lbl) -ForegroundColor Red
                $dryErrs++
                continue
            }
            $confRaw = [System.IO.File]::ReadAllText($tmpConfPath, [System.Text.Encoding]::UTF8)
            $missingToks = @()
            foreach ($expTok in $dm.Expect) {
                if (-not $confRaw.Contains($expTok)) { $missingToks += $expTok }
            }
            if ($dm.Wssize) {
                $idxWs = $confRaw.IndexOf('--lua-desync=wssize:')
                $idxMs = $confRaw.IndexOf('--lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_max')
                if ($idxWs -lt 0 -or $idxMs -lt 0 -or $idxWs -ge $idxMs) {
                    $missingToks += 'wssize-before-multisplit-order'
                }
            }
            if ($missingToks.Count -gt 0) {
                Write-Host ("  [FAIL] [{0}/{1}] {2} — не найдено в conf: {3}" -f $idx, $dryMatrix.Count, $lbl, ($missingToks -join ', ')) -ForegroundColor Red
                $dryErrs++
            } else {
                Write-Host ("  [OK]   [{0}/{1}] {2} — шаблон .bat и service.conf валидны" -f $idx, $dryMatrix.Count, $lbl) -ForegroundColor Green
            }
        }
    } finally {
        $env:Z2_SKIP_NLM_AUTO = $null
        $env:Z2_AUTOHOST = $null
        if (Test-Path -LiteralPath $tmpBatPath) { Remove-Item -LiteralPath $tmpBatPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpConfPath) { Remove-Item -LiteralPath $tmpConfPath -Force -ErrorAction SilentlyContinue }
    }

    if ($dryErrs -gt 0) {
        Write-Host "`n  [X] DryRun завершён с ошибками: $dryErrs" -ForegroundColor Red
        exit 1
    }
    Write-Host "`n  [OK] DryRun успешно пройден: все $($dryMatrix.Count) шаблонов и build_service_conf.ps1 валидны." -ForegroundColor Green
    exit 0
}

# ==============================================================================
# LIVE EXECUTION MODE
# ==============================================================================
if (-not (Test-Path -LiteralPath $winwsExe)) {
    Write-Host "  [X] Не найден бинарник $winwsExe" -ForegroundColor Red
    exit 1
}

$preSvc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
$wasRunning = ($null -ne $preSvc -and $preSvc.Status -eq 'Running')
if ($null -ne $preSvc) { try { $preSvc.Dispose() } catch {} }

Write-Host "`n  [*] Останавливаю текущую службу zapret на время работы конструктора..." -ForegroundColor Gray
Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000

$appliedNewStrategy = $false
$exitCode = 0
$stepCur = 0
$stepEstTotal = 16

try {
    # --------------------------------------------------------------------------
    # STAGE 1: Fooling reconnaissance (6 runs on 4 key targets)
    # --------------------------------------------------------------------------
    Write-Host "`n  [ЭТАП 1/3] Разведка fooling-механик (6 прогонов по 4 ключевым целям)..." -ForegroundColor Yellow
    $stage1Results = @()
    foreach ($fDef in $FoolingDefs) {
        $stepCur++
        Write-Host ("  [{0}/{1}] Стадия 1 — fooling: {2}..." -f $stepCur, $stepEstTotal, $fDef.Label) -ForegroundColor Cyan
        $batTxt = Build-Z2BuilderBatContent -FoolingId $fDef.Id -TechId 'base_split' -UseWssize $false -UdpMode 'fake'
        [System.IO.File]::WriteAllText($tmpBatPath, $batTxt, $utf8NoBom)
        $res = Invoke-Z2BuilderProbe -BatFile $tmpBatPath -Targets $FastTargets -Label ("S1:" + $fDef.Id)
        if ($null -ne $res) {
            $stage1Results += [PSCustomObject]@{
                FoolingId  = $fDef.Id
                Label      = $fDef.Label
                OkCount    = $res.OkCount
                AvgMs      = $res.AvgMs
                YtFreezeOk = $res.YtFreezeOk
                CfFreezeOk = $res.CfFreezeOk
                FreezeOk   = $res.FreezeOk
                Score      = $res.Score
            }
        }
    }

    if ($stage1Results.Count -eq 0) {
        Write-Host "`n  [X] Не удалось выполнить ни одного прогона на Стадии 1." -ForegroundColor Red
        $exitCode = 1
        throw 'Z2_BUILDER_ABORT'
    }

    $rankedS1 = @($stage1Results | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'OkCount'; Descending = $true }, @{ Expression = 'AvgMs'; Ascending = $true })
    $top2Foolings = @($rankedS1 | Select-Object -First 2)
    Write-Host ("  [*] Топ-2 fooling: #1 {0} ({1}/4, ~{2} мс), #2 {3} ({4}/4, ~{5} мс)" -f `
        $top2Foolings[0].FoolingId, $top2Foolings[0].OkCount, $top2Foolings[0].AvgMs, `
        $(if ($top2Foolings.Count -gt 1) { $top2Foolings[1].FoolingId } else { '—' }), `
        $(if ($top2Foolings.Count -gt 1) { $top2Foolings[1].OkCount } else { 0 }), `
        $(if ($top2Foolings.Count -gt 1) { $top2Foolings[1].AvgMs } else { 0 })) -ForegroundColor Green

    # --------------------------------------------------------------------------
    # STAGE 2: Native zapret2 techniques on top-2 foolings (7 runs + optional 1 wssize)
    # --------------------------------------------------------------------------
    $stage2Plan = New-Object System.Collections.Generic.List[object]
    $f1 = $top2Foolings[0].FoolingId
    $f2 = if ($top2Foolings.Count -gt 1) { $top2Foolings[1].FoolingId } else { '' }

    if ($f1 -eq 'clean') {
        # Fake-free techniques on clean, plus all 5 native techniques on #2 real fooling (total 7)
        foreach ($tid in @('multisplit_seqovl', 'multidisorder_seqovl')) {
            $stage2Plan.Add([PSCustomObject]@{ FoolingId = $f1; TechId = $tid })
        }
        if ($f2) {
            foreach ($td in $TechDefs) {
                $stage2Plan.Add([PSCustomObject]@{ FoolingId = $f2; TechId = $td.Id })
            }
        }
    } else {
        # All 5 native techniques on #1 real fooling
        foreach ($td in $TechDefs) {
            $stage2Plan.Add([PSCustomObject]@{ FoolingId = $f1; TechId = $td.Id })
        }
        # Plus 2 best contrasting techniques on #2 fooling (total 7)
        if ($f2) {
            $f2Techs = if ($f2 -eq 'clean') {
                @('multisplit_seqovl', 'multidisorder_seqovl')
            } else {
                @('multisplit_seqovl', 'hostfakesplit')
            }
            foreach ($tid in $f2Techs) {
                $stage2Plan.Add([PSCustomObject]@{ FoolingId = $f2; TechId = $tid })
            }
        }
    }

    Write-Host "`n  [ЭТАП 2/3] Подбор нативных техник zapret2 на топ-2 fooling ($($stage2Plan.Count) прогонов)..." -ForegroundColor Yellow
    $stage2Results = @()
    foreach ($cand in $stage2Plan) {
        $stepCur++
        $tLbl = "$($cand.FoolingId) + $($TechById[$cand.TechId].Label)"
        Write-Host ("  [{0}/{1}] Стадия 2 — {2}..." -f $stepCur, $stepEstTotal, $tLbl) -ForegroundColor Cyan
        $batTxt = Build-Z2BuilderBatContent -FoolingId $cand.FoolingId -TechId $cand.TechId -UseWssize $false -UdpMode 'fake'
        [System.IO.File]::WriteAllText($tmpBatPath, $batTxt, $utf8NoBom)
        $res = Invoke-Z2BuilderProbe -BatFile $tmpBatPath -Targets $FastTargets -Label ("S2:$($cand.FoolingId)+$($cand.TechId)")
        if ($null -ne $res) {
            $stage2Results += [PSCustomObject]@{
                FoolingId  = $cand.FoolingId
                TechId     = $cand.TechId
                UseWssize  = $false
                OkCount    = $res.OkCount
                AvgMs      = $res.AvgMs
                YtFreezeOk = $res.YtFreezeOk
                CfFreezeOk = $res.CfFreezeOk
                FreezeOk   = $res.FreezeOk
                Score      = $res.Score
            }
        }
    }

    if ($stage2Results.Count -eq 0) {
        Write-Host "`n  [X] Не удалось выполнить ни одного прогона на Стадии 2." -ForegroundColor Red
        $exitCode = 1
        throw 'Z2_BUILDER_ABORT'
    }

    $rankedS2 = @($stage2Results | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'OkCount'; Descending = $true }, @{ Expression = 'AvgMs'; Ascending = $true })
    $bestS2 = $rankedS2[0]

    # Optional 16KB anti-freeze wssize pass if Cloudflare 16KB freeze is detected on best candidate
    $useWssizeFinal = $false
    if (-not $bestS2.CfFreezeOk) {
        $stepCur++
        Write-Host ("  [{0}/{1}] Стадия 2b — обнаружен 16-КБ фриз на {2}+{3}, проверяю антифриз wssize..." -f $stepCur, $stepEstTotal, $bestS2.FoolingId, $bestS2.TechId) -ForegroundColor Yellow
        $batWs = Build-Z2BuilderBatContent -FoolingId $bestS2.FoolingId -TechId $bestS2.TechId -UseWssize $true -UdpMode 'fake'
        [System.IO.File]::WriteAllText($tmpBatPath, $batWs, $utf8NoBom)
        $wsRes = Invoke-Z2BuilderProbe -BatFile $tmpBatPath -Targets $FastTargets -Label ("S2w:$($bestS2.FoolingId)+wssize")
        if ($null -ne $wsRes -and ($wsRes.CfFreezeOk -or $wsRes.Score -gt $bestS2.Score)) {
            $useWssizeFinal = $true
            $bestS2 = [PSCustomObject]@{
                FoolingId  = $bestS2.FoolingId
                TechId     = $bestS2.TechId
                UseWssize  = $true
                OkCount    = $wsRes.OkCount
                AvgMs      = $wsRes.AvgMs
                YtFreezeOk = $wsRes.YtFreezeOk
                CfFreezeOk = $wsRes.CfFreezeOk
                FreezeOk   = $wsRes.FreezeOk
                Score      = $wsRes.Score
            }
            Write-Host '  [*] Антифриз wssize улучшил результат — включён на профиле ipset-all.txt!' -ForegroundColor Green
        } else {
            Write-Host '  [*] wssize не дал выигрыша — оставляю без wssize для максимальной скорости.' -ForegroundColor Gray
        }
    }

    Write-Host ("  [*] Лучшая TCP-комбинация: {0} + {1}{2} ({3}/4, ~{4} мс)" -f `
        $bestS2.FoolingId, $bestS2.TechId, $(if ($useWssizeFinal) { ' + wssize' } else { '' }), $bestS2.OkCount, $bestS2.AvgMs) -ForegroundColor Green

    # --------------------------------------------------------------------------
    # STAGE 3: UDP comparison (fake:repeats=6 vs udplen:increment=4) + final build & CORE verification
    # --------------------------------------------------------------------------
    $stepEstTotal = $stepCur + 3
    Write-Host "`n  [ЭТАП 3/3] Сравнение UDP-профилей (fake:repeats=6 vs udplen:increment=4)..." -ForegroundColor Yellow
    $udpScores = @{}
    foreach ($uMode in @('fake', 'udplen')) {
        $stepCur++
        $uLbl = if ($uMode -eq 'udplen') { 'udplen:increment=4' } else { 'fake:repeats=6' }
        Write-Host ("  [{0}/{1}] Стадия 3 — UDP-профиль: {2}..." -f $stepCur, $stepEstTotal, $uLbl) -ForegroundColor Cyan
        $batUdp = Build-Z2BuilderBatContent -FoolingId $bestS2.FoolingId -TechId $bestS2.TechId -UseWssize $useWssizeFinal -UdpMode $uMode
        [System.IO.File]::WriteAllText($tmpBatPath, $batUdp, $utf8NoBom)
        $uRes = Invoke-Z2BuilderProbe -BatFile $tmpBatPath -Targets $FastTargets -Label ("S3:udp_$uMode") -IncludeUdpTest
        $udpScores[$uMode] = $uRes
    }

    $chosenUdp = 'fake'
    $rFake = $udpScores['fake']
    $rUdplen = $udpScores['udplen']
    if ($null -ne $rUdplen) {
        if ($null -eq $rFake) {
            $chosenUdp = 'udplen'
        } else {
            $uFakeMetric = ($rFake.UdpOk * 1000) + $rFake.Score - [int]($rFake.UdpAvgMs / 20.0)
            $uLenMetric  = ($rUdplen.UdpOk * 1000) + $rUdplen.Score - [int]($rUdplen.UdpAvgMs / 20.0)
            if ($rUdplen.UdpOk -gt $rFake.UdpOk -or ($rUdplen.UdpOk -eq $rFake.UdpOk -and $rUdplen.UdpOk -gt 0 -and $uLenMetric -gt $uFakeMetric)) {
                $chosenUdp = 'udplen'
            }
        }
    }
    $chosenUdpLbl = if ($chosenUdp -eq 'udplen') { 'udplen:increment=4' } else { 'fake:repeats=6' }
    Write-Host "  [*] Выбран UDP-профиль: $chosenUdpLbl" -ForegroundColor Green

    $wsTag = if ($useWssizeFinal) { 'wssize=on' } else { 'wssize=off' }
    $recipeSummary = "fooling=$($bestS2.FoolingId) | tech=$($bestS2.TechId) | $wsTag | udp=$chosenUdpLbl"
    $finalBatTxt = Build-Z2BuilderBatContent -FoolingId $bestS2.FoolingId -TechId $bestS2.TechId -UseWssize $useWssizeFinal -UdpMode $chosenUdp -RecipeNote $recipeSummary
    [System.IO.File]::WriteAllText($outBatPath, $finalBatTxt, $utf8NoBom)
    Write-Host "`n  [*] Собрана стратегия: strategies\custom_built_for_me.bat" -ForegroundColor Yellow
    Write-Host "      Рецепт: $recipeSummary" -ForegroundColor Gray

    # Final full CORE verification
    $stepCur++
    Write-Host ("  [{0}/{1}] Финальная проверка custom_built_for_me.bat по {2} целям CORE..." -f $stepCur, $stepCur, $CoreTargets.Count) -ForegroundColor Cyan
    $coreRes = Invoke-Z2BuilderProbe -BatFile $outBatPath -Targets $CoreTargets -Label 'custom_built_for_me.bat (CORE)'

    if ($null -eq $coreRes -or $coreRes.OkCount -le 0) {
        Write-Host "`n  [X] Финальный тест custom_built_for_me.bat показал 0/$($CoreTargets.Count) (проверь сеть/VPN — прежняя служба будет восстановлена)." -ForegroundColor Red
        $exitCode = 1
        throw 'Z2_BUILDER_ABORT'
    }

    # Save score to utils\strategy_scores.json for GUI strategy list
    try {
        $scFile = Join-Path $Root 'utils\strategy_scores.json'
        $scMap = @{}
        if (Test-Path -LiteralPath $scFile) {
            $prevSc = Get-Content -LiteralPath $scFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prevSc) {
                foreach ($pr in $prevSc.PSObject.Properties) { $scMap[$pr.Name] = $pr.Value }
            }
        }
        $scMap['custom_built_for_me.bat'] = [PSCustomObject]@{
            ok      = $coreRes.OkCount
            total   = $coreRes.Total
            ms      = $coreRes.AvgMs
            yt      = ($coreRes.YtHits -ge 2)
            dc      = ($coreRes.DcHits -ge 2)
            ytHits  = $coreRes.YtHits
            ytTotal = $coreRes.YtTotal
            dcHits  = $coreRes.DcHits
            dcTotal = $coreRes.DcTotal
            freeze  = $coreRes.FreezeOk
            ytF     = $coreRes.YtFreezeOk
            cfF     = $coreRes.CfFreezeOk
            ts      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        [System.IO.File]::WriteAllText($scFile, ($scMap | ConvertTo-Json -Depth 4), $utf8NoBom)
    } catch {}

    $frSummary = if ($coreRes.FreezeOk) { 'HD OK' } else { 'SLOW' }
    Write-Host ''
    Write-Host '  ==================================================================' -ForegroundColor Cyan
    Write-Host ("  [ПОБЕДИТЕЛЬ] custom_built_for_me.bat: {0}/{1} | YT:{2}/{3} DC:{4}/{5} | 16-20KB:{6} | ~{7} мс" -f `
        $coreRes.OkCount, $coreRes.Total, $coreRes.YtHits, $coreRes.YtTotal, $coreRes.DcHits, $coreRes.DcTotal, $frSummary, $coreRes.AvgMs) -ForegroundColor Green
    Write-Host "  Рецепт: $recipeSummary" -ForegroundColor Gray
    Write-Host '  ==================================================================' -ForegroundColor Cyan

    $isHeadless = $false
    try { $isHeadless = [Console]::IsInputRedirected } catch { $isHeadless = $true }
    $ans = 'y'
    if (-not $NonInteractive -and -not $isHeadless) {
        try {
            $ans = Read-Host "`n  Применить custom_built_for_me.bat в службу zapret прямо сейчас? [Д/н] (Enter = Да)"
        } catch {
            $ans = 'y'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ans) -or $ans -notmatch '^[nNнН]') {
        # Clear temporary builder overrides before applying live service config
        $env:Z2_SKIP_NLM_AUTO = $null
        $env:Z2_AUTOHOST = $null
        Write-Host "`n  [*] Применяю custom_built_for_me.bat через utils\apply_strategy.ps1..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        & $applyScript -Root $Root -BatPath $outBatPath
        if ($LASTEXITCODE -eq 0) {
            $appliedNewStrategy = $true
            Write-Host "  [OK] custom_built_for_me.bat ($($coreRes.OkCount)/$($coreRes.Total), ~$($coreRes.AvgMs) мс) установлена и запущена!" -ForegroundColor Green
        } else {
            Write-Host "  [X] Не удалось применить custom_built_for_me.bat (код $LASTEXITCODE) — восстанавливаю прежнюю службу." -ForegroundColor Red
            $exitCode = 1
        }
    } else {
        Write-Host '  [OK] Стратегия сохранена в strategies\custom_built_for_me.bat (служба возвращена в исходное состояние).' -ForegroundColor Green
    }
} catch {
    if ($_.Exception.Message -ne 'Z2_BUILDER_ABORT') {
        Write-Host "  [X] Ошибка конструктора: $($_.Exception.Message)" -ForegroundColor Red
    }
    if ($exitCode -eq 0) { $exitCode = 1 }
} finally {
    $env:Z2_SKIP_NLM_AUTO = $null
    $env:Z2_AUTOHOST = $null
    if ($null -ne $script:ActiveWinwsProc -and -not $script:ActiveWinwsProc.HasExited) {
        try { $script:ActiveWinwsProc.Kill(); [void]$script:ActiveWinwsProc.WaitForExit(3000) } catch {}
    }
    $script:ActiveWinwsProc = $null
    if (Test-Path -LiteralPath $tmpBatPath) { Remove-Item -LiteralPath $tmpBatPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tmpConfPath) { Remove-Item -LiteralPath $tmpConfPath -Force -ErrorAction SilentlyContinue }
    if (-not $appliedNewStrategy) {
        Stop-Z2ServiceAndProcess -ServiceName 'zapret' -ServiceTimeoutSec 5 -ProcessTimeoutMs 3000
        if ($wasRunning) {
            Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
        }
    }
}
exit $exitCode
