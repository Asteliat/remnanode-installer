#!/usr/bin/env bash
# ============================================================================
#  nodego — меню управления Remnawave Node + Caddy selfsteal
# ============================================================================
#  Установка: ставится автоматически установщиком в /usr/local/bin/nodego
#
#  Запуск:            nodego
#  Без меню:          nodego status | logs | restart | update | net | preset <имя>
#                     nodego configs [xhttp|grpc|tcp|hysteria2] | keys
#                     nodego ports | nodego hysteria [status|on|off|cert|core|test]
#                     nodego swap [auto|1G|2G]
#                     nodego check [ip|region|bench-ru|bench|yabs|dpi|cpu|quick]
# ============================================================================

set -uo pipefail

REPO_OWNER="Asteliat"
REPO_NAME="remnanode-installer"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
TEMPLATES_BASE="${RAW_BASE}/templates"

STATE_DIR="/etc/remnawave-setup"
ANSWERS="$STATE_DIR/answers.env"
NET_ENV="$STATE_DIR/net.env"
ALERTS_ENV="$STATE_DIR/alerts.env"
CONFIGS_DIR="$STATE_DIR/configs"
NODE_DIR="/opt/remnanode"
SELFSTEAL_DIR="/opt/selfsteal"
CADDYFILE="$SELFSTEAL_DIR/Caddyfile"
UPDATE_LOG="/var/log/remnawave-update.log"
CONFIGS_BIN="/usr/local/sbin/rw-configs.sh"
CERT_SYNC="/usr/local/sbin/rw-cert-sync.sh"
HY_CERT="$NODE_DIR/cert"

TEMPLATE_KEYS=()
TEMPLATE_DESCS=()
NODEGO_CLI=false

load_templates() { # список сайтов из templates/manifest.tsv
    TEMPLATE_KEYS=()
    TEMPLATE_DESCS=()
    local tmp k d
    tmp="$(mktemp)"
    if curl -fsSL --max-time 15 "$TEMPLATES_BASE/manifest.tsv" -o "$tmp" 2>/dev/null; then
        while IFS='|' read -r k d; do
            k="${k%$'\r'}"
            [ -z "$k" ] && continue
            case "$k" in \#*) continue ;; esac
            TEMPLATE_KEYS+=("$k")
            TEMPLATE_DESCS+=("${d:-$k}")
        done < "$tmp"
    fi
    rm -f "$tmp"
    if [ "${#TEMPLATE_KEYS[@]}" -eq 0 ]; then
        warn "не удалось получить список шаблонов (нет сети?)"
        TEMPLATE_KEYS=(shop)
        TEMPLATE_DESCS=("магазин керамики — каталог, фильтры, корзина")
    fi
}

if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[0;37m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

say()  { echo -e "$*"; }
ok()   { say "  ${C_GRN}[ok]${C_OFF} $*"; }
warn() { say "  ${C_YEL}[!!]${C_OFF} $*"; }
err()  { say "  ${C_RED}[xx]${C_OFF} $*"; }
dim()  { say "  ${C_DIM}$*${C_OFF}"; }
note() { dim "$*"; }
hdr()  { echo; say "${C_BLU}▌ $*${C_OFF}"; }

pause() {
    # Пауза не должна превращать ошибку предыдущей команды в успех.
    local rc=$?
    [ "$NODEGO_CLI" = true ] && return "$rc"
    read -r -p "$(echo -e "${C_DIM}Enter — продолжить…${C_OFF}")" _ || true
    return "$rc"
}

ask() { # ask VAR "текст" "дефолт"
    local __var="$1" __prompt="$2" __def="${3:-}" __val=""
    if [ -n "$__def" ]; then
        read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} [${__def}]: ")" __val || true
        [ -z "$__val" ] && __val="$__def"
    else
        read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF}: ")" __val || true
    fi
    printf -v "$__var" '%s' "$__val"
}

confirm() { # confirm "текст" [y|n]
    local __prompt="$1" __def="${2:-y}" __val="" __hint
    if [ "$__def" = "y" ]; then __hint="Д/н"; else __hint="д/Н"; fi
    read -r -p "$(echo -e "${C_BLD}${__prompt}${C_OFF} [${__hint}]: ")" __val || true
    case "${__val:-$__def}" in
        y|Y|yes|д|Д|да|Да) return 0 ;;
        *) return 1 ;;
    esac
}

is_ipv4() {
    local ip="${1%/*}" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    local x
    for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done
    return 0
}

is_host_ipv4() { # строгий адрес хоста: без маски, ведущих нулей и служебных адресов
    # is_ipv4() выше допускает маску (это нужно ufw) — для IP2 нужен именно хост:
    # rw-secondary-ip делает ip addr add "$IP2/32", поэтому «1.2.3.4/24» и 0.0.0.0 ломают юнит.
    local ip="${1:-}" o x
    [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    IFS='.' read -r -a o <<< "$ip"
    for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done
    case "$ip" in
        0.0.0.0|255.255.255.255) return 1 ;;
    esac
    return 0
}

is_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

node_xray_version() {
    local v=""
    v="$(docker exec remnanode sh -c 'xray version 2>/dev/null || /usr/local/bin/xray version 2>/dev/null' 2>/dev/null | head -n1)"
    [ -n "$v" ] || v="нода не запущена"
    printf '%s\n' "$v"
}

have_configs() { [ -x "$CONFIGS_BIN" ]; }

