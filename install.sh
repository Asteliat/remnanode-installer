#!/usr/bin/env bash
# ============================================================================
#  Remnawave Node + Caddy Selfsteal — установщик "под ключ"
# ============================================================================
#  Что делает:
#    1. ставит зависимости и Docker (официальный get.docker.com)
#    2. тюнит систему под VPN-нагрузку (swap, nofile, sysctl, BBR+FQ, NTP, DNS)
#    3. разворачивает Remnawave Node (/opt/remnanode) с вашими NODE_PORT и ключом
#    4. разворачивает Caddy Selfsteal (/opt/selfsteal) с выбранным сайтом-заглушкой
#    5. настраивает firewall: порты транспортов — всем, порт ноды — только панели
#    6. создаёт systemd-юниты автозапуска (docker compose)
#    7. проверяет результат и печатает, что осталось сделать в панели
#
#  Быстрый старт:
#    bash <(curl -Ls https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh)
#
#  Неинтерактивный режим:
#    ... install.sh --yes --panel-ip 1.2.3.4 --secret-key KEY \
#                   --xhttp-port 443 --tcp-port 4443 --grpc-port 2096 \
#                   --domain vpn.example.com --template landing
#
#  Пропуск порта = порт не открывается. Самый простой способ "выключить":
#  нажать Enter на вопросе о порте либо передать --xhttp-port "" .
#
#  Схемы с IP:
#    1 IP  — вход и выход через один адрес (обычная схема)
#    2 IP  — клиенты входят на основной IP, в интернет нода выходит через
#            дополнительный (policy routing + SNAT только для NEW-соединений,
#            чтобы не ломать ответы на входящие)
#
#  Дополнительно скрипт спрашивает:
#    * DNS-фильтрацию AdGuard (блокировка рекламы/трекеров, DoT)
#    * автообновление ноды (systemd-таймер + откат при неудаче)
# ============================================================================

set -euo pipefail

VERSION="1.0.0"

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

# ------------------------------------------------------------------ defaults
PANEL_IP="${PANEL_IP:-}"
NODE_PORT="${NODE_PORT:-2222}"
SECRET_KEY="${SECRET_KEY:-}"
XHTTP_PORT="${XHTTP_PORT:-443}"
GRPC_PORT="${GRPC_PORT:-2096}"
TCP_PORT="${TCP_PORT:-4443}"
USE_SELFSTEAL="${USE_SELFSTEAL:-yes}"
DOMAIN="${DOMAIN:-}"
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
TEMPLATE="${TEMPLATE:-landing}"

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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)          ASSUME_YES=true ;;
        --reconfigure)     : ;;   # учтён на этапе пред-сканирования аргументов
        --skip-tuning)     SKIP_TUNING=true ;;
        --skip-firewall)   SKIP_FIREWALL=true ;;
        --panel-ip)        PANEL_IP="${2:?}"; shift ;;
        --node-port)       NODE_PORT="${2:?}"; shift ;;
        --secret-key)      SECRET_KEY="${2:?}"; shift ;;
        --xhttp-port)      XHTTP_PORT="${2-}"; shift || true ;;
        --grpc-port)       GRPC_PORT="${2-}"; shift || true ;;
        --tcp-port)        TCP_PORT="${2-}"; shift || true ;;
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
        -h|--help)         grep '^#  ' "$0" | sed 's/^#  //'; exit 0 ;;
        *) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 1 ;;
    esac
    if [ $# -gt 0 ]; then shift; fi
done

# ---- нормализация булевых флагов (yes/no/true/да ...) ----------------------
norm_yn() { case "${1,,}" in yes|y|да|д|true|1|on) echo yes ;; *) echo no ;; esac; }
USE_SELFSTEAL="$(norm_yn "$USE_SELFSTEAL")"
DUAL_IP="$(norm_yn "$DUAL_IP")"
USE_DNS="$(norm_yn "$USE_DNS")"
AUTO_UPDATE="$(norm_yn "$AUTO_UPDATE")"
ALERTS="$(norm_yn "$ALERTS")"

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

