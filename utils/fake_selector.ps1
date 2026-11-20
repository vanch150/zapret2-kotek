param(
    [string]$Action = 'menu',
    [string]$Root = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Root) { $Root = $env:Z2_ROOT }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = $Root.Trim('"', "'", '\', '/') + '\'
$BinDir = Join-Path $Root 'bin'
$LuaDir = Join-Path $Root 'lua'
$WinwsExe = Join-Path $BinDir 'winws2.exe'

$Curated = @(
    @{ Id = 1;  File = 'quic_initial_www_google_com.bin';          Desc = 'Google QUIC Initial (Универсальный эталон для Discord и игр)' },
    @{ Id = 2;  File = 'quic_initial_vk_com.bin';                  Desc = 'VK QUIC Initial (Отечественный белый SNI)' },
    @{ Id = 3;  File = 'quic_initial_rutube_ru.bin';               Desc = 'Rutube QUIC Initial (Белый РФ SNI — Flowseal 1.10.4)' },
    @{ Id = 4;  File = 'quic_initial_5ka_ru.bin';                  Desc = '5ka.ru QUIC Initial (Белый РФ SNI — Flowseal 1.10.4)' },
    @{ Id = 5;  File = 'quic_initial_steamstatic_com.bin';         Desc = 'SteamStatic QUIC Initial (Игровой белый SNI — Flowseal 1.10.4)' },
    @{ Id = 6;  File = 'quic_initial_4pda_to.bin';                 Desc = '4PDA QUIC Initial (Классический фейк из набора Flowseal)' },
    @{ Id = 7;  File = 'dtls_clienthello_w3_org.bin';              Desc = 'DTLS ClientHello (Для голоса Discord и WebRTC)' },
    @{ Id = 8;  File = 'discord-ip-discovery-with-port.bin';       Desc = 'Нативный пакет Discord IP Discovery (74 байта)' },
    @{ Id = 9;  File = 'quic_initial_rutracker_org_kyber_1.bin';   Desc = 'Post-Quantum Kyber QUIC Initial (Крупный современный пакет)' },
    @{ Id = 10; File = 'stun2.bin';                                Desc = 'STUN Binding Request v2 (Резервный для голоса и RTC)' },
    @{ Id = 11; File = 'stun.bin';                                 Desc = 'STUN Binding Request v1 (Компактный резервный пакет)' }
)

function Set-ActiveUdpFake([string]$FileName) {
    $src = Join-Path $BinDir $FileName
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    Copy-Item -LiteralPath $src -Destination (Join-Path $BinDir 'ACTIVE_DISCORD_UDP.bin') -Force
    Copy-Item -LiteralPath $src -Destination (Join-Path $BinDir 'ACTIVE_GAME_UDP.bin') -Force
    [System.IO.File]::WriteAllText((Join-Path $Root 'utils\active_udp_fake.txt'), $FileName, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Resolve-StunIpv4Targets {
    $hosts = @('stun.l.google.com', 'stun1.l.google.com', 'stun2.l.google.com')
    $ips = New-Object System.Collections.Generic.List[string]
    foreach ($h in $hosts) {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
            foreach ($a in $addrs) {
                $s = $a.IPAddressToString
                if (-not $ips.Contains($s)) {
                    $ips.Add($s)
                    break
                }
            }
        } catch {}
        if ($ips.Count -ge 2) { break }
    }
    if ($ips.Count -eq 0) {
        $ips.Add('74.125.250.129')
        $ips.Add('142.250.21.127')
    }
    return $ips
}

function Test-StunIpv4([string]$Ip, [int]$Port = 19302, [int]$TimeoutMs = 700) {
    $udp = $null
    try {
        # RFC 5389 STUN Binding Request (20 bytes): Type 0x0001, Len 0x0000, Magic Cookie 0x2112A442 + 12B TxID
        $req = New-Object byte[] 20
        $req[0] = 0x00; $req[1] = 0x01; $req[2] = 0x00; $req[3] = 0x00
        $req[4] = 0x21; $req[5] = 0x12; $req[6] = 0xA4; $req[7] = 0x42
        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        $txId = New-Object byte[] 12
        $rng.GetBytes($txId); $rng.Dispose()
        [System.Buffer]::BlockCopy($txId, 0, $req, 8, 12)

        $udp = New-Object System.Net.Sockets.UdpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
        $udp.Client.SendTimeout = $TimeoutMs
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $targetEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Ip), $Port)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($req, $req.Length, $targetEp)
        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remoteEp)
        $sw.Stop()

        if ($resp -and $resp.Length -ge 20 -and $resp[0] -eq 0x01 -and $resp[1] -eq 0x01) {
            return @{ Ok = $true; RttMs = [int]$sw.ElapsedMilliseconds }
        }
    } catch {
    } finally {
        if ($udp) { try { $udp.Close() } catch {} }
    }
    return @{ Ok = $false; RttMs = 9999 }
}