configs_count() {
    local n=0 f=""
    for f in "$CONFIGS_DIR"/*.json; do
        [ -f "$f" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

cfg_run() { # cfg_run <параметры rw-configs.sh>
    if ! have_configs; then
        err "генератор конфигов не найден ($CONFIGS_BIN) — запустите установщик ещё раз"
        return 1
    fi
    "$CONFIGS_BIN" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Запускайте от root: sudo nodego"
        exit 1
    fi
}

# ------------------------------------------------------------------ состояние
load_conf() {
    MODE="single"; IP1=""; IP2=""; IFACE=""; GW=""; BIND_IP="0.0.0.0"
    PANEL_IP=""; NODE_PORT=""; USE_SELFSTEAL=""; DOMAIN=""; SELFSTEAL_PORT="9443"
    TEMPLATE=""; USE_DNS=""; AUTO_UPDATE=""
    CONNECT_PORT=""; HYSTERIA="no"
    XHTTP_PORT=""; GRPC_PORT=""; TCP_PORT=""
    ALERTS="no"; TG_TOKEN=""; TG_CHAT=""
    # shellcheck disable=SC1090
    [ -f "$ANSWERS" ] && . "$ANSWERS"
    # shellcheck disable=SC1090
    [ -f "$NET_ENV" ] && . "$NET_ENV"
    # shellcheck disable=SC1090
    [ -f "$ALERTS_ENV" ] && . "$ALERTS_ENV"
    # В net.env мог остаться мусор от ручной правки или прежней версии;
    # кривой IP2 роняет rw-secondary-ip (ip addr add "$IP2/32") тихо, с exit 0.
    if [ -n "${IP2:-}" ] && ! is_host_ipv4 "$IP2"; then
        warn "в net.env некорректный IP2 ($IP2) — схема «два IP» отключена"
        IP2=""
        MODE="single"
    fi
    if [ -z "${CONNECT_PORT:-}" ]; then
        for _p in "${XHTTP_PORT:-}" "${GRPC_PORT:-}" "${TCP_PORT:-}"; do
            if [ -n "$_p" ]; then CONNECT_PORT="$_p"; break; fi
        done
        unset _p 2>/dev/null || true
    fi
    CONNECT_PORT="${CONNECT_PORT:-443}"
    HYSTERIA="${HYSTERIA:-no}"
    SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
    [ -n "${IP1:-}" ] || IP1="$(primary_ip)"
}

primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true
}

iface_for_ip() { # iface_for_ip <ip>
    ip -o -4 addr show 2>/dev/null \
        | awk -v ip="$1" 'index($4, ip "/")==1 {print $2; exit}' || true
}

default_iface() { ip -o route show default 2>/dev/null | awk '{print $5; exit}' || true; }
default_gw()    { ip -o route show default 2>/dev/null | awk '{print $3; exit}' || true; }

node_running()  { [ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo false)" = "true" ]; }
caddy_running() { [ "$(docker inspect -f '{{.State.Running}}' selfsteal 2>/dev/null || echo false)" = "true" ]; }

write_net_env() {
    mkdir -p "$STATE_DIR"
    cat > "$NET_ENV" <<EOF
# Схема сети Remnawave Node (меняется через nodego или повторной установкой)
MODE=$MODE
IP1=$IP1
IP2=$IP2
IFACE=$IFACE
GW=$GW
BIND_IP=$BIND_IP
EOF
    chmod 600 "$NET_ENV"
}

sync_answers() { # держим answers.env согласованным с net.env
    [ -f "$ANSWERS" ] || return 0
    sed -i -E "s|^DUAL_IP=.*|DUAL_IP='$([ "$MODE" = dual ] && echo yes || echo no)'|" "$ANSWERS"
    sed -i -E "s|^IP1=.*|IP1='$IP1'|" "$ANSWERS"
    sed -i -E "s|^IP2=.*|IP2='$IP2'|" "$ANSWERS"
}

env_quote() { # env_quote <значение> — безопасно записать в answers.env/alerts.env (потом source)
    local val="${1-}"
    case "$val" in
        # Перевод строки в одинарных кавычках не экранируется — для таких значений
        # берём printf %q: "$'a\nb'" bash прочитает обратно тем же значением.
        *$'\n'*|*$'\r'*) printf '%q' "$val"; return 0 ;;
    esac
    printf "'%s'" "${val//\'/\'\\\'\'}"
}

sed_repl() { # sed_repl <текст> — экранировать для правой части s|...|...| (| & \)
    local out="${1//\\/\\\\}"
    out="${out//&/\\&}"
    out="${out//|/\\|}"
    printf '%s' "$out"
}

set_answer() { # set_answer KEY VALUE — значение переживает source, кавычка не рвёт файл
    local key="$1" val="${2-}" quoted="" repl=""
    [ -f "$ANSWERS" ] || return 0
    quoted="$(env_quote "$val")" || return 1
    repl="$(sed_repl "$quoted")" || return 1
    if grep -q "^${key}=" "$ANSWERS"; then
        sed -i -E "s|^${key}=.*|${key}=${repl}|" "$ANSWERS" || return 1
    else
        printf '%s=%s\n' "$key" "$quoted" >> "$ANSWERS" || return 1
    fi
}

patch_caddy_bind() {
    [ -f "$CADDYFILE" ] || return 0
    sed -i -E "s|^([[:space:]]*)bind .*|\1bind ${BIND_IP:-0.0.0.0}|" "$CADDYFILE" || true
}

apply_net() {
    write_net_env
    patch_caddy_bind
    if systemctl restart rw-secondary-ip.service 2>/dev/null; then
        ok "правила применены (rw-secondary-ip)"
    else
        warn "не удалось перезапустить rw-secondary-ip — journalctl -u rw-secondary-ip"
    fi
    if [ "$USE_SELFSTEAL" = "yes" ] && [ -f "$SELFSTEAL_DIR/docker-compose.yml" ]; then
        if docker restart selfsteal >/dev/null 2>&1; then
            ok "Caddy перезапущен"
        fi
    fi
    sync_answers
    outbound_check
}

outbound_check() {
    local ip=""
    if [ "$MODE" = "dual" ] && [ -n "${IP2:-}" ]; then
        ip="$(curl -4 -fsS --max-time 10 --interface "$IP2" https://ifconfig.io 2>/dev/null || true)"
    else
        ip="$(curl -4 -fsS --max-time 10 https://ifconfig.io 2>/dev/null || true)"
    fi
    if [ -n "$ip" ]; then
        say "  исходящий IP: ${C_BLD}${ip}${C_OFF}"
    else
        dim "  исходящий IP: не удалось определить"
    fi
}

# ------------------------------------------------------------------- действия
show_status() {
    hdr "Статус"
    say "  ${C_BLD}Контейнеры:${C_OFF}"
    docker ps -a --format '    {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null \
        || dim "    docker недоступен"

    say ""
    say "  ${C_BLD}Службы:${C_OFF}"
    local u
    for u in remnanode selfsteal rw-secondary-ip; do
        if systemctl cat "$u.service" >/dev/null 2>&1; then
            say "    ${u}: $(systemctl is-enabled "$u.service" 2>/dev/null || echo -) / $(systemctl is-active "$u.service" 2>/dev/null || echo -)"
        fi
    done

    if systemctl cat rw-node-update.timer >/dev/null 2>&1; then
        say "    автообновление: $(systemctl is-active rw-node-update.timer 2>/dev/null || echo -)"
        systemctl list-timers rw-node-update.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /' || true
    fi

    say ""
    say "  ${C_BLD}Сеть:${C_OFF}"
    say "    схема:         $([ "$MODE" = dual ] && echo "2 IP (вход $IP1 → выход $IP2)" || echo "1 IP ($IP1)")"
    say "    интерфейс:     ${IFACE:-?}, шлюз: ${GW:-?}"
    say "    bind для Caddy: ${BIND_IP:-0.0.0.0}"
    outbound_check

    say ""
    say "  ${C_BLD}Ресурсы:${C_OFF}"
    say "    RAM:  $(free -h | awk '/^Mem:/{print $2" всего, "$7" доступно"}')"
    say "    swap: $(free -h | awk '/^Swap:/{print $2" всего, "$3" занято"}')"
    say "    диск: $(df -h / | awk 'NR==2{print $5" занято, "$4" свободно"}')"

    say ""
    say "  ${C_BLD}Порты:${C_OFF}"
    say "    панель: ${PANEL_IP:-—}   порт ноды: ${NODE_PORT:-—} (только с IP панели)"
    if [ "$USE_SELFSTEAL" = "yes" ]; then
        say "    selfsteal: ${DOMAIN:-—} (80/443 → 127.0.0.1:${SELFSTEAL_PORT:-9443}), шаблон: ${TEMPLATE:-shop}"
    else
        say "    selfsteal: выключен"
    fi
    say "    подключение: порт ${CONNECT_PORT:-—}/tcp — xHTTP, gRPC, TCP"
    if [ "$HYSTERIA" = "yes" ]; then
        if ss -ulnH "sport = :${CONNECT_PORT:-443}" 2>/dev/null | grep -q .; then
            say "    Hysteria2: UDP/${CONNECT_PORT} — слушается"
        else
            say "    Hysteria2: UDP/${CONNECT_PORT} открыт в ufw, но инбаунда в профиле панели нет"
        fi
    else
        say "    Hysteria2: выключена (nodego → 3)"
    fi
    say "    готовые конфиги: $(configs_count) шт. в $CONFIGS_DIR"
    say "    ядро ноды: $(node_xray_version)"
    say "    DNS-фильтр: ${USE_DNS:-no}   автообновление: ${AUTO_UPDATE:-no}"
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':(80|'"${NODE_PORT:-2222}"'|'"${CONNECT_PORT:-443}"')$' \
        | sort -u | sed 's/^/    слушается /' || true
}

logs_node() {
    hdr "Логи ноды (Ctrl+C — выход)"
    local rc=0
    docker logs --tail 80 -f remnanode 2>&1 || rc=$?
    # 130/143 — штатное прерывание по Ctrl+C, а не «контейнер не найден».
    case "$rc" in
        0|130|143) : ;;
        *) warn "docker logs завершился с кодом $rc — контейнер remnanode не найден?" ;;
    esac
    pause
}

logs_caddy() {
    hdr "Логи selfsteal (Ctrl+C — выход)"
    local rc=0
    docker logs --tail 80 -f selfsteal 2>&1 || rc=$?
    case "$rc" in
        0|130|143) : ;;
        *) warn "docker logs завершился с кодом $rc — контейнер selfsteal не найден?" ;;
    esac
    pause
}

logs_update() {
    hdr "Лог автообновления"
    if [ -f "$UPDATE_LOG" ]; then
        tail -n 60 "$UPDATE_LOG"
    else
        dim "лог ещё пуст: $UPDATE_LOG"
    fi
    pause
}

restart_node() {
    hdr "Перезапуск ноды"
    if [ ! -f "$NODE_DIR/docker-compose.yml" ]; then
        err "не найден $NODE_DIR/docker-compose.yml"
        pause; return 1
    fi
    ( cd "$NODE_DIR" && docker compose restart ) 2>&1 | sed 's/^/  /' || { pause; return 1; }
    sleep 3
    if ! node_running; then err "нода не поднялась — смотрите логи"; pause; return 1; fi
    ok "нода работает"
    pause
}

restart_caddy() {
    hdr "Перезапуск selfsteal"
    if [ ! -f "$SELFSTEAL_DIR/docker-compose.yml" ]; then
        err "selfsteal не установлен"
        pause; return 1
    fi
    ( cd "$SELFSTEAL_DIR" && docker compose restart ) 2>&1 | sed 's/^/  /' || { pause; return 1; }
    sleep 2
    if ! caddy_running; then err "Caddy не поднялся — смотрите логи"; pause; return 1; fi
    ok "Caddy работает"
    pause
}

restart_all() {
    hdr "Перезапуск всего"
    local rc=0
    restart_node || rc=$?
    if [ "$USE_SELFSTEAL" = "yes" ]; then restart_caddy || rc=$?; fi
    return "$rc"
}

update_now() {
    hdr "Обновление ноды"
    if [ ! -x /usr/local/sbin/rw-node-update.sh ]; then
        err "скрипт обновления не найден"
        pause; return 1
    fi
    dim "запускаю /usr/local/sbin/rw-node-update.sh (с откатом при сбое)…"
    local rc=0
    /usr/local/sbin/rw-node-update.sh 2>&1 | sed 's/^/  /' || rc=$?
    [ -f "$UPDATE_LOG" ] && { say ""; dim "последние строки лога:"; tail -n 10 "$UPDATE_LOG" | sed 's/^/  /'; }
    pause
    return "$rc"
}

change_preset() {
    hdr "Сайт-заглушка"
    if [ ! -d "$SELFSTEAL_DIR" ]; then
        err "selfsteal не установлен"
        pause; return
    fi
    load_templates
    local i choice key tmp cur
    say "  ${C_BLD}Доступные сайты (введите номер):${C_OFF}"
    for i in "${!TEMPLATE_KEYS[@]}"; do
        cur=""
        [ "${TEMPLATE_KEYS[$i]}" = "${TEMPLATE:-}" ] && cur=" ${C_DIM}← стоит сейчас${C_OFF}"
        printf "    %2d) %-12s — %s%s\n" "$((i+1))" "${TEMPLATE_KEYS[$i]}" "${TEMPLATE_DESCS[$i]}" "$cur"
    done
    say ""
    read -r -p "$(echo -e "${C_BLD}Выбор [1-${#TEMPLATE_KEYS[@]}, Enter — отмена]${C_OFF}: ")" choice || true
    [ -z "$choice" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        warn "неверный номер"
        pause; return
    fi
    choice=$((10#$choice))   # 010 — это десятый пункт, а не восьмой (bash читает ведущий 0 как восьмеричное)
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#TEMPLATE_KEYS[@]}" ]; then
        warn "неверный номер"
        pause; return
    fi
    key="${TEMPLATE_KEYS[$((choice-1))]}"
    if ! [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "недопустимое имя шаблона: '$key'"
        pause; return 1
    fi

    tmp="$(mktemp)"
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 30 "$TEMPLATES_BASE/$key/index.html" -o "$tmp"; then
        if ! mkdir -p "$SELFSTEAL_DIR/html" || ! cp "$tmp" "$SELFSTEAL_DIR/html/index.html"; then
            rm -f "$tmp"
            err "шаблон «$key» не записан в $SELFSTEAL_DIR/html"
            pause; return 1
        fi
        rm -f "$tmp"
        if ! set_answer TEMPLATE "$key"; then
            err "шаблон «$key» записан, но ключ TEMPLATE не сохранён — проверьте $ANSWERS"
            pause; return 1
        fi
        TEMPLATE="$key"
        ok "шаблон «$key» установлен (текущий: $TEMPLATE)"
        if confirm "перезапустить Caddy, чтобы применить?" "y"; then
            if docker restart selfsteal >/dev/null 2>&1; then
                ok "Caddy перезапущен"
            else
                warn "Caddy не перезапустился"
            fi
        fi
    else
        rm -f "$tmp"
        err "не удалось скачать шаблон «$key» (нет сети?)"
    fi
    pause
}

net_show() {
    hdr "Схема сети"
    say "  режим:          $MODE"
    say "  вход (IP1):     ${IP1:-—}"
    say "  выход (IP2):    ${IP2:-—}"
    say "  интерфейс:      ${IFACE:-—}"
    say "  шлюз:           ${GW:-—}"
    say "  bind Caddy:     ${BIND_IP:-0.0.0.0}"
    say ""
    dim "iptables POSTROUTING:"
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -v '^-N' | sed 's/^/  /' || true
    say ""
    dim "policy rules:"
    ip rule show 2>/dev/null | sed 's/^/  /' || true
}

net_dual_enable() {
    hdr "Схема: вход и выход через разные IP"
    local want
    [ -n "${IP1:-}" ] || IP1="$(primary_ip)"
    say "  вход будет с: ${C_BLD}${IP1:-?}${C_OFF}"
    ask want "Дополнительный (выходной) IP" "${IP2:-}"
    want="${want//[[:space:]]/}"
    if ! is_host_ipv4 "$want"; then
        err "нужен адрес хоста без маски и порта (например 192.0.2.10); 0.0.0.0 и 255.255.255.255 не подходят"
        pause; return 1
    fi
    if [ "$want" = "$IP1" ]; then err "выходной IP совпадает с основным"; pause; return 1; fi

    IP2="$want"
    MODE="dual"
    IFACE="$(iface_for_ip "$IP1")"
    [ -n "$IFACE" ] || IFACE="$(default_iface)"
    GW="$(default_gw)"
    BIND_IP="$IP1"
    apply_net
    pause
}

net_single() {
    hdr "Схема: один IP"
    if ! confirm "вернуть схему «вход и выход через один IP»?" "n"; then return; fi
    MODE="single"
    IP2=""
    BIND_IP="0.0.0.0"
    apply_net
    pause
}

net_swap() {
    hdr "Поменять вход и выход местами"
    if [ -z "${IP2:-}" ]; then
        err "сейчас схема с одним IP — сначала включите режим «два IP»"
        pause; return
    fi
    say "  было: вход ${IP1} → выход ${IP2}"
    say "  станет: вход ${IP2} → выход ${IP1}"
    if ! confirm "применить?" "n"; then return; fi
    local t="$IP1"; IP1="$IP2"; IP2="$t"
    MODE="dual"
    IFACE="$(iface_for_ip "$IP1")"
    [ -n "$IFACE" ] || IFACE="$(default_iface)"
    GW="$(default_gw)"
    BIND_IP="$IP1"
    apply_net
    pause
}

menu_net() {
    while true; do
        hdr "Сеть"
        say "  ${C_BLD}1)${C_OFF} показать текущую схему"
        say "  ${C_BLD}2)${C_OFF} один IP (вход и выход через один адрес)"
        say "  ${C_BLD}3)${C_OFF} два IP (вход на основной, выход через дополнительный)"
        say "  ${C_BLD}4)${C_OFF} поменять вход и выход местами"
        say "  ${C_BLD}0)${C_OFF} назад"
        say ""
        local c
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "$c" in
            1) net_show; pause ;;
            2) net_single ;;
            3) net_dual_enable ;;
            4) net_swap ;;
            0|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

toggle_autoupdate() {
    hdr "Автообновление ноды"
    if ! systemctl cat rw-node-update.timer >/dev/null 2>&1; then
        err "таймер не установлен"
        pause; return 1
    fi
    if systemctl is-enabled rw-node-update.timer >/dev/null 2>&1; then
        if confirm "сейчас включено. выключить?" "n"; then
            systemctl disable --now rw-node-update.timer >/dev/null 2>&1 || { err "таймер не выключен"; pause; return 1; }
            set_answer AUTO_UPDATE "no" || return 1
            ok "автообновление выключено"
        fi
    else
        if confirm "сейчас выключено. включить (ежедневно ~04:30)?" "y"; then
            systemctl enable --now rw-node-update.timer >/dev/null 2>&1 || { err "таймер не включён"; pause; return 1; }
            set_answer AUTO_UPDATE "yes" || return 1
            ok "автообновление включено"
        fi
    fi
    pause
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

toggle_dns() {
    hdr "DNS-фильтр AdGuard"
    local rc=0
    if [ -e "$(dns_path adguard.conf)" ] || [ -d "$STATE_DIR/dns-backup" ]; then
        if confirm "выключить и восстановить исходный DNS?" "n"; then dns_change off || rc=$?; fi
    else
        if confirm "включить блокировку рекламы через AdGuard DoT?" "y"; then dns_change on || rc=$?; fi
    fi
    pause
    return "$rc"
}

doctor() {
    hdr "Диагностика"
    local rc=0
    if [ -x /usr/local/sbin/rw-healthcheck.sh ]; then
        /usr/local/sbin/rw-healthcheck.sh --report 2>&1 | sed 's/^/  /'
        rc=${PIPESTATUS[0]}   # pause и sed вернули бы свой статус, а не статус healthcheck
    else
        warn "healthcheck-скрипт не найден (/usr/local/sbin/rw-healthcheck.sh)"
    fi
    say ""
    dim "последние события docker за сутки:"
    docker events --since 24h --until 0s --filter 'event=restart' \
        --format '  {{.Time}} {{.Actor.Attributes.name}} restart' 2>/dev/null | tail -5 || true
    if [ "$rc" -ne 0 ]; then
        err "healthcheck завершился с кодом $rc — отчёт может быть неполным"
    fi
    pause
    return "$rc"
}

# ============================================================================
#  Проверка сервера: сторонние скрипты (IP, чёрные списки, бенчмарки, DPI)
# ============================================================================
#  Скрипты чужие: запускаются от root, ходят в интернет и доставляют себе
#  пакеты — всё, что они поставят, остаётся в системе. Бенчмарки занимают
#  канал и CPU, поэтому на боевой ноде их лучше запускать в окно низкой
#  нагрузки. URL всегда печатается перед запуском: не доверяете — не жмите.


ensure_pkgs() { # ensure_pkgs <пакет>... — доставить через apt, если чего-то нет
    local -a miss=()
    local p
    for p in "$@"; do
        have "$p" || miss+=("$p")
    done
    if [ "${#miss[@]}" -eq 0 ]; then
        return 0
    fi
    if ! have apt-get; then
        warn "нет apt-get — поставьте вручную: ${miss[*]}"
        return 1
    fi
    say "  ${C_DIM}доставляю: ${miss[*]}${C_OFF}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" >/dev/null 2>&1; then
        err "не удалось поставить: ${miss[*]}"
        return 1
    fi
    for p in "${miss[@]}"; do
        if ! have "$p"; then
            err "после установки не найден: $p"
            return 1
        fi
    done
    ok "зависимости на месте"
}

check_dl() { # check_dl <url> <файл> — скачать и проверить, что это скрипт, а не HTML
    if have wget; then
        wget -q --timeout=40 --tries=2 -O "$2" "$1" 2>/dev/null || return 1
    else
        # часть сайтов (например bench.gig.ovh) отдаёт скрипт только на UA wget
        curl -fsSL --max-time 40 -A 'Wget/1.21.4' -o "$2" "$1" 2>/dev/null || return 1
    fi
    if [ ! -s "$2" ]; then
        return 1
    fi
    if ! head -c 512 "$2" | grep -qiE '(^#!)|bash'; then
        err "по ссылке пришёл не скрипт — не запускаю"
        return 1
    fi
    return 0
}

check_run() ( # Изолированная оболочка: ловушки не меняют меню.
    local url="$1" work="" f="" rc=0
    shift
    ensure_pkgs curl wget || return 1
    umask 077
    work="$(mktemp -d /tmp/nodego-checks.XXXXXXXXXX)" || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    f="$work/check.sh"
    dim "источник: $url"
    if ! check_dl "$url" "$f"; then
        rm -f "$f"
        err "не скачалось: $url"
        return 1
    fi
    dim "скачано $(du -h "$f" 2>/dev/null | cut -f1), запускаю…"
    say ""
    ( cd "$work" && bash "$f" "$@" ) || rc=$?
    say ""
    if [ "$rc" -eq 0 ]; then
        ok "проверка завершена (временные файлы удаляются)"
    else
        warn "скрипт вышел с кодом $rc — проверка не завершилась успешно"
    fi
    return "$rc"
)

check_head() { # check_head <заголовок> <что смотрим> <время>
    hdr "$1"
    say "  ${C_DIM}что смотрим:${C_OFF} $2"
    say "  ${C_DIM}время:${C_OFF}       $3"
    say ""
}

check_ip() {
    check_head "IP: блокировки и чёрные списки" \
        "доступность зарубежных сервисов с этого IP, чёрные списки, тип адреса (resi/hosting)" "1–3 мин"
    check_run "https://IP.Check.Place" -l en
    pause
}

check_region() {
    check_head "Регион IP" \
        "какая страна и провайдер числятся за IP в базах регистрации" "10–20 c"
    check_run "https://ipregion.xyz"
    pause
}

check_bench_ru() {
    check_head "Бенчмарк: RU-точки" \
        "скорость до российских городов, диск, CPU (резервный источник — bench.tlab.pw)" "1–2 мин"
    check_run "https://bench.gig.ovh" || check_run "https://bench.tlab.pw"
    pause
}

check_bench_world() {
    check_head "Бенчмарк: зарубежные точки" \
        "скорость до европейских и азиатских точек, диск, CPU (резерв — speed.tlab.pw)" "1–2 мин"
    check_run "https://bench.sh" || check_run "https://speed.tlab.pw"
    pause
}

check_yabs() {
    check_head "YABS: диск, iperf3, GeekBench" \
        "скорость диска, реальный канал (iperf3), CPU-скор GeekBench — по нему видно steal" "10–20 мин"
    warn "iperf3 расходует трафик, GeekBench грузит CPU: на боевой ноде лучше в окно низкой нагрузки"
    say ""
    if [ "$NODEGO_CLI" = true ] || confirm "запустить YABS?" "n"; then
        check_run "https://yabs.sh" -4
    fi
    pause
}

check_instagram() {
    check_head "Instagram: блокировка аудио" \
        "отдаёт ли Instagram музыку и аудио с этого IP" "~1 мин"
    check_run "https://bench.openode.xyz/checker_inst.sh"
    pause
}

check_dpi() {
    check_head "CensorCheck: DPI-фильтрация" \
        "режет ли провайдер трафик к заблокированным в РФ ресурсам" "~2 мин"
    warn "смысл есть только для ноды или канала в РФ: с зарубежного сервера тест покажет «всё доступно»"
    say ""
    check_run "https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh" --mode dpi
    pause
}

sysbench_cpu() {
    if ! ensure_pkgs sysbench; then
        return 1
    fi
    local rc=0
    sysbench cpu run --threads=1 2>&1 | sed 's/^/  /' || rc=$?
    say ""
    dim "сравнивайте с другой нодой того же класса: заметно ниже — проверяйте steal (top, mpstat)"
    return "$rc"
}

check_cpu() {
    check_head "CPU: sysbench, один поток" \
        "события в секунду в один поток; низкое или скачущее значение — признак steal" "~15 c"
    sysbench_cpu
    pause
}

check_quick() {
    check_head "Быстрый набор" \
        "исходящий IP, регион по IP и CPU в один поток — без тяжёлых бенчмарков" "~40 c"
    local rc=0
    outbound_check || rc=$?
    say ""
    check_run "https://ipregion.xyz" || rc=$?
    say ""
    sysbench_cpu || rc=$?
    pause
    return "$rc"
}

menu_checks() {
    local c=""
    while true; do
        hdr "Проверка сервера"
        dim "скрипты сторонние: запуск от root, доставка пакетов, выход в интернет"
        say ""
        say "  ${C_BLD}1)${C_OFF} IP: блокировки и чёрные списки       ${C_DIM}~1–3 мин${C_OFF}"
        say "  ${C_BLD}2)${C_OFF} Регион IP                            ${C_DIM}~15 c${C_OFF}"
        say "  ${C_BLD}3)${C_OFF} Бенчмарк: RU-точки                   ${C_DIM}~1–2 мин${C_OFF}"
        say "  ${C_BLD}4)${C_OFF} Бенчмарк: зарубежные точки           ${C_DIM}~1–2 мин${C_OFF}"
        say "  ${C_BLD}5)${C_OFF} YABS: диск, iperf3, GeekBench        ${C_DIM}~10–20 мин${C_OFF}"
        say "  ${C_BLD}6)${C_OFF} Instagram: блокировка аудио          ${C_DIM}~1 мин${C_OFF}"
        say "  ${C_BLD}7)${C_OFF} CensorCheck: DPI (нужна нода в РФ)   ${C_DIM}~2 мин${C_OFF}"
        say "  ${C_BLD}8)${C_OFF} CPU: sysbench, один поток            ${C_DIM}~15 c${C_OFF}"
        say "  ${C_BLD}9)${C_OFF} Быстрый набор: IP + регион + CPU     ${C_DIM}~40 c${C_OFF}"
        say "  ${C_BLD}0)${C_OFF} Назад"
        say ""
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "${c:-}" in
            1) check_ip ;;
            2) check_region ;;
            3) check_bench_ru ;;
            4) check_bench_world ;;
            5) check_yabs ;;
            6) check_instagram ;;
            7) check_dpi ;;
            8) check_cpu ;;
            9) check_quick ;;
            0|q|Q|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

cli_check() { # nodego check <имя> — то же без меню
    case "${1:-menu}" in
        ip|ipcheck)   check_ip ;;
        region|geoip) check_region ;;
        bench-ru|ru)  check_bench_ru ;;
        bench|world)  check_bench_world ;;
        yabs)         check_yabs ;;
        instagram|ig) check_instagram ;;
        dpi|censor)   check_dpi ;;
        cpu|sysbench) check_cpu ;;
        quick)        check_quick ;;
        menu|"")      menu_checks ;;
        *)
            err "неизвестная проверка: $1"
            say "  ip | region | bench-ru | bench | yabs | instagram | dpi | cpu | quick"
            exit 1
            ;;
    esac
}

backup_now() {
    hdr "Бэкап конфигов"
    if [ ! -x /usr/local/sbin/rw-backup.sh ]; then
        err "скрипт бэкапа не найден"
        pause; return 1
    fi
    local f
    f="$(/usr/local/sbin/rw-backup.sh create 2>&1)" || { err "бэкап не создался"; pause; return 1; }
    if [ -s "${f%%$'\n'*}" ] 2>/dev/null; then
        ok "создан: $f"
        say "  размер: $(du -h "$f" 2>/dev/null | cut -f1)"
    else
        warn "бэкап не создался"
        pause; return 1
    fi
    say ""
    dim "последние бэкапы:"
    /usr/local/sbin/rw-backup.sh list 2>/dev/null | head -5 | sed 's/^/  /'
    pause
}

restore_menu() {
    hdr "Восстановление из бэкапа"
    local dir="/var/backups/remnanode"
    local -a files=()
    local i choice
    mapfile -t files < <(ls -1t "$dir"/remnanode-*.tar.gz 2>/dev/null || true)
    if [ "${#files[@]}" -eq 0 ]; then
        warn "бэкапов нет ($dir)"
        pause; return 1
    fi
    for i in "${!files[@]}"; do
        printf "    %2d) %s  (%s)\n" "$((i+1))" "$(basename "${files[$i]}")" "$(du -h "${files[$i]}" 2>/dev/null | cut -f1)"
    done
    say ""
    read -r -p "$(echo -e "${C_BLD}Номер [Enter — отмена]: ${C_OFF}")" choice || true
    [ -z "$choice" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        warn "неверный номер"; pause; return 1
    fi
    choice=$((10#$choice))   # 010 — десятый файл; иначе bash считает номер восьмеричным
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
        warn "неверный номер"; pause; return 1
    fi
    local file="${files[$((choice-1))]}"
    say ""
    warn "файлы будут перезаписаны из $(basename "$file")"
    if confirm "продолжить?" "n"; then
        if /usr/local/sbin/rw-backup.sh restore "$file"; then
            ok "восстановлено"
            if confirm "перезапустить службы сейчас?" "y"; then
                systemctl restart rw-secondary-ip.service >/dev/null 2>&1 || { err "сеть не перезапущена"; pause; return 1; }
                ( cd "$NODE_DIR" && docker compose up -d ) >/dev/null 2>&1 || { err "нода не запущена"; pause; return 1; }
                if [ "$USE_SELFSTEAL" = yes ]; then
                    docker restart selfsteal >/dev/null 2>&1 || { err "Caddy не перезапущен"; pause; return 1; }
                fi
                ok "службы перезапущены"
            fi
        else
            err "восстановление не удалось"
            pause; return 1
        fi
    fi
    pause
}

write_alerts_env() {
    local a="" t="" c=""
    mkdir -p "$STATE_DIR" || return 1
    a="$(env_quote "${ALERTS:-no}")" || return 1
    t="$(env_quote "${TG_TOKEN:-}")" || return 1
    c="$(env_quote "${TG_CHAT:-}")" || return 1
    {
        printf '%s\n' '# Настройки алертов (меняются через nodego)'
        printf 'ALERTS=%s\n' "$a"
        printf 'TG_TOKEN=%s\n' "$t"
        printf 'TG_CHAT=%s\n' "$c"
    } > "$ALERTS_ENV" || return 1
    chmod 600 "$ALERTS_ENV"
}

toggle_alerts() {
    hdr "Алерты в Telegram"
    say "  сейчас: ${C_BLD}${ALERTS}${C_OFF}${TG_CHAT:+ (chat_id: $TG_CHAT)}"
    if [ "$ALERTS" = "yes" ]; then
        if confirm "выключить алерты?" "n"; then
            ALERTS="no"
            write_alerts_env
            ok "алерты выключены"
        fi
    else
        if confirm "включить алерты?" "y"; then
            if [ -z "$TG_TOKEN" ]; then
                ask TG_TOKEN "Токен бота (от @BotFather)" ""
            fi
            if [ -z "$TG_CHAT" ]; then
                ask TG_CHAT "chat_id получателя" ""
            fi
            if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
                err "нужны и токен, и chat_id"
                pause; return
            fi
            # Формат бота-токена (как в установщике, длину не проверяем): иначе
            # значение с кавычкой/пробелом рвёт alerts.env (он читается через `.`),
            # и теряются строки ниже.
            if ! [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                err "токен бота должен быть вида 123456789:AA... (цифры, двоеточие, буквы/цифры/-/_)"
                pause; return
            fi
            if ! [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]]; then
                err "chat_id — это число (для канала с минусом)"
                pause; return
            fi
            ALERTS="yes"
            write_alerts_env
            if curl -fsS --max-time 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                    -d "chat_id=${TG_CHAT}" --data-urlencode "text=✅ nodego: алерты включены" >/dev/null 2>&1; then
                ok "тестовое сообщение отправлено"
            else
                warn "не удалось отправить — проверьте токен/chat_id"
            fi
        fi
    fi
    pause
}

show_config() {    hdr "Конфигурация"
    say "  ${C_BLD}1)${C_OFF} answers.env (параметры установки)"
    say "  ${C_BLD}2)${C_OFF} net.env (схема сети)"
    say "  ${C_BLD}3)${C_OFF} .env ноды"
    say "  ${C_BLD}4)${C_OFF} docker-compose.yml ноды"
    say "  ${C_BLD}5)${C_OFF} Caddyfile"
    say "  ${C_BLD}0)${C_OFF} назад"
    say ""
    local c f
    read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
    case "$c" in
        1) f="$ANSWERS" ;;
        2) f="$NET_ENV" ;;
        3) f="$NODE_DIR/.env" ;;
        4) f="$NODE_DIR/docker-compose.yml" ;;
        5) f="$CADDYFILE" ;;
        0|"") return ;;
        *) warn "нет такого пункта"; return ;;
    esac
    if [ -f "$f" ]; then
        echo
        sed 's/^/  /' "$f"
        echo
    else
        warn "файл не найден: $f"
    fi
    pause
}

# ------------------------------------------------------------ готовые конфиги
configs_refresh() {
    hdr "Обновить параметры конфигов"
    dim "  порт, Reality target и serverNames подтянутся из текущих настроек;"
    dim "  privateKey, shortIds и теги останутся прежними"
    if cfg_run generate; then
        cfg_run brief
    fi
    pause
}

configs_regen() {
    hdr "Перегенерировать конфиги"
    warn "privateKey, shortIds и теги станут новыми — профиль в панели надо обновить"
    if confirm "продолжить?" "n"; then
        if cfg_run generate --force; then
            cfg_run brief
        fi
    fi
    pause
}

menu_configs() {
    while true; do
        hdr "Готовые конфиги (порт ${CONNECT_PORT:-?})"
        if [ "$HYSTERIA" = "yes" ]; then
            say "  набор: xHTTP, gRPC, TCP, Hysteria2   •   каталог: $CONFIGS_DIR"
            say "  hysteria2.json = hysteria (UDP) + xHTTP/Reality (TCP) для selfsteal"
        else
            say "  набор: xHTTP, gRPC, TCP   •   каталог: $CONFIGS_DIR"
        fi
        say ""
        say "  ${C_BLD}1)${C_OFF} показать все конфиги"
        say "  ${C_BLD}2)${C_OFF} xHTTP"
        say "  ${C_BLD}3)${C_OFF} gRPC"
        say "  ${C_BLD}4)${C_OFF} TCP"
        if [ "$HYSTERIA" = "yes" ]; then
            say "  ${C_BLD}5)${C_OFF} Hysteria2"
        else
            say "  ${C_BLD}5)${C_OFF} Hysteria2 — выключена"
        fi
        say "  ${C_BLD}6)${C_OFF} publicKey и shortIds (для ручных клиентов)"
        say "  ${C_BLD}7)${C_OFF} обновить параметры (порт/домен, ключи сохраняются)"
        say "  ${C_BLD}8)${C_OFF} перегенерировать (новые ключи, теги и shortIds)"
        say "  ${C_BLD}9)${C_OFF} проверить через xray -test"
        say "  ${C_BLD}0)${C_OFF} назад"
        say ""
        local c=""
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "${c:-}" in
            1) hdr "Все конфиги"; cfg_run show all; pause ;;
            2) hdr "xHTTP"; cfg_run show xhttp; pause ;;
            3) hdr "gRPC"; cfg_run show grpc; pause ;;
            4) hdr "TCP"; cfg_run show tcp; pause ;;
            5)
                if [ "$HYSTERIA" = "yes" ]; then
                    hdr "Hysteria2"; cfg_run show hysteria2
                else
                    warn "Hysteria2 выключена — включите её: главное меню → 3 → 2"
                fi
                pause
                ;;
            6) hdr "publicKey и shortIds"; cfg_run keys; pause ;;
            7) configs_refresh ;;
            8) configs_regen ;;
            9) hdr "Проверка конфигов (xray -test)"; cfg_run test; pause ;;
            0|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

# --------------------------------------------------------------------- порты
ports_list() {
    hdr "Открытые порты (ufw)"
    if have ufw; then
        ufw status verbose 2>/dev/null | sed 's/^/  /' || { err "ufw status завершился ошибкой"; pause; return 1; }
    else
        warn "ufw не установлен"
        pause; return 1
    fi
    pause
}

ports_add() {
    local p="" proto="" from="" label=""
    hdr "Открыть порт"
    read -r -p "$(echo -e "${C_BLD}Порт${C_OFF}: ")" p || true
    p="${p//[[:space:]]/}"
    if ! is_port "$p"; then err "некорректный порт: '$p'"; pause; return 1; fi
    read -r -p "$(echo -e "${C_BLD}Протокол${C_OFF} [tcp/udp/both, tcp]: ")" proto || true
    proto="${proto:-tcp}"
    proto="${proto,,}"
    case "$proto" in
        tcp|udp|both) : ;;
        *) err "протокол: tcp, udp или both"; pause; return 1 ;;
    esac
    read -r -p "$(echo -e "${C_BLD}Только для IP${C_OFF} [пусто — для всех]: ")" from || true
    from="${from//[[:space:]]/}"
    if [ -n "$from" ] && ! is_ipv4 "$from"; then
        err "некорректный IPv4: '$from'"
        pause
        return 1
    fi
    read -r -p "$(echo -e "${C_BLD}Подпись правила${C_OFF} [port $p]: ")" label || true
    label="${label:-port $p}"
    if ! have ufw; then err "ufw не установлен"; pause; return 1; fi
    local rc=0 protocols="$proto" protocol
    [ "$proto" = both ] && protocols="tcp udp"
    for protocol in $protocols; do
        if [ -n "$from" ]; then
            ufw allow from "$from" to any port "$p" proto "$protocol" comment "$label" >/dev/null 2>&1 || rc=$?
        else
            ufw allow "$p/$protocol" comment "$label" >/dev/null 2>&1 || rc=$?
        fi
    done
    if [ "$rc" -eq 0 ]; then
        ok "открыт $p/$proto ${from:+для $from} — «$label»"
    else
        err "ufw не применил все правила; проверьте список (возможно частичное применение)"
    fi
    say ""
    ufw status 2>/dev/null | grep -E "^${p}(/| )" | sed 's/^/  /' || true
    pause
    return "$rc"
}

ports_del() {
    local num=""
    hdr "Закрыть порт"
    if ! have ufw; then err "ufw не установлен"; pause; return; fi
    ufw status numbered 2>/dev/null | sed 's/^/  /' || true
    say ""
    read -r -p "$(echo -e "${C_BLD}Номер правила (Enter — отмена)${C_OFF}: ")" num || true
    [ -z "$num" ] && return
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then err "нужен номер из списка"; pause; return; fi
    if confirm "удалить правило №$num?" "n"; then
        if ufw --force delete "$num" >/dev/null 2>&1; then
            ok "правило №$num удалено"
        else
            warn "ufw не смог удалить правило №$num"
        fi
        say ""
        ufw status 2>/dev/null | sed 's/^/  /' || true
    fi
    pause
}

menu_ports() {
    while true; do
        hdr "Порты в firewall"
        say "  ${C_BLD}1)${C_OFF} список открытых портов"
        say "  ${C_BLD}2)${C_OFF} открыть новый порт с подписью"
        say "  ${C_BLD}3)${C_OFF} закрыть порт"
        say "  ${C_BLD}0)${C_OFF} назад"
        say ""
        local c=""
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "${c:-}" in
            1) ports_list ;;
            2) ports_add ;;
            3) ports_del ;;
            0|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

# ----------------------------------------------------------------- Hysteria2
ufw_drop_port() { # ufw_drop_port ПОРТ ПРОТОКОЛ (убирает все правила v4/v6)
    local p="$1" proto="$2" num="" tries=0
    while [ "$tries" -lt 5 ]; do
        num="$(ufw status numbered 2>/dev/null \
            | grep -E "\\] ${p}/${proto}([[:space:]]|$)" \
            | head -n1 | sed -n 's/^\[[[:space:]]*\([0-9]*\)\].*/\1/p')"
        [ -n "$num" ] || break
        ufw --force delete "$num" >/dev/null 2>&1 || break
        tries=$((tries + 1))
    done
    [ "$tries" -gt 0 ]
}