is_domain() { [[ "${1:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

detect_primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
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

ask_port() { # ask_port VAR "текст" "подсказка-дефолт"
    # В интерактивном режиме пустой ввод = порт НЕ открывается (так просил заказчик).
    # Значение по умолчанию применяется только в неинтерактивном режиме (--yes).
    local __var="$1" __prompt="$2" __hint="${3:-}" __val=""
    if [ "$ASSUME_YES" = true ]; then return 0; fi
    while true; do
        if [ -n "$__hint" ]; then
            read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} [${__hint} — Enter, чтобы не открывать]: ")" __val || true
        else
            read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} (Enter — не открывать): ")" __val || true
        fi
        __val="${__val//[[:space:]]/}"
        if [ -z "$__val" ]; then printf -v "$__var" '%s' ""; return 0; fi
        if is_port "$__val"; then printf -v "$__var" '%s' "$__val"; return 0; fi
        warn "'$__val' — не порт (1-65535)."
    done
}

backup() {
    local f="$1"
    [ -e "$f" ] || return 0
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
}

fetch() { # fetch URL DEST
    local url="$1" dest="$2"
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$dest"
}

compose() { docker compose "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# ============================================================================
# 0. Preflight
# ============================================================================
say ""
say "${C_BLD}Remnawave Node + Caddy Selfsteal installer v$VERSION${C_OFF}"
say "${C_DIM}логи: $LOG_FILE${C_OFF}"
say ""

[ "$(id -u)" -eq 0 ] || die "Запускать от root: sudo bash $0"
log "=== start v$VERSION args: $* ==="

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

# --- IP панели -------------------------------------------------------------
if [ -z "$PANEL_IP" ] || ! is_ipv4 "$PANEL_IP"; then
    while true; do
        ask PANEL_IP "IP панели Remnawave (к ней будет открыт порт ноды)" "${PANEL_IP:-}"
        is_ipv4 "$PANEL_IP" && break
        warn "Некорректный IPv4: '$PANEL_IP'"
        [ "$ASSUME_YES" = true ] && die "Укажите корректный --panel-ip"
    done
fi
ok "Панель: $PANEL_IP"

# --- Порт ноды -------------------------------------------------------------
while ! is_port "$NODE_PORT"; do
    if [ "$ASSUME_YES" = true ]; then
        die "Некорректный --node-port: '$NODE_PORT' (ожидается 1-65535)"
    fi
    ask NODE_PORT "Порт ноды (внутренний API, панель → нода)" "2222"
done
ok "Порт ноды: $NODE_PORT"

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
        fi
    done
fi
[ "${#SECRET_KEY}" -ge 16 ] || warn "SECRET_KEY короче 16 символов — проверьте, что скопировали целиком."
ok "SECRET_KEY: ${SECRET_KEY:0:6}…${SECRET_KEY: -4} (${#SECRET_KEY} символов)"

# --- Порты транспортов -----------------------------------------------------
say ""
note "Укажите порты, которые будут открыты в firewall. Enter — порт не открывать."
note "Сами inbound'ы настраиваются в панели; здесь важен только firewall."
say ""

ask_port XHTTP_PORT "Порт для xHTTP" "обычно 443"
if [ -n "$XHTTP_PORT" ]; then ok "xHTTP: $XHTTP_PORT"; else note "xHTTP: не открывается"; fi
ask_port GRPC_PORT  "Порт для gRPC" "обычно 2096"
if [ -n "$GRPC_PORT" ]; then ok "gRPC:  $GRPC_PORT"; else note "gRPC: не открывается"; fi
ask_port TCP_PORT   "Порт для TCP/Vision" "обычно 4443"
if [ -n "$TCP_PORT" ]; then ok "TCP:   $TCP_PORT"; else note "TCP: не открывается"; fi

# Валидация портов, переданных флагами (в --yes промптов не было)
for _pv in XHTTP_PORT GRPC_PORT TCP_PORT; do
    _v="${!_pv:-}"
    [ -z "$_v" ] && continue
    is_port "$_v" || die "Некорректный порт в --${_pv,,}: '$_v' (ожидается 1-65535)"
done

# Предупреждения о пересечениях портов
_used=""
for _pv in XHTTP_PORT GRPC_PORT TCP_PORT; do
    _v="${!_pv:-}"
    [ -z "$_v" ] && continue
    case " $_used " in
        *" $_v "*) warn "Порт $_v указан дважды — inbound'ы в панели будут конфликтовать" ;;
    esac
    _used="$_used $_v"
done
case " $_used " in
    *" $NODE_PORT "*) warn "Транспортный порт совпадает с портом ноды ($NODE_PORT) — так нельзя" ;;
