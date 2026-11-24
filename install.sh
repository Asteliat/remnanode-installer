#!/usr/bin/env bash
# ============================================================================
#  Remnawave Node + Caddy Selfsteal — установщик "под ключ"
# ============================================================================
#  Что делает:
#    1. ставит зависимости и Docker (официальный get.docker.com)
#    2. тюнит систему под VPN-нагрузку (swap, nofile, sysctl, BBR+FQ, NTP, DNS)
#    3. разворачивает Remnawave Node (/opt/remnanode) с вашими NODE_PORT и ключом
#    4. разворачивает Caddy Selfsteal (/opt/selfsteal) с выбранным сайтом-заглушкой
#    5. настраивает firewall: ОДИН порт подключения — всем, порт ноды — только панели
#    6. создаёт systemd-юниты автозапуска (docker compose)
#    7. готовит готовые конфиги для панели: xHTTP, gRPC, TCP (+ Hysteria2)
#    8. проверяет результат и печатает, что осталось сделать в панели
#
#  Быстрый старт:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Asteliat/remnanode-installer/main/install.sh)
#
#  Неинтерактивный режим:
#    ... install.sh --yes --node-port 2222 --panel-ip 1.2.3.4 --secret-key KEY \
#                   --connect-port 443 --domain vpn.example.com --template shop
#
#  Порты: спрашивается ОДИН порт подключения — на нём работают xHTTP, gRPC и TCP.
#  Какой именно inbound какого типа — установщику не важно: важны firewall и
#  готовые конфиги. Отдельно спрашивается порт ноды (внутренний API), и только
#  после него — IP панели, которой этот порт открывается.
#
#  Hysteria2 (UDP на том же порту) — по желанию: ставится вместе с нодой и
#  selfsteal, сертификат для TLS забирается у Caddy. Позже включить/выключить,
#  обновить сертификат или ядро можно в меню `nodego`.
#
#  Схемы с IP:
#    1 IP  — вход и выход через один адрес (обычная схема)
#    2 IP  — клиенты входят на IP1, в интернет нода выходит через IP2
#            (policy routing + SNAT только для NEW-соединений,
#            чтобы не ломать ответы на входящие)
#            IP1 можно указать вручную (--ip1) — например, докупленный адрес,
#            тогда он задаётся вопросом и при необходимости назначается на
#            интерфейс; автоопределённый IP сервера показывается как подсказка.
#
#  Дополнительно скрипт спрашивает:
#    * порт ноды и IP панели — порт ноды откроется только этому адресу
#      (порт веб-панели не спрашивается: нода пассивна, соединение всегда
#       панель → нода; необязательная проверка — ключом --panel-port)
#    * один порт подключения (xHTTP/gRPC/TCP) и Hysteria2 (UDP на нём же)
#    * DNS-фильтрацию AdGuard (блокировка рекламы/трекеров, DoT)
#    * автообновление ноды (systemd-таймер + откат при неудаче)
#    * алерты в Telegram (healthcheck)
#
#  Перед установкой проверяется сеть: внешний IP, A-запись домена,
#  доступность ACME (Let's Encrypt / ZeroSSL), GitHub raw и Docker Hub.
#  Отключить: --skip-netcheck
# ============================================================================

set -euo pipefail

VERSION="1.3.5"

REPO_OWNER="Asteliat"
REPO_NAME="remnanode-installer"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
TEMPLATES_BASE="${RAW_BASE}/templates"

NODE_DIR="/opt/remnanode"
SELFSTEAL_DIR="/opt/selfsteal"
STATE_DIR="/etc/remnawave-setup"
ANSWERS_FILE="$STATE_DIR/answers.env"
LOG_FILE="/var/log/remnawave-setup.log"
NODE_IMAGE="remnawave/node:latest"
CADDY_IMAGE="caddy:2-alpine"
SWAP_SIZE="${SWAP_SIZE:-auto}"      # auto | off | 512M | 2G

# ------------------------------------------------------------------ defaults
PANEL_IP="${PANEL_IP:-}"
PANEL_PORT="${PANEL_PORT:-}"     # необязателен: только для проверки --panel-port (нода к панели не стучится)
NODE_PORT="${NODE_PORT:-2222}"
SECRET_KEY="${SECRET_KEY:-}"
CONNECT_PORT="${CONNECT_PORT:-}"    # один порт для xHTTP/gRPC/TCP (и UDP для Hysteria2)
HYSTERIA="${HYSTERIA:-}"            # yes = Hysteria2 (UDP на CONNECT_PORT)
USE_SELFSTEAL="${USE_SELFSTEAL:-yes}"
DOMAIN="${DOMAIN:-}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
TEMPLATE="${TEMPLATE:-shop}"

# --- сеть -------------------------------------------------------------------
DUAL_IP="${DUAL_IP:-no}"        # yes = вход на IP1, выход через IP2
IP1="${IP1:-}"                  # основной IP (определяется автоматически)
IP2="${IP2:-}"                  # дополнительный/выходной IP

# --- дополнительные опции ---------------------------------------------------
USE_DNS="${USE_DNS:-yes}"           # AdGuard DoT (блокировка рекламы)
AUTO_UPDATE="${AUTO_UPDATE:-yes}"   # автообновление ноды через systemd-таймер
ALERTS="${ALERTS:-no}"              # алерты в Telegram
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"

ASSUME_YES=false
SKIP_TUNING=false
SKIP_FIREWALL=false
SKIP_NETCHECK=false
UPGRADE_SYSTEM=false   # обновление всех пакетов — только по явному запросу
SWAP_ONLY=false        # --swap-only: показать/пересоздать swap и выйти

# Ответы прошлого запуска читаем ДО разбора флагов — чтобы флаги имели приоритет.
for _arg in "$@"; do
    case "$_arg" in
        --yes|-y)      _PRE_YES=true ;;
        --reconfigure) _PRE_RECONF=true ;;
    esac
done
if [ "${_PRE_YES:-false}" = true ] && [ "${_PRE_RECONF:-false}" = false ] && [ -f "$ANSWERS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
fi
unset _arg _PRE_YES _PRE_RECONF 2>/dev/null || true

# --------------------------------------------------------------------- args
usage() {
    cat <<'USAGE'
Remnawave Node + Caddy selfsteal — установщик

Запуск:
  bash install.sh                 интерактивно
  bash install.sh --yes ...       неинтерактивно (флаги ниже)

Основные флаги:
  --node-port PORT       порт ноды (внутренний API, по умолчанию 2222)
  --panel-ip IP          IP панели Remnawave (порт ноды откроется только ему)
  --panel-port PORT      необязательно: проверить доступность веб-порта панели
                         (нода к панели не подключается — только панель к ноде)
  --secret-key KEY       SECRET_KEY из панели
  --connect-port PORT    ОДИН порт для подключения клиентов (по умолчанию 443):
                         на нём работают xHTTP, gRPC и TCP
  --hysteria yes|no      Hysteria2 (UDP на порту подключения, по умолчанию yes
                         при включённом selfsteal)
  --no-hysteria          не включать Hysteria2
  --selfsteal yes|no     разворачивать сайт-заглушку
  --no-selfsteal         не разворачивать сайт-заглушку (то же, что --selfsteal no)
  --domain DOMAIN        домен для selfsteal
  --selfsteal-port PORT  внутренний порт Caddy (9443)
  --template NAME        сайт-заглушка: shop (по умолчанию), studio, saas, docs,
                         blog, dashboard, restaurant, travel, forum, hosting
  --one-ip | --two-ip    схема сети (2 IP: клиенты входят на --ip1, нода выходит с --ip2)
  --dual-ip yes|no       схема сети (yes = вход на IP1, выход через IP2)
  --ip1 IP               IP для входа (по умолчанию — автоопределённый IP сервера;
                         можно указать докупленный адрес)
  --ip2 IP               IP для выхода в интернет (для схемы с двумя IP)
  --dns yes|no           DNS-фильтр AdGuard (по умолчанию yes)
  --no-dns               без DNS-фильтра AdGuard (то же, что --dns no)
  --autoupdate yes|no    автообновление ноды (по умолчанию yes)
  --no-autoupdate        без автообновления ноды (то же, что --autoupdate no)
  --alerts yes|no        алерты в Telegram (плюс --tg-token и --tg-chat)
  --no-alerts            без алертов в Telegram (то же, что --alerts no)
  --swap-size auto|off|1024M|2G   размер swap (auto — подбор под сервер)
  --swap-only            только swap: показать состояние, при необходимости
                         пересоздать и выйти; docker, Caddy, конфиги и
                         firewall не трогает (для уже установленной ноды)
  --upgrade-system       обновить все пакеты ОС (может перезапустить чужие службы)
  --skip-tuning          не трогать sysctl/swap/лимиты
  --skip-firewall        не настраивать ufw
  --skip-netcheck        не проверять сеть и DNS перед установкой
  --reconfigure          игнорировать сохранённые ответы
  --yes                  без вопросов (нужны флаги)
  -h, --help             эта справка
  -v, --version          версия

  Устаревшие флаги --xhttp-port / --grpc-port / --tcp-port (раньше было три
  отдельных порта) принимаются и задают общий --connect-port.
  Сами inbound'ы настраиваются в панели — установщику важен только firewall.

Примеры:
  bash install.sh
  bash install.sh --yes --node-port 2222 --panel-ip 1.2.3.4 --secret-key KEY \
      --connect-port 443 --hysteria yes \
      --domain vpn.example.com --template shop --two-ip --ip2 5.6.7.8
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)          ASSUME_YES=true ;;
        --reconfigure)     : ;;   # учтён на этапе пред-сканирования аргументов
        --skip-tuning)     SKIP_TUNING=true ;;
        --upgrade-system)  UPGRADE_SYSTEM=true ;;
        --swap-size)       SWAP_SIZE="${2:?}"; shift ;;
        --swap-only)       SWAP_ONLY=true ;;
        --skip-firewall)   SKIP_FIREWALL=true ;;
        --skip-netcheck)   SKIP_NETCHECK=true ;;
        --panel-ip)        PANEL_IP="${2:?}"; shift ;;
        --panel-port)      PANEL_PORT="${2-}"; shift || true ;;
        --node-port)       NODE_PORT="${2:?}"; shift ;;
        --secret-key)      SECRET_KEY="${2:?}"; shift ;;
        --connect-port)    CONNECT_PORT="${2:?}"; shift ;;
        --hysteria)        HYSTERIA="${2:?}"; shift ;;
        --no-hysteria)     HYSTERIA="no" ;;
        # старые флаги: три порта → один общий (первый непустой)
        --xhttp-port|--grpc-port|--tcp-port)
            if [ -n "${2:-}" ] && [ -z "$CONNECT_PORT" ]; then CONNECT_PORT="$2"; fi
            shift || true ;;
        --selfsteal)       USE_SELFSTEAL="${2:?}"; shift ;;
        --no-selfsteal)    USE_SELFSTEAL="no" ;;
        --domain)          DOMAIN="${2:?}"; shift ;;
        --selfsteal-port)  SELFSTEAL_PORT="${2:?}"; shift ;;
        --template)        TEMPLATE="${2:?}"; shift ;;
        --port)            NODE_PORT="${2:?}"; shift ;;
        --dual-ip)         DUAL_IP="${2:?}"; shift ;;
        --two-ip)          DUAL_IP="yes" ;;
        --one-ip)          DUAL_IP="no" ;;
        --ip2)             IP2="${2:?}"; DUAL_IP="yes"; shift ;;
        --ip1)             IP1="${2:?}"; shift ;;
        --dns)             USE_DNS="${2:?}"; shift ;;
        --no-dns)          USE_DNS="no" ;;
        --autoupdate)      AUTO_UPDATE="${2:?}"; shift ;;
        --no-autoupdate)   AUTO_UPDATE="no" ;;
        --alerts)          ALERTS="${2:?}"; shift ;;
        --no-alerts)       ALERTS="no" ;;
        --tg-token)        TG_TOKEN="${2:?}"; ALERTS="yes"; shift ;;
        --tg-chat)         TG_CHAT="${2:?}"; ALERTS="yes"; shift ;;
        -v|--version)      echo "remnawave node installer v$VERSION"; exit 0 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 1 ;;
    esac
    if [ $# -gt 0 ]; then shift; fi
done

# ---- нормализация булевых флагов (yes/no/true/да ...) ----------------------
norm_yn() { case "${1,,}" in yes|y|да|д|true|1|on) echo yes ;; *) echo no ;; esac; }

# Значение для answers.env/alerts.env: файлы читаются через `.`, поэтому
# одинарные кавычки и переводы строк обязаны пережить запись и чтение.
# Апостроф экранируется в стиле '\''; перевод строки — через $'...'.
env_quote() {
    local val="${1-}"
    case "$val" in
        *$'\n'*|*$'\r'*) printf '%q' "$val"; return 0 ;;
    esac
    printf "'%s'" "${val//\'/\'\\\'\'}"
}
USE_SELFSTEAL="$(norm_yn "$USE_SELFSTEAL")"
DUAL_IP="$(norm_yn "$DUAL_IP")"
USE_DNS="$(norm_yn "$USE_DNS")"
AUTO_UPDATE="$(norm_yn "$AUTO_UPDATE")"
ALERTS="$(norm_yn "$ALERTS")"

# ---- один порт вместо трёх: читаем и старые answers.env, и старые флаги -----
if [ -z "${CONNECT_PORT:-}" ]; then
    for _legacy_port in "${XHTTP_PORT:-}" "${GRPC_PORT:-}" "${TCP_PORT:-}"; do
        if [ -n "$_legacy_port" ]; then CONNECT_PORT="$_legacy_port"; break; fi
    done
    unset _legacy_port 2>/dev/null || true
fi
CONNECT_PORT="${CONNECT_PORT:-443}"
HYSTERIA="$(norm_yn "${HYSTERIA:-yes}")"

# ------------------------------------------------------------------ helpers
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[0;37m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

log()  { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
say()  { echo -e "$*"; log "$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')"; }
hdr()  { echo; say "${C_BLU}=== $* ===${C_OFF}"; }
ok()   { say "  ${C_GRN}[ok]${C_OFF} $*"; }
warn() { say "  ${C_YEL}[!!]${C_OFF} $*"; }
err()  { say "  ${C_RED}[xx]${C_OFF} $*"; }
note() { say "  ${C_DIM}$*${C_OFF}"; }
die()  { err "$*"; exit 1; }

is_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_ipv4() {
    local ip="${1%/*}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o
    IFS='.' read -r -a o <<< "$ip"
    for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done
    return 0
}

# Строгий host-IP: без маски, ведущих нулей, 0.0.0.0 и 255.255.255.255.
# is_ipv4 выше допускает CIDR (нужен для ufw), но IP2 идёт в net.env и в
# `ip addr add "$IP2/32"` — «1.2.3.4/24», «010.0.0.1» и 0.0.0.0 ломают юнит молча.
is_host_ipv4() {
    local ip="${1:-}" o x
    [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done
    case "$ip" in
        0.0.0.0|255.255.255.255) return 1 ;;
    esac
    return 0
}

is_domain() { [[ "${1:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

# SECRET_KEY пишется в answers.env (через env_quote) и в /opt/remnanode/.env
# без кавычек. Пробел, #, $ и \ ломают .env ноды, апостроф/перевод строки —
# нечитаемый при source answers.env (у старых версий). Такой ключ отвергаем
# до записи: иначе повторный запуск и nodego падают на нечитаемом файле.
secret_key_valid() {
    case "${1:-}" in
        ''|*"'"*|*$'\n'*|*'"'*|*[\\]*|*' '*|*'#'*|*'$'*) return 1 ;;
    esac
    return 0
}

detect_primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
}

# "2G" / "512M" / "1024" → мегабайты; "auto"/"off" → пустая строка
to_mb() {
    local v="${1:-}" n=""
    case "${v,,}" in
        ''|auto|off|no|none|0) echo ""; return 0 ;;
        *g) n="${v%[Gg]}" ;;
        *m) n="${v%[Mm]}" ;;
        *[!0-9]*) echo ""; return 0 ;;
        *) echo "$v"; return 0 ;;
    esac
    # Числовая часть — только целое: «1.5G», «0.5g», «G», «abcG», «1,5G» —
    # мусор, а не размер. Иначе $(( )) роняет установщик посреди раздела 5.
    case "$n" in
        ''|*[!0-9]*) echo ""; return 0 ;;
    esac
    case "${v,,}" in
        *g) echo $(( n * 1024 )) ;;
        *)  echo "$n" ;;
    esac
}

# Подбор размера swap: RAM + свободный диск.
#   <=512 МБ RAM  → 1 ГБ (маленькому VPS нужен запас)
#   <=8 ГБ RAM    → 2 ГБ (типовой VPS: страховка от OOM, не более)
#   >8 ГБ RAM     → 1 ГБ (только аварийный запас)
# Дополнительно: не больше 20% свободного диска, не меньше 512 МБ,
# и совсем не создаём, если свободно меньше 1 ГБ.
detect_swap_mb() {
    local ram="${1:-1024}" free="${2:-0}" mb max_disk
    if [ "$ram" -le 512 ]; then
        mb=1024
    elif [ "$ram" -le 8192 ]; then
        mb=2048
    else
        mb=1024
    fi
    max_disk=$(( free / 5 ))
    max_disk=$(( max_disk / 256 * 256 ))   # округляем вниз до 256 МБ
    if [ "$mb" -gt "$max_disk" ]; then mb="$max_disk"; fi
    if [ "$mb" -gt 4096 ]; then mb=4096; fi
    if [ "$free" -lt 1024 ]; then
        mb=0
    elif [ "$mb" -lt 512 ]; then
        mb=512
    fi
    echo "$mb"
}

# Пояснение к рекомендации: откуда взялось число (показывается в консоли).
swap_hint() {
    local ram="${1:-0}" free="${2:-0}" base cap
    case "$ram"  in ''|*[!0-9]*) ram=0 ;; esac
    case "$free" in ''|*[!0-9]*) free=0 ;; esac
    if [ "$free" -lt 1024 ]; then
        echo "на диске свободно меньше 1 ГБ"
        return 0
    fi
    if [ "$ram" -le 512 ]; then base=1024
    elif [ "$ram" -le 8192 ]; then base=2048
    else base=1024
    fi
    cap=$(( free / 5 / 256 * 256 ))
    if [ "$base" -gt "$cap" ]; then
        echo "RAM ${ram} МБ → ${base} МБ, но диск режет до 20% от ${free} МБ (${cap} МБ)"
    elif [ "$ram" -le 512 ]; then
        echo "RAM ${ram} МБ (≤ 512) → запас 1 ГБ"
    elif [ "$ram" -le 8192 ]; then
        echo "RAM ${ram} МБ (1–8 ГБ) → страховка от OOM, 2 ГБ"
    else
        echo "RAM ${ram} МБ (> 8 ГБ) → аварийный запас 1 ГБ"
    fi
}

# Создать swap-файл нужного размера (без включения): fallocate, при неудаче dd.
swap_format() { # swap_format FILE SIZE_MB
    local f="$1" mb="$2"
    rm -f "$f" 2>/dev/null || true
    if ! fallocate -l "${mb}M" "$f" 2>/dev/null; then
        if ! dd if=/dev/zero of="$f" bs=1M count="$mb" status=none 2>/dev/null; then
            dd if=/dev/zero of="$f" bs=1M count="$mb" 2>/dev/null || {
                rm -f "$f" 2>/dev/null || true
                return 1
            }
        fi
    fi
    chmod 600 "$f" 2>/dev/null || true
    mkswap "$f" >/dev/null 2>&1 || return 1
    return 0
}

