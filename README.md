# remnanode-installer

[![CI](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml)

Установщик **Remnawave Node + Caddy Selfsteal** «под ключ» для чистого Debian/Ubuntu.

Один скрипт: зависимости → Docker → тюнинг системы → сеть (1 или 2 IP) → нода →
сайт-заглушка → firewall → DNS-фильтр → автообновление → systemd → проверка.

## Быстрый старт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/install.sh)
```

`-f` важен: если сеть до GitHub недоступна, вы увидите ошибку, а не тихий пустой запуск.

Скрипт спросит (для портов: **Enter = порт не открывается**):

| Вопрос | Значение в `--yes` | Зачем |
|---|---|---|
| IP панели Remnawave | — | порт ноды откроется **только** для этого IP |
| Порт ноды | `2222` | внутренний API «панель → нода» |
| `SECRET_KEY` | — | копируется из панели при создании ноды |
| Порт xHTTP | `443` | Enter = порт не открывается |
| Порт gRPC | `2096` | Enter = порт не открывается |
| Порт TCP/Vision | `4443` | Enter = порт не открывается |
| Selfsteal (да/нет) | `да` | сайт-заглушка для Reality/TLS |
| Домен | — | A-запись должна указывать на сервер (нужна для Let's Encrypt) |
| Внутренний порт Caddy | `9443` | Xray будет проксировать сюда |
| Сайт-заглушка | `landing` | 50 пресетов, см. ниже |
| Схема сети: 1 или 2 IP | `1` | `2` — вход на IP1, выход через IP2 |
| IP входа | автоопределённый | можно указать докупленный адрес (`--ip1`) |
| IP выхода | — | адрес, с которого нода ходит в интернет (`--ip2`) |
| DNS-фильтр AdGuard | `да` | блокировка рекламы и трекеров, DNS-over-TLS |
| Автообновление ноды | `да` | ежедневная проверка + откат при сбое |
| Алерты в Telegram | `нет` | если да — спросит токен бота и chat_id |

**Пропуск порта = порт не открывается.** В неинтерактивном режиме значение по
умолчанию применяется, только если флаг не передан; чтобы порт не открывался —
передайте пустую строку: `--grpc-port ''`.

## Неинтерактивный режим

```bash
bash install.sh --yes \
  --panel-ip 203.0.113.10 \
  --node-port 2222 \
  --secret-key 'КЛЮЧ_ИЗ_ПАНЕЛИ' \
  --xhttp-port 443 --grpc-port '' --tcp-port '' \
  --domain vpn.example.com --template landing \
  --two-ip --ip2 198.51.100.7 \
  --dns yes --autoupdate yes
```

Флаги: `--panel-ip`, `--node-port`, `--secret-key`, `--xhttp-port`, `--grpc-port`,
`--tcp-port`, `--selfsteal yes|no`, `--no-selfsteal`, `--domain`,
`--selfsteal-port`, `--template`, `--one-ip` / `--two-ip` / `--dual-ip`,
`--ip1`, `--ip2`, `--dns yes|no` / `--no-dns`, `--autoupdate yes|no` /
`--no-autoupdate`, `--alerts yes|no` / `--no-alerts`, `--tg-token`, `--tg-chat`,
`--swap-size auto|off|1024M`, `--yes`, `--reconfigure`, `--skip-tuning`,
`--skip-firewall`, `--skip-netcheck`, `--help`.

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
   - порты транспортов — всем;
   - порт ноды — только с IP панели.
8. **Нода** `/opt/remnanode`:
   - `.env` (`NODE_PORT`, `SECRET_KEY`), compose (`remnawave/node:latest`,
     host network, `restart: always`, `cap_add: NET_ADMIN`, ulimits, лог-ротация,
     монтирование `/var/log/remnanode`);
   - `remnanode.service` — автозапуск через `docker compose`.
9. **Selfsteal** `/opt/selfsteal`: Caddy на `127.0.0.1:9443`, ACME через 80,
   редирект, security-заголовки, выбранный сайт-заглушка,
   публичный `:80` привязан к основному IP.
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
13. **Проверка**: контейнеры, порты, локальный запрос к Caddy, статус юнитов
    и таймеров, исходящий IP, DNS.
14. **Итог**: что нажать в панели.

## Проверка сети перед установкой

До изменения системы скрипт проверяет окружение и предупреждает о проблемах,
которые потом «всплывают» уже после установки:

| Проверка | Что выявляет |
|---|---|
| внешний IP (`ifconfig.io`) | нет выхода в интернет / NAT-адресация |
| A-запись домена | не указывает на **IP входа** (`--ip1`) или домен не резолвится |
| ACME: Let's Encrypt | **блокировка у хостера** (частая причина «сайт не открывается») |
| ACME: ZeroSSL | резервный путь, если LE недоступен |
| GitHub raw | не скачаются шаблоны и `nodego` |
| Docker Hub (`registry-1.docker.io`) | не скачаются образы ноды и Caddy |
| панель `IP:3000` | доступность панели (информационно) |

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
рабочий HTTPS не перезаписывается.

### Проверка результата

После старта selfsteal скрипт до 60 секунд ждёт, пока HTTPS заработает
**с доверенным сертификатом** (без `-k`). Если не поднялось — печатает частые причины
и последние строки лога Caddy.

## Сайты-заглушки (50 пресетов)

Список и описания берутся из [`templates/manifest.tsv`](templates/manifest.tsv) —
чтобы добавить сайт, достаточно создать папку и строку в манифесте, код не правится.

- **Базовые:** `landing` (визитка), `startup` (SaaS-лендинг), `agency` (кейсы),
  `portfolio` (портфолио разработчика)
- **Документация и сервисы:** `docs` (API), `wiki` (статья), `paste` (pastebin),
  `git` (репозитории), `status` (статус-страница)
- **Интерфейсы:** `dashboard`, `analytics`, `mail`, `chat`, `calendar`, `notes`,
  `tasks`, `crm`, `hr`, `edu`, `quiz`
- **Медиа:** `podcast`, `radio`, `music`, `video`, `cinema`, `photos`, `gallery`, `cloud`
- **Сообщество:** `news`, `forum`, `blog`, `torrent`, `503`
- **Коммерция:** `shop`, `restaurant`, `fitness`, `health`, `law`, `insurance`,
  `realestate`, `auto`, `logistics`, `travel`, `hotel`
- **Тех/бизнес:** `crypto`, `finance`, `hosting`, `cdn`, `speedtest`, `auth`

Каждый — одиночный `index.html` без внешних CDN, шрифтов и трекеров, с тёмной темой
(`prefers-color-scheme`). Скачивается скриптом при установке (из клона — берётся локально).

Сменить сайт без переустановки:

```bash
curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/templates/blog/index.html \
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
3. Для selfsteal в inbound'ах xHTTP/gRPC включите **Self-steal**:
   - `dest: 127.0.0.1:9443`
   - domain: ваш домен

Проверить, что заглушка жива: откройте `https://ваш-домен` в браузере.

## Управление

После установки на сервере появляется команда **`nodego`** — интерактивное меню:

```
1) Статус: контейнеры, службы, сеть, порты
2) Логи ноды (live)
3) Логи selfsteal (live)
4) Лог автообновления
5) Перезапустить ноду
6) Перезапустить selfsteal
7) Перезапустить всё
8) Сеть: 1 IP / 2 IP, вход и выход
9) Сменить сайт-заглушку
10) Обновить ноду сейчас (с откатом)
11) Проверить исходящий IP
12) Показать конфигурацию
13) Автообновление: включить/выключить
14) DNS-фильтр AdGuard: включить/выключить
15) Диагностика (doctor)
16) Бэкап конфигов сейчас
17) Восстановить из бэкапа
18) Алерты Telegram: включить/выключить
```

Без меню:

```bash
nodego status          # состояние
nodego logs            # логи ноды
nodego restart         # перезапуск ноды
nodego update          # обновление с откатом
nodego net             # схема сети
nodego preset blog     # сменить заглушку
nodego doctor          # диагностика (7 проверок + события docker)
nodego backup          # бэкап конфигов
nodego restore <файл>  # восстановление
nodego alerts          # статус алертов
```

### Смена схемы IP без переустановки

Схема хранится в `/etc/remnawave-setup/net.env`, применение — универсальный
`/usr/local/sbin/rw-secondary-ip.sh`. Поэтому в меню `nodego → 8` можно:

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
| `/opt/remnanode/` | `docker-compose.yml`, `.env` |
| `/opt/selfsteal/` | `docker-compose.yml`, `Caddyfile`, `html/`, `logs/` |
| `/etc/systemd/system/remnanode.service` | автозапуск ноды |
| `/etc/systemd/system/selfsteal.service` | автозапуск Caddy |
| `/etc/systemd/system/rw-secondary-ip.service` | второй IP + SNAT |
| `/etc/systemd/system/rw-node-update.{service,timer}` | автообновление |
| `/usr/local/bin/nodego` | интерактивное меню управления |
| `/usr/local/sbin/rw-secondary-ip.sh` | применение схемы сети из `net.env` |
| `/usr/local/sbin/rw-node-update.sh` | обновление с откатом |
| `/usr/local/sbin/rw-healthcheck.sh` | проверки + алерты (и `--report` для doctor) |
| `/usr/local/sbin/rw-backup.sh` | бэкап/список/восстановление конфигов |
| `/etc/remnawave-setup/answers.env` | сохранённые ответы (chmod 600) |
| `/etc/remnawave-setup/net.env` | текущая схема IP (chmod 600) |
| `/etc/remnawave-setup/alerts.env` | токен/chat_id для алертов (chmod 600) |
| `/var/backups/remnanode/` | бэкапы конфигов (14 копий) |
| `/var/log/remnanode/` | логи Xray (logrotate) |
| `/var/log/remnawave-setup.log` | лог установки |

## Частые вопросы

**Нода не видна в панели.** Проверьте, что панель может достучаться до
`IP:порт_ноды` (правило UFW только для IP панели), и что `SECRET_KEY` совпадает.

**Caddy не выпускает сертификат.** A-запись домена должна указывать на основной
IP, а порт 80 — быть доступен снаружи. До выпуска сертификата Caddy отдаёт
внутренний TLS — это нормально.

**После смены IP/шлюза ломается выход.** Поправьте `GW` в
`/usr/local/sbin/rw-secondary-ip.sh` и выполните
`systemctl restart rw-secondary-ip`.

**Порт занят.** Скрипт предупредит до запуска контейнеров:
`ss -tlnp | grep :443`.

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
| шаблоны | 50 штук: манифест без дублей, у каждого ключа есть папка и наоборот, `index.html` непустой |
| встроенные скрипты | `rw-secondary-ip.sh`, `rw-node-update.sh`, `rw-healthcheck.sh`, `rw-backup.sh` парсятся bash |
| сгенерированные конфиги | оба `docker-compose.yml` валидны как YAML, Caddyfile структурно цел |

Проверить локально:

```bash
shellcheck -S style install.sh nodego.sh
bash -n install.sh
```

## Лицензия

MIT
