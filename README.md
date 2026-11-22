<p align="center">
  <img src="utils/kotek_happy.png" width="96" alt="Котек" />
</p>

<h1 align="center">Zapret2 Kotek</h1>

<p align="center">
  Настольная сборка <a href="https://github.com/bol-van/zapret2">zapret2</a> для Windows с нормальным интерфейсом, автоподбором стратегий, локальным Telegram-прокси и доступом к ИИ-сервисам.
</p>

<p align="center">
  <a href="https://github.com/vanch150/zapret2-kotek/releases/latest"><strong>Скачать v1.1.0</strong></a> ·
  <a href="https://github.com/vanch150/zapret2-kotek/releases">Все релизы</a> ·
  <a href="#зачем-этот-проект">О проекте</a> ·
  <a href="#быстрый-старт">Установка</a> ·
  <a href="LICENSE">MIT</a>
</p>

![Главное окно Zapret2 Kotek](docs/screenshots/home.png)

## Зачем этот проект

Сам по себе [zapret2](https://github.com/bol-van/zapret2) — отличный инструмент, но в базовом виде это консольная утилита и десятки `.bat`-файлов, которые нужно перебирать вручную, а потом ещё отдельно разбираться с Telegram, нейросетями, сломанным YouTube в браузере и конфликтами с VPN или античитами.

**Zapret2 Kotek** делался как сборка «поставил и забыл» для обычных домашних ПК на Windows 10/11: без возни в терминале, но с открытым кодом и возможностью тонко всё настроить, если нужно.

## Чем отличается от обычных батников

- **Автоматический подбор вместо ручного перебора.** Программа сама тестирует готовые стратегии на вашем интернете (YouTube, Discord, 7TV, Cloudflare) и выбирает рабочую. Если провайдер режет трафик по-разному для разных сервисов, сборка умеет склеить персональный гибридный конфиг из лучших вариантов.
- **Telegram и нейросети без сторонних VPN.** Внутрь встроен собственный локальный MTProto-прокси для Telegram Desktop (написан на C#, работает только на `127.0.0.1`) и точечный обход для ИИ-сервисов (Gemini, ChatGPT, Claude, Copilot, Grok, Perplexity, Cursor / Windsurf). Остальной интернет, банки и игры при этом идут напрямую, системный DNS провайдера не ломается.
- **Уживается с играми и VPN.** Популярные VPN-клиенты (WireGuard, AmneziaWG, OpenVPN) исключаются автоматически и не конфликтуют с обходом. Если нужно зайти в игру со строгим античитом (Vanguard, FACEIT, EAC, BattlEye), обход можно полностью выгрузить вместе с драйвером в один клик, а потом так же вернуть.
- **Всё открыто и проверяется.** Движок `winws2.exe` и драйвер `WinDivert` взяты напрямую из [bol-van/zapret2](https://github.com/bol-van/zapret2), списки и фейки — на базе [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube). Обновления выходят только здесь и проверяются по контрольным суммам `SHA256SUMS.txt`.

> [!WARNING]
> **Про антивирус:** Windows Defender и антивирусы часто отмечают подписанный драйвер `WinDivert` как `HackTool/WinDivert` или `RiskTool`. Это стандартное ложное срабатывание для всех сборок на базе `zapret`. Скачивайте архив только из раздела [Releases](https://github.com/vanch150/zapret2-kotek/releases) этого репозитория и при необходимости добавьте папку программы в исключения.

## Быстрый старт

1. Скачайте `zapret2-kotek-v1.1.0.zip` со страницы [Releases](https://github.com/vanch150/zapret2-kotek/releases/latest) и распакуйте в папку с английским путём (например, `C:\Zapret2`).
2. Запустите `!_START_KOTEK.bat` и подтвердите права администратора.
3. Запустите быструю настройку прямо в открывшемся окне — через 1–2 минуты службы поднимутся и заработают в фоне. После этого окно можно закрыть, при перезагрузке ПК всё стартует само.

Удалить программу полностью (включая службы, драйвер, правила DNS и `hosts`) можно из настроек приложения или файлом `utils\UNINSTALL.bat`.

## Интерфейс

<table>
<tr>
<td width="50%">
<img src="docs/screenshots/strategies.png" alt="Вкладка Стратегии" />
<p align="center"><sub>Стратегии и результаты проверки</sub></p>
</td>
<td width="50%">
<img src="docs/screenshots/settings.png" alt="Вкладка Настройки" />
<p align="center"><sub>Настройки, диагностика и автообновление</sub></p>
</td>
</tr>
<tr>
<td width="50%">
<img src="docs/screenshots/lists_dialog.png" alt="Свои списки сайтов" />
<p align="center"><sub>Редактор своих списков сайтов</sub></p>
</td>
<td width="50%">
<img src="docs/screenshots/nlm_dialog.png" alt="Исключение VPN-адаптеров" />
<p align="center"><sub>Исключение VPN-адаптеров (NLM)</sub></p>
</td>
</tr>
</table>

## Что стоит учитывать

- **Это не VPN.** Программа не шифрует трафик и не скрывает ваш IP-адрес. Она обходит блокировки со стороны провайдера, но не открывает сервисы, которые сами закрыли доступ по региону (исключение — выбранные нейросети в разделе «Обход ИИ»).
- **Блокировки меняются.** Если стратегия перестала помогать, нужно просто запустить подбор заново.
- **YouTube в браузере.** Если видео всё равно тормозит или не грузятся смайлы 7TV, обычно мешает протокол QUIC (HTTP/3) в браузере — в программе есть встроенный переключатель для его отключения с откатом.
- **Приватность.** Сбор анонимных отчётов об ошибках выключен по умолчанию и включается только по желанию пользователя (IP, пути и списки сайтов не отправляются).

<details>
<summary>Под капотом (для тех, кому интересна техническая часть)</summary>

- **Ядро:** `bin\winws2.exe` из [bol-van/zapret2](https://github.com/bol-van/zapret2) (1.0.7), Lua-скрипты (`lua\`) и ядерные фильтры `bin\filters\windivert_part.*`. Списки и `.bin`-фейки на базе [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) (1.10.4).
- **Стратегии:** 10 базовых (`strategies\`) и 12 дополнительных (`configs_archive\`), бенчмарк по 27 целям + 64-КБ проверка по `speed.cloudflare.com`, синтез гибрида (`utils\deep_optimize.ps1`).
- **Telegram Proxy:** C# 5 сервис (`utils\TgWsProxyService.cs`, собирается системным `.NET 4.x csc.exe`), служба `zapret-tgws` под `NT AUTHORITY\NetworkService`, loopback `127.0.0.1:1443`, режимы `smart` / `direct` / `cfonly`, равноправная гонка `ws://:80` и `wss://:443`.
- **Обход ИИ:** точечные правила Windows NRPT (`utils\ai_bypass_helper.ps1`) на пул SmartDNS (`lists\ai-dns-pool.txt`) с автопаузой при активном системном VPN.
- **Автообновление:** `utils\self_update.ps1` с обязательной проверкой `SHA256SUMS.txt` (fail-closed), защитой от Zip-Slip, сохранением пользовательских списков (`*-user.txt`, `ai-custom-domains.txt`, `targets.txt`) и задачей Планировщика в простое ПК.
- **CLI:** для работы без GUI поддерживается `!_START_KOTEK.bat --cli`.

</details>

## Основа проекта и лицензия

Код распространяется под лицензией [MIT](LICENSE). Информация о сторонних компонентах вынесена в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

- [bol-van/zapret2](https://github.com/bol-van/zapret2) (MIT) — движок `winws2.exe`, Lua-библиотеки и ядерные фильтры.
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) (MIT) — базы доменов/IPSet, `.bin`-фейки и базовые стратегии.
- [WinDivert](https://github.com/basil00/WinDivert) (LGPLv3 / GPLv2) — драйвер пакетной фильтрации для Windows.
