# remnanode-installer

[![CI](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml)

Установщик **Remnawave Node + Caddy Selfsteal** «под ключ» для чистого Debian/Ubuntu.

Один скрипт: зависимости → Docker → тюнинг системы → сеть (1 или 2 IP) → нода →
сайт-заглушка → firewall → DNS-фильтр → автообновление → systemd →
готовые конфиги для панели → проверка.

## Быстрый старт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/install.sh)
```

`-f` важен: если сеть до GitHub недоступна, вы увидите ошибку, а не тихий пустой запуск.

Скрипт спросит (сначала порт ноды, затем панель и **один** порт подключения):

| Вопрос | Значение в `--yes` | Зачем |
|---|---|---|
| Порт ноды | `2222` | внутренний API «панель → нода» |
| IP панели Remnawave | — | порт ноды откроется **только** для этого IP |
| `SECRET_KEY` | — | копируется из панели при создании ноды |
| Порт подключения | `443` | **один** порт на xHTTP, gRPC и TCP; открывается всем |
| Hysteria2 (да/нет) | `да` | UDP на том же порту + сертификат selfsteal |
| Selfsteal (да/нет) | `да` | сайт-заглушка для Reality/TLS |
| Домен | — | A-запись должна указывать на сервер (нужна для Let's Encrypt) |
| Внутренний порт Caddy | `9443` | Reality target: `127.0.0.1:9443` |
| Сайт-заглушка | `studio` | 9 готовых сайтов, см. ниже |
| Схема сети: 1 или 2 IP | `1` | `2` — вход на IP1, выход через IP2 |
| IP входа | автоопределённый | можно указать докупленный адрес (`--ip1`) |
| IP выхода | — | адрес, с которого нода ходит в интернет (`--ip2`) |
| DNS-фильтр AdGuard | `да` | блокировка рекламы и трекеров, DNS-over-TLS |
| Автообновление ноды | `да` | ежедневная проверка + откат при сбое |
| Алерты в Telegram | `нет` | если да — спросит токен бота и chat_id |

**Один порт вместо трёх.** Раньше спрашивались порты для xHTTP, gRPC и TCP по
отдельности — теперь спрашивается один порт подключения (по умолчанию `443`).
Все inbound'ы работают на нём; установщику не важно, какие именно вы создадите
в панели. Порт ноды по-прежнему спрашивается отдельно и открывается только
IP панели.

**Hysteria2 — это hysteria-инбаунд внутри Xray ноды**, отдельный бинарь не
ставится: ядро `remnawave/node` умеет этот протокол. Установщик копирует
сертификат selfsteal в `/opt/remnanode/cert` (в контейнере — `/etc/remnanode/cert`),
открывает UDP на порту подключения и обновляет сертификат по таймеру после
продления Caddy. Включить/выключить позже: `nodego` → 3.

## Неинтерактивный режим

```bash
bash install.sh --yes \
  --node-port 2222 --panel-ip 203.0.113.10 \
  --secret-key 'КЛЮЧ_ИЗ_ПАНЕЛИ' \
  --connect-port 443 --hysteria yes \
  --domain vpn.example.com --template studio \
  --two-ip --ip2 198.51.100.7 \
  --dns yes --autoupdate yes
```

Флаги: `--node-port`, `--panel-ip`, `--secret-key`,
`--connect-port` (один порт для xHTTP/gRPC/TCP), `--hysteria yes|no` /
`--no-hysteria`, `--selfsteal yes|no`, `--no-selfsteal`, `--domain`,
`--selfsteal-port`, `--template`, `--one-ip` / `--two-ip` / `--dual-ip`,
`--ip1`, `--ip2`, `--dns yes|no` / `--no-dns`, `--autoupdate yes|no` /
`--no-autoupdate`, `--alerts yes|no` / `--no-alerts`, `--tg-token`, `--tg-chat`,
`--swap-size auto|off|1024M`, `--yes`, `--reconfigure`, `--skip-tuning`,
`--skip-firewall`, `--skip-netcheck`, `--help`.

Старые флаги `--xhttp-port` / `--grpc-port` / `--tcp-port` принимаются и задают
общий `--connect-port` (первый непустой) — существующие команды установки
продолжают работать.

Повторный запуск с `--yes` без флагов читает сохранённые ответы из
`/etc/remnawave-setup/answers.env`. Переопределить: `--reconfigure`.

## Что делает скрипт

1. **Проверки**: root, Debian/Ubuntu, архитектура, свободное место.
2. **Пакеты**: `apt-get update` + `apt-get upgrade` (noninteractive, confdef/confold)
   и установка curl, wget, jq, ufw, logrotate, dnsutils, cron, gnupg.
3. **Время и NTP** — критично для ACME/TLS.
4. **Docker** — официальный `get.docker.com` + compose v2.
5. **Тюнинг**:
   - **swap подбирается под сервер**: по RAM и свободному диску (см. ниже),
     с записью в `/etc/fstab`, `swappiness=10`;
   - `nofile = 1048576` (хост + drop-in для `docker.service`);
   - sysctl: backlog, буферы, conntrack (+ `hashsize`), `vm.overcommit_memory=1`,
     `fs.nr_open`, `tcp_mtu_probing` (MTU-blackhole в мобильных сетях);
   - BBR + FQ с проверкой поддержки ядра;
   - journald ограничен 500 МБ.
6. **Сеть**: схема с одним IP или «вход IP1 / выход IP2»:
   - адрес IP2 + policy routing (`ip rule`/`ip route table 100`);
   - SNAT **только для новых исходящих соединений**
     (`-m conntrack --ctstate NEW`), поэтому ответы на входящие уходят
     с исходного IP и клиенты не рвутся;
   - systemd-юнит `rw-secondary-ip.service` — восстановление после ребута;
   - проверка фактического исходящего IP.
7. **Firewall (UFW)**:
   - SSH-порт (определяется автоматически);
   - `80/tcp` — если selfsteal (ACME HTTP-01 + редирект);
   - порт подключения `443/tcp` — всем (xHTTP, gRPC, TCP);
   - `443/udp` — если включена Hysteria2;
   - порт ноды — только с IP панели.
8. **Нода** `/opt/remnanode`:
   - `.env` (`NODE_PORT`, `SECRET_KEY`), compose (`remnawave/node:latest`,
     host network, `restart: always`, `cap_add: NET_ADMIN`, ulimits, лог-ротация,
     монтирование `/var/log/remnanode` и `./cert` → `/etc/remnanode/cert`);
   - `remnanode.service` — автозапуск через `docker compose`.
9. **Selfsteal** `/opt/selfsteal`: Caddy на `127.0.0.1:9443`, ACME через 80,
   редирект, security-заголовки, выбранный сайт-заглушка,
   публичный `:80` привязан к основному IP; сертификат копируется в
   `/opt/remnanode/cert` для Hysteria2 (`rw-cert-sync.timer`).
10. **DNS-фильтр AdGuard DoT** (опционально, по вопросу):
    - `DNS=`/`FallbackDNS=` в `/etc/systemd/resolved.conf` **закомментированы**,
      чтобы старые глобальные DNS не перебивали AdGuard;
    - `Domains=~.` — AdGuard используется для всех доменов, а не только для тех,
      что не пришли из DHCP;
    - `/etc/resolv.conf` → `stub-resolv.conf`, cloud-init отключён от его
      управления (`manage_resolv_conf: false`);
    - предупреждение, если другие drop-in'ы в `resolved.conf.d` тоже задают `DNS=`.
11. **Автообновление**: таймер `rw-node-update.timer` (ежедневно ~04:30)
    с откатом на предыдущий образ, если новый контейнер не поднялся;
    плюс `unattended-upgrades` для обновлений безопасности ОС без ребута.
12. **Обслуживание**:
    - `rw-healthcheck.timer` — проверка каждые 5 минут: контейнер, порт ноды, диск,
      conntrack, исходящий IP, число рестартов, срок сертификата;
      алерт в Telegram **только при смене состояния**;
    - `rw-backup.timer` — ежедневный бэкап конфигов в `/var/backups/remnanode`
      (хранится 14 копий), восстановление: `nodego restore`;
    - `logrotate` для логов ноды + cron (docker-логи, неиспользуемые образы);
    - journald ограничен 500 МБ через `journald.conf.d` (без cron-обрезки).
13. **Готовые конфиги** для Config Profile панели — `xHTTP`, `gRPC`, `TCP`
    (+ `Hysteria2`): настоящие `privateKey` из `xray x25519`, случайные
    `shortId`, теги на 8 символов, `target: 127.0.0.1:9443` при selfsteal и
    `serverNames` с доменом (или `apple.com`, если selfsteal нет).
    `hysteria2.json` содержит два инбаунда — hysteria (UDP) и xHTTP+Reality
    (TCP) для Caddy selfsteal; раздавать xHTTP клиентам не обязательно.
    Файлы: `/etc/remnawave-setup/configs/*.json`, показ и обновление — `nodego`.
14. **Проверка**: контейнеры, порты (TCP и UDP), версия ядра Xray, локальный
    запрос к Caddy, статус юнитов и таймеров, исходящий IP, DNS.
15. **Итог**: что нажать в панели.

## Проверка сети перед установкой

До изменения системы скрипт проверяет окружение и предупреждает о проблемах,
которые потом «всплывают» уже после установки:

| Проверка | Что выявляет |
|---|---|
| внешний IP (`ifconfig.io`) | нет выхода в интернет / NAT-адресация |
| A-запись домена | не указывает ни на один адрес сервера (сверяется со всеми адресами интерфейсов, `--ip1` и внешним IP — ложной тревоги при NAT и смене IP не бывает); домен не резолвится |
| ACME: Let's Encrypt | **блокировка у хостера** (частая причина «сайт не открывается») |
| ACME: ZeroSSL | резервный путь, если LE недоступен |
| GitHub raw | не скачаются шаблоны и `nodego` |
| Docker Hub (`registry-1.docker.io`) | не скачаются образы ноды и Caddy |
| панель `IP:PORT` | доступность веб-порта панели — только по явному `--panel-port`; для работы ноды не нужно (соединение всегда панель → нода) |

Пример вывода на проблемном сервере:

```
=== Проверка сети и DNS ===
  [ok] внешний IP: 212.193.0.119
  [ok] DNS: rom.cloudre.store → 212.193.0.119
  [!!] Let's Encrypt недоступен (000) — похоже, блокировка у хостера
  --  ZeroSSL доступен: сертификат можно выпустить через DNS-01 (acme.sh)
  [ok] GitHub raw доступен
  [ok] Docker Hub доступен
```

Отключить: `--skip-netcheck`.

### Если сертификат уже есть

Если положить `fullchain.crt` и `private.key` в `/opt/selfsteal/ssl/`, установщик
не станет полагаться на ACME: впишет `tls /etc/caddy/ssl/...` в Caddyfile и смонтирует
каталог в контейнер. Это же правило работает и при повторной установке —
рабочий HTTPS не перезаписывается. Проверка A-записи в этом случае пропускается:
сертификат уже не зависит от DNS.

### Проверка результата

После старта selfsteal скрипт до 60 секунд ждёт, пока HTTPS заработает
**с доверенным сертификатом** (без `-k`). Если не поднялось — печатает частые причины
и последние строки лога Caddy.

## Сайты-заглушки (9 сайтов)

Список и описания берутся из [`templates/manifest.tsv`](templates/manifest.tsv) —
чтобы добавить сайт, достаточно создать папку и строку в манифесте, код не правится.

| Ключ | Что это | Что работает |
|---|---|---|
| `studio` | дизайн-студия «Цех» (по-русски) | кейсы в модалках, таймлайн подхода, форма заявки с валидацией |
| `saas` | лендинг Lattice (поддержка клиентов) | переключатель биллинга, слайдер мест с живым пересчётом, табы фич, FAQ, заявка на демо |
| `docs` | документация Quarry API | поиск по разделам, табы cURL/Node/Python/Go, копирование, scroll-spy, светлая и тёмная тема |
| `blog` | журнал Field Notes | статьи на хеш-роутинге, теги, архив, прогресс чтения, подписка |
| `dashboard` | Meridian — продуктовая аналитика | вход с демо-доступом, KPI, графики с подсказками, сортируемая таблица, экспорт CSV, ⌘K |
| `restaurant` | Osteria Nove (Флоренция) | меню по табам, EN/IT, бронь со слотами, `.ics` в календарь |
| `travel` | гид Northbound | фильтры региона и сезона, избранное в localStorage, маршруты по дням, калькулятор бюджета |
| `forum` | форум Tinker | треды, голосование, пагинация, ответы, создание темы, поиск |
| `hosting` | Basalt Cloud — VPS | конфигуратор с живой ценой, регионы с задержками, карта, деплой с прогрессом |

Каждый — один самодостаточный `index.html`: CSS и JS внутри, ноль внешних запросов
(шрифты системные, вся графика — inline SVG и CSS), работает и по HTTPS, и открытый
локально. Навигация внутри сайта — на хешах, поэтому Caddy отдаёт один документ
на любой путь (`try_files {path} /index.html`) и клики не ломаются.

Сменить сайт без переустановки:

```bash
nodego preset docs      # или интерактивно: nodego → 12
```

Вручную (если `nodego` не установлен):

```bash
curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/templates/docs/index.html \
  -o /opt/selfsteal/html/index.html && docker restart selfsteal
```


## Авто-подбор swap

Размер swap считается по характеристикам сервера, а не фиксирован:

| RAM | Swap | Почему |
|---|---|---|
| ≤ 512 МБ | 1024 МБ | маленькому VPS нужен запас |
| 1–8 ГБ | 2048 МБ | страховка от OOM, не более |
| > 8 ГБ | 1024 МБ | только аварийный запас |

Дополнительно:

- не больше **20% свободного диска** (округляется вниз до 256 МБ);
- не меньше 512 МБ;
- если свободно **меньше 1 ГБ** — swap не создаётся, скрипт предупреждает;
- если swap уже активен — не трогаем;
- если `/swapfile` есть, но другого размера — пересоздаётся.

При установке показываются реальные цифры и предлагается выбор:

```
RAM: 2048 МБ, свободно на диске: 40000 МБ
рекомендуется swap: 2048 МБ (RAM 2048 МБ, диск 40000 МБ)
Размер swap (auto / off / например 1024M) [auto]:
```

Неинтерактивно: `--swap-size auto`, `--swap-size off`, `--swap-size 2G`.
Фактический выбор сохраняется в `answers.env`, чтобы повторный запуск не переспрашивал.

## Схема с двумя IP

Вход и выход можно развести на разные адреса. **IP входа задаётся вручную** —
скрипт подсказывает автоопределённый IP сервера, но его можно заменить на
докупленный адрес:

```
клиент → IP1:443 (Xray, selfsteal) → интернет через IP2
```

При запуске в режиме «2 IP»:

1. вопрос «IP для входа» — по умолчанию автоопределённый, можно ввести другой;
   если такого адреса нет на интерфейсе, скрипт предложит добавить его
   (`ip addr add IP1/32 dev IFACE`);
2. вопрос «IP для выхода» — адрес, с которого нода ходит в интернет;
3. адреса добавляются на интерфейс только если их там ещё нет (маску сети
   у существующих адресов скрипт не трогает — это важно, если «выходом»
   указывают основной IP, у которого обычно `/24`).

Что делает скрипт для выхода:

1. policy routing: `ip rule from IP2 → table 100`, `default via GW src IP2`
2. `iptables -t nat POSTROUTING -o IFACE -m conntrack --ctstate NEW -j SNAT --to-source IP2`

Почему `--ctstate NEW`: SNAT без этого условия переписывает и ответы на входящие
соединения — клиент, подключившийся к IP1, получает ответ с IP2 и рвёт сессию.
С `NEW` переписываются только соединения, инициированные самим сервером.

Пример неинтерактивного запуска, когда вход — докупленный IP, а выход — основной:

```bash
bash install.sh --yes --two-ip --ip1 203.0.113.55 --ip2 198.51.100.7 ...
```

Дополнительно можно закрепить это на уровне Xray — в Config Profile, outbound
`freedom`:

```json
{ "tag": "DIRECT", "protocol": "freedom", "sendThrough": "IP2" }
```

Если провайдер требует, чтобы второй IP ходил через отдельный шлюз —
поправьте `GW` в `/usr/local/sbin/rw-secondary-ip.sh`
(файл перезаписывается при повторном запуске установщика).

## После установки — в панели Remnawave

1. **Nodes → Management → `+`**
   - Address: IP этого сервера (основной)
   - Port: тот, что вы указали как «порт ноды»
   - `SECRET_KEY`: тот, что вставили при установке
2. **Next** → выберите Config Profile → **Create**.
3. **Готовые конфиги** — `nodego` → `1` (или `nodego configs`):
   - `xhttp.json`, `grpc.json`, `tcp.json` — VLESS+Reality; `target` уже
     `127.0.0.1:9443`, `serverNames` — ваш домен, `privateKey` и `shortIds`
     сгенерированы;
   - `hysteria2.json` — если Hysteria2 включена: **два инбаунда** в одном
     файле — `hysteria` (UDP/443, сертификат из `/etc/remnanode/cert`) и
     `vless` + `xhttp` + `reality` (TCP/443, `target 127.0.0.1:9443`).
     xHTTP там нужен для **Caddy selfsteal**: у hysteria-инбаунда в Xray нет
     fallback, поэтому без TCP-инбаунда сайт-заглушка снаружи не открывается
     (на 443 некому слушать). Раздавать xHTTP клиентам не обязательно —
     это решает **Squads → Inbounds**.
   Скопируйте нужный JSON в Config Profile (или перенесите inbound'ы в один
   профиль), затем **Squads → Inbounds** и **Hosts**.
4. Hysteria2 отдельно «ставить» не надо: UDP-порт уже открыт, сертификат
   синхронизирован, а ядро обновляется вместе с нодой
   (`nodego` → `3` → `5`).

Проверить, что заглушка жива: откройте `https://ваш-домен` в браузере.

## Управление

После установки на сервере появляется команда **`nodego`** — интерактивное меню:

```
1) Готовые конфиги: xHTTP, gRPC, TCP (+ Hysteria2)
2) Порты: список / открыть новый с подписью / закрыть
3) Hysteria2: статус, включить/выключить, сертификат, ядро
4) Статус: контейнеры, службы, сеть, порты
5) Логи ноды (live)
6) Логи selfsteal (live)
7) Лог автообновления
8) Перезапустить ноду
9) Перезапустить selfsteal
10) Перезапустить всё
11) Сеть: 1 IP / 2 IP, вход и выход
12) Сменить сайт-заглушку
13) Обновить ноду сейчас (с откатом)
14) Проверить исходящий IP
15) Показать конфигурацию
16) Автообновление: включить/выключить
17) DNS-фильтр AdGuard: включить/выключить
18) Диагностика (doctor)
19) Бэкап конфигов сейчас
20) Восстановить из бэкапа
21) Алерты Telegram: включить/выключить
```

Без меню:

```bash
nodego status                # состояние
nodego logs                  # логи ноды
nodego restart               # перезапуск ноды
nodego update                # обновление с откатом
nodego net                   # схема сети
nodego configs               # все готовые конфиги
nodego configs hysteria2     # один конфиг
nodego keys                  # publicKey + shortIds (для ручных клиентов)
nodego ports                 # открытые порты
nodego hysteria status       # Hysteria2: статус
nodego hysteria on|off       # включить/выключить
nodego hysteria cert         # обновить сертификат из selfsteal
nodego hysteria core         # обновить ядро ноды (Xray) до latest
nodego hysteria test         # проверить конфиг через xray -test
nodego preset blog           # сменить заглушку
nodego doctor                # диагностика (7 проверок + события docker)
nodego backup                # бэкап конфигов
nodego restore <файл>        # восстановление
nodego alerts                # статус алертов
```

### Смена схемы IP без переустановки

Схема хранится в `/etc/remnawave-setup/net.env`, применение — универсальный
`/usr/local/sbin/rw-secondary-ip.sh`. Поэтому в меню `nodego → 11` можно:

- перейти с 1 IP на 2 IP (ввести выходной адрес);
- перейти с 2 IP на 1 IP (правила снимаются автоматически);
- **поменять вход и выход местами** (например, было `1.1.1.1 вход → 2.2.2.2 выход`,
  станет `2.2.2.2 вход → 1.1.1.1 выход`), Caddy при этом перевязывается на новый IP.

То же самое можно сделать переустановкой: `--yes --two-ip --ip1 ... --ip2 ...`
(флаги имеют приоритет над сохранёнными ответами).

### Обычные команды

```bash
systemctl status remnanode selfsteal rw-secondary-ip
systemctl list-timers rw-node-update.timer
docker logs -f remnanode
docker logs -f selfsteal

cd /opt/remnanode && docker compose pull && docker compose up -d   # обновить вручную
systemctl start rw-node-update.service                              # обновить с проверкой/откатом
tail -f /var/log/remnawave-update.log
```

Отключить автообновление:

```bash
systemctl disable --now rw-node-update.timer
```

Проверить, что исходящий трафик идёт через второй IP:

```bash
curl -4 --interface <IP2> https://ifconfig.io
```

## Файлы на сервере

| Путь | Что |
|---|---|
| `/opt/remnanode/` | `docker-compose.yml`, `.env`, `cert/` (сертификат для Hysteria2) |
| `/opt/selfsteal/` | `docker-compose.yml`, `Caddyfile`, `html/`, `logs/`, `ssl/` |
| `/etc/systemd/system/remnanode.service` | автозапуск ноды |
| `/etc/systemd/system/selfsteal.service` | автозапуск Caddy |
| `/etc/systemd/system/rw-secondary-ip.service` | второй IP + SNAT |
| `/etc/systemd/system/rw-node-update.{service,timer}` | автообновление |
| `/etc/systemd/system/rw-cert-sync.{service,timer}` | сертификат для Hysteria2 |
| `/usr/local/bin/nodego` | интерактивное меню управления |
| `/usr/local/sbin/rw-configs.sh` | генератор готовых конфигов (xHTTP/gRPC/TCP/Hysteria2) |
| `/usr/local/sbin/rw-cert-sync.sh` | копирование сертификата selfsteal в ноду |
| `/usr/local/sbin/rw-secondary-ip.sh` | применение схемы сети из `net.env` |
| `/usr/local/sbin/rw-node-update.sh` | обновление с откатом |
| `/usr/local/sbin/rw-healthcheck.sh` | проверки + алерты (и `--report` для doctor) |
| `/usr/local/sbin/rw-backup.sh` | бэкап/список/восстановление конфигов |
| `/etc/remnawave-setup/answers.env` | сохранённые ответы (chmod 600) |
| `/etc/remnawave-setup/net.env` | текущая схема IP (chmod 600) |
| `/etc/remnawave-setup/alerts.env` | токен/chat_id для алертов (chmod 600) |
| `/etc/remnawave-setup/configs/` | готовые JSON-конфиги + `meta.env` (chmod 600) |
| `/var/backups/remnanode/` | бэкапы конфигов (14 копий) |
| `/var/log/remnanode/` | логи Xray (logrotate) |
| `/var/log/remnawave-setup.log` | лог установки |

## Частые вопросы

**Нода не видна в панели.** Проверьте, что панель может достучаться до
`IP:порт_ноды` (правило UFW только для IP панели), и что `SECRET_KEY` совпадает.

**Caddy не выпускает сертификат.** A-запись домена должна указывать на основной
IP, а порт 80 — быть доступен снаружи. До выпуска сертификата Caddy отдаёт
внутренний TLS — это нормально.

**Установщик пишет, что A-запись не туда, хотя домен открывается.** Значит DNS
ещё не разошёлся после смены IP или сервер стоит за NAT. Это информационное
сообщение, установка не блокируется: A-запись сверяется со **всеми** адресами
интерфейсов, `--ip1` и внешним IP, а не с одним автоопределённым. Если домен
уже отдаёт заглушку — всё в порядке; ACME проверяет A-запись в момент выпуска.

**После смены IP/шлюза ломается выход.** Поправьте `GW` в
`/usr/local/sbin/rw-secondary-ip.sh` и выполните
`systemctl restart rw-secondary-ip`.

**Порт занят.** Скрипт предупредит до запуска контейнеров:
`ss -tlnp | grep :443`.

**Hysteria2 не подключается.** Проверьте по порядку: `nodego hysteria status`
(UDP открыт? сертификат на месте?), затем `nodego hysteria test` — ядро должно
принять `hysteria2.json`. Если UDP-порт закрыт в **облачном** firewall
(security group у хостера), ufw этого не видит — откройте порт там.
Клиентская ссылка должна указывать на порт подключения (например `:443`),
а `hysteria-инбаунд` — быть включён в Squads и Hosts панели.

**Конфиги не подходят к панели / поменял домен.** `nodego` → `1` → `7`
обновляет порт, target и serverNames, не меняя ключи; `8` перегенерирует
конфиги полностью (новые ключи — профиль в панели придётся обновить).

**Нужен перезапуск?** Да, для полного применения `nofile`:
`reboot`.

## Требования

- Debian 12+/Ubuntu 22.04+ (apt)
- root, открытый SSH
- 2 ГБ свободного диска, 512 МБ RAM
- для selfsteal: домен с A-записью на сервер

## Проверки качества (CI)

На каждый пуш и PR GitHub Actions прогоняет:

| Проверка | Что ловит |
|---|---|
| `bash -n install.sh` | синтаксис |
| **ShellCheck** (`-S style`, все уровни) для `install.sh` и `nodego.sh` | ошибки и плохие практики |
| шаблоны | 9 сайтов: манифест без дублей, у каждого ключа есть папка и наоборот, `index.html` непустой и самодостаточный (нет внешних URL, кроме `xmlns`) |
| JS шаблонов | весь инлайн-JS каждого сайта проверяется `node --check` |
| встроенные скрипты | `rw-secondary-ip.sh`, `rw-node-update.sh`, `rw-healthcheck.sh`, `rw-backup.sh`, `rw-cert-sync.sh`, `rw-configs.sh` парсятся bash |
| генератор конфигов | `rw-configs.sh` реально генерирует 3–4 JSON; проверяются теги, порт, `privateKey` (43 символа), 6 `shortIds` по 16 hex, target `127.0.0.1:9443`/`www.apple.com:443`, `serverNames` и поля Hysteria2 |
| сгенерированные конфиги | оба `docker-compose.yml` валидны как YAML, Caddyfile структурно цел |

Проверить локально:

```bash
shellcheck -S style install.sh nodego.sh
bash -n install.sh
bash -n nodego.sh

# внешних ссылок быть не должно — в выводе остаётся только www.w3.org (xmlns SVG)
grep -rhoE 'https?://[a-z0-9.-]+' templates --include=index.html | sort -u

# синтаксис инлайн-JS каждого шаблона (нужен node)
python3 - <<'EOF'
import os, re, subprocess, tempfile
for key in sorted(os.listdir("templates")):
    p = os.path.join("templates", key, "index.html")
    if not os.path.isfile(p):
        continue
    html = open(p, encoding="utf-8").read()
    for i, m in enumerate(re.finditer(r"<script\b([^>]*)>(.*?)</script>", html, re.S)):
        attrs, body = m.group(1), m.group(2)
        if "src=" in attrs or "json" in attrs or not body.strip():
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
            f.write(body)
            tmp = f.name
        r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        print(f"{p} #{i}: {'ok' if r.returncode == 0 else r.stderr.strip()[:200]}")
        os.unlink(tmp)
EOF
```

Переводы строк в репозитории — только **LF** (`.gitattributes`: `* text=auto eol=lf`).
`install.sh` и `nodego.sh` скачиваются на серверы по `raw.githubusercontent.com` и
запускаются как есть: с CRLF bash получает `\r` в конце команд и падает. Правки
делайте в редакторе с LF; атрибут нормализует файлы при коммите сам.

## Лицензия

MIT