hy_short_status() {
    local udp="нет" cert="нет" state="выключена"
    if ufw status 2>/dev/null | grep -qE "^${CONNECT_PORT}/udp"; then udp="открыт"; fi
    if [ -s "$HY_CERT/fullchain.crt" ] && [ -s "$HY_CERT/private.key" ]; then cert="есть"; fi
    if [ "$HYSTERIA" = "yes" ]; then state="включена"; fi
    say "  состояние: ${C_BLD}${state}${C_OFF}   UDP/${CONNECT_PORT}: $udp   сертификат: $cert"
    say "  ядро ноды: $(node_xray_version)"
}

hy_status() {
    hdr "Hysteria2: статус"
    hy_short_status
    say ""
    say "  домен:          ${DOMAIN:-—}"
    say "  Reality target: 127.0.0.1:${SELFSTEAL_PORT:-9443}"
    if [ -f "$CONFIGS_DIR/hysteria2.json" ]; then
        say "  конфиг:         $CONFIGS_DIR/hysteria2.json (есть)"
    else
        say "  конфиг:         нет — включите Hysteria2 (пункт 2)"
    fi
    say "  таймер сертификата: $(systemctl is-active rw-cert-sync.timer 2>/dev/null || echo -)"
    dim "  UDP в ядре Xray поднимается только когда hysteria-инбаунд есть в профиле панели"
    pause
}