esac
unset _pv _v _used 2>/dev/null || true

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
    TEMPLATE_KEYS=(landing cloud speedtest blog 503 news forum torrent shop auth)
    TEMPLATE_DESCS=(
        "лендинг — визитка небольшой компании"
        "облако — интерфейс файлового хранилища"
        "спидтест — замер скорости соединения"
        "блог — статья с текстом"
        "503 — «сервис временно недоступен»"
        "новости — лента новостей с сайдбаром"
        "форум — темы и обсуждения"
        "торрент — таблица раздач"
        "магазин — карточки товаров"
        "вход в панель — форма логина"
    )
    for i in "${!TEMPLATE_KEYS[@]}"; do
        printf "    %d) %-10s — %s\n" "$((i+1))" "${TEMPLATE_KEYS[$i]}" "${TEMPLATE_DESCS[$i]}"
    done

    if [ "$ASSUME_YES" = false ]; then
        while true; do
            read -r -p "$(echo -e "  ${C_BLD}Выбор [1-${#TEMPLATE_KEYS[@]}]${C_OFF} [${TEMPLATE}]: ")" tsel || true
            [ -z "$tsel" ] && break
            if [[ "$tsel" =~ ^[0-9]+$ ]] && [ "$tsel" -ge 1 ] && [ "$tsel" -le "${#TEMPLATE_KEYS[@]}" ]; then
                TEMPLATE="${TEMPLATE_KEYS[$((tsel-1))]}"
                break
            fi
            warn "Введите число от 1 до ${#TEMPLATE_KEYS[@]}"
        done
    fi

    valid=false
    for k in "${TEMPLATE_KEYS[@]}"; do [ "$k" = "$TEMPLATE" ] && valid=true; done
    [ "$valid" = true ] || die "Неизвестный шаблон '$TEMPLATE'. Допустимо: ${TEMPLATE_KEYS[*]}"
    ok "Сайт-заглушка: $TEMPLATE"
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
    if [ -z "$IP1" ] || ! is_ipv4 "$IP1"; then
        IP1="$(detect_primary_ip)"
        if ! is_ipv4 "${IP1:-}"; then
            while true; do
                ask IP1 "Основной (входящий) IP этого сервера" "${IP1:-}"
                is_ipv4 "$IP1" && break
                warn "Некорректный IPv4: '$IP1'"
                [ "$ASSUME_YES" = true ] && die "Укажите корректный --ip1"
            done
        fi
    fi
    ok "Основной IP (вход): $IP1"

    if [ -z "$IP2" ] || ! is_ipv4 "$IP2"; then
        while true; do
            ask IP2 "Дополнительный IP (через него нода выходит в интернет)" "${IP2:-}"
            is_ipv4 "$IP2" && break
            warn "Некорректный IPv4: '$IP2'"
            [ "$ASSUME_YES" = true ] && die "Укажите корректный --ip2"
        done
    fi
    [ "$IP2" = "$IP1" ] && die "Дополнительный IP совпадает с основным"
    ok "Дополнительный IP (выход): $IP2"
    note "Домен selfsteal будет привязан к $IP1 (вход), выход пойдёт с $IP2."
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
say "    панель ............ $PANEL_IP"
say "    порт ноды ......... $NODE_PORT"
say "    xHTTP ............. ${XHTTP_PORT:-<не открывать>}"
say "    gRPC .............. ${GRPC_PORT:-<не открывать>}"
say "    TCP ............... ${TCP_PORT:-<не открывать>}"
if [ "$USE_SELFSTEAL" = "yes" ]; then
    say "    selfsteal ......... ${DOMAIN}:80/443 → Caddy 127.0.0.1:${SELFSTEAL_PORT} (${TEMPLATE})"
else
    say "    selfsteal ......... выключен"
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

# сохраняем ответы для повторного запуска
umask 077
cat > "$ANSWERS_FILE" <<EOF
# Сгенерировано remnawave node installer v$VERSION $(date '+%F %T')
PANEL_IP='$PANEL_IP'
NODE_PORT='$NODE_PORT'
SECRET_KEY='$SECRET_KEY'
XHTTP_PORT='$XHTTP_PORT'
GRPC_PORT='$GRPC_PORT'
TCP_PORT='$TCP_PORT'
USE_SELFSTEAL='$USE_SELFSTEAL'
DOMAIN='$DOMAIN'
SELFSTEAL_PORT='$SELFSTEAL_PORT'
TEMPLATE='$TEMPLATE'
DUAL_IP='$DUAL_IP'
IP1='$IP1'
IP2='$IP2'
USE_DNS='$USE_DNS'
AUTO_UPDATE='$AUTO_UPDATE'
ALERTS='$ALERTS'
TG_TOKEN='$TG_TOKEN'
TG_CHAT='$TG_CHAT'
EOF
chmod 600 "$ANSWERS_FILE"

# ============================================================================
# 2. Зависимости
# ============================================================================
hdr "2. Зависимости"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold || warn "apt upgrade завершился с ошибкой (продолжаем)"
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
    if [ -z "$(swapon --show=NAME --noheadings 2>/dev/null || true)" ]; then
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile || warn "swapon не сработал"
        grep -q '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap 2G создан и закреплён в /etc/fstab"
    else
        ok "Swap уже активен"
    fi

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
#   single : правила не добавляются, все прежние снимаются
set -uo pipefail

CONF=/etc/remnawave-setup/net.env
TABLE=100
log() { echo "[$(date '+%F %T')] $*"; }

[ -f "$CONF" ] || { log "нет $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# --- снимаем прежние правила этого типа (прошлый IP2 / прошлая схема) -------
while ip rule show | grep -q "lookup $TABLE"; do
    ip rule del table "$TABLE" 2>/dev/null || break
done
while read -r spec; do
    [ -n "${spec:-}" ] || continue
    # shellcheck disable=SC2086
    iptables -t nat -D POSTROUTING $spec 2>/dev/null || true
done < <(iptables -t nat -S POSTROUTING 2>/dev/null \
         | grep -- '-m conntrack --ctstate NEW -j SNAT' \
         | sed 's/^-A POSTROUTING //' || true)

if [ "${MODE:-single}" != "dual" ]; then
    log "режим single — правила сняты"
    exit 0
fi

if [ -z "${IP2:-}" ] || [ -z "${IFACE:-}" ] || [ -z "${GW:-}" ]; then
    log "в net.env не хватает IP2/IFACE/GW"
    exit 1
fi

ip addr replace "$IP2/32" dev "$IFACE"
ip rule add from "$IP2/32" table "$TABLE"
ip route replace default via "$GW" dev "$IFACE" src "$IP2" table "$TABLE"
iptables -t nat -A POSTROUTING -o "$IFACE" -m conntrack --ctstate NEW -j SNAT --to-source "$IP2"
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
    SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    SSH_PORT="${SSH_PORT:-22}"

    ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null

    if [ "$USE_SELFSTEAL" = "yes" ]; then
        ufw allow 80/tcp comment 'ACME HTTP-01 + redirect' >/dev/null
    fi

    # Транспортные порты — всем (это публичные inbound'ы)
    for p in "$XHTTP_PORT" "$GRPC_PORT" "$TCP_PORT"; do
        [ -n "$p" ] || continue
        ufw allow "$p/tcp" comment "xray inbound $p" >/dev/null
    done

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
for p in "$NODE_PORT" "$XHTTP_PORT" "$GRPC_PORT" "$TCP_PORT"; do
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
mkdir -p "$NODE_DIR" /var/log/remnanode
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
( cd "$NODE_DIR" && { compose pull -q >/dev/null 2>&1 || warn "образ не скачался — пробую локальный"; } ; compose up -d ) || warn "docker compose up вернул ошибку — смотрите: docker compose -f $NODE_DIR/docker-compose.yml logs"
systemctl daemon-reload
systemctl enable remnanode.service >/dev/null 2>&1 || true
ok "Нода запущена, автозагрузка включена (remnanode.service)"

# ============================================================================
# 9. Caddy selfsteal
# ============================================================================
if [ "$USE_SELFSTEAL" = "yes" ]; then
    hdr "9. Caddy selfsteal"
    mkdir -p "$SELFSTEAL_DIR/html" "$SELFSTEAL_DIR/logs"
    backup "$SELFSTEAL_DIR/Caddyfile"; backup "$SELFSTEAL_DIR/docker-compose.yml"

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

    # --- DNS-проверка (не блокирующая) ------------------------------------
    if command -v dig >/dev/null 2>&1; then
        SERVER_IP="$(curl -fsS4 --max-time 10 https://ifconfig.io 2>/dev/null || true)"
        A_IP="$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
        if [ -n "$A_IP" ] && [ -n "$SERVER_IP" ] && [ "$A_IP" != "$SERVER_IP" ]; then
            warn "DNS: $DOMAIN → $A_IP, а сервер $SERVER_IP. ACME-сертификат не выпустится, пока A-запись не исправлена."
            warn "Caddy продолжит работать, но HTTPS-сертификат будет внутренним."
        elif [ -n "$A_IP" ]; then
            ok "DNS: $DOMAIN → $A_IP"
        else
            warn "DNS: A-запись для $DOMAIN не найдена — сертификат Let's Encrypt не выпустится."
        fi
    fi

    note "Запускаю Caddy…"
    ( cd "$SELFSTEAL_DIR" && { compose pull -q >/dev/null 2>&1 || warn "образ не скачался — пробую локальный"; } ; compose up -d ) || warn "Caddy не стартовал — смотрите: docker compose -f $SELFSTEAL_DIR/docker-compose.yml logs"

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
    systemctl enable selfsteal.service >/dev/null 2>&1 || true
    ok "Selfsteal запущен, автозагрузка включена (selfsteal.service)"
else
    hdr "9. Caddy selfsteal"
    note "Пропущено по выбору пользователя"
fi

# ============================================================================
# 10. DNS-фильтрация (AdGuard DoT)
# ============================================================================
hdr "10. DNS"
if [ "$USE_DNS" = "yes" ]; then
    backup /etc/resolv.conf
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-adguard-dot.conf <<'EOF'
[Resolve]
DNS=94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
EOF
    # не даём глобальным DNS из основного конфига перебивать наши
    if [ -f /etc/systemd/resolved.conf ]; then
        sed -i -E 's/^[[:space:]]*(DNS|FallbackDNS)=/#\1=/' /etc/systemd/resolved.conf
    fi
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved || warn "systemd-resolved не перезапустился"
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || \
        warn "не удалось подменить /etc/resolv.conf (файл защищён провайдером?)"
    resolvectl flush-caches >/dev/null 2>&1 || true
    sleep 1
    if resolvectl query example.com >/dev/null 2>&1; then
        ok "AdGuard DoT активен, резолвинг работает"
    else
        warn "DNS не отвечает — проверьте: resolvectl status"
    fi
else
    note "Пропущено: остаётся системный DNS"
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
OLD_ID="$(docker inspect --format '{{.Image}}' remnanode 2>/dev/null || true)"

say "== pull =="
if ! docker compose pull -q >>"$LOG" 2>&1; then
    say "pull не удался — обновление пропущено"
    exit 0
fi

say "== up =="
docker compose up -d --remove-orphans >>"$LOG" 2>&1 || say "compose up вернул ошибку"

sleep 30
if [ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" != "true" ]; then
    say "контейнер не поднялся — откатываю"
    docker compose stop >>"$LOG" 2>&1 || true
    if [ -n "$OLD_ID" ]; then
        docker tag "$OLD_ID" remnawave/node:latest >>"$LOG" 2>&1 && say "восстановлен $OLD_ID"
    fi
    docker compose up -d --remove-orphans >>"$LOG" 2>&1 || true
    exit 1
fi
say "== ok =="
docker image prune -f >>"$LOG" 2>&1 || true
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
    systemctl enable --now rw-node-update.timer >/dev/null 2>&1 || warn "таймер автообновления не включился"
    ok "Нода обновляется автоматически (~04:30, лог /var/log/remnawave-update.log)"
else
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
ALERTS='$ALERTS'
TG_TOKEN='$TG_TOKEN'
TG_CHAT='$TG_CHAT'
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
# shellcheck disable=SC1090
[ -f "$CONF" ]    && . "$CONF"
# shellcheck disable=SC1090
[ -f "$ANSWERS" ] && . "$ANSWERS"
# shellcheck disable=SC1090
[ -f "$NET" ]     && . "$NET"

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
# раз в неделю — неиспользуемые образы
0 5 * * 0 root docker image prune -f >/dev/null 2>&1 || true
EOF
chmod 644 /etc/cron.d/remnawave-maintenance /etc/logrotate.d/remnanode
ok "logrotate для ноды + cron-обслуживание"

# ============================================================================
# 13. Проверка
# ============================================================================
hdr "13. Проверка"
sleep 3

say "  ${C_BLD}Контейнеры:${C_OFF}"
docker ps --format '    {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || warn "docker ps недоступен"

say ""
say "  ${C_BLD}Слушающие порты:${C_OFF}"
for p in "$NODE_PORT" "$XHTTP_PORT" "$GRPC_PORT" "$TCP_PORT" 80 443; do
    [ -n "$p" ] || continue
    if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
        say "    :$p — слушается"
    else
        note "    :$p — свободен"
    fi
done

if [ "$USE_SELFSTEAL" = "yes" ]; then
    say ""
    say "  ${C_BLD}Локальная проверка selfsteal:${C_OFF}"
    if curl -fsSk --max-time 5 -H "Host: $DOMAIN" "https://127.0.0.1:$SELFSTEAL_PORT/" -o /dev/null; then
        ok "Caddy отвечает по https://127.0.0.1:$SELFSTEAL_PORT"
    else
        warn "Caddy пока не отвечает (первый запуск + выпуск сертификата может занять до минуты)"
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
# 14. Что дальше
# ============================================================================
hdr "Готово"
say ""
say "  ${C_BLD}1) В панели Remnawave:${C_OFF}"
say "     Nodes → Management → добавьте этот сервер"
say "       • Address: IP этого сервера"
say "       • Port: $NODE_PORT"
say "       • SECRET_KEY: тот, что вы вставили при установке"
say "     Затем «Next» → выберите Config Profile → Create."
say ""
if [ "$USE_SELFSTEAL" = "yes" ]; then
    say "  ${C_BLD}2) Для selfsteal в панели:${C_OFF}"
    say "     В inbound'ах xHTTP/gRPC включите Self-steal и укажите:"
    say "       • dest: 127.0.0.1:$SELFSTEAL_PORT"
    say "       • domain: $DOMAIN"
    say "     Reality/xHTTP будут отдавать этот домен при обычном обращении."
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
say "  ${C_BLD}3) Откройте в браузере:${C_OFF} https://${DOMAIN:-<ваш домен>}"
say ""
say "  ${C_BLD}Управление:${C_OFF}"
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
