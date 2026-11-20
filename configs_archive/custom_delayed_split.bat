@echo off
chcp 65001 > nul
:: Experimental: Delayed ClientHello Split (tcpseg + send:delay=15ms + Timestamp Fake)
:: Separates fake/first segment and full ClientHello in time to evade stateful DPI reassembly

cd /d "%~dp0..\"
call "%ROOT%utils\service.bat" status_zapret
call "%ROOT%utils\service.bat" check_updates
call "%ROOT%utils\service.bat" load_game_filter
call "%ROOT%utils\service.bat" load_user_lists
echo:

chcp 65001 > nul
if not defined GameFilterTCP set "GameFilterTCP=12"
if not defined GameFilterUDP set "GameFilterUDP=12"
set "ROOT=%~dp0..\"
set "BIN=%ROOT%bin\"
set "LISTS=%ROOT%lists\"
set "LUA=%ROOT%lua\"
if not exist "%LUA%zapret-lib.lua" if exist "%BIN%lua\zapret-lib.lua" set "LUA=%BIN%lua\"
if not exist "%LUA%zapret-lib.lua" if exist "%BIN%zapret-lib.lua" set "LUA=%BIN%"
set "DISCORD_FAKE=%BIN%ACTIVE_DISCORD_UDP.bin"
if not exist "%DISCORD_FAKE%" set "DISCORD_FAKE=%BIN%quic_initial_www_google_com.bin"
set "GAME_FAKE=%BIN%ACTIVE_GAME_UDP.bin"
if not exist "%GAME_FAKE%" set "GAME_FAKE=%BIN%quic_initial_www_google_com.bin"
cd /d "%BIN%"

start "zapret2: %~n0" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,500,1701,2408,4500,19294-19344,50000-50100,%GameFilterUDP% ^
--lua-init=@"%LUA%zapret-lib.lua" --lua-init=@"%LUA%zapret-antidpi.lua" ^
--blob=quic_google:@"%BIN%quic_initial_www_google_com.bin" --blob=wg_init:@"%BIN%wireguard_initiation.bin" --blob=discord_udp:@"%DISCORD_FAKE%" --blob=tls_google:@"%BIN%tls_clienthello_www_google_com.bin" --blob=tls_max:@"%BIN%tls_clienthello_max_ru.bin" --blob=game_udp:@"%GAME_FAKE%" ^
--filter-udp=443 --filter-l7=quic --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6 --new ^
--filter-udp=500,1701,2408,4500 --filter-l7=wireguard,stun,unknown --out-range=-d4 --payload=wireguard_initiation,wireguard_keepalive,stun,unknown --lua-desync=fake:blob=wg_init:payload=all:repeats=6 --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --out-range=-d4 --payload=discord_ip_discovery,stun --lua-desync=fake:blob=discord_udp:repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --hostlist-domains=discord.media --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_ts=-600000:repeats=4 --lua-desync=tcpseg:pos=0,midsld --lua-desync=send:delay=15 --lua-desync=drop --new ^
--filter-tcp=443 --filter-l7=tls --hostlist="%LISTS%list-google.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_ts=-600000:ip_id=zero:repeats=4 --lua-desync=tcpseg:pos=0,midsld --lua-desync=send:delay=15 --lua-desync=drop --new ^
--filter-tcp=80,443 --filter-l7=http,tls --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=fake:blob=tls_max:tcp_ts=-600000:repeats=4 --lua-desync=tcpseg:pos=0,midsld --lua-desync=send:delay=15 --lua-desync=drop --new ^
--filter-udp=443 --filter-l7=quic --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6 --new ^
--filter-tcp=80,443,8443 --filter-l7=http,tls --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=fake:blob=tls_max:tcp_ts=-600000:repeats=4 --lua-desync=tcpseg:pos=0,midsld --lua-desync=send:delay=15 --lua-desync=drop --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d4 --payload=known,unknown --lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max:payload=all --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d3 --payload=known,unknown --lua-desync=fake:blob=game_udp:payload=all:repeats=6