hy_enable() {
    hdr "Hysteria2: включить"
    if [ "$USE_SELFSTEAL" != "yes" ] || [ -z "${DOMAIN:-}" ]; then
        err "нужен selfsteal с доменом (сейчас: ${USE_SELFSTEAL:-нет}, домен '${DOMAIN:-—}')"
        pause
        return 1
    fi
    if [ ! -x "$CERT_SYNC" ]; then
        err "нет $CERT_SYNC — запустите установщик ещё раз"
        pause
        return 1
    fi
    say "  синхронизирую сертификат…"
    "$CERT_SYNC" | sed 's/^/  /' || { err "синхронизация сертификата не удалась"; pause; return 1; }
    if [ ! -s "$HY_CERT/fullchain.crt" ]; then
        err "сертификат не найден — selfsteal ещё не выпустил (проверьте: docker logs selfsteal)"
        pause
        return 1
    fi
    if have ufw; then
        ufw allow "$CONNECT_PORT/udp" comment "hysteria2 QUIC $CONNECT_PORT" >/dev/null 2>&1 || { err "UDP не открыт"; pause; return 1; }
        ok "UDP/$CONNECT_PORT открыт в ufw"
    fi
    local prev_hy="$HYSTERIA"
    set_answer HYSTERIA yes || { err "не удалось сохранить HYSTERIA=yes в $ANSWERS"; pause; return 1; }
    HYSTERIA="yes"
    if ! cfg_run generate; then
        # Без hysteria2.json флаг «включена» врёт: возвращаем прежнее значение.
        if set_answer HYSTERIA "$prev_hy"; then
            HYSTERIA="$prev_hy"
        else
            warn "не удалось вернуть HYSTERIA=$prev_hy — исправьте $ANSWERS вручную"
        fi
        err "генерация конфига не удалась — Hysteria2 не включена"
        pause; return 1
    fi
    cfg_run brief || return 1
    ok "Hysteria2 включена: конфиг $CONFIGS_DIR/hysteria2.json"
    note "дальше: вставьте его в Config Profile, включите в Squads и Hosts, перезапустите ноду"
    pause
}