fstab_swap_ensure() { # строка для swap-файла в /etc/fstab
    local f="$1"
    grep -q "^[[:space:]]*${f}[[:space:]]" /etc/fstab 2>/dev/null && return 0
    printf '%s none swap sw 0 0\n' "$f" >> /etc/fstab
}

fstab_swap_drop() { # убрать строку прежнего swap из /etc/fstab
    local f="$1"
    [ -n "$f" ] || return 0
    [ -f /etc/fstab ] || return 0
    grep -q "^[[:space:]]*${f}[[:space:]]" /etc/fstab 2>/dev/null || return 0
    backup /etc/fstab
    sed -i "\|^[[:space:]]*${f}[[:space:]]|d" /etc/fstab
}

# --- swap ---------------------------------------------------------------
# Пересоздание swap по характеристикам сервера. Функция нужна дважды: в
# основном потоке (раздел «Тюнинг системы») и в режиме --swap-only — чтобы
# не держать две копии логики с проверками безопасности.
swap_section() {
    # RAM и диск читаем из /proc/meminfo и df: free/swapon из procps на
    # минимальном образе может отсутствовать, а /proc есть всегда.
    # Главное отличие от прежней версии: показываем и учитываем swap, который уже
    # включён провайдером (типовая картинка VPS — /swapfile или /swap.img на
    # 512 МБ). Раньше такой swap молча оставляли, и «на любом сервере выходило
    # 512 МБ», хотя рекомендация была другой.
    RAM_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    RAM_MB="${RAM_MB:-1024}"
    FREE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    FREE_MB="${FREE_MB:-0}"
    REC_SWAP="$(detect_swap_mb "$RAM_MB" "$FREE_MB")"

    _swapinfo="$(awk '/^SwapTotal:/{t=int($2/1024)} /^SwapFree:/{f=int($2/1024)} END{printf "%d %d", t+0, t-f}' /proc/meminfo 2>/dev/null || true)"
    CUR_SWAP_MB="${_swapinfo%% *}"
    SWAP_USED_MB="${_swapinfo##* }"
    unset _swapinfo 2>/dev/null || true
    case "$CUR_SWAP_MB" in ''|*[!0-9]*) CUR_SWAP_MB=0 ;; esac
    case "$SWAP_USED_MB" in ''|*[!0-9]*) SWAP_USED_MB=0 ;; esac
    SWAP_DEV="$(swapon --show=NAME --noheadings 2>/dev/null | awk 'NF{print $1; exit}' || true)"

    if [ "$CUR_SWAP_MB" -gt 0 ]; then
        say "  RAM: ${RAM_MB} МБ · диск: свободно ${FREE_MB} МБ · swap: включён ${CUR_SWAP_MB} МБ (${SWAP_DEV:-?}, занято ${SWAP_USED_MB} МБ)"
    else
        say "  RAM: ${RAM_MB} МБ · диск: свободно ${FREE_MB} МБ · swap: не включён"
    fi
    if [ "$REC_SWAP" -gt 0 ]; then
        say "  рекомендация для этого сервера: ${REC_SWAP} МБ — $(swap_hint "$RAM_MB" "$FREE_MB")"
    else
        warn "  рекомендация для этого сервера: swap не создавать — $(swap_hint "$RAM_MB" "$FREE_MB")"
    fi

    # ---- сколько ставить -------------------------------------------------
    SWAP_TARGET=""
    SWAP_AUTO_CHOICE=false
    case "${SWAP_SIZE,,}" in
        auto|'')
            SWAP_TARGET="$REC_SWAP"
            SWAP_AUTO_CHOICE=true
            if [ "$ASSUME_YES" = false ]; then
                # В подсказке стоит само число, поэтому Enter = ровно то, что
                # написано в «рекомендация», без «угадай, что будет».
                _swap_def="$REC_SWAP"
                [ "${_swap_def:-0}" -eq 0 ] && _swap_def="off"
                while :; do
                    swap_choice=""
                    ask swap_choice "Размер swap (1024M / 2G / off; Enter — рекомендация)" "$_swap_def"
                    case "${swap_choice,,}" in
                        ''|auto|да|д|yes|y|on)
                            SWAP_TARGET="$REC_SWAP"; SWAP_AUTO_CHOICE=true; break ;;
                        off|no|none|0|нет|н)
                            SWAP_TARGET=0; SWAP_AUTO_CHOICE=false; break ;;
                        *)
                            _mb="$(to_mb "$swap_choice")"
                            case "${_mb:-x}" in
                                ''|*[!0-9]*)
                                    warn "не понял «$swap_choice» — напишите размер: 1024M, 2G или off"
                                    continue ;;
                            esac
                            if [ "$_mb" -lt 128 ]; then
                                warn "меньше 128 МБ swap не делаю — 1024M, 2G или off"
                                continue
                            fi
                            SWAP_TARGET="$_mb"
                            [ "$_mb" -eq "$REC_SWAP" ] || SWAP_AUTO_CHOICE=false
                            break ;;
                    esac
                done
                unset _swap_def _mb 2>/dev/null || true
            fi
            ;;
        off|no|none|0)
            SWAP_TARGET=0
            ;;
        *)
            SWAP_TARGET="$(to_mb "$SWAP_SIZE")"
            if ! [[ "${SWAP_TARGET:-}" =~ ^[0-9]+$ ]] || [ "${SWAP_TARGET:-0}" -lt 128 ]; then
                warn "некорректный --swap-size «$SWAP_SIZE» — беру рекомендацию ${REC_SWAP} МБ"
                SWAP_TARGET="$REC_SWAP"
                SWAP_AUTO_CHOICE=true
            fi
            ;;
    esac

    # ---- применяем -------------------------------------------------------
    SWAP_APPLIED_MB="$CUR_SWAP_MB"
    _swap_is_file=true
    case "$SWAP_DEV" in
        /dev/*) _swap_is_file=false ;;   # swap на разделе — не трогаем
    esac

    if [ "${SWAP_TARGET:-0}" -eq 0 ]; then
        if [ "$CUR_SWAP_MB" -gt 0 ]; then
            note "swap не трогаю: уже включён ${CUR_SWAP_MB} МБ${SWAP_DEV:+ ($SWAP_DEV)}"
        else
            warn "Swap не создаётся (мало места или выключено вручную)"
        fi
    elif [ "$CUR_SWAP_MB" -gt 0 ] && [ "$CUR_SWAP_MB" -eq "$SWAP_TARGET" ]; then
        ok "Swap ${SWAP_TARGET} МБ уже включён — как и планировалось"
    else
        _do_swap=true
        if [ "$CUR_SWAP_MB" -gt 0 ]; then
            if [ "$_swap_is_file" = false ]; then
                _do_swap=false
                warn "swap на разделе ${SWAP_DEV:-?} — разделы не трогаю (нужно ${SWAP_TARGET} МБ)"
            else
                # swapoff возвращает занятое в RAM, поэтому решение не «сколько
                # процентов занято», а «хватит ли памяти это принять». Прежнее
                # правило «больше 20% — не трогаем» ложно срабатывало на
                # провайдерских 512 МБ: 110 МБ занято = 21%, а вернуть их в 2 ГБ
                # RAM безопасно.
                _avail_mb="$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
                case "$_avail_mb" in ''|*[!0-9]*) _avail_mb=0 ;; esac
                if [ "$SWAP_USED_MB" -gt 1024 ] || [ $(( _avail_mb - SWAP_USED_MB )) -lt 128 ]; then
                    _do_swap=false
                    warn "в swap занято ${SWAP_USED_MB} МБ, доступно RAM ${_avail_mb} МБ — swapoff рискован, не пересоздаю (нужно ${SWAP_TARGET} МБ)"
                elif [ "$ASSUME_YES" = false ]; then
                    say "  сейчас: swap ${CUR_SWAP_MB} МБ (${SWAP_DEV:-?}), занято ${SWAP_USED_MB} МБ"
                    say "  по плану: swap ${SWAP_TARGET} МБ"
                    SWAP_RESIZE=""
                    ask_yesno SWAP_RESIZE "Пересоздать swap под размер сервера?" "д"
                    [ "$SWAP_RESIZE" = "no" ] && _do_swap=false
                fi
                unset _avail_mb 2>/dev/null || true
            fi
        fi

        if [ "$_do_swap" = true ]; then
            _swap_tmp="/swapfile.new"
            _ok_swap=false
            _file_mb=0
            [ -f /swapfile ] && _file_mb=$(( $(stat -c %s /swapfile 2>/dev/null || echo 0) / 1048576 ))
            if [ "$CUR_SWAP_MB" -eq 0 ] && [ "$_file_mb" -eq "$SWAP_TARGET" ]; then
                # уже нужного размера и не включён — только переформатировать
                chmod 600 /swapfile 2>/dev/null || true
                mkswap /swapfile >/dev/null 2>&1 || true
                _ok_swap=true
            elif ! swap_format "$_swap_tmp" "$SWAP_TARGET"; then
                warn "не удалось подготовить swap-файл ${SWAP_TARGET} МБ — оставляю как есть"
            elif [ "$CUR_SWAP_MB" -gt 0 ] && ! swapoff "$SWAP_DEV" 2>/dev/null; then
                rm -f "$_swap_tmp" 2>/dev/null || true
                warn "swapoff ${SWAP_DEV:-?} не удался — swap оставляю прежним"
            else
                if [ "$CUR_SWAP_MB" -gt 0 ]; then
                    case "$SWAP_DEV" in
                        /swapfile|/swap.img|/swap) rm -f "$SWAP_DEV" 2>/dev/null || true ;;
                    esac
                    fstab_swap_drop "$SWAP_DEV"
                fi
                mv -f "$_swap_tmp" /swapfile 2>/dev/null || \
                    cp -f "$_swap_tmp" /swapfile 2>/dev/null || true
                rm -f "$_swap_tmp" 2>/dev/null || true
                chmod 600 /swapfile 2>/dev/null || true
                _ok_swap=true
            fi

            if [ "$_ok_swap" = true ]; then
                if swapon /swapfile 2>/dev/null; then
                    fstab_swap_ensure /swapfile
                    SWAP_APPLIED_MB="$SWAP_TARGET"
                    if [ "$CUR_SWAP_MB" -gt 0 ]; then
                        ok "Swap пересоздан: ${CUR_SWAP_MB} МБ → ${SWAP_TARGET} МБ (закреплён в /etc/fstab)"
                    else
                        ok "Swap ${SWAP_TARGET} МБ создан и закреплён в /etc/fstab (RAM ${RAM_MB} МБ, диск ${FREE_MB} МБ)"
                    fi
                else
                    warn "swapon не сработал — swap выключен, включите вручную: swapon /swapfile"
                fi
            fi
            unset _swap_tmp _file_mb _ok_swap 2>/dev/null || true
        fi
    fi
    unset _swap_is_file _do_swap 2>/dev/null || true

    # В /etc/fstab поменялась строка swap — systemd мог сгенерировать .swap-юнит
    # от прежней записи, перечитываем (в режиме --swap-only это единственное
    # место, где случается daemon-reload).
    systemctl daemon-reload 2>/dev/null || true

    # Запоминаем выбор для повторного запуска: auto остаётся auto (при следующем
    # запуске размер пересчитается под сервер), явный размер — как есть.
    if [ -f "$ANSWERS_FILE" ]; then
        if [ "$SWAP_AUTO_CHOICE" = true ]; then
            SWAP_REC="auto"
        elif [ "${SWAP_APPLIED_MB:-0}" -gt 0 ]; then
            SWAP_REC="${SWAP_APPLIED_MB}M"
        else
            SWAP_REC="off"
        fi
        sed -i '/^SWAP_SIZE=/d' "$ANSWERS_FILE"
        printf "SWAP_SIZE='%s'\n" "$SWAP_REC" >> "$ANSWERS_FILE"
    fi
}

ask() { # ask VAR "текст" "дефолт"
    local __var="$1" __prompt="$2" __def="${3:-}" __val=""
    if [ "$ASSUME_YES" = true ] && [ -n "${!__var:-}" ]; then return 0; fi
    if [ -n "$__def" ]; then
        read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} [${__def}]: ")" __val || true
        [ -z "$__val" ] && __val="$__def"
    else
        read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF}: ")" __val || true
    fi
    printf -v "$__var" '%s' "$__val"
}

ask_yesno() { # ask_yesno VAR "текст" default(y/n)
    local __var="$1" __prompt="$2" __def="${3:-y}" __val="" __hint
    if [ "$ASSUME_YES" = true ] && [ -n "${!__var:-}" ]; then return 0; fi
    case "${__def,,}" in
        y|yes|да|д|1|true|on) __def=y ;;
        *) __def=n ;;
    esac
    if [ "$__def" = "y" ]; then __hint="Д/н"; else __hint="д/Н"; fi
    while true; do
        read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} [${__hint}]: ")" __val || true
        __val="${__val:-$__def}"
        case "${__val,,}" in
            y|yes|д|да) printf -v "$__var" '%s' "yes"; return 0 ;;
            n|no|н|нет) printf -v "$__var" '%s' "no"; return 0 ;;
            *) warn "Ответьте «д» (да) или «н» (нет)" ;;
        esac
    done
}

backup() {
    local f="$1"
    [ -e "$f" ] || return 0
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
}

fetch() { # fetch URL DEST
    local url="$1" dest="$2"
    # --max-time: без него загрузка шаблона/скрипта может висеть бесконечно.
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$url" -o "$dest"
}

compose() { docker compose "$@"; }

# Проверяем API, а не клиентские inbound'ы: их панель ещё могла не прислать.
wait_service() { # контейнер, TCP-порт, число попыток
    local container="$1" port="$2" attempts="${3:-30}" n=0 good=0
    while [ "$n" -lt "$attempts" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] \
            && ss -tlnH "sport = :$port" 2>/dev/null | grep -q . \
            && check_port_owner "$port" "$container"; then
            good=$((good + 1))
            [ "$good" -ge 3 ] && return 0
        else
            good=0
        fi
        n=$((n + 1))
        sleep 2
    done
    return 1
}

# Разрешаем занятый порт только при доказанном владельце из нашего контейнера.
check_port_owner() { # порт, контейнер
    local port="$1" container="$2" listeners pids pid owners listener
    listeners="$(ss -tlnpH "sport = :$port" 2>/dev/null)" || return 1
    [ -n "$listeners" ] || return 0
    owners="$(docker top "$container" -eo pid 2>/dev/null | awk 'NR>1 {print $1}')" || return 1
    while IFS= read -r listener; do
        pids="$(printf '%s\n' "$listener" | grep -oE 'pid=[0-9]+' | cut -d= -f2)" || return 1
        [ -n "$pids" ] || return 1
        for pid in $pids; do
            printf '%s\n' "$owners" | grep -qx "$pid" || return 1
        done
    done <<< "$listeners"
}

snapshot_node() {
    NODE_SNAPSHOT="$(mktemp -d "$NODE_DIR/.install-backup.XXXXXXXX")" || return 1
    chmod 700 "$NODE_SNAPSHOT"
    local name
    for name in .env docker-compose.yml; do
        if [ -e "$NODE_DIR/$name" ]; then
            cp -a "$NODE_DIR/$name" "$NODE_SNAPSHOT/$name" || return 1
        fi
    done
    NODE_OLD_IMAGE="$(docker inspect -f '{{.Image}}' remnanode 2>/dev/null || true)"
    NODE_OLD_REF="$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null || true)"
    if [ -n "$NODE_OLD_IMAGE" ]; then
        docker tag "$NODE_OLD_IMAGE" remnawave/node:installer-rollback || return 1
    fi
}

rollback_node() {
    local name old_port
    # На новой установке нечего восстанавливать; оставляем файлы для диагностики.
    [ -f "$NODE_SNAPSHOT/docker-compose.yml" ] || return 0
    for name in .env docker-compose.yml; do
        if [ -e "$NODE_SNAPSHOT/$name" ]; then
            cp -a "$NODE_SNAPSHOT/$name" "$NODE_DIR/$name" || return 1
        fi
    done
    [ -n "$NODE_OLD_IMAGE" ] || return 1
    printf 'services:\n  remnanode:\n    image: %s\n' "$NODE_OLD_IMAGE" > "$NODE_SNAPSHOT/rollback.yml" || return 1
    ( cd "$NODE_DIR" && compose -f docker-compose.yml -f "$NODE_SNAPSHOT/rollback.yml" up -d --pull never remnanode ) || return 1
    old_port="$(sed -n 's/^NODE_PORT=//p' "$NODE_DIR/.env" | tr -d '\"\047\r' | head -n1)"
    wait_service remnanode "$old_port" || return 1
    case "$NODE_OLD_REF" in
        ''|*@*|sha256:*) : ;;
        *) docker tag "$NODE_OLD_IMAGE" "$NODE_OLD_REF" || return 1 ;;
    esac
}

start_node() {
    (
        cd "$NODE_DIR" || exit 1
        compose pull -q || warn "образ не скачался — пробую локальный"
        compose up -d || exit 1
    ) || return 1
    wait_service remnanode "$NODE_PORT"
}

start_caddy() {
    local old_image rollback
    # Одноразовый контейнер видит актуальные bind-mount, не старый inode.
    (
        cd "$SELFSTEAL_DIR" || exit 1
        compose config -q || exit 1
        compose run --rm --no-deps --entrypoint caddy caddy validate \
            --config /etc/caddy/Caddyfile --adapter caddyfile
    ) || return 1
    old_image="$(docker inspect -f '{{.Image}}' selfsteal 2>/dev/null || true)"
    if ( cd "$SELFSTEAL_DIR" && compose up -d ) && wait_service selfsteal "$SELFSTEAL_PORT"; then
        return 0
    fi
    if [ -n "$old_image" ]; then
        rollback="$(mktemp "$SELFSTEAL_DIR/.rollback.XXXXXX.yml")" || return 1
        printf 'services:\n  caddy:\n    image: %s\n' "$old_image" > "$rollback" || return 1
        if ( cd "$SELFSTEAL_DIR" && compose -f docker-compose.yml -f "$rollback" up -d --pull never caddy ) \
            && wait_service selfsteal "$SELFSTEAL_PORT"; then
            warn "Восстановлен прежний образ Caddy; текущая установка завершится ошибкой."
            rm -f "$rollback"
        else
            warn "Откат Caddy не прошёл проверку; override сохранён: $rollback"
        fi
    fi
    return 1
}

# UFW аддитивен: узкое правило не отменяет прежние широкие разрешения.
check_api_firewall() {
    local rules sshports status
    # UFW может быть активен с «default allow incoming»: широких правил нет,
    # а API всё равно открыт всему интернету. Политику проверяем отдельно.
    status="$(LC_ALL=C ufw status verbose 2>/dev/null || true)"
    if printf '%s\n' "$status" | grep -q '^Status: active'; then
        if ! printf '%s\n' "$status" | grep -qE '^Default: deny \(incoming\)'; then
            warn "UFW активен, но политика по умолчанию не «deny incoming» — API $NODE_PORT открыт всем. Выполните: ufw default deny incoming"
            return 1
        fi
    elif ! grep -qE '^DEFAULT_INPUT_POLICY="?DROP"?$' /etc/default/ufw 2>/dev/null; then
        warn "UFW выключен, а /etc/default/ufw не задаёт DEFAULT_INPUT_POLICY=\"DROP\" — после включения API $NODE_PORT будет открыт всем. Выполните: ufw default deny incoming"
        return 1
    fi
    rules="$(LC_ALL=C ufw show added)" || return 1
    # OpenSSH часто уже разрешён на VPS; доверяем не имени, а портам профиля.
    sshports="$(LC_ALL=C ufw app info OpenSSH 2>/dev/null | awk '/^Ports?:/ {found=1; next} found && NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' || true)"
    if printf '%s\n' "$rules" | awk -v port="$NODE_PORT" -v panel="$PANEL_IP" -v sshports="$sshports" '
        /^ufw allow / {
            if (index($0, "from " panel " to ") || index($0, "from " panel "/32 to ")) next
            dest=$3
            if (dest=="OpenSSH") dest=sshports
            for (i=3;i<=NF;i++) if ($i=="port") dest=$(i+1)
            sub(/\/(tcp|udp)$/, "", dest)
            # Неизвестный профиль приложения/Anywhere тоже требует ручной проверки.
            if (dest !~ /^[0-9,:]+$/) { bad=1; next }
            count=split(dest, items, ",")
            for (j=1;j<=count;j++) {
                n=split(items[j], bounds, ":")
                if ((n==1 && bounds[1]==port) || (n==2 && bounds[1]<=port && bounds[2]>=port)) bad=1
            }
        }
        END { exit !bad }
    '; then
        warn "UFW: прежние разрешения могут открывать API $NODE_PORT не только панели. Чужие правила не удалены; проверьте ufw show added."
        return 1
    fi
}

# Все SSH-порты. При «Port 22» + «Port 2222» админ ходит на второй, а раньше
# в ufw открывался только первый — после ufw enable это lockout. Если sshd -T
# не отработал, смотрим фактические слушатели sshd; пустой список — не гадаем
# про 22, а честно падаем до включения ufw.
ssh_ports() {
    local ports="" p out=""
    ports="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -un || true)"
    if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
        ports="$(ss -tlnpH 2>/dev/null | awk '/users:\(\("sshd"/ {n=split($4,a,":"); print a[n]}' | sort -un || true)"
    fi
    if [ -z "$ports" ] && command -v netstat >/dev/null 2>&1; then
        ports="$(netstat -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -un || true)"
    fi
    for p in $ports; do
        is_port "$p" || continue
        out="${out}${out:+$'\n'}$p"
    done
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Сохраняем только булев DNS-флаг после успешной транзакции.
set_answer() {
    [ "$1" = USE_DNS ] || return 1
    sed -i '/^USE_DNS=/d' "$ANSWERS_FILE" || return 1
    printf "USE_DNS='%s'\n" "$2" >> "$ANSWERS_FILE"
}

# BEGIN DNS_TRANSACTION — общий формат снимка для установщика и nodego.
dns_path() {
    case "$1" in
        resolved.conf) printf '%s\n' /etc/systemd/resolved.conf ;;
        resolv.conf) printf '%s\n' /etc/resolv.conf ;;
        cloud.conf) printf '%s\n' /etc/cloud/cloud.cfg.d/99-remnawave-resolv.cfg ;;
        adguard.conf) printf '%s\n' /etc/systemd/resolved.conf.d/99-adguard-dot.conf ;;
        *) return 1 ;;
    esac
}

dns_snapshot() {
    local dest="$1" key path enabled active
    enabled="$(systemctl is-enabled systemd-resolved 2>/dev/null)" || true
    active="$(systemctl is-active systemd-resolved 2>/dev/null)" || true
    case "$enabled" in enabled|enabled-runtime|disabled|static|indirect) ;; *) err "неподдерживаемое состояние systemd-resolved: $enabled"; return 1 ;; esac
    case "$active" in active|inactive) ;; *) err "нестабильное состояние systemd-resolved: $active"; return 1 ;; esac
    mkdir -m 700 "$dest" || return 1
    for key in resolved.conf resolv.conf cloud.conf adguard.conf; do
        path="$(dns_path "$key")" || return 1
        if [ -e "$path" ] || [ -L "$path" ]; then
            [ ! -d "$path" ] || return 1
            cp -a -- "$path" "$dest/$key" || return 1
        else
            : > "$dest/$key.absent" || return 1
        fi
    done
    printf '%s\n' "$enabled" > "$dest/enabled" || return 1
    printf '%s\n' "$active" > "$dest/active" || return 1
    : > "$dest/complete"
}

dns_restore() {
    local src="$1" key path enabled active
    [ -f "$src/complete" ] || return 1
    read -r enabled < "$src/enabled" || return 1
    read -r active < "$src/active" || return 1
    # Проверяем весь снимок до первого изменения.
    case "$enabled" in enabled|enabled-runtime|disabled|static|indirect) ;; *) return 1 ;; esac
    case "$active" in active|inactive) ;; *) return 1 ;; esac
    for key in resolved.conf resolv.conf cloud.conf adguard.conf; do
        [ -e "$src/$key" ] || [ -L "$src/$key" ] || [ -f "$src/$key.absent" ] || return 1
    done
    for key in resolved.conf resolv.conf cloud.conf adguard.conf; do
        path="$(dns_path "$key")" || return 1
        rm -f -- "$path" || return 1
        if [ ! -f "$src/$key.absent" ]; then
            cp -a -- "$src/$key" "$path" || return 1
        fi
    done
    case "$enabled" in
        enabled) systemctl enable systemd-resolved >/dev/null 2>&1 || return 1 ;;
        enabled-runtime) systemctl disable systemd-resolved >/dev/null 2>&1 && systemctl enable --runtime systemd-resolved >/dev/null 2>&1 || return 1 ;;
        *) systemctl disable systemd-resolved >/dev/null 2>&1 || return 1 ;;
    esac
    if [ "$active" = active ]; then
        systemctl restart systemd-resolved >/dev/null 2>&1
    else
        systemctl stop systemd-resolved >/dev/null 2>&1
    fi
}

# Совпадает ли текущее состояние с полным снимком. Нужно, чтобы отличить
# «прошлый сбой: trap уже вернул исходные файлы, снимок можно переиспользовать»
# от «файлы после сбоя меняли руками, перезаписывать их нельзя».
dns_snapshot_matches() {
    local snap="$1" key path
    [ -f "$snap/complete" ] || return 1
    for key in resolved.conf resolv.conf cloud.conf adguard.conf; do
        path="$(dns_path "$key")" || return 1
        if [ -f "$snap/$key.absent" ]; then
            # В снимке файла не было — сейчас его тоже быть не должно.
            if [ -e "$path" ] || [ -L "$path" ]; then return 1; fi
        elif [ -L "$snap/$key" ]; then
            # В снимке был симлинк — сверяем и тип, и цель.
            if [ ! -L "$path" ]; then return 1; fi
            if [ "$(readlink -- "$snap/$key")" != "$(readlink -- "$path")" ]; then return 1; fi
        else
            if [ ! -f "$path" ] || [ -L "$path" ]; then return 1; fi
            cmp -s -- "$snap/$key" "$path" || return 1
        fi
    done
    return 0
}

dns_probe() {
    # Проверяем реальное разрешение имён, а не только статус службы.
    timeout 20 getent ahostsv4 example.com >/dev/null 2>&1
}

dns_change() (
    local mode="$1" backup="$STATE_DIR/dns-backup" lock="$STATE_DIR/dns-lock"
    local work="" rollback="" committed=false conf rc=0
    umask 077
    mkdir -p "$STATE_DIR" || return 1
    mkdir -m 700 "$lock" 2>/dev/null || { err "DNS уже изменяется; проверьте $lock"; return 1; }
    # Ловушки действуют только в этой подоболочке; при сбое снимок сохраняется.
    trap 'rc=$?; if [ "$committed" = false ]; then err "изменение DNS не завершено"; if [ -n "$rollback" ]; then dns_restore "$rollback" || err "откат DNS не завершён; снимок: $rollback"; warn "снимок сохранён для восстановления: $rollback"; fi; fi; rmdir "$lock"; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    conf="$(dns_path adguard.conf)" || return 1
    if [ "$mode" = on ]; then
        if [ -e "$conf" ] || [ -L "$conf" ]; then
            err "DNS уже настроен или остался снимок $backup; сначала восстановите исходное состояние"
            return 1
        fi
        if [ -e "$backup" ] || [ -L "$backup" ]; then
            # Прошлое включение не удалось: снимок полный, trap уже вернул файлы,
            # но каталог остался и раньше блокировал повтор навсегда. Повторяем
            # с этим же снимком (не удаляя его), но только если текущее состояние
            # ему соответствует — иначе не перезаписываем чужие правки.
            if dns_snapshot_matches "$backup"; then
                note "снимок прошлого запуска подходит — повторяю с ним"
                rollback="$backup"
            else
                err "DNS уже настроен или остался снимок $backup; сначала восстановите исходное состояние"
                return 1
            fi
        else
            dns_snapshot "$backup" || { err "снимок DNS не создан полностью; проверьте $backup перед повтором"; return 1; }
            rollback="$backup"
        fi
        mkdir -p "$(dirname "$conf")" || return 1
        # Списки сбрасываем в drop-in, основной resolved.conf не редактируем.
        cat > "$conf" <<'EOF' || return 1
[Resolve]
DNS=
DNS=94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com
FallbackDNS=
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
EOF
        local cloud
        cloud="$(dns_path cloud.conf)" || return 1
        if [ -d "$(dirname "$cloud")" ]; then
            # Не пишем через возможную ссылку на чужой конфиг.
            rm -f -- "$cloud" || return 1
            printf '%s\n' '# Remnawave: resolv.conf управляется systemd-resolved' 'manage_resolv_conf: false' > "$cloud" || return 1
        fi
        systemctl enable systemd-resolved >/dev/null 2>&1 || return 1
        systemctl restart systemd-resolved >/dev/null 2>&1 || return 1
        systemctl is-active --quiet systemd-resolved || return 1
        ln -sfn /run/systemd/resolve/stub-resolv.conf "$(dns_path resolv.conf)" || return 1
        resolvectl flush-caches >/dev/null 2>&1 || return 1
        timeout 20 resolvectl query example.com >/dev/null 2>&1 || return 1
        dns_probe || { err "DNS не отвечает; восстанавливаю исходные настройки"; return 1; }
        set_answer USE_DNS yes || return 1
        committed=true
        ok "AdGuard включён, исходный DNS сохранён в $backup"
    elif [ "$mode" = off ]; then
        if [ ! -f "$backup/complete" ]; then
            err "нет исходного снимка DNS (старая установка): автоматический откат небезопасен"
            warn "восстановите исходные resolved.conf и resolv.conf из своего бэкапа; текущие файлы не изменены"
            return 1
        fi
        work="$(mktemp -d "$STATE_DIR/dns-current.XXXXXXXXXX")" || return 1
        dns_snapshot "$work/snapshot" || return 1
        rollback="$work/snapshot"
        dns_restore "$backup" || return 1
        dns_probe || { err "исходный DNS не отвечает; возвращаю AdGuard"; return 1; }
        set_answer USE_DNS no || return 1
        committed=true
        rm -rf -- "$backup" "$work" || return 1
        ok "AdGuard выключен, исходные файлы и состояние службы восстановлены"
    else
        return 1
    fi
)
# END DNS_TRANSACTION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# ============================================================================
#  Проверка сети и DNS (до установки)
# ============================================================================
net_check() {
    local pub_ip="" le_code="" zs_code="" gh_code="" dh_code="" a_ip="" warned=0 local_ips="" expect_ips=""

    hdr "Проверка сети и DNS"

    pub_ip="$(curl -4 -fsS --max-time 8 https://ifconfig.io 2>/dev/null || true)"
    if [ -n "$pub_ip" ]; then
        ok "внешний IP (выход): $pub_ip"
    else
        warn "не удалось определить внешний IP — проверьте выход в интернет"
        warned=$((warned + 1))
    fi

    # A-запись домена должна указывать на тот адрес, на который подключаются
    # клиенты: в схеме с двумя IP это IP входа (--ip1), а не адрес выхода.
    if [ "$DUAL_IP" = "yes" ] && [ -n "${IP1:-}" ] && [ "$IP1" != "$pub_ip" ]; then
        note "IP входа: $IP1 (выход — $pub_ip)"
    fi

    # Адреса, реально назначенные на этом сервере (NAT/докупленные IP,
    # когда автоопределение показывает не то)
    local_ips="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' || true)"

    # A-запись сверяем со всеми «своими» адресами (интерфейсы + IP входа +
    # внешний), а не с одним автоопределённым: при NAT и дополнительных
    # адресах ifconfig.io показывает адрес выхода и даёт ложную тревогу
    # на полностью рабочем домене.
    expect_ips="$local_ips"
    if [ -n "${IP1:-}" ] && ! printf '%s\n' "$expect_ips" | grep -qx "$IP1"; then
        expect_ips="$expect_ips"$'\n'"$IP1"
    fi
    if [ -n "$pub_ip" ] && ! printf '%s\n' "$expect_ips" | grep -qx "$pub_ip"; then
        expect_ips="$expect_ips"$'\n'"$pub_ip"
    fi

    if [ "$USE_SELFSTEAL" = "yes" ] && [ -n "${DOMAIN:-}" ]; then
        a_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
        if [ -z "$a_ip" ]; then
            warn "домен $DOMAIN не резолвится — сертификат не выпустится"
            warned=$((warned + 1))
        elif printf '%s\n' "$expect_ips" | grep -qx "$a_ip"; then
            ok "DNS: $DOMAIN → $a_ip"
        else
            note "A-запись $DOMAIN → $a_ip; адреса этого сервера: $(printf '%s' "$local_ips" | tr '\n' ' ')"
            note "если DNS меняли только что — подождите TTL (5–10 мин); HTTP-01 сверяет A-запись в момент выпуска"
        fi
    fi

    le_code="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 8 \
        https://acme-v02.api.letsencrypt.org/directory 2>/dev/null || true)"
    if [ "$le_code" = "200" ]; then
        ok "ACME: Let's Encrypt доступен"
    else
        zs_code="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 8 \
            https://acme.zerossl.com/v2/DV90 2>/dev/null || true)"
        warned=$((warned + 1))
        if [ "$zs_code" = "200" ]; then
            warn "Let's Encrypt недоступен (${le_code:-нет ответа}) — похоже, блокировка у хостера"
            note "ZeroSSL доступен: сертификат можно выпустить через DNS-01 (acme.sh)"
        else
            warn "ACME-API недоступны: LE=${le_code:-?}, ZeroSSL=${zs_code:-?}"
            note "автоматический сертификат не выпустится — нужен ручной или DNS-01"
        fi
    fi

    gh_code="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/templates/manifest.tsv" \
        2>/dev/null || true)"
    if [ "$gh_code" = "200" ]; then
        ok "GitHub raw доступен"
    else
        warn "GitHub raw недоступен (${gh_code:-timeout}) — шаблоны и nodego не скачаются"
        warned=$((warned + 1))
    fi

    dh_code="$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 \
        https://registry-1.docker.io/v2/ 2>/dev/null || true)"
    case "$dh_code" in
        200|401|403) ok "Docker Hub доступен" ;;
        *)
            warn "Docker Hub недоступен (${dh_code:-timeout}) — образы не скачаются"
            warned=$((warned + 1))
            ;;
    esac

    # Порт панели не нужен для работы ноды: соединение всегда панель → нода
    # (NODE_PORT). Проверка только по явному --panel-port, иначе молчим.
    if [ -n "${PANEL_PORT:-}" ]; then
        if timeout 4 bash -c "echo > /dev/tcp/${PANEL_IP}/${PANEL_PORT}" 2>/dev/null; then
            ok "панель ${PANEL_IP}:${PANEL_PORT} отвечает (информационно, для ноды не нужно)"
        else
            note "панель ${PANEL_IP}:${PANEL_PORT} не отвечает — не критично, нода подключается не сама"
        fi
    fi

    if [ "$warned" -gt 0 ]; then
        say ""
        warn "предупреждений: $warned — установка продолжится, но проверьте их"
    fi
    say ""
}

# ============================================================================
# 0. Preflight
# ============================================================================
say ""
say "${C_BLD}Remnawave Node + Caddy Selfsteal installer v$VERSION${C_OFF}"
say "${C_DIM}логи: $LOG_FILE${C_OFF}"
say ""

[ "$(id -u)" -eq 0 ] || die "Запускать от root: sudo bash $0"
log "=== start v$VERSION args: $* ==="

# --- режим «только swap» ----------------------------------------------------
# Починить swap на уже установленной ноде: показать состояние, при
# необходимости пересоздать и выйти. Docker, Caddy, конфиги и firewall не
# трогаются, поэтому запускать на рабочей ноде безопасно.
if [ "$SWAP_ONLY" = true ]; then
    hdr "swap"
    swap_section
    exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
    die "Поддерживаются только Debian/Ubuntu (apt-get не найден)."
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|arm64) : ;;
    *) warn "Архитектура $ARCH не проверялась — продолжаем." ;;
esac

FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[ "${FREE_KB:-0}" -ge 2097152 ] || warn "Свободно меньше 2 ГБ — может не хватить."

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || true

# ============================================================================
# 1. Конфигурация (интерактивно или из ответов прошлого запуска)
# ============================================================================
hdr "1. Параметры установки"

# --- Порт ноды -------------------------------------------------------------
# Спрашиваем первым: именно этот порт открывается в firewall — и только панели.
while ! is_port "$NODE_PORT"; do
    if [ "$ASSUME_YES" = true ]; then
        die "Некорректный --node-port: '$NODE_PORT' (ожидается 1-65535)"
    fi
    ask NODE_PORT "Порт ноды (внутренний API, панель → нода)" "2222"
done
ok "Порт ноды: $NODE_PORT"

# --- IP панели -------------------------------------------------------------
if [ -z "$PANEL_IP" ] || ! is_ipv4 "$PANEL_IP"; then
    _panel_def=""
    is_ipv4 "${PANEL_IP:-}" && _panel_def="$PANEL_IP"
    say ""
    note "IP панели — адрес сервера, где работает Remnawave (это не порт)."
    note "Порт ноды $NODE_PORT откроется в firewall только для этого адреса."
    while true; do
        ask PANEL_IP "IPv4 панели Remnawave (пример: 203.0.113.10)" "$_panel_def"
        is_ipv4 "$PANEL_IP" && break
        case "$PANEL_IP" in
            ''|*[!0-9]*) warn "Это не IPv4: '$PANEL_IP'. Нужен адрес вида 203.0.113.10." ;;
            *)           warn "'$PANEL_IP' — похоже на порт. Нужен IP панели (пример: 203.0.113.10)." ;;
        esac
        [ "$ASSUME_YES" = true ] && die "Укажите корректный --panel-ip"
        _panel_def=""
    done
    unset _panel_def
fi
ok "Панель: $PANEL_IP (порт $NODE_PORT будет открыт только ей)"

# --- Порт панели (необязательно) --------------------------------------------
# Нода — пассивная сторона: панель сама стучится к ней на NODE_PORT, обратного
# соединения нет. Поэтому порт панели не спрашиваем: он нужен только для
# необязательной проверки веб-порта панели (--panel-port PORT).
if [ -n "${PANEL_PORT:-}" ] && ! is_port "$PANEL_PORT"; then
    die "Некорректный --panel-port: '$PANEL_PORT' (ожидается 1-65535 или пусто)"
fi

# --- Секретный ключ --------------------------------------------------------
if [ -z "$SECRET_KEY" ]; then
    [ "$ASSUME_YES" = true ] && die "Не указан --secret-key (обязателен в режиме --yes)"
    say ""
    note "SECRET_KEY выдаётся панелью при создании ноды (Nodes → Management → +)."
    note "Скопируйте его из формы создания ноды и вставьте сюда."
    while [ -z "$SECRET_KEY" ]; do
        ask SECRET_KEY "Ключ ноды из панели (SECRET_KEY)" ""
        if [ -z "$SECRET_KEY" ]; then
            if [ ! -t 0 ]; then die "Ввод недоступен — передайте --secret-key KEY"; fi
            warn "Ключ обязателен."
        elif ! secret_key_valid "$SECRET_KEY"; then
            warn "В ключе недопустимые символы (' \" \\ \$ # пробел или перевод строки) — они ломают answers.env и .env ноды. Скопируйте ключ ещё раз."
            SECRET_KEY=""
        fi
    done
fi
if ! secret_key_valid "$SECRET_KEY"; then
    die "Некорректный SECRET_KEY: недопустимы ' \" \\ \$ # пробел и перевод строки — они ломают answers.env и .env ноды"
fi
[ "${#SECRET_KEY}" -ge 16 ] || warn "SECRET_KEY короче 16 символов — проверьте, что скопировали целиком."
ok "SECRET_KEY: ${SECRET_KEY:0:6}…${SECRET_KEY: -4} (${#SECRET_KEY} символов)"

# --- Порт подключения ------------------------------------------------------
# Один порт на все транспорты: и xHTTP, и gRPC, и TCP слушают его в панели.
# Сколько inbound'ов на нём — установщику не важно, важны firewall и конфиги.
say ""
note "Один порт для подключения клиентов: xHTTP, gRPC и TCP работают на нём."
note "Firewall откроет его всем; сами inbound'ы настраиваются в панели."
while ! is_port "$CONNECT_PORT"; do
    if [ "$ASSUME_YES" = true ]; then
        die "Некорректный --connect-port: '$CONNECT_PORT' (ожидается 1-65535)"
    fi
    ask CONNECT_PORT "Порт для подключения (xHTTP/gRPC/TCP)" "443"
done
if [ "$CONNECT_PORT" = "$NODE_PORT" ]; then
    die "Порт подключения совпал с портом ноды ($NODE_PORT) — выберите другой"
fi
ok "Порт подключения: $CONNECT_PORT/tcp (xHTTP, gRPC, TCP)"

# --- Selfsteal -------------------------------------------------------------
say ""
ask_yesno USE_SELFSTEAL "Развернуть Caddy selfsteal (сайт-заглушка для Reality/TLS)?" "yes"

if [ "$USE_SELFSTEAL" = "yes" ]; then
    if [ -z "$DOMAIN" ] || ! is_domain "$DOMAIN"; then
        while true; do
            ask DOMAIN "Домен для selfsteal (A-запись должна указывать на этот сервер)" "${DOMAIN:-}"
            is_domain "$DOMAIN" && break
            warn "Некорректный домен: '$DOMAIN'"
            [ "$ASSUME_YES" = true ] && die "Укажите корректный --domain"
        done
    fi
    ok "Домен: $DOMAIN"

    while ! is_port "$SELFSTEAL_PORT"; do
        if [ "$ASSUME_YES" = true ]; then
            die "Некорректный --selfsteal-port: '$SELFSTEAL_PORT' (ожидается 1-65535)"
        fi
        ask SELFSTEAL_PORT "Внутренний HTTPS-порт Caddy (127.0.0.1)" "9443"
    done
    ok "Порт Caddy: 127.0.0.1:$SELFSTEAL_PORT"

    say ""
    say "  ${C_BLD}Доступные сайты-заглушки (введите номер):${C_OFF}"
    # Список берём из templates/manifest.tsv — тогда новый шаблон не требует
    # правок установщика (локальная копия или raw из репозитория).
    TEMPLATE_KEYS=()
    TEMPLATE_DESCS=()
    _mf="$(mktemp)"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/templates/manifest.tsv" ]; then
        cp "$SCRIPT_DIR/templates/manifest.tsv" "$_mf"
    elif ! fetch "$TEMPLATES_BASE/manifest.tsv" "$_mf" 2>/dev/null; then
        warn "не удалось получить список шаблонов — доступен только shop"
        printf 'shop|магазин керамики — каталог, фильтры, корзина\n' > "$_mf"
    fi
    while IFS='|' read -r _tk _td; do
        _tk="${_tk%$'\r'}"
        [ -z "$_tk" ] && continue
        case "$_tk" in \#*) continue ;; esac
        TEMPLATE_KEYS+=("$_tk")
        TEMPLATE_DESCS+=("${_td:-$_tk}")
    done < "$_mf"
    rm -f "$_mf"
    unset _tk _td _mf 2>/dev/null || true
    if [ "${#TEMPLATE_KEYS[@]}" -eq 0 ]; then
        TEMPLATE_KEYS=(shop)
        TEMPLATE_DESCS=("магазин керамики — каталог, фильтры, корзина")
    fi

    # Совместимость со старым answers.env: там мог остаться ключ из прежнего
    # набора шаблонов. Молча подставляем ближайший по смыслу сайт,
    # иначе повторная установка упала бы на «неизвестный шаблон».
    _tvalid=false
    for k in "${TEMPLATE_KEYS[@]}"; do [ "$k" = "$TEMPLATE" ] && _tvalid=true; done
    if [ "$_tvalid" != true ]; then
        _old="$TEMPLATE"
        case "$TEMPLATE" in
            startup)                                 TEMPLATE=saas ;;
            agency|portfolio|landing)                TEMPLATE=studio ;;
            wiki|paste|git)                          TEMPLATE=docs ;;
            analytics|auth|mail|chat|calendar|notes)  TEMPLATE=dashboard ;;
            tasks|crm|hr|edu|quiz|crypto|finance)     TEMPLATE=dashboard ;;
            news|torrent|music|video|cinema)          TEMPLATE=blog ;;
            podcast|radio|hotel|photos|gallery)       TEMPLATE=travel ;;
            fitness|health|law|insurance|realestate)  TEMPLATE=shop ;;
            auto|logistics|speedtest)                 TEMPLATE=hosting ;;
            status|503|cdn|cloud)                     TEMPLATE=hosting ;;
            *)                                       TEMPLATE="${TEMPLATE_KEYS[0]}" ;;
        esac
        note "шаблон «$_old» из прежнего набора заменён на «$TEMPLATE»"
        unset _old 2>/dev/null || true
    fi
    unset _tvalid 2>/dev/null || true
    for i in "${!TEMPLATE_KEYS[@]}"; do
        printf "    %2d) %-12s — %s\n" "$((i+1))" "${TEMPLATE_KEYS[$i]}" "${TEMPLATE_DESCS[$i]}"
    done

    if [ "$ASSUME_YES" = false ]; then
        while true; do
            read -r -p "$(echo -e "  ${C_BLD}Выбор [1-${#TEMPLATE_KEYS[@]}]${C_OFF} [${TEMPLATE}]: ")" tsel || true
            [ -z "$tsel" ] && break
            if [[ "$tsel" =~ ^[0-9]+$ ]]; then
                # 10#: иначе ввод «010» bash читает как восьмеричное 8.
                tsel=$((10#$tsel))
                if [ "$tsel" -ge 1 ] && [ "$tsel" -le "${#TEMPLATE_KEYS[@]}" ]; then
                    TEMPLATE="${TEMPLATE_KEYS[$((tsel-1))]}"
                    break
                fi
            fi
            warn "Введите число от 1 до ${#TEMPLATE_KEYS[@]}"
        done
    fi

    valid=false
    for k in "${TEMPLATE_KEYS[@]}"; do [ "$k" = "$TEMPLATE" ] && valid=true; done
    [ "$valid" = true ] || die "Неизвестный шаблон '$TEMPLATE'. Допустимо: ${TEMPLATE_KEYS[*]}"
    ok "Сайт-заглушка: $TEMPLATE"
fi

# --- Hysteria2 -------------------------------------------------------------
# Hysteria2 — это UDP-транспорт внутри Xray ноды: отдельный бинарь не нужен,
# ядро ноды (remnawave/node + свежий Xray) умеет hysteria-инбаунд само.
# Нужны только сертификат домена и открытый UDP на порту подключения.
say ""
note "Hysteria2 — тот же порт подключения, но по UDP (QUIC): выручает там, где"
note "оператор режет TCP-TLS. Сертификат берётся от selfsteal, ставить нечего."
if [ "$USE_SELFSTEAL" != "yes" ]; then
    note "Hysteria2 требует домен и сертификат (selfsteal) — пропускаю."
    HYSTERIA="no"
else
    ask_yesno HYSTERIA "Установить Hysteria2 (UDP/$CONNECT_PORT)?" "yes"
    if [ "$HYSTERIA" = "yes" ]; then
        ok "Hysteria2: UDP/$CONNECT_PORT, сертификат $DOMAIN"
        if [ "$CONNECT_PORT" = "443" ]; then
            note "Caddy уже без HTTP/3 (h1/h2), так что UDP/443 остаётся Hysteria2."
        fi
    else
        note "Hysteria2: не установлен (включить позже: nodego → Hysteria2)"
    fi
fi

# --- Схема с IP ------------------------------------------------------------
say ""
say "  ${C_BLD}Схема сети:${C_OFF}"
say "    1) Один IP — клиенты входят и выходят через один адрес (обычный вариант)"
say "    2) Два IP — клиенты входят на основной IP, в интернет выходят через дополнительный"

if [ "$ASSUME_YES" = false ]; then
    while true; do
        read -r -p "$(echo -e "  ${C_BLD}Выбор [1/2]${C_OFF} [$([ "$DUAL_IP" = yes ] && echo 2 || echo 1)]: ")" net_choice || true
        net_choice="${net_choice:-$([ "$DUAL_IP" = yes ] && echo 2 || echo 1)}"
        case "$net_choice" in
            1) DUAL_IP="no";  break ;;
            2) DUAL_IP="yes"; break ;;
            *) warn "Введите 1 или 2" ;;
        esac
    done
fi

if [ "$DUAL_IP" = "yes" ]; then
    DETECTED_IP1="$(detect_primary_ip)"

    # Входящий (основной) IP: по умолчанию — автоопределённый, но его всегда
    # можно заменить на докупленный адрес: клиенты будут входить на него,
    # а выходить нода будет через IP2.
    if [ -z "$IP1" ] || ! is_ipv4 "$IP1"; then
        IP1="$DETECTED_IP1"
    fi

    if [ "$ASSUME_YES" = false ]; then
        while true; do
            ask IP1 "IP для входа (на него подключаются клиенты)" "${IP1:-$DETECTED_IP1}"
            is_ipv4 "$IP1" && break
            warn "Некорректный IPv4: '$IP1'"
        done
    fi

    if ! is_ipv4 "$IP1"; then
        die "Укажите корректный --ip1"
    fi
    ok "Основной IP (вход): $IP1"
    [ -n "$DETECTED_IP1" ] && [ "$IP1" != "$DETECTED_IP1" ] \
        && note "автоопределённый IP сервера: $DETECTED_IP1 (вход переназначен на $IP1)"

    # IP входа должен быть настроен на машине, иначе нода не сможет его слушать
    if ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$IP1"; then
        ok "IP $IP1 найден на интерфейсе сервера"
    else
        warn "IP $IP1 НЕ найден на интерфейсах этого сервера"
        note "вход на него не заработает, пока адрес не назначен:"
        note "  ip addr add $IP1/32 dev <интерфейс>   # или настройка у провайдера/в облаке"
        if [ "$ASSUME_YES" = true ]; then
            die "Адрес $IP1 не настроен на сервере. Назначьте его и повторите запуск."
        fi
        while true; do
            read -r -p "$(echo -e "  ${C_BLD}Продолжить всё равно? [д/н]${C_OFF}: ")" _cont || true
            case "$(norm_yn "${_cont:-}")" in
                yes) break ;;
                no)  die "Остановлено: назначьте $IP1 и запустите снова." ;;
            esac
        done
    fi

    if [ -z "$IP2" ] || ! is_host_ipv4 "$IP2"; then
        while true; do
            ask IP2 "IP для выхода (через него нода ходит в интернет)" "${IP2:-$DETECTED_IP1}"
            is_host_ipv4 "$IP2" && break
            warn "Некорректный IPv4: '$IP2' — нужен адрес хоста без маски (например 198.51.100.5)"
            [ "$ASSUME_YES" = true ] && die "Укажите корректный --ip2"
        done
    fi
    [ "$IP2" = "$IP1" ] && die "IP входа и выхода совпадают"
    ok "Дополнительный IP (выход): $IP2"
    note "домен selfsteal будет привязан к $IP1 (вход), трафик в интернет пойдёт с $IP2."
else
    ok "Один IP: вход и выход через один адрес"
fi

# --- DNS-фильтрация --------------------------------------------------------
say ""
ask_yesno USE_DNS "Включить DNS-фильтрацию AdGuard (блокировка рекламы и трекеров, DNS-over-TLS)?" "yes"
if [ "$USE_DNS" = "yes" ]; then
    ok "DNS: AdGuard DoT"
else
    note "DNS: остаётся системный"
fi

# --- Автообновление --------------------------------------------------------
say ""
ask_yesno AUTO_UPDATE "Включить автообновление Remnawave Node (ежедневная проверка с откатом при сбое)?" "yes"
if [ "$AUTO_UPDATE" = "yes" ]; then
    ok "Автообновление: включено"
else
    note "Автообновление: выключено"
fi

# --- Алерты в Telegram -----------------------------------------------------
say ""
say "  ${C_BLD}Алерты:${C_OFF} проверка каждые 5 минут (нода, порт, диск, conntrack, сертификат)."
say "  Сообщение приходит только при смене состояния — не спамит."
ask_yesno ALERTS "Включить алерты в Telegram?" "no"

if [ "$ALERTS" = "yes" ]; then
    say ""
    note "1) Создайте бота у @BotFather → получите токен вида 123456789:AA..."
    note "2) Напишите боту любое сообщение, затем узнайте chat_id:"
    note "   curl -s \"https://api.telegram.org/bot<ТОКЕН>/getUpdates\" | grep -o '\"id\":[-0-9]*' | head -1"
    while [ -z "$TG_TOKEN" ] || ! [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; do
        [ "$ASSUME_YES" = true ] && die "Укажите корректный --tg-token"
        ask TG_TOKEN "Токен бота" "${TG_TOKEN:-}"
        [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || warn "Формат токена: 123456789:AA..."
    done
    while [ -z "$TG_CHAT" ] || ! [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]]; do
        [ "$ASSUME_YES" = true ] && die "Укажите корректный --tg-chat"
        ask TG_CHAT "chat_id получателя" "${TG_CHAT:-}"
        [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]] || warn "chat_id — это число (для канала с минусом)"
    done
    ok "Алерты включены (chat_id: $TG_CHAT)"
    # проверяем, что бот/чат рабочие, но не блокируем установку
    if curl -fsS --max-time 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT}" --data-urlencode "text=✅ remnawave-installer: алерты подключены" >/dev/null 2>&1; then
        ok "Тестовое сообщение отправлено"
    else
        warn "Не удалось отправить тестовое сообщение — проверьте токен/chat_id"
    fi
else
    note "Алерты выключены"
fi

# --- Сводка и подтверждение ------------------------------------------------
say ""
say "  ${C_BLD}Итого:${C_OFF}"
say "    панель ............ ${PANEL_IP}"
say "    порт ноды ......... $NODE_PORT (только с $PANEL_IP)"
say "    порт подключения .. $CONNECT_PORT/tcp — xHTTP, gRPC, TCP"
if [ "$HYSTERIA" = "yes" ]; then
    say "    Hysteria2 ......... UDP/$CONNECT_PORT (сертификат $DOMAIN)"
else
    say "    Hysteria2 ......... выключен"
fi
if [ "$USE_SELFSTEAL" = "yes" ]; then
    say "    selfsteal ......... ${DOMAIN}:80/443 → Caddy 127.0.0.1:${SELFSTEAL_PORT} (${TEMPLATE})"
else
    say "    selfsteal ......... выключен"
fi
if [ "$HYSTERIA" = "yes" ]; then
    say "    готовые конфиги ... xHTTP, gRPC, TCP, Hysteria2"
else
    say "    готовые конфиги ... xHTTP, gRPC, TCP"
fi
if [ "$DUAL_IP" = "yes" ]; then
    say "    сеть .............. вход $IP1 → выход $IP2"
else
    say "    сеть .............. один IP"
fi
say "    DNS-фильтр ........ ${USE_DNS}"
say "    автообновление .... ${AUTO_UPDATE}"
say "    healthcheck ....... каждые 5 минут"
say "    алерты Telegram ... ${ALERTS}"
say "    бэкап конфигов .... ежедневно, хранится 14 копий"
say ""

if [ "$ASSUME_YES" = false ]; then
    read -r -p "$(echo -e "${C_BLD}Продолжить установку?${C_OFF} [Д/н]: ")" confirm || true
    case "${confirm:-y}" in
        n|N|no|No|NO) die "Отменено пользователем." ;;
    esac
fi

# На общем сервере сначала проверяем конфликт, только потом меняем конфиги.
command -v ss >/dev/null 2>&1 || die "Для проверки портов установите iproute2 (ss) и повторите запуск"
check_port_owner "$NODE_PORT" remnanode || die "API-порт $NODE_PORT занят другой службой или владелец неизвестен; нода не изменена."
if [ "$USE_SELFSTEAL" = yes ]; then
    command -v ss >/dev/null 2>&1 || die "Для проверки портов установите iproute2 (ss) и повторите запуск"
    for _port in 80 "$SELFSTEAL_PORT"; do
        check_port_owner "$_port" selfsteal || die "Порт $_port занят чужой службой или владелец неизвестен. Существующий Caddy не трогаю; объедините конфиги вручную."
    done
    if [ -e "$SELFSTEAL_DIR/Caddyfile" ]; then
        [ -f "$SELFSTEAL_DIR/docker-compose.yml" ] && [ -f "$SELFSTEAL_DIR/.env" ] \
            || die "Неполный существующий selfsteal: нужны compose и .env. Автоматическая перезапись запрещена."
        if ! grep -qxF "SELF_STEAL_DOMAIN=$DOMAIN" "$SELFSTEAL_DIR/.env" \
            || ! grep -qxF "SELF_STEAL_PORT=$SELFSTEAL_PORT" "$SELFSTEAL_DIR/.env"; then
            die "Домен/порт существующего selfsteal отличаются. Сначала согласуйте Caddyfile, compose и .env вручную."
        fi
        warn "Существующий selfsteal сохраняется целиком, включая дополнительные сайты. --template не применяется."
    fi
fi

# сохраняем ответы для повторного запуска
umask 077
cat > "$ANSWERS_FILE" <<EOF
# Сгенерировано remnawave node installer v$VERSION $(date '+%F %T')
PANEL_IP=$(env_quote "$PANEL_IP")
PANEL_PORT=$(env_quote "$PANEL_PORT")
NODE_PORT=$(env_quote "$NODE_PORT")
SECRET_KEY=$(env_quote "$SECRET_KEY")
CONNECT_PORT=$(env_quote "$CONNECT_PORT")
HYSTERIA=$(env_quote "$HYSTERIA")
USE_SELFSTEAL=$(env_quote "$USE_SELFSTEAL")
DOMAIN=$(env_quote "$DOMAIN")
SELFSTEAL_PORT=$(env_quote "$SELFSTEAL_PORT")
TEMPLATE=$(env_quote "$TEMPLATE")
DUAL_IP=$(env_quote "$DUAL_IP")
IP1=$(env_quote "$IP1")
IP2=$(env_quote "$IP2")
USE_DNS=$(env_quote "$USE_DNS")
AUTO_UPDATE=$(env_quote "$AUTO_UPDATE")
SWAP_SIZE=$(env_quote "$SWAP_SIZE")
ALERTS=$(env_quote "$ALERTS")
TG_TOKEN=$(env_quote "$TG_TOKEN")
TG_CHAT=$(env_quote "$TG_CHAT")
EOF
chmod 600 "$ANSWERS_FILE"
umask 022   # дальше создаём каталоги/файлы с обычными правами

# ============================================================================
# Проверка сети и DNS
# ============================================================================
if [ "$SKIP_NETCHECK" = true ]; then
    hdr "Проверка сети и DNS"
    warn "Пропущено (--skip-netcheck)"
else
    net_check
fi

# ============================================================================
# 2. Зависимости
# ============================================================================
hdr "2. Зависимости"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if [ "$UPGRADE_SYSTEM" = true ]; then
    apt-get upgrade -y -qq \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold || die "apt upgrade завершился с ошибкой"
fi
apt-get install -y -qq \
    curl wget ca-certificates openssl jq ufw logrotate dnsutils cron \
    gnupg lsb-release tzdata iptables iproute2 || warn "Часть пакетов не установилась"
ok "Базовые пакеты готовы"

# ============================================================================
# 3. Время и NTP
# ============================================================================
hdr "3. Время и синхронизация"
timedatectl set-timezone "${TZ_NAME:-Europe/Moscow}" 2>/dev/null || true
if command -v systemd-timesyncd >/dev/null 2>&1 || [ -d /lib/systemd/systemd-timesyncd ]; then
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl 2>/dev/null | sed -n '1,5p' | sed 's/^/  /' || true

# ============================================================================
# 4. Docker
# ============================================================================
hdr "4. Docker"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker --version 2>/dev/null)"
else
    note "Устанавливаю Docker (get.docker.com)…"
    curl -fsSL https://get.docker.com | sh || die "Не удалось установить Docker"
    systemctl enable --now docker
    ok "Docker установлен"
fi

if ! docker compose version >/dev/null 2>&1; then
    note "Плагин compose отсутствует — ставлю…"
    apt-get install -y -qq docker-compose-plugin || {
        mkdir -p /usr/libexec/docker/cli-plugins
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" \
            -o /usr/libexec/docker/cli-plugins/docker-compose
        chmod +x /usr/libexec/docker/cli-plugins/docker-compose
    }
    docker compose version >/dev/null 2>&1 || die "docker compose недоступен"
fi
ok "docker compose: $(docker compose version --short 2>/dev/null || echo ok)"

DOCKER_BIN="$(command -v docker || true)"
[ -n "$DOCKER_BIN" ] || DOCKER_BIN="/usr/bin/docker"
note "docker: $DOCKER_BIN"

# --- daemon.json: ротация логов + live-restore -------------------------------
DAEMON_RESTART=false
mkdir -p /etc/docker
if [ -s /etc/docker/daemon.json ] && ! grep -q '"log-opts"' /etc/docker/daemon.json; then
    warn "/etc/docker/daemon.json уже существует — заменяю (бэкап рядом)"
fi
if ! grep -q '"log-opts"' /etc/docker/daemon.json 2>/dev/null; then
    backup /etc/docker/daemon.json
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false,
  "iptables": true
}
EOF
    DAEMON_RESTART=true
    ok "docker daemon: логи 10m×3, live-restore"
else
    ok "docker daemon.json уже настроен — не трогаю"
fi

if [ "$DAEMON_RESTART" = true ]; then
    if [ -n "$(docker ps -q 2>/dev/null || true)" ]; then
        warn "есть запущенные контейнеры — новые настройки демона применятся"
        note "после их перезапуска (или перезагрузки сервера)"
    elif systemctl restart docker >/dev/null 2>&1; then
        ok "docker перезапущен с новым конфигом"
    else
        warn "docker не перезапустился — настройки применятся при следующем старте"
    fi
fi

# ============================================================================
# 5. Тюнинг системы
# ============================================================================
if [ "$SKIP_TUNING" = true ]; then
    hdr "5. Тюнинг системы"
    warn "Пропущено (--skip-tuning)"
else
    hdr "5. Тюнинг системы"

    # --- swap -------------------------------------------------------------
    # состояние, размер и применение — в swap_section: та же функция
    # используется режимом --swap-only.
    swap_section

    # --- nofile -----------------------------------------------------------
    cat > /etc/security/limits.d/99-remnawave.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
    cat > /etc/systemd/system/docker.service.d/99-nofile.conf <<'EOF'
[Service]
LimitNOFILE=infinity
EOF
    systemctl daemon-reload
    # Демон должен поднять свой лимит ДО создания контейнера с ulimits 1048576,
    # иначе docker обрежет лимит внутри ноды.
    if [ -z "$(docker ps -q 2>/dev/null || true)" ]; then
        systemctl restart docker >/dev/null 2>&1 || true
    fi
    ok "nofile=1048576 (host + docker.service)"

    # --- sysctl -----------------------------------------------------------
    cat > /etc/sysctl.d/99-remnawave.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
vm.overcommit_memory = 1
fs.nr_open = 2097152
vm.swappiness = 10
vm.vfs_cache_pressure = 50
# помогает при MTU-blackhole (частая беда мобильных сетей)
net.ipv4.tcp_mtu_probing = 1
EOF
    echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
    # hashsize: без него при 262k записей таблица деградирует в список коллизий
    cat > /etc/modprobe.d/99-remnawave-conntrack.conf <<'EOF'
options nf_conntrack hashsize=65536
EOF
    modprobe nf_conntrack 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || warn "не все sysctl-ключи применились"
    ok "sysctl применены (conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a))"

    # --- BBR+FQ -----------------------------------------------------------
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl --system >/dev/null 2>&1 || true
        IFACE="$(ip -o route show default | awk '{print $5; exit}' || true)"
        if [ -n "${IFACE:-}" ]; then
            tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
        fi
        ok "BBR + FQ включены (${IFACE:-?})"
    else
        warn "BBR недоступен в ядре — оставлен текущий алгоритм"
    fi

    # --- journald ---------------------------------------------------------
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-remnawave.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    ok "journald ограничен 500M"

    systemctl daemon-reload
fi

# ============================================================================
# 6. Сеть: схема с одним или двумя IP
# ============================================================================
hdr "6. Сеть"
BIND_IP="0.0.0.0"
IFACE="$(ip -o route show default | awk '{print $5; exit}' || true)"
GW="$(ip -o route show default | awk '{print $3; exit}' || true)"

if [ "$DUAL_IP" = "yes" ]; then
    IFACE="$(ip -o -4 addr show | awk -v ip="$IP1" 'index($4, ip "/")==1 {print $2; exit}')"
    [ -n "${IFACE:-}" ] || IFACE="$(ip -o route show default | awk '{print $5; exit}')"
    [ -n "${GW:-}" ] || GW="$(ip -o route show default | awk '{print $3; exit}')"
    if [ -z "${IFACE:-}" ] || [ -z "${GW:-}" ]; then
        die "Не удалось определить интерфейс/шлюз для второго IP"
    fi
    BIND_IP="$IP1"
    ok "Вход: $IP1 → выход: $IP2 (интерфейс $IFACE, шлюз $GW)"

    # Входной IP может быть докупленным адресом, ещё не назначенным на интерфейс.
    # Снимаем маску, чтобы не испортить существующий адрес, и добавляем только
    # если такого адреса на интерфейсе нет. На будущее это же делает и
    # rw-secondary-ip.service при загрузке.
    if ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$IP1"; then
        ok "IP входа $IP1 уже настроен на $IFACE"
    else
        if ip addr add "$IP1/32" dev "$IFACE" 2>/dev/null; then
            ok "IP входа $IP1 добавлен на $IFACE"
            ip route replace "$IP1" dev "$IFACE" scope link 2>/dev/null || true
        else
            warn "Не удалось добавить $IP1 на $IFACE — добавьте вручную"
        fi
    fi
else
    ok "Один IP: вход и выход через один адрес"
fi

# Состояние схемы храним в отдельном файле: так меню `nodego` может менять
# настройки без переустановки, а скрипт применения — читать их из одного места.
cat > "$STATE_DIR/net.env" <<EOF
# Схема сети Remnawave Node (меняется через nodego или повторной установкой)
MODE=$([ "$DUAL_IP" = "yes" ] && echo dual || echo single)
IP1=$IP1
IP2=$IP2
IFACE=$IFACE
GW=$GW
BIND_IP=$BIND_IP
EOF
chmod 600 "$STATE_DIR/net.env"

# Скрипт применения универсальный (читает net.env), поэтому смена схемы
# 1 IP ↔ 2 IP или обмен входа/выхода не требует переустановки.
cat > /usr/local/sbin/rw-secondary-ip.sh <<'SCRIPT_EOF'
#!/bin/bash
# Применяет схему сети из /etc/remnawave-setup/net.env.
#   dual   : вход на IP1, выход через IP2 (SNAT только для новых соединений)
#   single : правила не добавляются, свои прежние снимаются
set -uo pipefail

CONF=/etc/remnawave-setup/net.env
TABLE=100
RULE_PRIO=1000
log() { echo "[$(date '+%F %T')] $*"; }

[ -f "$CONF" ] || { log "нет $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# --- снимаем ТОЛЬКО свои прежние правила (прошлый IP2 / прошлая схема) ------
# На общем сервере рядом живут чужие policy-rule и SNAT соседнего проекта:
# снимать «всё по table $TABLE» или «любой SNAT» нельзя — правило помечено
# комментарием и фиксированным priority.
while ip rule show 2>/dev/null | grep -q "^${RULE_PRIO}:"; do
    ip rule del priority "$RULE_PRIO" 2>/dev/null || break
done
while read -r spec; do
    [ -n "${spec:-}" ] || continue
    # shellcheck disable=SC2086
    iptables -t nat -D POSTROUTING $spec 2>/dev/null || true
done < <(iptables -t nat -S POSTROUTING 2>/dev/null \
         | grep -F -- 'rw-secondary-ip' \
         | sed 's/^-A POSTROUTING //; s/"//g' || true)

if [ "${MODE:-single}" != "dual" ]; then
    log "режим single — правила сняты"
    exit 0
fi

if [ -z "${IP2:-}" ] || [ -z "${IFACE:-}" ] || [ -z "${GW:-}" ]; then
    log "в net.env не хватает IP2/IFACE/GW"
    exit 1
fi

ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "${IP1:-}" \
    || ip addr add "$IP1/32" dev "$IFACE" 2>/dev/null || true
ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$IP2" \
    || ip addr add "$IP2/32" dev "$IFACE" 2>/dev/null || true
ip rule add priority "$RULE_PRIO" from "$IP2/32" table "$TABLE"
ip route replace default via "$GW" dev "$IFACE" src "$IP2" table "$TABLE"
iptables -t nat -A POSTROUTING -o "$IFACE" -m conntrack --ctstate NEW \
    -m comment --comment rw-secondary-ip -j SNAT --to-source "$IP2"
log "dual: вход ${IP1:-?}, выход $IP2 ($IFACE via $GW)"
SCRIPT_EOF
chmod 0755 /usr/local/sbin/rw-secondary-ip.sh

cat > /etc/systemd/system/rw-secondary-ip.service <<'EOF'
[Unit]
Description=Remnawave network scheme (1 or 2 IP)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rw-secondary-ip.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable rw-secondary-ip.service >/dev/null 2>&1 || true
if systemctl restart rw-secondary-ip.service; then
    ok "Схема сети применена (rw-secondary-ip.service)"
else
    warn "Не удалось применить схему — смотрите: journalctl -u rw-secondary-ip"
fi

if [ "$DUAL_IP" = "yes" ]; then
    OUT_IP="$(curl -4 -fsS --max-time 10 --interface "$IP2" https://ifconfig.io 2>/dev/null || true)"
    if [ "$OUT_IP" = "$IP2" ]; then
        ok "Исходящий трафик идёт с $IP2"
    elif [ -n "$OUT_IP" ]; then
        warn "Исходящий IP = $OUT_IP (ожидался $IP2) — проверьте маршрут/SNAT"
    else
        warn "Не удалось проверить исходящий IP (нет сети или IP2 не поднят)"
    fi
fi

# ============================================================================
# 7. Firewall
# ============================================================================
hdr "7. Firewall"
if [ "$SKIP_FIREWALL" = true ]; then
    warn "Пропущено (--skip-firewall)"
else
    check_api_firewall || die "Нельзя гарантировать доступ к API только панели: исправьте конфликтующие правила UFW вручную."
    SSH_PORTS="$(ssh_ports || true)"
    if [ -z "$SSH_PORTS" ]; then
        die "Не удалось определить SSH-порт(ы) — ufw не включаю, иначе можно потерять доступ. Проверьте вручную: sshd -T | grep '^port '"
    fi
    # Открываем каждый найденный порт: админ может ходить на любой из них.
    for _p in $SSH_PORTS; do
        ufw allow "$_p/tcp" comment 'SSH' >/dev/null
    done
    unset _p

    if [ "$USE_SELFSTEAL" = "yes" ]; then
        ufw allow 80/tcp comment 'ACME HTTP-01 + redirect' >/dev/null
    fi

    # Порт подключения — всем: на нём публичные inbound'ы (xHTTP, gRPC, TCP)
    ufw allow "$CONNECT_PORT/tcp" comment "xray inbound $CONNECT_PORT" >/dev/null

    # Hysteria2 — тот же порт по UDP (QUIC)
    if [ "$HYSTERIA" = "yes" ]; then
        ufw allow "$CONNECT_PORT/udp" comment "hysteria2 QUIC $CONNECT_PORT" >/dev/null
    fi

    # Порт ноды — только панели
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment "remnanode API $NODE_PORT" >/dev/null

    ufw --force enable >/dev/null

    # ufw перестраивает свои таблицы — на всякий случай применяем SNAT повторно
    if [ "$DUAL_IP" = "yes" ]; then
        if systemctl restart rw-secondary-ip.service >/dev/null 2>&1; then
            note "SNAT переприменён после включения ufw"
        fi
    fi
    ok "Правила добавлены:"
    ufw status 2>/dev/null | sed -n '2,25p' | sed 's/^/    /' || true
fi

# Проверка занятости портов до запуска контейнеров
conflict=""
for p in "$NODE_PORT" "$CONNECT_PORT"; do
    [ -n "$p" ] || continue
    if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
        conflict="$conflict $p"
    fi
done
[ -n "$conflict" ] && warn "Порты уже заняты:$conflict (проверьте перед стартом)"

# ============================================================================
# 8. Remnawave Node
# ============================================================================
hdr "8. Remnawave Node"
mkdir -p "$NODE_DIR" /var/log/remnanode "$NODE_DIR/cert"
chmod 700 "$NODE_DIR/cert"
snapshot_node || die "Не удалось сохранить ноду для отката"
backup "$NODE_DIR/docker-compose.yml"; backup "$NODE_DIR/.env"

cat > "$NODE_DIR/.env" <<EOF
### NODE ###
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
chmod 600 "$NODE_DIR/.env"

# export:node-compose
cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: $NODE_IMAGE
    restart: always
    network_mode: host
    # даём Xray время корректно закрыть сессии при stop/restart
    stop_grace_period: 30s
    env_file:
      - .env
    cap_add:
      - NET_ADMIN
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      # сертификат selfsteal для Hysteria2 (TLS-инбаунд внутри Xray);
      # синхронизирует rw-cert-sync.timer, без Hysteria2 просто лежит рядом
      - ./cert:/etc/remnanode/cert:ro
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    # export:end
ok "docker-compose.yml и .env созданы в $NODE_DIR"

cat > /etc/systemd/system/remnanode.service <<EOF
[Unit]
Description=Remnawave Node (Docker Compose)
After=network-online.target docker.service
Wants=network-online.target docker.service
ConditionPathExists=$NODE_DIR/docker-compose.yml

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$NODE_DIR
ExecStart=$DOCKER_BIN compose up -d --remove-orphans
ExecReload=$DOCKER_BIN compose up -d --remove-orphans
ExecStop=$DOCKER_BIN compose down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

note "Запускаю ноду…"
if ! start_node; then
    rollback_node || warn "Откат ноды не восстановил API; снимок: $NODE_SNAPSHOT"
    die "Нода не запустилась или API $NODE_PORT не слушает. Смотрите: docker compose -f $NODE_DIR/docker-compose.yml logs"
fi
systemctl daemon-reload
systemctl enable remnanode.service >/dev/null 2>&1 || die "Не удалось включить автозапуск ноды"
ok "Нода запущена, автозагрузка включена (remnanode.service)"

# ============================================================================
# 9. Caddy selfsteal
# ============================================================================
if [ "$USE_SELFSTEAL" = "yes" ]; then
    hdr "9. Caddy selfsteal"
    mkdir -p "$SELFSTEAL_DIR/html" "$SELFSTEAL_DIR/logs"
    HAS_CERT=false
    if [ -f "$SELFSTEAL_DIR/ssl/fullchain.crt" ] && [ -f "$SELFSTEAL_DIR/ssl/private.key" ]; then
        HAS_CERT=true
    fi
    # Не разбираем произвольные site-блоки: сохраняем также mounts/imports/контент.
    if [ ! -e "$SELFSTEAL_DIR/Caddyfile" ]; then
    backup "$SELFSTEAL_DIR/docker-compose.yml"; backup "$SELFSTEAL_DIR/.env"

    # --- сайт-заглушка ----------------------------------------------------
    TEMPLATE_SRC=""
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/templates/$TEMPLATE/index.html" ]; then
        TEMPLATE_SRC="$SCRIPT_DIR/templates/$TEMPLATE/index.html"
        note "Шаблон взят локально: $TEMPLATE_SRC"
    fi

    if [ -n "$TEMPLATE_SRC" ]; then
        cp "$TEMPLATE_SRC" "$SELFSTEAL_DIR/html/index.html"
    else
        note "Скачиваю шаблон '$TEMPLATE' из репозитория…"
        if ! fetch "$TEMPLATES_BASE/$TEMPLATE/index.html" "$SELFSTEAL_DIR/html/index.html"; then
            warn "Не удалось скачать шаблон — ставлю минимальную страницу"
            cat > "$SELFSTEAL_DIR/html/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>$DOMAIN</title><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:16px/1.6 system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#0f1115;color:#e8e8ea}main{max-width:36rem;padding:2rem;text-align:center}</style>
</head><body><main><h1>$DOMAIN</h1><p>Service is running.</p></main></body></html>
EOF
        fi
    fi
    ok "Сайт-заглушка: $TEMPLATE → $SELFSTEAL_DIR/html/index.html"

    # --- .env -------------------------------------------------------------
    cat > "$SELFSTEAL_DIR/.env" <<EOF
SELF_STEAL_DOMAIN=$DOMAIN
SELF_STEAL_PORT=$SELFSTEAL_PORT
EOF

    # --- Caddyfile --------------------------------------------------------
    # export:caddyfile
    cat > "$SELFSTEAL_DIR/Caddyfile" <<'EOF'
{
	https_port {$SELF_STEAL_PORT}
	default_bind 127.0.0.1
	auto_https disable_redirects
	admin off
	servers {
		protocols h1 h2
	}
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level ERROR
		format json
	}
}

http://{$SELF_STEAL_DOMAIN} {
	bind __BIND_IP__
	redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
	log {
		output file /var/log/caddy/redirect.log {
			roll_size 5MB
			roll_keep 3
		}
	}
}

https://{$SELF_STEAL_DOMAIN} {
	encode gzip
	header {
		-Server
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		X-XSS-Protection "1; mode=block"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level ERROR
	}
}

:{$SELF_STEAL_PORT} {
	tls internal
	respond 204
	log off
}

:80 {
	bind __BIND_IP__
	respond 204
	log off
}
EOF

    # export:end

    # Привязываем публичный :80 к основному IP (в схеме с двумя IP — только вход)
    sed -i "s|__BIND_IP__|$BIND_IP|g" "$SELFSTEAL_DIR/Caddyfile"
    note "Caddy :80 слушает $BIND_IP"

    # --- compose ----------------------------------------------------------
    # export:selfsteal-compose
    cat > "$SELFSTEAL_DIR/docker-compose.yml" <<EOF
services:
  caddy:
    image: $CADDY_IMAGE
    container_name: selfsteal
    restart: unless-stopped
    network_mode: host
    stop_grace_period: 15s
    # Caddyfile использует {\$SELF_STEAL_DOMAIN}/{\$SELF_STEAL_PORT} — переменные
    # должны быть в окружении контейнера, иначе шаблон раскроется в пустоту.
    env_file:
      - .env
    environment:
      SELF_STEAL_DOMAIN: "$DOMAIN"
      SELF_STEAL_PORT: "$SELFSTEAL_PORT"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/var/www/html:ro
      - ./ssl:/etc/caddy/ssl:ro
      - ./logs:/var/log/caddy
      - selfsteal_data:/data
      - selfsteal_config:/config
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  selfsteal_data:
  selfsteal_config:
EOF
    # export:end

    fi  # новый selfsteal; существующий стек не перезаписываем

    # Готовый сертификат в ./ssl (выпущен вручную или через acme.sh) подключаем
    # и на сохранённом стеке: иначе повторная установка ждёт ACME, режет
    # проверку HTTPS до 3 попыток и падает «Установка неполная» при живом
    # сертификате. Правим только свой site-блок, чужой Caddyfile не трогаем.
    if [ "$HAS_CERT" = true ]; then
        if [ -f "$SELFSTEAL_DIR/Caddyfile" ] \
            && grep -qF "https://{\$SELF_STEAL_DOMAIN} {" "$SELFSTEAL_DIR/Caddyfile"; then
            if ! grep -qF 'tls /etc/caddy/ssl/fullchain.crt' "$SELFSTEAL_DIR/Caddyfile"; then
                # shellcheck disable=SC2016  # здесь нужны литеральные {$SELF_STEAL_DOMAIN}
                sed -i 's|^https://{\$SELF_STEAL_DOMAIN} {|https://{$SELF_STEAL_DOMAIN} {\n\ttls /etc/caddy/ssl/fullchain.crt /etc/caddy/ssl/private.key|' \
                    "$SELFSTEAL_DIR/Caddyfile" || true
            fi
            if grep -qF 'tls /etc/caddy/ssl/fullchain.crt' "$SELFSTEAL_DIR/Caddyfile"; then
                ok "найден готовый сертификат в $SELFSTEAL_DIR/ssl — ACME для домена не используется"
            else
                HAS_CERT=false
                warn "сертификат в $SELFSTEAL_DIR/ssl есть, но tls в Caddyfile подключить не удалось — считаю, что он не используется"
            fi
        else
            HAS_CERT=false
            warn "сертификат в ssl/ есть, но Caddyfile не наш (нет site-блока https://{\$SELF_STEAL_DOMAIN}) — чужой конфиг не правлю, ACME не отключаю"
        fi
    fi

    # --- DNS-проверка (не блокирующая) ------------------------------------
    # Сверяем A-запись с адресами, реально назначенными на этом сервере, а не с
    # «внешним IP» из ifconfig.io: при NAT/дополнительных адресах автоопределение
    # показывает адрес выхода, и раньше это давало ложное «сертификат не
    # выпустится» на полностью рабочем домене.
    if [ "$HAS_CERT" = true ]; then
        note "DNS не проверяю: для $DOMAIN используется готовый сертификат"
    elif command -v dig >/dev/null 2>&1 || command -v getent >/dev/null 2>&1; then
        self_a_ips="$( { dig +short A "$DOMAIN" 2>/dev/null || true
                         getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' || true; } \
                     | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)"
        self_srv_ips="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
                        | grep -v '^127\.' || true)"
        for _x in "${BIND_IP:-}" "${IP1:-}"; do
            [ -n "$_x" ] || continue
            printf '%s\n' "$self_srv_ips" | grep -qx "$_x" || self_srv_ips="$self_srv_ips"$'\n'"$_x"
        done
        self_srv_ips="$(printf '%s\n' "$self_srv_ips" | sort -u | tr '\n' ' ' | sed 's/ *$//')"
        self_a_match=""
        # shellcheck disable=SC2086  # разбор списка адресов по словам
        for _x in $self_a_ips; do
            case " $self_srv_ips " in
                *" $_x "*) self_a_match="$_x"; break ;;
            esac
        done
        if [ -z "$self_a_ips" ]; then
            warn "DNS: A-запись для $DOMAIN не найдена — Let's Encrypt не выпустится, пока домен не настроен."
        elif [ -n "$self_a_match" ]; then
            ok "DNS: $DOMAIN → $self_a_match"
        else
            note "DNS: $DOMAIN → $self_a_ips; адреса этого сервера: $self_srv_ips"
            note "если домен уже открывается и отдаёт заглушку — всё в порядке (кэш DNS/TTL)"
            note "ACME сработает, когда A-запись указывает на этот сервер: HTTP-01 проверяет её в момент выпуска"
        fi
        unset _x self_a_ips self_srv_ips self_a_match 2>/dev/null || true
    fi

    note "Запускаю Caddy…"
    start_caddy || die "Caddy: конфиг невалиден, запуск не удался или порт $SELFSTEAL_PORT не слушает. Проверьте docker logs selfsteal; существующие конфиги сохранены."

    cat > /etc/systemd/system/selfsteal.service <<EOF
[Unit]
Description=Caddy selfsteal (Remnawave decoy site)
After=network-online.target docker.service
Wants=network-online.target docker.service
ConditionPathExists=$SELFSTEAL_DIR/docker-compose.yml

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$SELFSTEAL_DIR
ExecStart=$DOCKER_BIN compose up -d --remove-orphans
ExecReload=$DOCKER_BIN compose up -d --remove-orphans
ExecStop=$DOCKER_BIN compose down
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable selfsteal.service >/dev/null 2>&1 || die "Не удалось включить автозапуск Caddy"
    ok "Selfsteal запущен, автозагрузка включена (selfsteal.service)"

    # --- сертификат для Hysteria2 -----------------------------------------
    # Hysteria2 работает внутри Xray ноды и требует файлы сертификата.
    # Копируем их из selfsteal (из ./ssl или из тома Caddy) в /opt/remnanode/cert
    # (он смонтирован в контейнер как /etc/remnanode/cert) и обновляем по таймеру:
    # Caddy продлевает сертификат сам, нода должна увидеть новый файл.
    cat > /usr/local/sbin/rw-cert-sync.sh <<'CERT_SYNC_EOF'
#!/bin/bash
# Синхронизация сертификата selfsteal → /opt/remnanode/cert (для Hysteria2).
# Источники: ./ssl (сертификат выпущен вручную/acme.sh) или том Caddy.
set -uo pipefail

ANSWERS=/etc/remnawave-setup/answers.env
DEST=/opt/remnanode/cert
DOMAIN=""; HYSTERIA=""
NO_RESTART=false
[ "${1:-}" = "--no-restart" ] && NO_RESTART=true
# shellcheck disable=SC1090
[ -f "$ANSWERS" ] && . "$ANSWERS"

if [ -z "${DOMAIN:-}" ]; then
    echo "домен selfsteal не задан — синхронизация сертификата не нужна"
    exit 0
fi

mkdir -p "$DEST" 2>/dev/null || true
chmod 700 "$DEST" 2>/dev/null || true
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

src_crt=""; src_key=""
if [ -s /opt/selfsteal/ssl/fullchain.crt ] && [ -s /opt/selfsteal/ssl/private.key ]; then
    src_crt=/opt/selfsteal/ssl/fullchain.crt
    src_key=/opt/selfsteal/ssl/private.key
elif docker inspect -f '{{.State.Running}}' selfsteal 2>/dev/null | grep -q true; then
    # Caddy хранит ACME-сертификаты в своём томе: .../certificates/<issuer>/<домен>/
    p="$(docker exec selfsteal sh -c "find /data/caddy/certificates -type f -name '*.crt' -path '*/${DOMAIN}/*' 2>/dev/null | head -n 1" 2>/dev/null | tr -d '\r')"
    if [ -n "${p:-}" ]; then
        docker exec selfsteal cat "$p" > "$tmpd/fullchain.crt" 2>/dev/null || true
        docker exec selfsteal cat "${p%.crt}.key" > "$tmpd/private.key" 2>/dev/null || true
        if [ -s "$tmpd/fullchain.crt" ] && [ -s "$tmpd/private.key" ]; then
            src_crt="$tmpd/fullchain.crt"
            src_key="$tmpd/private.key"
        fi
    fi
fi

if [ -z "$src_crt" ]; then
    echo "сертификат для $DOMAIN не найден (selfsteal ещё не выпустил?) — повторим позже"
    exit 1
fi

if ! openssl x509 -noout -in "$src_crt" >/dev/null 2>&1; then
    echo "файл сертификата повреждён — пропускаю"
    exit 1
fi

changed=false
if ! cmp -s "$src_crt" "$DEST/fullchain.crt" 2>/dev/null \
   || ! cmp -s "$src_key" "$DEST/private.key" 2>/dev/null; then
    install -m 600 "$src_crt" "$DEST/fullchain.crt"
    install -m 600 "$src_key" "$DEST/private.key"
    changed=true
fi

if [ "$changed" = true ]; then
    echo "сертификат $DOMAIN обновлён в $DEST"
    if [ "$NO_RESTART" = false ] && [ "${HYSTERIA:-no}" = "yes" ] \
       && [ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || true)" = "true" ]; then
        docker restart remnanode >/dev/null 2>&1 \
            && echo "нода перезапущена (Hysteria2 перечитает сертификат)"
    fi
else
    echo "сертификат в $DEST уже актуален"
fi
CERT_SYNC_EOF
    chmod 0755 /usr/local/sbin/rw-cert-sync.sh

    cat > /etc/systemd/system/rw-cert-sync.service <<'EOF'
[Unit]
Description=Sync selfsteal certificate to Remnawave Node (Hysteria2)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rw-cert-sync.sh
EOF

    cat > /etc/systemd/system/rw-cert-sync.timer <<'EOF'
[Unit]
Description=Daily certificate sync for Hysteria2

[Timer]
OnCalendar=*-*-* 05:20:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now rw-cert-sync.timer >/dev/null 2>&1 \
        || warn "таймер синхронизации сертификата не включился"
    # Caddy выпускает сертификат уже после старта, поэтому ждём до 60 с:
    # без файлов в /opt/remnanode/cert Hysteria2 не поднимется.
    _cert_ok=false
    _cert_try=0
    while [ "$_cert_try" -lt 12 ]; do
        if /usr/local/sbin/rw-cert-sync.sh --no-restart >/dev/null 2>&1; then
            _cert_ok=true
            break
        fi
        sleep 5
        _cert_try=$((_cert_try + 1))
    done
    unset _cert_try 2>/dev/null || true
    if [ "$_cert_ok" = true ]; then
        ok "Сертификат скопирован в $NODE_DIR/cert (для Hysteria2), обновление по таймеру"
    else
        warn "Сертификат пока не скопирован — Caddy не успел выпустить; повторит таймер"
        note "вручную: nodego → Hysteria2 → обновить сертификат"
    fi
    unset _cert_ok 2>/dev/null || true
else
    hdr "9. Caddy selfsteal"
    note "Пропущено по выбору пользователя"
fi

# ============================================================================
# 10. DNS-фильтрация (AdGuard DoT)
# ============================================================================
hdr "10. DNS"
if [ "$USE_DNS" = "yes" ]; then
    if [ -f /etc/systemd/resolved.conf.d/99-adguard-dot.conf ]; then
        dns_probe || die "Существующий DNS не отвечает; конфиги не изменены"
        note "Существующий DNS сохранён; изменение режима — через nodego dns"
        if [ ! -f "$STATE_DIR/dns-backup/complete" ]; then
            warn "Старая установка DNS без исходного снимка: автоматический dns off невозможен; нужен ручной бэкап."
        fi
    elif ! systemctl cat systemd-resolved.service >/dev/null 2>&1; then
        warn "systemd-resolved отсутствует: рабочий DNS не меняю, AdGuard не включён."
        USE_DNS=no
        set_answer USE_DNS no
    else
        dns_change on || die "DNS не включён; проверяйте сообщения отката и снимок $STATE_DIR/dns-backup"
    fi
else
    note "Пропущено: текущий системный DNS не меняется (отключение AdGuard: nodego dns off)"
fi

# ============================================================================
# 11. Автообновление
# ============================================================================
hdr "11. Автообновление"
if [ "$AUTO_UPDATE" = "yes" ]; then
    cat > /usr/local/sbin/rw-node-update.sh <<'EOS'
#!/bin/bash
# Обновляет Remnawave Node до latest. Если новый образ не поднялся — откат
# на предыдущий (перетегируем старый image ID обратно в :latest).
set -uo pipefail
DIR=/opt/remnanode
LOG=/var/log/remnawave-update.log
say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

cd "$DIR" || exit 1
# Не допускаем одновременно ручное и плановое обновление.
exec 9> .update.lock
flock -n 9 || { say "обновление уже выполняется"; exit 1; }
OLD_ID="$(docker inspect --format '{{.Image}}' remnanode 2>/dev/null || true)"
OLD_REF="$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null || true)"
NODE_PORT="$(sed -n 's/^NODE_PORT=//p' .env | tr -d '\"\047\r' | head -n1)"
[[ "$NODE_PORT" =~ ^[0-9]+$ ]] || { say "неизвестен NODE_PORT"; exit 1; }
[ -n "$OLD_ID" ] && [ -n "$OLD_REF" ] || { say "нет образа для отката"; exit 1; }
# Отдельный тег удерживает старый образ; глобальный prune не трогает соседей.
docker tag "$OLD_ID" remnawave/node:rollback >>"$LOG" 2>&1 || exit 1

check_port_owner() { # порт, контейнер
    local port="$1" container="$2" listeners pids pid owners listener
    listeners="$(ss -tlnpH "sport = :$port" 2>/dev/null)" || return 1
    [ -n "$listeners" ] || return 0
    owners="$(docker top "$container" -eo pid 2>/dev/null | awk 'NR>1 {print $1}')" || return 1
    while IFS= read -r listener; do
        pids="$(printf '%s\n' "$listener" | grep -oE 'pid=[0-9]+' | cut -d= -f2)" || return 1
        [ -n "$pids" ] || return 1
        for pid in $pids; do
            printf '%s\n' "$owners" | grep -qx "$pid" || return 1
        done
    done <<< "$listeners"
}

node_ready() {
    local n=0 good=0
    while [ "$n" -lt 30 ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" = true ] \
            && ss -tlnH "sport = :$NODE_PORT" 2>/dev/null | grep -q . \
            && check_port_owner "$NODE_PORT" remnanode; then
            good=$((good + 1))
            [ "$good" -ge 3 ] && return 0
        else
            good=0
        fi
        n=$((n + 1)); sleep 2
    done
    return 1
}

say "== pull =="
if ! docker compose pull -q >>"$LOG" 2>&1; then
    say "pull не удался — обновление пропущено"
    exit 1
fi

say "== up =="
if docker compose up -d remnanode >>"$LOG" 2>&1 && node_ready; then
    say "== ok (Running + API) =="
else
    say "запуск/API не прошёл проверку — откатываю"
    # Override по ID не зависит от mutable latest и не правит основной compose.
    rollback="$(mktemp "$DIR/.rollback.XXXXXX.yml")" || exit 1
    printf 'services:\n  remnanode:\n    image: %s\n' "$OLD_ID" > "$rollback"
    if docker compose -f docker-compose.yml -f "$rollback" up -d --pull never remnanode >>"$LOG" 2>&1 && node_ready; then
        say "старый образ восстановлен"
        case "$OLD_REF" in *@*) : ;; *) docker tag "$OLD_ID" "$OLD_REF" >>"$LOG" 2>&1 || true ;; esac
    else
        say "ОШИБКА: откат не восстановил API; требуется ручная проверка"
    fi
    rm -f "$rollback"
    exit 1
fi
EOS
    chmod 0755 /usr/local/sbin/rw-node-update.sh

    cat > /etc/systemd/system/rw-node-update.service <<'EOF'
[Unit]
Description=Remnawave Node auto-update
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rw-node-update.sh
TimeoutStartSec=900
EOF

    cat > /etc/systemd/system/rw-node-update.timer <<'EOF'
[Unit]
Description=Daily Remnawave Node update check

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now rw-node-update.timer >/dev/null 2>&1 || die "Таймер автообновления не включился"
    ok "Нода обновляется автоматически (~04:30, лог /var/log/remnawave-update.log)"
else
    if systemctl cat rw-node-update.timer >/dev/null 2>&1; then
        systemctl disable --now rw-node-update.timer >/dev/null 2>&1 \
            || die "Не удалось остановить прежний таймер автообновления"
    fi
    note "Автообновление ноды выключено"
fi

# Обновления безопасности ОС — без автоматической перезагрузки
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 || warn "unattended-upgrades не установился"
cat > /etc/apt/apt.conf.d/99-rw-unattended <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
ok "Обновления безопасности ОС включены (без автоперезагрузки)"

# ============================================================================
# 12. Обслуживание: логи и очистка
# ============================================================================
hdr "12. Обслуживание"

# ============================================================ healthcheck ===
cat > "$STATE_DIR/alerts.env" <<EOF
# Настройки алертов (меняются через nodego)
ALERTS=$(env_quote "$ALERTS")
TG_TOKEN=$(env_quote "$TG_TOKEN")
TG_CHAT=$(env_quote "$TG_CHAT")
EOF
chmod 600 "$STATE_DIR/alerts.env"

cat > /usr/local/sbin/rw-healthcheck.sh <<'HEALTH_EOF'
#!/bin/bash
# Проверка состояния ноды.
#   без аргументов — режим таймера: сравнивает с прошлым состоянием и
#                    отправляет алерт в Telegram только при изменениях
#   --report       — подробный отчёт без алертов (nodego doctor)
set -uo pipefail

CONF=/etc/remnawave-setup/alerts.env
ANSWERS=/etc/remnawave-setup/answers.env
NET=/etc/remnawave-setup/net.env
NODE_ENV=/opt/remnanode/.env
STATE_DIR=/var/lib/rw-healthcheck
STATE="$STATE_DIR/state"

REPORT=false
[ "${1:-}" = "--report" ] && REPORT=true

ALERTS=no; TG_TOKEN=""; TG_CHAT=""
MODE=single; IP1=""; IP2=""; DOMAIN=""; SELFSTEAL_PORT="9443"
# Порядок важен: alerts.env читается ПОСЛЕДНИМ. В answers.env лежат ALERTS/TG_*
# на момент установки, и если прочитать их после alerts.env, настройки алертов,
# изменённые через nodego, молча теряются.
# shellcheck disable=SC1090
[ -f "$ANSWERS" ] && . "$ANSWERS"
# shellcheck disable=SC1090
[ -f "$NET" ]     && . "$NET"
# shellcheck disable=SC1090
[ -f "$CONF" ]    && . "$CONF"

NODE_PORT="${NODE_PORT:-2222}"
if [ -f "$NODE_ENV" ]; then
    _p="$(grep -E '^NODE_PORT=' "$NODE_ENV" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
    [ -n "${_p:-}" ] && NODE_PORT="$_p"
fi

RESULTS=()
problems=()

run_check() { # run_check <key> <человеческое описание> <команда...>
    local key="$1" label="$2"; shift 2
    if "$@"; then
        RESULTS+=("$key|ok|$label")
    else
        RESULTS+=("$key|fail|$label")
        problems+=("$label")
    fi
}

c_container() {
    local st
    st="$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo missing)"
    [ "$st" = "true" ]
}

c_port() {
    ss -tlnH "sport = :$NODE_PORT" 2>/dev/null | grep -q .
}

c_disk() {
    local use
    use="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    [ -n "$use" ] || return 0
    [ "$use" -lt 85 ]
}

c_conntrack() {
    local cur max
    cur="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "")"
    max="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "")"
    [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] || return 0
    [ $((cur * 100 / max)) -lt 70 ]
}

c_outbound() {
    [ "$MODE" = "dual" ] && [ -n "${IP2:-}" ] || return 0
    local ip
    ip="$(curl -4 -fsS --max-time 8 --interface "$IP2" https://ifconfig.io 2>/dev/null || true)"
    [ -z "$ip" ] && return 0
    [ "$ip" = "$IP2" ]
}

c_restarts() {
    local n
    n="$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null || echo 0)"
    [ -n "$n" ] || return 0
    [ "$n" -lt 5 ]
}

c_cert() {
    [ -n "${DOMAIN:-}" ] || return 0
    [ -d /opt/selfsteal ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0
    local end days
    end="$(echo | timeout 8 openssl s_client -servername "$DOMAIN" \
            -connect "127.0.0.1:${SELFSTEAL_PORT:-9443}" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -n "$end" ] || return 0
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    [ "$days" -ge 7 ]
}

run_check container "контейнер ноды не запущен"               c_container
run_check port      "порт ноды $NODE_PORT не слушается"      c_port
run_check disk      "мало места на диске (<15%)"             c_disk
run_check conntrack "таблица conntrack заполнена >70%"       c_conntrack
run_check outbound  "исходящий IP не совпадает с $IP2"       c_outbound
run_check restarts  "нода перезапускалась 5+ раз"            c_restarts
run_check cert      "сертификат Caddy истекает (<7 дней)"    c_cert

if [ "$REPORT" = true ]; then
    echo "=== healthcheck $(date '+%F %T') ==="
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r key st label <<< "$line"
        if [ "$st" = "ok" ]; then printf '  [ok]   %s\n' "$key"
        else printf '  [FAIL] %s — %s\n' "$key" "$label"; fi
    done
    echo
    echo "контейнер:   $(docker inspect -f '{{.State.Status}} (restarts: {{.RestartCount}})' remnanode 2>/dev/null || echo missing)"
    echo "порт ноды:   $NODE_PORT"
    echo "схема сети:  $MODE${IP2:+ ($IP1 → $IP2)}"
    echo "диск:        $(df -h / | awk 'NR==2 {print $5" занято, "$4" свободно"}')"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        echo "conntrack:   $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
    fi
    [ -f /var/run/reboot-required ] && echo "требуется перезагрузка: да"
    echo
    if [ "${#problems[@]}" -eq 0 ]; then
        echo "проблем не найдено"
    else
        printf 'проблема: %s\n' "${problems[@]}"
    fi
    exit 0
fi

# --------------------------------------------------------------- таймер-режим
tg_send() {
    [ "$ALERTS" = "yes" ] && [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
    curl -fsS --max-time 10 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" -d "disable_web_page_preview=true" \
        --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

mkdir -p "$STATE_DIR"
old_state=""
[ -f "$STATE" ] && old_state="$(cat "$STATE")"

new_state=""
message=""
for line in "${RESULTS[@]}"; do
    IFS='|' read -r key st label <<< "$line"
    new_state+="${key}=${st}"$'\n'
    prev="$(printf '%s\n' "$old_state" | grep -m1 "^${key}=" | cut -d= -f2 || true)"
    if [ -n "$prev" ] && [ "$prev" != "$st" ]; then
        if [ "$st" = "fail" ]; then
            message+="🔴 ${label}"$'\n'
        else
            message+="🟢 восстановлено: ${key}"$'\n'
        fi
    fi
done

printf '%s' "$new_state" > "$STATE"

if [ -n "$message" ]; then
    tg_send "🖥 $(hostname) — нода
${message}
$(date '+%F %T')"
fi
exit 0
HEALTH_EOF
chmod 0755 /usr/local/sbin/rw-healthcheck.sh

cat > /etc/systemd/system/rw-healthcheck.service <<'EOF'
[Unit]
Description=Remnawave node healthcheck
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rw-healthcheck.sh
EOF

cat > /etc/systemd/system/rw-healthcheck.timer <<'EOF'
[Unit]
Description=Run Remnawave healthcheck every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

# ================================================================ бэкапы ===
cat > /usr/local/sbin/rw-backup.sh <<'BACKUP_EOF'
#!/bin/bash
# Бэкап конфигов Remnawave: create | list | restore <файл>
set -uo pipefail

DIR=/var/backups/remnanode
KEEP=14

create() {
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    local ts f
    ts="$(date +%Y%m%d-%H%M%S)"
    f="$DIR/remnawave-$ts.tar.gz"
    tar czf "$f" --ignore-failed-read -C / \
        etc/remnawave-setup \
        opt/remnanode/.env \
        opt/remnanode/docker-compose.yml \
        opt/selfsteal/.env \
        opt/selfsteal/Caddyfile \
        opt/selfsteal/docker-compose.yml 2>/dev/null
    if [ ! -s "$f" ]; then
        echo "бэкап не создался" >&2
        return 1
    fi
    chmod 600 "$f"
    ls -1t "$DIR"/remnawave-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
    echo "$f"
}

list() {
    ls -1t "$DIR"/remnawave-*.tar.gz 2>/dev/null || echo "(бэкапов пока нет)"
}

restore() {
    local f="${1:-}"
    [ -n "$f" ] || { echo "укажите файл бэкапа" >&2; return 1; }
    [ -f "$f" ] || { echo "нет файла: $f" >&2; return 1; }
    tar xzf "$f" -C /
    echo "восстановлено из $f"
    echo "перезапустите службы: systemctl restart remnanode selfsteal"
}

case "${1:-create}" in
    create)  create ;;
    list)    list ;;
    restore) shift; restore "${1:-}" ;;
    -h|--help)
        echo "rw-backup.sh [create|list|restore <файл>]"
        ;;
    *) echo "неизвестная команда: $1" >&2; exit 1 ;;
esac
BACKUP_EOF
chmod 0755 /usr/local/sbin/rw-backup.sh

cat > /etc/systemd/system/rw-backup.service <<'EOF'
[Unit]
Description=Backup Remnawave configs
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rw-backup.sh create
EOF

cat > /etc/systemd/system/rw-backup.timer <<'EOF'
[Unit]
Description=Daily Remnawave config backup

[Timer]
OnCalendar=*-*-* 03:45:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now rw-healthcheck.timer >/dev/null 2>&1 || warn "healthcheck-таймер не включился"
systemctl enable --now rw-backup.timer >/dev/null 2>&1 || warn "бэкап-таймер не включился"
ok "healthcheck раз в 5 минут, бэкап конфигов ежедневно (хранится 14 копий)"

# первый прогон — чтобы не ждать 5 минут
/usr/local/sbin/rw-healthcheck.sh >/dev/null 2>&1 || true
/usr/local/sbin/rw-backup.sh create >/dev/null 2>&1 || warn "первый бэкап не создался"

# --- меню управления nodego -------------------------------------------------
NODEGO_OK=false
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/nodego.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/nodego.sh" /usr/local/bin/nodego && NODEGO_OK=true
fi
if [ "$NODEGO_OK" = false ]; then
    if fetch "$RAW_BASE/nodego.sh" /usr/local/bin/nodego 2>/dev/null; then
        chmod 0755 /usr/local/bin/nodego && NODEGO_OK=true
    fi
fi
if [ "$NODEGO_OK" = true ]; then
    ok "Меню управления: команда nodego"
else
    warn "Не удалось установить nodego (меню управления) — не критично"
fi

# ============================================================================
# Генератор готовых конфигов (используется установщиком и меню nodego)
# ============================================================================
# xHTTP / gRPC / TCP (VLESS+Reality) и Hysteria2 — с уже сгенерированными
# privateKey (настоящая X25519-пара из xray внутри ноды), shortIds, тегами
# на 8 символов, правильным Reality target (127.0.0.1:9443 при selfsteal)
# и serverNames (домен selfsteal либо apple.com).
cat > /usr/local/sbin/rw-configs.sh <<'CONFIGS_EOF'
#!/bin/bash
# ============================================================================
#  rw-configs — готовые конфиги для Config Profile панели Remnawave
# ============================================================================
#  xHTTP, gRPC, TCP (VLESS + Reality) и Hysteria2 (TLS по UDP).
#
#  hysteria2.json содержит ДВА инбаунда: hysteria (UDP) и xHTTP + Reality (TCP,
#  target 127.0.0.1:<порт Caddy>). Второй нужен для Caddy selfsteal: без него на
#  публичном TCP/443 никто не слушает, и сайт-заглушка не открывается — у
#  hysteria-инбаунда в Xray нет fallback. Для клиентов xHTTP включать не
#  обязательно (Squads → Inbounds решает, раздавать ли его в подписках).
#
#  Секреты и имена — случайные при каждой генерации:
#    * privateKey — настоящая X25519-пара (xray x25519 внутри ноды),
#      в конфиг попадает приватный ключ, publicKey выводит команда keys
#    * shortIds   — случайные 8-байтные hex (16 символов), по 6 на инбаунд
#    * tag        — 8 символов: NodeGo22 / Node6521 / GoNode29 / 21Node54
#    * target     — 127.0.0.1:<порт Caddy>, если стоит selfsteal,
#                   иначе www.apple.com:443
#    * serverNames — домен selfsteal, иначе apple.com и www.apple.com
#    * порт       — общий порт подключения из answers.env (CONNECT_PORT)
#
#  Запуск (обычно через nodego):
#    rw-configs.sh generate [--force]   создать/обновить конфиги
#    rw-configs.sh brief                короткая сводка
#    rw-configs.sh show [тип|all]       напечатать конфиги
#    rw-configs.sh path <тип>           путь к файлу
#    rw-configs.sh keys                 publicKey / shortIds / tag
#    rw-configs.sh test [тип]           проверка через xray -test в ноде
# ============================================================================
set -uo pipefail

STATE_DIR="${RW_STATE_DIR:-/etc/remnawave-setup}"
ANSWERS="$STATE_DIR/answers.env"
CONF_DIR="$STATE_DIR/configs"
NODE_CONTAINER="remnanode"
APL_TARGET="www.apple.com:443"
APL_NAMES='"www.apple.com", "apple.com"'

SHORT_IDS_JSON=""
SHORT_IDS_LIST=""

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
warn() { echo "  [!!] $*"; }
say()  { echo "$*"; }

usage() {
    sed -n '4,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' | sed '/^$/d' || true
}

load_conf() {
    CONNECT_PORT=""
    # Наш пресет — selfsteal (дефолт установщика тоже yes). В старом answers.env
    # ключа USE_SELFSTEAL нет; дефолт no молча давал target www.apple.com:443
    # вместо 127.0.0.1:9443. Явное значение из answers.env по-прежнему главнее.
    HYSTERIA="no"; USE_SELFSTEAL="yes"; DOMAIN=""; SELFSTEAL_PORT="9443"
    XHTTP_PORT=""; GRPC_PORT=""; TCP_PORT=""
    # shellcheck disable=SC1090
    if [ -f "$ANSWERS" ]; then . "$ANSWERS"; fi
    if [ -z "${CONNECT_PORT:-}" ]; then
        for _p in "${XHTTP_PORT:-}" "${GRPC_PORT:-}" "${TCP_PORT:-}"; do
            if [ -n "$_p" ]; then CONNECT_PORT="$_p"; break; fi
        done
        unset _p 2>/dev/null || true
    fi
    CONNECT_PORT="${CONNECT_PORT:-443}"
    HYSTERIA="${HYSTERIA:-no}"
    SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
    if [ "${USE_SELFSTEAL:-no}" = "yes" ] && [ -n "${DOMAIN:-}" ]; then
        REALITY_TARGET="127.0.0.1:${SELFSTEAL_PORT}"
        SERVER_NAMES="\"${DOMAIN}\""
        SNI="$DOMAIN"
    else
        REALITY_TARGET="$APL_TARGET"
        SERVER_NAMES="$APL_NAMES"
        SNI="www.apple.com"
    fi
}

# ------------------------------------------------------------------ утилиты
has_docker() { command -v docker >/dev/null 2>&1; }

node_running() {
    has_docker || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || true)" = "true" ]
}

xray_exec() { docker exec "$NODE_CONTAINER" sh -c "$1" 2>/dev/null; }

gen_short_id() {
    local s=""
    s="$(openssl rand -hex 8 2>/dev/null || true)"
    if [ -z "$s" ]; then
        s="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n')"
    fi
    printf '%s' "${s:0:16}"
}

gen_short_id_set() {
    local i="" sid=""
    SHORT_IDS_JSON=""
    SHORT_IDS_LIST=""
    for i in 1 2 3 4 5 6; do
        sid="$(gen_short_id)"
        if [ -z "$SHORT_IDS_JSON" ]; then
            SHORT_IDS_JSON="\"$sid\""
            SHORT_IDS_LIST="$sid"
        else
            SHORT_IDS_JSON="$SHORT_IDS_JSON, \"$sid\""
            SHORT_IDS_LIST="$SHORT_IDS_LIST,$sid"
        fi
    done
}

# Настоящая X25519-пара: сначала через xray внутри ноды (как в панели),
# если ноды/докера нет — через openssl (key = 32 байта base64url).
gen_pair() {
    local out="" priv="" pub="" pem=""
    if node_running; then
        out="$(xray_exec 'xray x25519 2>/dev/null || /usr/local/bin/xray x25519 2>/dev/null' | tr -d '\r')"
        priv="$(printf '%s\n' "$out" | grep -iE '^private' | head -n1 | sed 's/^[^:]*:[[:space:]]*//')"
        pub="$(printf '%s\n' "$out" | grep -iE 'public|password' | head -n1 | sed 's/^[^:]*:[[:space:]]*//')"
    fi
    case "$priv" in
        ""|*[!A-Za-z0-9_-]*) priv="" ;;
    esac
    if [ "${#priv}" -ne 43 ] || [ "${#pub}" -ne 43 ]; then
        pem="$(mktemp)"
        if openssl genpkey -algorithm X25519 -out "$pem" >/dev/null 2>&1; then
            priv="$(openssl pkey -in "$pem" -outform DER 2>/dev/null | tail -c 32 \
                    | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
            pub="$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 \
                    | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
        fi
        rm -f "$pem"
    fi
    if [ "${#priv}" -ne 43 ] || [ "${#pub}" -ne 43 ]; then
        return 1
    fi
    printf '%s %s\n' "$priv" "$pub"
}

