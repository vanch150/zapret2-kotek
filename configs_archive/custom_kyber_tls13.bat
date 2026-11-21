@echo off
chcp 65001 > nul
:: 65001 - UTF-8
:: Post-Quantum TLS 1.3 Kyber + Dynamic TLS Mod + Midsld Split

set "ROOT=%~dp0"
if exist "%~dp0..\utils\service.bat" set "ROOT=%~dp0..\"
if exist "%~dp0..\utils\service.bat" cd /d "%ROOT%"
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
if not exist "%DISCORD_FAKE%" set "DISCORD_FAKE=%BIN%quic_initial_rutracker_org_kyber_1.bin"
set "GAME_FAKE=%BIN%ACTIVE_GAME_UDP.bin"
if not exist "%GAME_FAKE%" set "GAME_FAKE=%BIN%quic_initial_rutracker_org_kyber_1.bin"
cd /d "%BIN%"

start "zapret2: %~n0" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,500,1701,2408,4500,19294-19344,50000-50100,%GameFilterUDP% ^
--lua-init=@"%LUA%zapret-lib.lua" --lua-init=@"%LUA%zapret-antidpi.lua" ^
--blob=quic_kyber:@"%BIN%quic_initial_rutracker_org_kyber_1.bin" --blob=quic_gvideo_kyber:@"%BIN%quic_initial_rr1---sn-xguxaxjvh-n8me_googlevideo_com_kyber_1.bin" --blob=wg_init:@"%BIN%wireguard_initiation.bin" --blob=discord_udp:@"%DISCORD_FAKE%" --blob=tls_kyber:@"%BIN%tls_clienthello_rutracker_org_kyber.bin" --blob=tls_vk_kyber:@"%BIN%tls_clienthello_vk_com_kyber.bin" --blob=tls_vk:@"%BIN%tls_clienthello_vk_com.bin" --blob=tls_google:@"%BIN%tls_clienthello_www_google_com.bin" --blob=stun2:@"%BIN%stun2.bin" --blob=game_udp:@"%GAME_FAKE%" ^
--filter-udp=443 --filter-l7=quic --hostlist="%LISTS%list-google.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_gvideo_kyber:repeats=6 --new ^
--filter-udp=443 --filter-l7=quic --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_kyber:repeats=6 --new ^
--filter-udp=500,1701,2408,4500 --filter-l7=wireguard,stun,unknown --out-range=-d4 --payload=wireguard_initiation,wireguard_keepalive,stun,unknown --lua-desync=fake:blob=wg_init:payload=all:repeats=6 --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun,unknown --out-range=-d4 --payload=discord_ip_discovery,stun,unknown --lua-desync=fake:blob=discord_udp:payload=all:repeats=4 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --filter-l7=tls --hostlist-domains=discord.media --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_kyber:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=5 --payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google --new ^
--filter-tcp=80,443 --filter-l7=http,tls --hostlist="%LISTS%list-google.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_google:tls_mod=rnd,dupsid,padencap,sni=www.google.com:tcp_ts=-600000:ip_id=zero:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld --new ^
--filter-tcp=80,443 --filter-l7=http,tls --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=tls_kyber:tls_mod=rnd,dupsid,padencap:tcp_ts=-600000:repeats=4 --payload=http_req --lua-desync=fake:blob=tls_vk_kyber:tcp_ts=-600000:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld:seqovl=517:seqovl_pattern=tls_vk --new ^
--filter-udp=443 --filter-l7=quic --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=quic_initial --lua-desync=fake:blob=quic_kyber:repeats=6 --new ^
--filter-tcp=80,443,8443 --filter-l7=http,tls --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=4 --lua-desync=fake:blob=tls_vk_kyber:tls_mod=rnd,dupsid:tcp_ts=-600000:repeats=4 --payload=http_req --lua-desync=fake:blob=tls_vk_kyber:tcp_ts=-600000:repeats=4 --payload=tls_client_hello,http_req --lua-desync=multisplit:pos=1,midsld --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d4 --payload=tls_client_hello,unknown --lua-desync=fake:blob=stun2:payload=all:tcp_ts=-600000:repeats=3 --payload=known,unknown --lua-desync=multisplit:pos=1:payload=all --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --out-range=-d4 --payload=known,unknown --lua-desync=fake:blob=game_udp:payload=all:repeats=3