hy_disable() {
    hdr "Hysteria2: выключить"
    if [ "$NODEGO_CLI" = false ]; then
        confirm "закрыть UDP/$CONNECT_PORT и удалить конфиг?" "n" || return 0
    fi
    if have ufw; then
        if ufw_drop_port "$CONNECT_PORT" udp; then
            ok "UDP/$CONNECT_PORT закрыт в ufw"
        fi
    fi
    set_answer HYSTERIA no || { err "не удалось сохранить HYSTERIA=no в $ANSWERS — Hysteria2 остаётся включённой"; pause; return 1; }
    HYSTERIA="no"
    cfg_run generate >/dev/null 2>&1 || { err "обновление конфигов не удалось"; pause; return 1; }
    ok "Hysteria2 выключена, конфиг hysteria2.json удалён"
    note "не забудьте убрать hysteria-инбаунд из профиля панели"
    pause
}

hy_cert() {
    hdr "Hysteria2: сертификат"
    if [ ! -x "$CERT_SYNC" ]; then
        err "нет $CERT_SYNC — запустите установщик ещё раз"
        pause
        return 1
    fi
    "$CERT_SYNC" | sed 's/^/  /' || { err "синхронизация сертификата не удалась"; pause; return 1; }
    if [ -s "$HY_CERT/fullchain.crt" ]; then
        ok "сертификат на месте: $HY_CERT/{fullchain.crt,private.key}"
    else
        warn "сертификата нет — Caddy ещё не выпустил или домен не тот"
        pause; return 1
    fi
    pause
}