# Тег на 8 символов в духе NodeGo22 / Node6521 / GoNode29 / 21Node54
gen_tag() {
    local a="" b=""
    a="$(printf '%02d' $((RANDOM % 100)))"
    b="$(printf '%02d' $((RANDOM % 100)))"
    case $((RANDOM % 4)) in
        0) printf 'NodeGo%s' "$a" ;;
        1) printf 'Node%s%s' "$a" "$b" ;;
        2) printf 'GoNode%s' "$a" ;;
        *) printf '%sNode%s' "$a" "$b" ;;
    esac
}

tag_of() {
    sed -n 's/^[[:space:]]*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}

tag_exists() {
    local t="$1" f=""
    for f in "$CONF_DIR"/*.json; do
        [ -f "$f" ] || continue
        if [ "$(tag_of "$f")" = "$t" ]; then return 0; fi
    done
    return 1
}

new_tag() {
    local t="" i=0
    while [ "$i" -lt 50 ]; do
        t="$(gen_tag)"
        if ! tag_exists "$t"; then printf '%s' "$t"; return 0; fi
        i=$((i + 1))
    done
    printf 'NodeGo%s' "$(printf '%02d' $((RANDOM % 100)))"
}

meta_add() { # meta_add ТИП КЛЮЧ ЗНАЧЕНИЕ
    local t="$1" k="$2" v="$3"
    t="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
    printf "%s_%s='%s'\n" "$t" "$k" "$v" >> "$CONF_DIR/meta.env"
}

meta_drop() { # meta_drop ТИП
    local t="$1"
    t="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
    [ -f "$CONF_DIR/meta.env" ] || return 0
    sed -i "/^${t}_/d" "$CONF_DIR/meta.env"
}

# ------------------------------------------------------------- JSON-шаблоны
write_xhttp() { # write_xhttp TAG PRIVKEY
    cat > "$CONF_DIR/xhttp.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "$1",
      "port": $CONNECT_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/"
        },
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "$REALITY_TARGET",
          "shortIds": [$SHORT_IDS_JSON],
          "privateKey": "$2",
          "serverNames": [$SERVER_NAMES]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
}

write_grpc() { # write_grpc TAG PRIVKEY SERVICE
    cat > "$CONF_DIR/grpc.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "$1",
      "port": $CONNECT_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "grpcSettings": {
          "serviceName": "$3"
        },
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "$REALITY_TARGET",
          "shortIds": [$SHORT_IDS_JSON],
          "privateKey": "$2",
          "serverNames": [$SERVER_NAMES]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
}

write_tcp() { # write_tcp TAG PRIVKEY
    cat > "$CONF_DIR/tcp.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "$1",
      "port": $CONNECT_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "$REALITY_TARGET",
          "shortIds": [$SHORT_IDS_JSON],
          "privateKey": "$2",
          "serverNames": [$SERVER_NAMES]
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
}

json_head() {
    cat <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
EOF
}

json_tail() {
    cat <<'EOF'
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
}

# hysteria2.json = hysteria (UDP) и, если задан второй тег, ещё xHTTP + Reality
# (TCP) в том же файле. xHTTP нужен для Caddy selfsteal: у hysteria-инбаунда нет
# fallback, поэтому без TCP-инбаунда сайт-заглушка снаружи не открывается.
# Раздавать ли xHTTP клиентам — решает Squads → Inbounds, это не обязательно.
write_hysteria() { # write_hysteria HY_TAG [XH_TAG XH_PRIV]
    {
        json_head
        cat <<EOF
    {
      "tag": "$1",
      "port": $CONNECT_PORT,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": {
        "clients": [],
        "version": 2
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "keyFile": "/etc/remnanode/cert/private.key",
              "certificateFile": "/etc/remnanode/cert/fullchain.crt"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60
        }
      }
    }
EOF
        if [ -n "${2:-}" ]; then
            cat <<EOF
    ,
    {
      "tag": "$2",
      "port": $CONNECT_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/"
        },
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "$REALITY_TARGET",
          "shortIds": [$SHORT_IDS_JSON],
          "privateKey": "$3",
          "serverNames": [$SERVER_NAMES]
        }
      }
    }
EOF
        fi
        json_tail
    } > "$CONF_DIR/hysteria2.json"
}

# Обновляет «переменные» параметры (порт, target, serverNames) в готовом
# конфиге, не трогая ключи и shortId: сменился домен/порт — профиль в панели
# можно не перегенерировать.
sync_existing() { # sync_existing FILE
    local f="$1" tmp=""
    command -v jq >/dev/null 2>&1 || { warn "jq не найден — параметры $f не обновлены"; return 0; }
    tmp="$(mktemp)"
    # shellcheck disable=SC2016  # $port/$target/$names/$sni — переменные jq
    if jq --argjson port "$CONNECT_PORT" \
          --arg target "$REALITY_TARGET" \
          --arg sni "$SNI" \
          --argjson names "[$SERVER_NAMES]" '
        .inbounds |= map(
            .port = $port
            | if .streamSettings.realitySettings then
                .streamSettings.realitySettings.target = $target
                | .streamSettings.realitySettings.serverNames = $names
              else . end
            | if .streamSettings.tlsSettings then
                .streamSettings.tlsSettings.serverName = $sni
              else . end
        )
      ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        warn "не удалось обновить параметры в $f"
    fi
}

# ------------------------------------------------------------------- команды
generate() {
    local force="${1:-}" type="" f="" tag="" pair="" priv="" pub="" svc="" xh_tag=""
    [ -f "$ANSWERS" ] || die "нет $ANSWERS — сначала запустите установщик"
    mkdir -p "$CONF_DIR"
    chmod 700 "$STATE_DIR" "$CONF_DIR" 2>/dev/null || true
    if [ "$force" = "--force" ]; then
        rm -f "$CONF_DIR"/*.json
        rm -f "$CONF_DIR/meta.env"
    fi
    : >> "$CONF_DIR/meta.env"
    chmod 600 "$CONF_DIR/meta.env"

    for type in xhttp grpc tcp; do
        f="$CONF_DIR/$type.json"
        if [ -f "$f" ]; then
            sync_existing "$f"
            continue
        fi
        pair="$(gen_pair)" || true
        priv="${pair%% *}"
        pub="${pair#* }"
        if [ -z "$priv" ] || [ "$priv" = "$pair" ]; then
            warn "не удалось сгенерировать ключ X25519 для $type"
            continue
        fi
        tag="$(new_tag)"
        gen_short_id_set
        case "$type" in
            xhttp) write_xhttp "$tag" "$priv" ;;
            grpc)
                svc="srv$(openssl rand -hex 4 2>/dev/null || gen_short_id)"
                write_grpc "$tag" "$priv" "$svc"
                ;;
            tcp)   write_tcp "$tag" "$priv" ;;
        esac
        chmod 600 "$f"
        meta_add "$type" TAG "$tag"
        meta_add "$type" PUB "$pub"
        meta_add "$type" SIDS "$SHORT_IDS_LIST"
        say "  готов: $type (tag $tag, порт $CONNECT_PORT)"
    done

    if [ "${HYSTERIA:-no}" = "yes" ] && [ -n "${DOMAIN:-}" ]; then
        f="$CONF_DIR/hysteria2.json"
        if [ -f "$f" ]; then
            sync_existing "$f"
        else
            priv=""
            pair="$(gen_pair)" || true
            priv="${pair%% *}"
            pub="${pair#* }"
            if [ -z "$priv" ] || [ "$priv" = "$pair" ]; then
                priv=""; pub=""
                warn "не удалось сгенерировать X25519 — hysteria2 без xHTTP"
            fi
            tag="$(new_tag)"
            if [ -n "$priv" ]; then
                xh_tag="$(new_tag)"
                gen_short_id_set
                write_hysteria "$tag" "$xh_tag" "$priv"
                meta_add hysteria2 TAG "$tag"
                meta_add hysteria2 XHTTP_TAG "$xh_tag"
                meta_add hysteria2 XHTTP_PUB "$pub"
                meta_add hysteria2 XHTTP_SIDS "$SHORT_IDS_LIST"
                say "  готов: hysteria2 (tag $tag, $CONNECT_PORT/udp)"
                say "         + xHTTP/Reality (tag $xh_tag, $CONNECT_PORT/tcp) — нужен для selfsteal"
            else
                write_hysteria "$tag"
                meta_add hysteria2 TAG "$tag"
                say "  готов: hysteria2 (tag $tag, $CONNECT_PORT/udp), без xHTTP"
            fi
            chmod 600 "$f"
        fi
    else
        if [ -f "$CONF_DIR/hysteria2.json" ]; then
            rm -f "$CONF_DIR/hysteria2.json"
            meta_drop hysteria2
            say "  Hysteria2 выключена — конфиг hysteria2.json удалён"
        fi
    fi
    return 0
}

brief() {
    local type="" f="" tag="" port="" n=0 xh_tag=""
    say "Готовые конфиги: $CONF_DIR"
    for type in xhttp grpc tcp hysteria2; do
        f="$CONF_DIR/$type.json"
        [ -f "$f" ] || continue
        tag="$(tag_of "$f")"
        port="$(sed -n 's/^[[:space:]]*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -n1)"
        if [ "$type" = "hysteria2" ]; then
            say "  $(printf '%-9s' "$type") tag $(printf '%-8s' "$tag") UDP/$port  TLS: $SNI"
            xh_tag="$(meta_val HYSTERIA2_XHTTP_TAG)"
            if [ -n "$xh_tag" ]; then
                say "  $(printf '%-9s' 'xHTTP') tag $(printf '%-8s' "$xh_tag") TCP/$port  target $REALITY_TARGET  SNI $SNI"
                say "            в том же hysteria2.json; нужен для selfsteal, клиентам не обязателен"
            fi
        else
            say "  $(printf '%-9s' "$type") tag $(printf '%-8s' "$tag") TCP/$port  target $REALITY_TARGET  SNI $SNI"
        fi
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        warn "конфигов пока нет — создайте: rw-configs.sh generate"
        return 1
    fi
    say "  privateKey и shortIds уже внутри; publicKey: rw-configs.sh keys"
}

meta_val() { # meta_val КЛЮЧ -> значение из meta.env (без source)
    sed -n "s/^${1}='\(.*\)'\$/\1/p" "$CONF_DIR/meta.env" 2>/dev/null | head -n1
}

keys() {
    local type="" f="" var="" tag="" pub="" sids="" xh=""
    [ -s "$CONF_DIR/meta.env" ] || { warn "нет $CONF_DIR/meta.env — перегенерируйте конфиги"; return 1; }
    for type in xhttp grpc tcp hysteria2; do
        f="$CONF_DIR/$type.json"
        [ -f "$f" ] || continue
        var="$(printf '%s' "$type" | tr '[:lower:]' '[:upper:]')"
        tag="$(meta_val "${var}_TAG")"
        pub="$(meta_val "${var}_PUB")"
        sids="$(meta_val "${var}_SIDS")"
        if [ "$type" = "hysteria2" ]; then
            say "  $type: tag $tag, TLS serverName $SNI"
            xh="$(meta_val HYSTERIA2_XHTTP_TAG)"
            if [ -n "$xh" ]; then
                say "    xHTTP (второй инбаунд в том же файле, нужен для selfsteal):"
                say "      tag:       $xh"
                say "      publicKey: $(meta_val HYSTERIA2_XHTTP_PUB)"
                say "      shortIds:  $(meta_val HYSTERIA2_XHTTP_SIDS)"
            fi
            continue
        fi
        say "  $type: tag $tag"
        say "    publicKey: $pub"
        say "    shortIds:  $sids"
    done
}

show() {
    local what="${1:-all}" type="" f=""
    case "$what" in hy2|hysteria) what="hysteria2" ;; esac
    for type in xhttp grpc tcp hysteria2; do
        if [ "$what" != "all" ] && [ "$what" != "$type" ]; then continue; fi
        f="$CONF_DIR/$type.json"
        [ -f "$f" ] || continue
        say "=== $type — $f ==="
        cat "$f"
        say ""
    done
}

path_cmd() {
    local type="${1:-xhttp}"
    case "$type" in hy2|hysteria) type="hysteria2" ;; esac
    printf '%s\n' "$CONF_DIR/$type.json"
}

test_configs() {
    local what="${1:-all}" type="" f="" out="" rc=0
    case "$what" in hy2|hysteria) what="hysteria2" ;; esac
    if ! node_running; then
        warn "нода не запущена — проверка конфигов недоступна"
        return 1
    fi
    for type in xhttp grpc tcp hysteria2; do
        if [ "$what" != "all" ] && [ "$what" != "$type" ]; then continue; fi
        f="$CONF_DIR/$type.json"
        [ -f "$f" ] || continue
        if ! docker cp "$f" "$NODE_CONTAINER:/tmp/rw-cfg-test.json" >/dev/null 2>&1; then
            warn "$type: не удалось скопировать конфиг в контейнер"
            rc=1
            continue
        fi
        if out="$(xray_exec 'xray run -test -c /tmp/rw-cfg-test.json 2>&1 || /usr/local/bin/xray run -test -c /tmp/rw-cfg-test.json 2>&1')"; then
            say "  OK   $type"
        else
            say "  FAIL $type"
            printf '%s\n' "$out" | tail -n 6 | sed 's/^/       /'
            rc=1
        fi
        docker exec "$NODE_CONTAINER" rm -f /tmp/rw-cfg-test.json >/dev/null 2>&1 || true
    done
    return "$rc"
}

load_conf

case "${1:-brief}" in
    generate) shift || true; generate "${1:-}" ;;
    brief|status|list) brief ;;
    show) shift || true; show "${1:-all}" ;;
    path) shift || true; path_cmd "${1:-xhttp}" ;;
    keys) keys ;;
    test) shift || true; test_configs "${1:-all}" ;;
    -h|--help|help) usage ;;
    *)
        say "неизвестная команда: $1"
        usage
        exit 1
        ;;
esac
CONFIGS_EOF
chmod 0755 /usr/local/sbin/rw-configs.sh

mkdir -p /var/log/remnanode
cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

cat > /etc/cron.d/remnawave-maintenance <<'EOF'
# journald ограничен через /etc/systemd/journald.conf.d, отдельная чистка не нужна
# страховка по логам docker (поверх log-opts)
30 4 * * * root find /var/lib/docker/containers -name '*-json.log' -size +100M -exec truncate -s 50M {} \; 2>/dev/null || true
# Образы не чистим: они могут понадобиться для отката других проектов.
EOF
chmod 644 /etc/cron.d/remnawave-maintenance /etc/logrotate.d/remnanode
ok "logrotate для ноды + cron-обслуживание"

# ============================================================================
# 13. Готовые конфиги для панели
# ============================================================================
hdr "13. Готовые конфиги для панели"
if /usr/local/sbin/rw-configs.sh generate; then
    /usr/local/sbin/rw-configs.sh brief | sed 's/^/  /' || true
    if /usr/local/sbin/rw-configs.sh test >/dev/null 2>&1; then
        ok "конфиги проверены через xray -test"
    else
        note "проверку xray -test не прошли — смотрите: nodego → Готовые конфиги → проверить"
    fi
else
    warn "конфиги не сгенерировались — позже: nodego → Готовые конфиги"
fi

# ============================================================================
# 14. Проверка
# ============================================================================
hdr "14. Проверка"
sleep 3

say "  ${C_BLD}Контейнеры:${C_OFF}"
docker ps --format '    {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || warn "docker ps недоступен"

say ""
say "  ${C_BLD}Слушающие порты:${C_OFF}"
for p in "$NODE_PORT" "$CONNECT_PORT" 80 "$SELFSTEAL_PORT"; do
    [ -n "$p" ] || continue
    if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
        say "    :$p/tcp — слушается"
    else
        note "    :$p/tcp — свободен"
    fi
done
if [ "$HYSTERIA" = "yes" ]; then
    if ss -ulnH "sport = :$CONNECT_PORT" 2>/dev/null | grep -q .; then
        say "    :$CONNECT_PORT/udp — слушается (Hysteria2)"
    else
        note "    :$CONNECT_PORT/udp — свободен: слушается, когда hysteria-инбаунд появится в профиле панели"
    fi
fi

say ""
say "  ${C_BLD}Ядро ноды:${C_OFF} $(docker exec remnanode sh -c 'xray version 2>/dev/null || /usr/local/bin/xray version 2>/dev/null' 2>/dev/null | head -n1 || echo n/a)"

if [ "$USE_SELFSTEAL" = "yes" ]; then
    say ""
    say "  ${C_BLD}Проверка selfsteal:${C_OFF}"
    CERT_OK=false
    _tries=12
    [ "$HAS_CERT" = true ] && _tries=3
    for _i in $(seq 1 "$_tries"); do
        if curl -fsS --max-time 5 --resolve "$DOMAIN:$SELFSTEAL_PORT:127.0.0.1" \
                "https://$DOMAIN:$SELFSTEAL_PORT/" -o /dev/null 2>/dev/null; then
            CERT_OK=true
            break
        fi
        sleep 5
    done
    unset _i _tries 2>/dev/null || true

    if [ "$CERT_OK" = true ]; then
        ok "HTTPS работает, сертификат доверенный"
    else
        warn "HTTPS не поднялся — сертификат не выпущен или не подхвачен"
        note "частые причины:"
        note "  • порт 80 закрыт снаружи (cloud firewall / security group)"
        note "  • A-запись домена указывает не на этот сервер"
        note "  • ACME-API недоступен у хостера (проверьте вывод «Проверка сети») "
        note "  • домен за прокси, и валидация не доходит до сервера"
        note "лог Caddy:"
        docker exec selfsteal sh -c 'tail -n 5 /var/log/caddy/access.log 2>/dev/null' 2>/dev/null \
            | sed 's/^/      /' || true
        note "дальше: docker logs --tail 40 selfsteal"
    fi
fi

say ""
say "  ${C_BLD}systemd:${C_OFF}"
for u in remnanode selfsteal rw-secondary-ip; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then
        say "    $u.service: $(systemctl is-enabled "$u.service" 2>/dev/null || echo -), $(systemctl is-active "$u.service" 2>/dev/null || echo -)"
    fi
done

if systemctl cat rw-node-update.timer >/dev/null 2>&1; then
    say "    rw-node-update.timer: $(systemctl is-enabled rw-node-update.timer 2>/dev/null || echo -), след. запуск: $(systemctl show -p NextElapseUSecRealtime --value rw-node-update.timer 2>/dev/null | cut -c1-19)"
fi
for _t in rw-healthcheck rw-backup; do
    if systemctl cat "$_t.timer" >/dev/null 2>&1; then
        say "    $_t.timer: $(systemctl is-active "$_t.timer" 2>/dev/null || echo -)"
    fi
done
unset _t 2>/dev/null || true

if [ "$DUAL_IP" = "yes" ]; then
    say ""
    say "  ${C_BLD}Второй IP:${C_OFF}"
    ip -4 addr show dev "${IFACE:-$(ip -o route show default | awk '{print $5; exit}')}" 2>/dev/null | grep -E 'inet ' | sed 's/^/    /' || true
    say "    правило SNAT: $(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c "to-source $IP2") шт."
fi

if [ "$USE_DNS" = "yes" ]; then
    say ""
    say "  ${C_BLD}DNS:${C_OFF} $(resolvectl status 2>/dev/null | grep -m1 'DNS Servers' | sed 's/^ *//' || echo n/a)"
fi

# ============================================================================
# 15. Что дальше
# ============================================================================
wait_service remnanode "$NODE_PORT" || die "Итоговая проверка: нода/API недоступны"
if [ "$USE_SELFSTEAL" = yes ]; then
    wait_service selfsteal "$SELFSTEAL_PORT" || die "Итоговая проверка: Caddy недоступен"
    [ "$CERT_OK" = true ] || die "Установка неполная: доверенный HTTPS selfsteal пока не работает"
fi
hdr "Готово"
say ""
say "  ${C_BLD}1) В панели Remnawave:${C_OFF}"
say "     Nodes → Management → добавьте этот сервер"
say "       • Address: IP этого сервера"
say "       • Port: $NODE_PORT"
say "       • SECRET_KEY: тот, что вы вставили при установке"
say "     Затем «Next» → выберите Config Profile → Create."
say ""
say "  ${C_BLD}2) Готовые конфиги для Config Profile:${C_OFF}"
say "     nodego → 1 (или: nodego configs; файлы в /etc/remnawave-setup/configs/)"
if [ "$HYSTERIA" = "yes" ]; then
    say "     xHTTP, gRPC, TCP и Hysteria2 — порт $CONNECT_PORT,"
else
    say "     xHTTP, gRPC, TCP — порт $CONNECT_PORT,"
fi
say "     privateKey/shortIds/tag уже сгенерированы, при selfsteal target = 127.0.0.1:$SELFSTEAL_PORT."
if [ "$HYSTERIA" = "yes" ]; then
    say "     В hysteria2.json два инбаунда — hysteria (UDP) и xHTTP+Reality (TCP);"
    say "     xHTTP нужен для Caddy selfsteal, раздавать его клиентам не обязательно."
fi
say "     Скопируйте нужный JSON в Config Profile (или перенесите inbound'ы в один профиль),"
say "     затем Squads → Inbounds, Hosts → привязка к инбаунду."
say ""
if [ "$USE_SELFSTEAL" = "yes" ]; then
    say "  ${C_BLD}3) Selfsteal:${C_OFF}"
    say "     Reality-инбаунды смотрят target 127.0.0.1:$SELFSTEAL_PORT, serverNames = $DOMAIN."
    say "     Отдельно включать «Self-steal» в панели не нужно — это уже в конфигах."
    say "     Проверка: https://${DOMAIN:-<ваш домен>} в браузере."
    say ""
fi
if [ "$HYSTERIA" = "yes" ]; then
    say "  ${C_BLD}Hysteria2:${C_OFF}"
    say "     UDP/$CONNECT_PORT уже открыт в ufw; сертификат лежит в $NODE_DIR/cert,"
    say "     таймер rw-cert-sync.timer обновляет его после продления Caddy."
    say "     Инбаунд — в $STATE_DIR/configs/hysteria2.json:"
    say "       • hysteria (protocol: hysteria, version 2) — UDP/$CONNECT_PORT;"
    say "       • xHTTP + Reality — TCP/$CONNECT_PORT, target 127.0.0.1:${SELFSTEAL_PORT}."
    say "     xHTTP здесь нужен для Caddy selfsteal: у hysteria-инбаунда нет fallback,"
    say "     и без TCP-инбаунда сайт-заглушка снаружи не открывается. Клиентам"
    say "     включать его не обязательно — решает Squads → Inbounds."
    say "     Управление: nodego → Hysteria2 (включить/выключить, сертификат, ядро)."
    say ""
fi
if [ "$DUAL_IP" = "yes" ]; then
    say "  ${C_BLD}Вход на $IP1 / выход через $IP2:${C_OFF}"
    say "     На уровне ОС уже включён SNAT новых исходящих в $IP2"
    say "     (ответы на входящие остаются с $IP1 — соединения не рвутся)."
    say "     Чтобы закрепить это в самом Xray, в Config Profile → outbound freedom:"
    say "       \"sendThrough\": \"$IP2\""
    say "     Inbound'ы держите на $IP1 (или 0.0.0.0)."
    say ""
fi
say "  ${C_BLD}Открыть дополнительные порты:${C_OFF} nodego → 2 (порт + протокол + подпись)"
say "  ${C_BLD}Проверить сам сервер:${C_OFF}    nodego → 22 (IP, чёрные списки, бенчмарки, DPI)"
say ""
say "  ${C_BLD}Управление:${C_OFF}"
say "     nodego                       # меню: конфиги, порты, Hysteria2, сеть, бэкапы"
say "     systemctl status remnanode selfsteal"
say "     docker logs -f remnanode"
say "     docker logs -f selfsteal"
say "     cd $NODE_DIR && docker compose pull && docker compose up -d   # обновление ноды"
say ""
say "  ${C_BLD}Конфиг:${C_OFF} $ANSWERS_FILE (повторный запуск с этими ответами: --yes)"
say "  ${C_BLD}Лог:${C_OFF}    $LOG_FILE"
say ""
warn "Перезагрузка применит лимиты nofile полностью: reboot"
say ""
