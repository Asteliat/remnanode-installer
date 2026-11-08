# remnanode-installer

Установщик **Remnawave Node + Caddy Selfsteal** «под ключ» для чистого Debian/Ubuntu.

Один скрипт: зависимости → Docker → тюнинг системы → нода → сайт-заглушка → firewall → systemd → проверка.

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
| Сайт-заглушка | `landing` | `landing`, `cloud`, `speedtest`, `blog`, `503` |

**Пропуск порта = порт не открывается.** Это и есть способ «выключить» транспорт:
нажать Enter на соответствующем вопросе. В неинтерактивном режиме значение по
умолчанию применяется, только если флаг не передан; чтобы порт не открывался —
передайте пустую строку: `--grpc-port ''`.

## Неинтерактивный режим

```bash
bash install.sh --yes \
  --panel-ip 203.0.113.10 \
  --node-port 2222 \
  --secret-key 'ВАШ_КЛЮЧ_ИЗ_ПАНЕЛИ' \
  --xhttp-port 443 \
  --grpc-port '' \
  --tcp-port '' \
  --domain vpn.example.com \
  --template landing
```

Ключи: `--panel-ip`, `--node-port`, `--secret-key`, `--xhttp-port`, `--grpc-port`,
`--tcp-port`, `--selfsteal yes|no` / `--no-selfsteal`, `--domain`,
`--selfsteal-port`, `--template`, `--yes`, `--reconfigure`,
`--skip-tuning`, `--skip-firewall`, `--help`.

Повторный запуск с `--yes` без флагов читает сохранённые ответы из
`/etc/remnawave-setup/answers.env`. Переопределить их: `--reconfigure`.

## Что делает скрипт

1. **Проверки**: root, Debian/Ubuntu, архитектура, свободное место.
2. **Пакеты**: `curl wget ca-certificates openssl jq ufw logrotate dnsutils cron`.
3. **Время**: часовой пояс + NTP (важно для ACME/TLS).
4. **Docker**: официальный `get.docker.com` + `docker compose` v2.
5. **Тюнинг**:
   - swap 2 ГБ + запись в `/etc/fstab`;
   - `nofile = 1048576` (как `ulimits` ноды) + drop-in для `docker.service`;
   - sysctl: backlog, буферы, conntrack, `vm.overcommit_memory=1`;
   - BBR + FQ (с проверкой поддержки ядра).
6. **Firewall (UFW)**:
   - SSH-порт (определяется автоматически);
   - `80/tcp` — если включён selfsteal (ACME HTTP-01 + редирект);
   - порты транспортов — всем;
   - порт ноды — только с IP панели.
7. **Нода** `/opt/remnanode`:
   - `.env` (`NODE_PORT`, `SECRET_KEY`), `docker-compose.yml` (`remnawave/node:latest`,
     `network_mode: host`, `restart: always`, `cap_add: NET_ADMIN`, ulimits);
   - `remnanode.service` — автозапуск через `docker compose`.
8. **Selfsteal** `/opt/selfsteal`:
   - `Caddyfile` (Caddy слушает `127.0.0.1:9443`, ACME через 80, редирект);
   - выбранный шаблон сайта в `html/index.html`;
   - `selfsteal.service` — автозапуск.
9. **Проверка**: контейнеры, слушающие порты, локальный запрос к Caddy, статус юнитов.
10. **Итог**: что нажать в панели.

## Сайты-заглушки (пресеты)

| Ключ | Что это |
|---|---|
| `landing` | Нейтральный лендинг небольшой студии |
| `cloud` | Интерфейс облачного хранилища |
| `speedtest` | Спидтест, считает локально |
| `blog` | Статья в блоге |
| `503` | Страница обслуживания |

Шаблоны — статичный HTML без внешних зависимостей и трекеров. Лежат в
[`templates/`](templates/) и скачиваются скриптом при установке
(если запускать из клона репозитория — берутся локально).

## После установки — в панели Remnawave

1. **Nodes → Management → `+`**
   - Address: IP этого сервера
   - Port: тот, что вы указали как «порт ноды»
   - `SECRET_KEY`: тот, что вставили при установке
2. **Next** → выберите Config Profile → **Create**.
3. Для selfsteal в inbound'ах xHTTP/gRPC включите **Self-steal**:
   - `dest: 127.0.0.1:9443`
   - domain: ваш домен

Проверить, что заглушка жива: откройте `https://ваш-домен` в браузере.

## Управление

```bash
systemctl status remnanode selfsteal
docker logs -f remnanode
docker logs -f selfsteal

cd /opt/remnanode && docker compose pull && docker compose up -d   # обновить ноду
cd /opt/selfsteal && docker compose restart                        # перезапустить Caddy
```

Сменить сайт-заглушку без переустановки:

```bash
curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/templates/blog/index.html \
  -o /opt/selfsteal/html/index.html && docker restart selfsteal
```

## Файлы на сервере

| Путь | Что |
|---|---|
| `/opt/remnanode/` | `docker-compose.yml`, `.env` |
| `/opt/selfsteal/` | `docker-compose.yml`, `Caddyfile`, `html/`, `logs/` |
| `/etc/systemd/system/remnanode.service` | автозапуск ноды |
| `/etc/systemd/system/selfsteal.service` | автозапуск Caddy |
| `/etc/remnawave-setup/answers.env` | сохранённые ответы (chmod 600) |
| `/var/log/remnawave-setup.log` | лог установки |

## Частые вопросы

**Нода не видна в панели.** Проверьте, что панель может достучаться до
`IP:порт_ноды` (правило UFW только для IP панели), и что `SECRET_KEY` совпадает.

**Caddy не выпускает сертификат.** A-запись домена должна указывать на этот
сервер, а порт 80 — быть доступен снаружи. До выпуска сертификата Caddy отдаёт
внутренний TLS — это нормально.

**Порт занят.** Скрипт предупредит до запуска контейнеров:
`ss -tlnp | grep :443`.

**Нужен перезапуск?** Да, для полного применения `nofile`:
`reboot`.

## Требования

- Debian 12+/Ubuntu 22.04+ (apt)
- root
- 2 ГБ свободного диска, 512 МБ RAM
- открытый SSH-доступ

## Лицензия

MIT