hy_core() {
    hdr "Hysteria2: обновление ядра (Xray в ноде)"
    say "  сейчас: $(node_xray_version)"
    if [ "$NODEGO_CLI" = false ]; then
        confirm "обновить Docker-образ ноды до latest (с откатом при сбое)?" "y" || return 0
    fi
    local rc=0
    if [ -x /usr/local/sbin/rw-node-update.sh ]; then
        /usr/local/sbin/rw-node-update.sh | sed 's/^/  /'
    else
        ( cd "$NODE_DIR" && docker compose pull -q && docker compose up -d ) 2>&1 | sed 's/^/  /'
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then err "обновление ядра не удалось"; pause; return "$rc"; fi
    say "  после обновления: $(node_xray_version)"
    note "свежий Xray умеет hysteria-инбаунд — ядро обновлено"
    pause
}

hy_test() {
    hdr "Hysteria2: проверка конфига (xray -test)"
    if cfg_run test hysteria2; then
        ok "конфиг hysteria2.json принимается ядром"
    else
        warn "ядро не приняло конфиг — чаще всего нет сертификата ($HY_CERT) или Xray старый"
        note "обновить сертификат: пункт 4, ядро: пункт 5"
        pause; return 1
    fi
    pause
}

menu_hysteria() {
    while true; do
        hdr "Hysteria2"
        hy_short_status
        say ""
        say "  ${C_BLD}1)${C_OFF} статус подробно"
        say "  ${C_BLD}2)${C_OFF} включить (сертификат + UDP/$CONNECT_PORT + конфиг)"
        say "  ${C_BLD}3)${C_OFF} выключить"
        say "  ${C_BLD}4)${C_OFF} обновить сертификат сейчас"
        say "  ${C_BLD}5)${C_OFF} обновить ядро ноды (Xray) до последней версии"
        say "  ${C_BLD}6)${C_OFF} проверить конфиг через xray -test"
        say "  ${C_BLD}0)${C_OFF} назад"
        say ""
        local c=""
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "${c:-}" in
            1) hy_status ;;
            2) hy_enable ;;
            3) hy_disable ;;
            4) hy_cert ;;
            5) hy_core ;;
            6) hy_test ;;
            0|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