function Invoke-AutoPickUdpFake {
    Write-Host "        [*] Живой тест приоритетных UDP-фейков через winws2.exe (IPv4 STUN :19302)..." -ForegroundColor Cyan

    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $wasRunning = ($null -ne $svc -and $svc.Status -eq 'Running')
    if ($wasRunning) {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200

    $stunIps = Resolve-StunIpv4Targets

    # Baseline check without winws2
    $baseHits = 0; $baseRttSum = 0
    foreach ($ip in $stunIps) {
        $rb = Test-StunIpv4 $ip 19302 650
        if ($rb.Ok) { $baseHits++; $baseRttSum += $rb.RttMs }
    }
    if ($baseHits -gt 0) {
        $avgBase = [int]($baseRttSum / $baseHits)
        Write-Host ("        [БАЗА] Без winws2: STUN доступен ({0}/{1}, ~{2} мс)" -f $baseHits, $stunIps.Count, $avgBase) -ForegroundColor DarkGray
    } else {
        Write-Host ("        [БАЗА] Без winws2: STUN заблокирован ТСПУ (0/{0}) — проверяем обход..." -f $stunIps.Count) -ForegroundColor Yellow
    }

    $tmpConf = Join-Path $env:TEMP 'z2_udp_bench_$PID.conf'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $luaSlash = $LuaDir.Replace('\', '/')
    $q = [char]34

    $bestFile = 'quic_initial_www_google_com.bin'
    $bestHits = -1
    $bestRtt = 99999

    foreach ($item in $Curated) {
        $fPath = Join-Path $BinDir $item.File
        if (-not (Test-Path -LiteralPath $fPath)) { continue }

        $blobSlash = $fPath.Replace('\', '/')
        $confLines = @(
            '--wf-udp-out=19294-19344',
            ($q + "--lua-init=@$luaSlash/zapret-lib.lua" + $q),
            ($q + "--lua-init=@$luaSlash/zapret-antidpi.lua" + $q),
            ($q + "--blob=test_udp:@$blobSlash" + $q),
            '--filter-udp=19294-19344',
            '--filter-l7=stun',
            '--payload=stun',
            '--lua-desync=fake:blob=test_udp:repeats=6'
        )
        [System.IO.File]::WriteAllLines($tmpConf, $confLines, $utf8NoBom)

        $proc = $null
        try {
            $proc = Start-Process -FilePath $WinwsExe -ArgumentList "@`"$tmpConf`"" -WorkingDirectory $BinDir -WindowStyle Hidden -PassThru
        } catch {}
        Start-Sleep -Milliseconds 350

        $hits = 0; $rttSum = 0
        foreach ($ip in $stunIps) {
            $r = Test-StunIpv4 $ip 19302 700
            if ($r.Ok) { $hits++; $rttSum += $r.RttMs }
        }

        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 120

        if ($hits -gt 0) {
            $avgRtt = [int]($rttSum / $hits)
            Write-Host ("        - {0,-38} : OK {1}/{2} ({3} мс)" -f $item.File, $hits, $stunIps.Count, $avgRtt) -ForegroundColor Green
            if (($hits -gt $bestHits) -or ($hits -eq $bestHits -and ($avgRtt + 15) -lt $bestRtt)) {
                $bestHits = $hits
                $bestRtt = $avgRtt
                $bestFile = $item.File
            }
        } else {
            Write-Host ("        - {0,-38} : нет ответа (0/{1})" -f $item.File, $stunIps.Count) -ForegroundColor DarkGray
        }
    }

    if (Test-Path -LiteralPath $tmpConf) { Remove-Item -LiteralPath $tmpConf -Force -ErrorAction SilentlyContinue }

    if ($bestHits -le 0) {
        $bestFile = 'quic_initial_www_google_com.bin'
        Write-Host "        [ИНФО] STUN :19302 недоступен ни с одним фейком -> выбран универсальный Google QUIC." -ForegroundColor Yellow
    }

    Set-ActiveUdpFake $bestFile | Out-Null
    Write-Host "        [OK] Выбран лучший UDP-фейк: $bestFile" -ForegroundColor Green
    Write-Host "        [OK] Обновлены bin\ACTIVE_DISCORD_UDP.bin и bin\ACTIVE_GAME_UDP.bin" -ForegroundColor DarkGray

    if ($wasRunning) {
        Start-Service -Name 'zapret' -ErrorAction SilentlyContinue
    }
}

if ($Action -eq 'auto') {
    Invoke-AutoPickUdpFake
    exit 0
}

while ($true) {
    Clear-Host
    $curFake = 'quic_initial_www_google_com.bin'
    $stateFile = Join-Path $Root 'utils\active_udp_fake.txt'
    if (Test-Path -LiteralPath $stateFile) {
        $curFake = (Get-Content -LiteralPath $stateFile -Raw).Trim()
    }
    Write-Host ""
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host "         ОПТИМИЗАТОР UDP-ФЕЙКОВ (Discord и Игры)          " -ForegroundColor Cyan
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host "  Текущий UDP-фейк : $curFake" -ForegroundColor Yellow
    Write-Host "  Целевые файлы    : ACTIVE_DISCORD_UDP.bin, ACTIVE_GAME_UDP.bin"
    Write-Host "  --------------------------------------------------------"
    Write-Host "  [1] Автоподбор лучшего UDP-фейка (живой тест через winws2)" -ForegroundColor Green
    Write-Host "  [2] Выбрать из $($Curated.Count) проверенных UDP-фейков (для Discord / Игр)"
    Write-Host "  [3] Показать все .bin фейки из папки bin\ (Расширенный)"
    Write-Host "  [0] Назад в главное меню"
    Write-Host "  --------------------------------------------------------"
    $ch = Read-Host "  Выберите пункт (0-3)"

    if ($ch -eq '0' -or $ch -eq '') { break }
    elseif ($ch -eq '1') {
        Invoke-AutoPickUdpFake
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '2') {
        Write-Host "`n  --- $($Curated.Count) проверенных UDP-фейков ---" -ForegroundColor Cyan
        foreach ($c in $Curated) {
            Write-Host ("  [{0}] {1,-38} - {2}" -f $c.Id, $c.File, $c.Desc)
        }
        $pick = Read-Host "`n  Введите номер (1-$($Curated.Count), 0 для отмены)"
        $pickNum = 0; $sel = if ([int]::TryParse($pick, [ref]$pickNum)) { $Curated | Where-Object { $_.Id -eq $pickNum } } else { $null }
        if ($sel) {
            if (Set-ActiveUdpFake $sel.File) {
                Write-Host "  [OK] Установлен $($sel.File) в ACTIVE_DISCORD_UDP.bin и ACTIVE_GAME_UDP.bin" -ForegroundColor Green
                $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
                    Write-Host "  [OK] Служба 'zapret' перезапущена." -ForegroundColor Green
                }
            }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
    elseif ($ch -eq '3') {
        $allBins = @(Get-ChildItem -LiteralPath $BinDir -Filter '*.bin' | Where-Object { $_.Name -notlike 'ACTIVE_*' } | Sort-Object Name)
        Write-Host "`n  --- Все доступные .bin фейки ($($allBins.Count)) ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allBins.Count; $i++) {
            Write-Host ("  [{0,2}] {1} ({2} B)" -f ($i + 1), $allBins[$i].Name, $allBins[$i].Length)
        }
        $pick = Read-Host "`n  Введите номер (1-$($allBins.Count), 0 для отмены)"
        $idx = 0
        if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $allBins.Count) {
            $chosen = $allBins[$idx - 1].Name
            Set-ActiveUdpFake $chosen | Out-Null
            Write-Host "  [OK] Установлен $chosen в ACTIVE_DISCORD_UDP.bin и ACTIVE_GAME_UDP.bin" -ForegroundColor Green
            $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Restart-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
                Write-Host "  [OK] Служба 'zapret' перезапущена." -ForegroundColor Green
            }
        }
        Read-Host "`n  Нажмите Enter для продолжения"
    }
}
