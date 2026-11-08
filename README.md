# remnanode-installer

[![CI](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/Asteliat/remnanode-installer/actions/workflows/ci.yml)

Установщик **Remnawave Node + Caddy Selfsteal** «под ключ» для чистого Debian/Ubuntu.

Один скрипт: зависимости → Docker → тюнинг системы → сеть (1 или 2 IP) → нода →
сайт-заглушка → firewall → DNS-фильтр → автообновление → systemd → проверка.

## Быстрый старт

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/install.sh)
```

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
| Сайт-заглушка | `landing` | 10 пресетов, см. ниже |
| Схема сети: 1 или 2 IP | `1` | `2` — вход на основной IP, выход через дополнительный |
| Дополнительный IP | — | нужен только для схемы «2 IP» |
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
`--no-autoupdate`, `--yes`, `--reconfigure`, `--skip-tuning`, `--skip-firewall`,
`--help`.

Повторный запуск с `--yes` без флагов читает сохранённые ответы из
`/etc/remnawave-setup/answers.env`. Переопределить: `--reconfigure`.

## Что делает скрипт

1. **Проверки**: root, Debian/Ubuntu, архитектура, свободное место.
2. **Пакеты**: `apt-get update` + `apt-get upgrade` (noninteractive, confdef/confold)
   и установка curl, wget, jq, ufw, logrotate, dnsutils, cron, gnupg.
3. **Время и NTP** — критично для ACME/TLS.
4. **Docker** — официальный `get.docker.com` + compose v2.
5. **Тюнинг**:
   - swap 2 ГБ + запись в `/etc/fstab`, `swappiness=10`;
   - `nofile = 1048576` (хост + drop-in для `docker.service`);
   - sysctl: backlog, буферы, conntrack, `vm.overcommit_memory=1`,
     `fs.nr_open`, `tcp_mtu_probing` (MTU-blackhole в мобильных сетях);
   - BBR + FQ с проверкой поддержки ядра.
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
10. **DNS-фильтр AdGuard DoT** (опционально, по вопросу).
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

## Сайты-заглушки (10 пресетов)

| Ключ | Что это |
|---|---|
| `landing` | лендинг — визитка небольшой компании |
| `cloud` | облако — интерфейс файлового хранилища |
| `speedtest` | спидтест — замер скорости соединения |
| `blog` | блог — статья с текстом |
| `503` | 503 — «сервис временно недоступен» |
| `news` | новости — лента новостей с сайдбаром |
| `forum` | форум — темы и обсуждения |
| `torrent` | торрент — таблица раздач |
| `shop` | магазин — карточки товаров |
| `auth` | вход в панель — форма логина |

Описания показываются прямо в меню выбора при установке.

Все — одиночные `index.html` без внешних CDN, шрифтов и трекеров, с поддержкой
тёмной темы (`prefers-color-scheme`). Лежат в [`templates/`](templates/) и
скачиваются скриптом при установке (если запускать из клона — берутся локально).

Сменить сайт без переустановки:

```bash
curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/templates/blog/index.html \
  -o /opt/selfsteal/html/index.html && docker restart selfsteal
```

## Схема с двумя IP

Вход остаётся на основном IP (там же домен и selfsteal), а исходящий трафик
ноды уходит с дополнительного:

```
клиент → IP1:443 (Xray, selfsteal) → интернет через IP2
```

Что делает скрипт:

1. `ip addr replace IP2/32 dev IFACE`
2. policy routing: `ip rule from IP2 → table 100`, `default via GW src IP2`
3. `iptables -t nat POSTROUTING -o IFACE -m conntrack --ctstate NEW -j SNAT --to-source IP2`

Почему `--ctstate NEW`: SNAT без этого условия переписывает и ответы на входящие
соединения — клиент, подключившийся к IP1, получает ответ с IP2 и рвёт сессию.
С `NEW` переписываются только соединения, инициированные самим сервером.

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
| шаблоны | все 10 существуют, непустые и упомянуты в установщике |
| встроенные скрипты | `rw-secondary-ip.sh`, `rw-node-update.sh`, `rw-healthcheck.sh`, `rw-backup.sh` парсятся bash |
| сгенерированные конфиги | оба `docker-compose.yml` валидны как YAML, Caddyfile структурно цел |

Проверить локально:

```bash
shellcheck -S style install.sh nodego.sh
bash -n install.sh
```

## Лицензия

MIT