cli_hysteria() {
    case "${1:-status}" in
        status) hdr "Hysteria2: статус"; hy_short_status ;;
        on)     hy_enable ;;
        off)    hy_disable ;;
        cert)   "$CERT_SYNC" ;;
        core)   hy_core ;;
        test)   hdr "Hysteria2: проверка конфига (xray -test)"; cfg_run test hysteria2 ;;
        *)
            err "hysteria: status | on | off | cert | core | test"
            exit 1
            ;;
    esac
}

# --------------------------------------------------------------------- swap
# Логика swap живёт в одном месте — режим --swap-only установщика: там
# рекомендация по размеру, проверки безопасности (swap на разделе,
# MemAvailable) и запись в /etc/fstab. Меню её не дублирует, а запускает
# установщик: две копии такой логики рано или поздно разойдутся.
swap_show() {
    local ram="" avail="" free_mb="" info="" tot="" used="" dev=""
    ram="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    avail="$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || true)"
    info="$(awk '/^SwapTotal:/{t=int($2/1024)} /^SwapFree:/{f=int($2/1024)} END{printf "%d %d", t+0, t-f}' /proc/meminfo 2>/dev/null || true)"
    tot="${info%% *}"
    used="${info##* }"
    case "$tot"  in ''|*[!0-9]*) tot=0 ;; esac
    case "$used" in ''|*[!0-9]*) used=0 ;; esac
    say "  RAM: ${ram:-?} МБ (доступно ${avail:-?}) · диск: свободно ${free_mb:-?} МБ"
    if [ "$tot" -gt 0 ]; then
        dev="$(swapon --show=NAME --noheadings 2>/dev/null | awk 'NF{print $1; exit}' || true)"
        say "  swap: ${C_BLD}${tot} МБ${C_OFF} (${dev:-файл}, занято ${used} МБ)"
    else
        say "  swap: ${C_BLD}не включён${C_OFF}"
    fi
}

swap_apply() { # swap_apply [размер] — пересоздать swap через install.sh --swap-only
    local size="${1:-}" tmp="" rc=0
    tmp="$(mktemp)" || { err "mktemp не сработал"; return 1; }
    dim "  загружаю установщик из репозитория…"
    if ! curl -fsSL --retry 2 --max-time 30 "$RAW_BASE/install.sh" -o "$tmp"; then
        rm -f "$tmp"
        err "не удалось скачать install.sh — проверьте сеть и DNS"
        return 1
    fi
    if ! head -c 128 "$tmp" | grep -q 'bash'; then
        rm -f "$tmp"
        err "по ссылке пришёл не скрипт — не запускаю"
        return 1
    fi
    # Без размера установщик сам покажет рекомендацию и спросит (Enter =
    # рекомендация). С размером — молча: пункт меню уже означает согласие.
    if [ -n "$size" ]; then
        bash "$tmp" --swap-only --swap-size "$size" --yes
    else
        bash "$tmp" --swap-only
    fi
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

swap_details() {
    local oom=""
    say ""
    say "  ${C_BLD}включённые swap:${C_OFF}"
    swapon --show 2>/dev/null | sed 's/^/    /' || true
    say ""
    say "  ${C_BLD}/etc/fstab:${C_OFF}"
    if grep -qE '[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null; then
        grep -E '[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null | sed 's/^/    /'
    else
        say "    записей про swap нет"
    fi
    say ""
    say "  ${C_BLD}память:${C_OFF}"
    free -m 2>/dev/null | sed 's/^/    /' || true
    say ""
    say "  ${C_BLD}OOM-killer срабатывал:${C_OFF}"
    oom="$(dmesg 2>/dev/null | grep -ci 'killed process' || true)"
    case "$oom" in ''|*[!0-9]*) oom=0 ;; esac
    if [ "$oom" -gt 0 ]; then
        warn "    да, ${oom} раз(а) — swap пригодится, но это скорее нехватка RAM"
    else
        say "    нет"
    fi
    dim "  активная подкачка прямо сейчас: vmstat 1 5 (колонки si/so)"
}

menu_swap() {
    local c=""
    while true; do
        hdr "Swap"
        swap_show
        say ""
        say "  ${C_BLD}1)${C_OFF} пересоздать: размер по рекомендации ${C_DIM}(спросит подтверждение)${C_OFF}"
        say "  ${C_BLD}2)${C_OFF} пересоздать: 1 ГБ"
        say "  ${C_BLD}3)${C_OFF} пересоздать: 2 ГБ"
        say "  ${C_BLD}4)${C_OFF} подробнее: swapon, /etc/fstab, OOM в dmesg"
        say "  ${C_BLD}0)${C_OFF} назад"
        dim "  docker, Caddy, конфиги и firewall не трогаются; нода не перезапускается"
        say ""
        read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" c || true
        case "${c:-}" in
            1) swap_apply ;;
            2) if confirm "пересоздать swap на 1 ГБ?" "n"; then swap_apply 1G; fi; pause ;;
            3) if confirm "пересоздать swap на 2 ГБ?" "n"; then swap_apply 2G; fi; pause ;;
            4) swap_details; pause ;;
            0|q|Q|"") return ;;
            *) warn "нет такого пункта" ;;
        esac
    done
}

cli_swap() { # nodego swap [auto|512M|1G|2G]
    local size="${1:-}"
    case "$size" in
        off|no|none|0)
            warn "off в установщике означает «не создавать и не трогать существующий swap»"
            dim "  убрать swap вручную: swapoff -a && sed -i '/ swap /d' /etc/fstab && rm -f /swapfile"
            return 1
            ;;
        ''|auto) swap_apply ;;
        *)       swap_apply "$size" ;;
    esac
}

