@echo off
chcp 65001 > nul
:: 65001 - UTF-8

set "ROOT=%~dp0"
if exist "%~dp0..\utils\service.bat" set "ROOT=%~dp0..\"
cd /d "%ROOT%"
call "%ROOT%utils\service.bat" status_zapret
call "%ROOT%utils\service.bat" check_updates
call "%ROOT%utils\service.bat" load_game_filter
call "%ROOT%utils\service.bat" load_user_lists
echo:

chcp 65001 > nul
if not defined GameFilterTCP set "GameFilterTCP=12"
if not defined GameFilterUDP set "GameFilterUDP=12"
set "BIN=%ROOT%bin\"
set "LISTS=%ROOT%lists\"
set "LUA=%ROOT%lua\"
if not exist "%LUA%zapret-lib.lua" set "LUA=%ROOT%bin\lua\"
if not exist "%LUA%zapret-lib.lua" set "LUA=%BIN%"
set "DISCORD_FAKE=%BIN%ACTIVE_DISCORD_UDP.bin"
if not exist "%DISCORD_FAKE%" set "DISCORD_FAKE=%BIN%quic_initial_www_google_com.bin"
set "GAME_FAKE=%BIN%ACTIVE_GAME_UDP.bin"
if not exist "%GAME_FAKE%" set "GAME_FAKE=%BIN%quic_initial_www_google_com.bin"
cd /d "%BIN%"

start "zapret2: %~n0" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,500,1701,2408,4500,19294-19344,50000-50100,%GameFilterUDP% ^
--lua-init=@"%LUA%zapret-lib.lua" --lua-init=@"%LUA%zapret-antidpi.lua" ^
--blob=quic_google:@"%BIN%quic_initial_www_google_com.bin" --blob=stun:@"%BIN%stun.bin" --blob=wg_init:@"%BIN%wireguard_initiation.bin" --blob=discord_udp:@"%DISCORD_FAKE%" --blob=tls_google:@"%BIN%tls_clienthello_www_google_com.bin" --blob=tls_sferum:@"%BIN%tls_clienthello_www_sferum_ru.bin" --blob=game_udp:@"%GAME_FAKE%" ^
--filter-udp=443 --filter-l7=quic --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11 --new ^
--filter-udp=500,1701,2408,4500 --filter-l7=wireguard,stun,unknown --out-range=-d4 --payload=wireguard_initiation,wireguard_keepalive,stun,unknown --lua-desync=fake:blob=wg_init:payload=all:repeats=6 --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --out-range=-d4 --payload=discord_ip_discovery --lua-desync=fake:blob=stun:repeats=3 --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=3 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --hostlist-domains=discord.media --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=8 --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google --new ^
--filter-tcp=443 --filter-l7=tls --hostlist="%LISTS%list-google.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=hostfakesplit:host=www.google.com:midhost=midsld:tcp_ts=-600000:ip_id=zero --new ^
--filter-tcp=80,443 --filter-l7=http,tls --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun:tcp_ts=-600000:repeats=8 --lua-desync=fake:blob=tls_sferum:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=8 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_ts=-600000:repeats=8 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_sferum --new ^
--filter-udp=443 --filter-l7=quic --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11 --new ^
--filter-tcp=80,443,8443 --filter-l7=http,tls --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun:tcp_ts=-600000:repeats=8 --lua-desync=fake:blob=tls_sferum:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=8 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_ts=-600000:repeats=8 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_sferum --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d4 --payload=tls_client_hello --lua-desync=fake:blob=stun:tcp_ts=-600000:repeats=4 --lua-desync=fake:blob=tls_sferum:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=4 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_ts=-600000:repeats=4 --payload=unknown --lua-desync=fake:blob=stun:payload=all:tcp_ts=-600000:repeats=4 --lua-desync=fake:blob=tls_sferum:payload=all:tcp_ts=-600000:repeats=4 --payload=known,unknown --lua-desync=multisplit:pos=1,midsld:seqovl=664:seqovl_pattern=tls_sferum:payload=all --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d4 --payload=known,unknown --lua-desync=fake:blob=game_udp:payload=all:repeats=10