# ---------------------------------------------------------------- CLI-режим
cli() {
    case "${1:-}" in
        status)  load_conf; show_status ;;
        logs)    load_conf; docker logs --tail 100 remnanode 2>&1 ;;
        restart) load_conf; restart_node ;;
        update)  load_conf; /usr/local/sbin/rw-node-update.sh ;;
        doctor)  load_conf; /usr/local/sbin/rw-healthcheck.sh --report ;;
        backup)  load_conf; /usr/local/sbin/rw-backup.sh create ;;
        restore)
            load_conf
            shift
            /usr/local/sbin/rw-backup.sh restore "${1:-}"
            ;;
        alerts)
            load_conf
            say "алерты: ${ALERTS}${TG_CHAT:+ (chat_id: $TG_CHAT)}"
            ;;
        net)     load_conf; shift; net_show ;;
        configs|config)
            load_conf
            shift || true
            cfg_run show "${1:-all}"
            ;;
        keys)    load_conf; cfg_run keys ;;
        ports)   load_conf; shift || true; ports_list ;;
        hysteria)
            load_conf
            shift || true
            cli_hysteria "${1:-status}"
            ;;
        dns)
            load_conf
            case "${2:-}" in
                on|off) dns_change "$2" ;;
                *) err "укажите nodego dns on или nodego dns off"; return 1 ;;
            esac
            ;;
        certsync) load_conf; "$CERT_SYNC" ;;
        swap)
            load_conf
            shift || true
            cli_swap "${1:-}"
            ;;
        preset)
            load_conf
            load_templates
            if [ $# -lt 2 ]; then
                err "укажите имя шаблона: ${TEMPLATE_KEYS[*]}"
                exit 1
            fi
            if ! [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
                err "недопустимое имя шаблона: '$2'"
                exit 1
            fi
            local tmp
            tmp="$(mktemp)" || return 1
            if curl -fsSL --retry 2 --connect-timeout 15 --max-time 30 "$TEMPLATES_BASE/$2/index.html" -o "$tmp"; then
                if ! mkdir -p "$SELFSTEAL_DIR/html" || ! cp "$tmp" "$SELFSTEAL_DIR/html/index.html"; then
                    rm -f "$tmp"; err "шаблон не записан"; return 1
                fi
                rm -f "$tmp"
                set_answer TEMPLATE "$2" || return 1
                docker restart selfsteal >/dev/null 2>&1 || { err "Caddy не перезапущен"; return 1; }
                ok "шаблон «$2» применён"
            else
                rm -f "$tmp"
                err "не удалось скачать шаблон «$2»"
                exit 1
            fi
            ;;
        check|checks)
            shift || true
            cli_check "${1:-menu}"
            ;;
        -h|--help|help)
            say "nodego — меню управления Remnawave Node"
            say ""
            say "  nodego                 интерактивное меню"
            say "  nodego status          состояние контейнеров, служб и сети"
            say "  nodego logs            логи ноды"
            say "  nodego restart         перезапустить ноду"
            say "  nodego update          обновить ноду (с откатом)"
            say "  nodego net             показать схему сети"
            say "  nodego configs [тип]   готовые конфиги: xhttp|grpc|tcp|hysteria2|all"
            say "  nodego keys            publicKey и shortIds для ручных клиентов"
            say "  nodego ports           открытые порты в ufw"
            say "  nodego dns on|off      AdGuard: включить / восстановить исходный DNS"
            say "  nodego certsync        синхронизировать сертификат selfsteal → ноде"
            say "  nodego hysteria ...    status | on | off | cert | core | test"
            say "  nodego preset <имя>    сменить сайт-заглушку"
            say "  nodego doctor          диагностика (7 проверок)"
            say "  nodego backup          бэкап конфигов"
            say "  nodego restore <файл>  восстановление из бэкапа"
            say "  nodego alerts          статус алертов"
            say "  nodego swap [размер]   swap: состояние и пересоздание (auto | 1G | 2G)"
            say "  nodego check [что]     проверка сервера: ip | region | bench-ru | bench |"
            say "                         yabs | instagram | dpi | cpu | quick"
            ;;
        *) err "неизвестная команда: $1 (см. nodego --help)"; exit 1 ;;
    esac
}

# ------------------------------------------------------------------- главное
need_root
load_conf

if [ $# -gt 0 ]; then
    NODEGO_CLI=true
    cli "$@"
    exit $?
fi

while true; do
    echo
    say "${C_BLU}╔══════════════════════════════════════════════════════════╗${C_OFF}"
    say "${C_BLU}║${C_OFF}  ${C_BLD}nodego${C_OFF} — управление Remnawave Node                  ${C_BLU}║${C_OFF}"
    say "${C_BLU}╚══════════════════════════════════════════════════════════╝${C_OFF}"
    net_state="$([ "$MODE" = dual ] && echo "2 IP: $IP1 → $IP2" || echo "1 IP: ${IP1:-?}")"
    hy_state="$([ "$HYSTERIA" = "yes" ] && echo "Hy2 UDP/$CONNECT_PORT" || echo "Hy2 off")"
    say "  нода: $(node_running && echo "${C_GRN}работает${C_OFF}" || echo "${C_RED}остановлена${C_OFF}")   |   сеть: $net_state   |   порт ${CONNECT_PORT:-?}   |   $hy_state"
    say ""
    say "  ${C_BLD}1)${C_OFF} Готовые конфиги: xHTTP, gRPC, TCP$([ "$HYSTERIA" = "yes" ] && echo ", Hysteria2")"
    say "  ${C_BLD}2)${C_OFF} Порты: список / открыть новый с подписью / закрыть"
    say "  ${C_BLD}3)${C_OFF} Hysteria2: статус, включить/выключить, сертификат, ядро"
    say "  ${C_BLD}4)${C_OFF} Статус: контейнеры, службы, сеть, порты"
    say "  ${C_BLD}5)${C_OFF} Логи ноды (live)"
    say "  ${C_BLD}6)${C_OFF} Логи selfsteal (live)"
    say "  ${C_BLD}7)${C_OFF} Лог автообновления"
    say "  ${C_BLD}8)${C_OFF} Перезапустить ноду"
    say "  ${C_BLD}9)${C_OFF} Перезапустить selfsteal"
    say "  ${C_BLD}10)${C_OFF} Перезапустить всё"
    say "  ${C_BLD}11)${C_OFF} Сеть: 1 IP / 2 IP, вход и выход"
    say "  ${C_BLD}12)${C_OFF} Сменить сайт-заглушку"
    say "  ${C_BLD}13)${C_OFF} Обновить ноду сейчас (с откатом)"
    say "  ${C_BLD}14)${C_OFF} Проверить исходящий IP"
    say "  ${C_BLD}15)${C_OFF} Показать конфигурацию"
    say "  ${C_BLD}16)${C_OFF} Автообновление: включить/выключить"
    say "  ${C_BLD}17)${C_OFF} DNS-фильтр AdGuard: включить/выключить"
    say "  ${C_BLD}18)${C_OFF} Диагностика (doctor)"
    say "  ${C_BLD}19)${C_OFF} Бэкап конфигов сейчас"
    say "  ${C_BLD}20)${C_OFF} Восстановить из бэкапа"
    say "  ${C_BLD}21)${C_OFF} Алерты Telegram: включить/выключить"
    say "  ${C_BLD}22)${C_OFF} Проверка сервера: IP, бенчмарки, DPI"
    say "  ${C_BLD}23)${C_OFF} Swap: состояние, пересоздать, размер"
    say "  ${C_BLD}0)${C_OFF} Выход"
    say ""
    read -r -p "$(echo -e "${C_BLD}Выбор: ${C_OFF}")" choice || true
    case "${choice:-}" in
        1)  menu_configs ;;
        2)  menu_ports ;;
        3)  menu_hysteria ;;
        4)  show_status; pause ;;
        5)  logs_node ;;
        6)  logs_caddy ;;
        7)  logs_update ;;
        8)  restart_node ;;
        9)  restart_caddy ;;
        10) restart_all ;;
        11) menu_net ;;
        12) change_preset ;;
        13) update_now ;;
        14) hdr "Исходящий IP"; outbound_check; pause ;;
        15) show_config ;;
        16) toggle_autoupdate ;;
        17) toggle_dns ;;
        18) doctor ;;
        19) backup_now ;;
        20) restore_menu ;;
        21) toggle_alerts ;;
        22) menu_checks ;;
        23) menu_swap ;;
        0|q|Q|"") say ""; dim "выход"; exit 0 ;;
        *) warn "нет такого пункта" ;;
    esac
    load_conf
done
