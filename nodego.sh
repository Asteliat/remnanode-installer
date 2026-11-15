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
        TEMPLATE_KEYS=(landing)
        TEMPLATE_DESCS=("лендинг — визитка небольшой компании")
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
    [ "$NODEGO_CLI" = true ] && return 0
    read -r -p "$(echo -e "${C_DIM}Enter — продолжить…${C_OFF}")" _ || true
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

set_answer() { # set_answer KEY VALUE
    local key="$1" val="$2"
    [ -f "$ANSWERS" ] || return 0
    if grep -q "^${key}=" "$ANSWERS"; then
        sed -i -E "s|^${key}=.*|${key}='${val}'|" "$ANSWERS"
    else
        printf '%s=%s\n' "$key" "'$val'" >> "$ANSWERS"
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
        say "    selfsteal: ${DOMAIN:-—} (80/443 → 127.0.0.1:${SELFSTEAL_PORT:-9443}), шаблон: ${TEMPLATE:-landing}"
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
    docker logs --tail 80 -f remnanode 2>&1 || warn "контейнер remnanode не найден"
    pause
}

logs_caddy() {
    hdr "Логи selfsteal (Ctrl+C — выход)"
    docker logs --tail 80 -f selfsteal 2>&1 || warn "контейнер selfsteal не найден"
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
        pause; return
    fi
    ( cd "$NODE_DIR" && docker compose restart ) 2>&1 | sed 's/^/  /'
    sleep 3
    if node_running; then ok "нода работает"; else warn "нода не поднялась — смотрите логи ноды"; fi
    pause
}

restart_caddy() {
    hdr "Перезапуск selfsteal"
    if [ ! -f "$SELFSTEAL_DIR/docker-compose.yml" ]; then
        err "selfsteal не установлен"
        pause; return
    fi
    ( cd "$SELFSTEAL_DIR" && docker compose restart ) 2>&1 | sed 's/^/  /'
    sleep 2
    if caddy_running; then ok "Caddy работает"; else warn "Caddy не поднялся — смотрите логи"; fi
    pause
}

restart_all() {
    hdr "Перезапуск всего"
    restart_node
    [ "$USE_SELFSTEAL" = "yes" ] && restart_caddy
}

update_now() {
    hdr "Обновление ноды"
    if [ ! -x /usr/local/sbin/rw-node-update.sh ]; then
        err "скрипт обновления не найден"
        pause; return
    fi
    dim "запускаю /usr/local/sbin/rw-node-update.sh (с откатом при сбое)…"
    /usr/local/sbin/rw-node-update.sh 2>&1 | sed 's/^/  /'
    [ -f "$UPDATE_LOG" ] && { say ""; dim "последние строки лога:"; tail -n 10 "$UPDATE_LOG" | sed 's/^/  /'; }
    pause
}

change_preset() {
    hdr "Сайт-заглушка"
    if [ ! -d "$SELFSTEAL_DIR" ]; then
        err "selfsteal не установлен"
        pause; return
    fi
    load_templates
    local i choice key tmp
    say "  ${C_BLD}Доступные сайты (введите номер):${C_OFF}"
    for i in "${!TEMPLATE_KEYS[@]}"; do
        printf "    %2d) %-12s — %s\n" "$((i+1))" "${TEMPLATE_KEYS[$i]}" "${TEMPLATE_DESCS[$i]}"
    done
    say ""
    read -r -p "$(echo -e "${C_BLD}Выбор [1-${#TEMPLATE_KEYS[@]}, Enter — отмена]${C_OFF}: ")" choice || true
    [ -z "$choice" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#TEMPLATE_KEYS[@]}" ]; then
        warn "неверный номер"
        pause; return
    fi
    key="${TEMPLATE_KEYS[$((choice-1))]}"

    tmp="$(mktemp)"
    if curl -fsSL --retry 2 --connect-timeout 15 "$TEMPLATES_BASE/$key/index.html" -o "$tmp"; then
        mkdir -p "$SELFSTEAL_DIR/html"
        cp "$tmp" "$SELFSTEAL_DIR/html/index.html"
        rm -f "$tmp"
        set_answer TEMPLATE "$key"
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
    if ! is_ipv4 "$want"; then err "некорректный IPv4"; pause; return; fi
    if [ "$want" = "$IP1" ]; then err "выходной IP совпадает с основным"; pause; return; fi

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
        pause; return
    fi
    if systemctl is-enabled rw-node-update.timer >/dev/null 2>&1; then
        if confirm "сейчас включено. выключить?" "n"; then
            systemctl disable --now rw-node-update.timer >/dev/null 2>&1
            set_answer AUTO_UPDATE "no"
            ok "автообновление выключено"
        fi
    else
        if confirm "сейчас выключено. включить (ежедневно ~04:30)?" "y"; then
            systemctl enable --now rw-node-update.timer >/dev/null 2>&1
            set_answer AUTO_UPDATE "yes"
            ok "автообновление включено"
        fi
    fi
    pause
}

toggle_dns() {
    hdr "DNS-фильтр AdGuard"
    local conf="/etc/systemd/resolved.conf.d/99-adguard-dot.conf"
    if [ -f "$conf" ]; then
        if confirm "сейчас включён. выключить и вернуть системный DNS?" "n"; then
            rm -f "$conf"
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
            resolvectl flush-caches >/dev/null 2>&1 || true
            set_answer USE_DNS "no"
            ok "AdGuard выключен"
        fi
    else
        if confirm "включить блокировку рекламы через AdGuard DoT?" "y"; then
            mkdir -p /etc/systemd/resolved.conf.d
            cat > "$conf" <<'EOF'
[Resolve]
DNS=94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
EOF
            # гасим старые глобальные DNS, иначе они могут выиграть у наших
            if [ -f /etc/systemd/resolved.conf ]; then
                sed -i -E 's/^[[:space:]]*(DNS|FallbackDNS)=/#\1=/' /etc/systemd/resolved.conf
            fi
            if [ -d /etc/cloud/cloud.cfg.d ]; then
                cat > /etc/cloud/cloud.cfg.d/99-remnawave-resolv.cfg <<'EOF'
# remnawave-installer: не трогать /etc/resolv.conf — им управляет systemd-resolved
manage_resolv_conf: false
EOF
            fi
            systemctl enable systemd-resolved >/dev/null 2>&1 || true
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
            ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
            resolvectl flush-caches >/dev/null 2>&1 || true
            set_answer USE_DNS "yes"
            ok "AdGuard включён"
            resolvectl status 2>/dev/null | grep -m1 'DNS Servers' | sed 's/^/  /' || true
        fi
    fi
    pause
}

doctor() {
    hdr "Диагностика"
    if [ -x /usr/local/sbin/rw-healthcheck.sh ]; then
        /usr/local/sbin/rw-healthcheck.sh --report 2>&1 | sed 's/^/  /'
    else
        warn "healthcheck-скрипт не найден (/usr/local/sbin/rw-healthcheck.sh)"
    fi
    say ""
    dim "последние события docker за сутки:"
    docker events --since 24h --until 0s --filter 'event=restart' \
        --format '  {{.Time}} {{.Actor.Attributes.name}} restart' 2>/dev/null | tail -5 || true
    pause
}

backup_now() {
    hdr "Бэкап конфигов"
    if [ ! -x /usr/local/sbin/rw-backup.sh ]; then
        err "скрипт бэкапа не найден"
        pause; return
    fi
    local f
    f="$(/usr/local/sbin/rw-backup.sh create 2>&1)"
    if [ -s "${f%%$'\n'*}" ] 2>/dev/null; then
        ok "создан: $f"
        say "  размер: $(du -h "$f" 2>/dev/null | cut -f1)"
    else
        warn "бэкап не создался"
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
        pause; return
    fi
    for i in "${!files[@]}"; do
        printf "    %2d) %s  (%s)\n" "$((i+1))" "$(basename "${files[$i]}")" "$(du -h "${files[$i]}" 2>/dev/null | cut -f1)"
    done
    say ""
    read -r -p "$(echo -e "${C_BLD}Номер [Enter — отмена]: ${C_OFF}")" choice || true
    [ -z "$choice" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
        warn "неверный номер"; pause; return
    fi
    local file="${files[$((choice-1))]}"
    say ""
    warn "файлы будут перезаписаны из $(basename "$file")"
    if confirm "продолжить?" "n"; then
        if /usr/local/sbin/rw-backup.sh restore "$file"; then
            ok "восстановлено"
            if confirm "перезапустить службы сейчас?" "y"; then
                systemctl restart rw-secondary-ip.service >/dev/null 2>&1 || true
                ( cd "$NODE_DIR" && docker compose up -d ) >/dev/null 2>&1 || true
                docker restart selfsteal >/dev/null 2>&1 || true
                ok "службы перезапущены"
            fi
        else
            err "восстановление не удалось"
        fi
    fi
    pause
}

write_alerts_env() {
    mkdir -p "$STATE_DIR"
    cat > "$ALERTS_ENV" <<EOF
# Настройки алертов (меняются через nodego)
ALERTS='$ALERTS'
TG_TOKEN='$TG_TOKEN'
TG_CHAT='$TG_CHAT'
EOF
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
        ufw status verbose 2>/dev/null | sed 's/^/  /' || true
    else
        warn "ufw не установлен"
    fi
    pause
}

ports_add() {
    local p="" proto="" from="" label=""
    hdr "Открыть порт"
    read -r -p "$(echo -e "${C_BLD}Порт${C_OFF}: ")" p || true
    p="${p//[[:space:]]/}"
    if ! is_port "$p"; then err "некорректный порт: '$p'"; pause; return; fi
    read -r -p "$(echo -e "${C_BLD}Протокол${C_OFF} [tcp/udp/both, tcp]: ")" proto || true
    proto="${proto:-tcp}"
    proto="${proto,,}"
    case "$proto" in
        tcp|udp|both) : ;;
        *) err "протокол: tcp, udp или both"; pause; return ;;
    esac
    read -r -p "$(echo -e "${C_BLD}Только для IP${C_OFF} [пусто — для всех]: ")" from || true
    from="${from//[[:space:]]/}"
    if [ -n "$from" ] && ! is_ipv4 "$from"; then
        err "некорректный IPv4: '$from'"
        pause
        return
    fi
    read -r -p "$(echo -e "${C_BLD}Подпись правила${C_OFF} [port $p]: ")" label || true
    label="${label:-port $p}"
    if ! have ufw; then err "ufw не установлен"; pause; return; fi
    if [ -n "$from" ]; then
        if ufw allow from "$from" to any port "$p" proto "$proto" comment "$label" >/dev/null 2>&1; then
            ok "открыт $p/$proto для $from — «$label»"
        else
            warn "ufw не принял правило"
        fi
    elif [ "$proto" = "both" ]; then
        ufw allow "$p/tcp" comment "$label" >/dev/null 2>&1
        ufw allow "$p/udp" comment "$label" >/dev/null 2>&1
        ok "открыт $p/tcp и $p/udp — «$label»"
    else
        if ufw allow "$p/$proto" comment "$label" >/dev/null 2>&1; then
            ok "открыт $p/$proto — «$label»"
        else
            warn "ufw не принял правило"
        fi
    fi
    say ""
    ufw status 2>/dev/null | grep -E "^${p}(/| )" | sed 's/^/  /' || true
    pause
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
    "$CERT_SYNC" | sed 's/^/  /'
    if [ ! -s "$HY_CERT/fullchain.crt" ]; then
        err "сертификат не найден — selfsteal ещё не выпустил (проверьте: docker logs selfsteal)"
        pause
        return 1
    fi
    if have ufw; then
        ufw allow "$CONNECT_PORT/udp" comment "hysteria2 QUIC $CONNECT_PORT" >/dev/null 2>&1 || true
        ok "UDP/$CONNECT_PORT открыт в ufw"
    fi
    set_answer HYSTERIA yes
    HYSTERIA="yes"
    if cfg_run generate; then
        cfg_run brief
    fi
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
    set_answer HYSTERIA no
    HYSTERIA="no"
    cfg_run generate >/dev/null 2>&1 || true
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
    "$CERT_SYNC" | sed 's/^/  /'
    if [ -s "$HY_CERT/fullchain.crt" ]; then
        ok "сертификат на месте: $HY_CERT/{fullchain.crt,private.key}"
    else
        warn "сертификата нет — Caddy ещё не выпустил или домен не тот"
    fi
    pause
}

hy_core() {
    hdr "Hysteria2: обновление ядра (Xray в ноде)"
    say "  сейчас: $(node_xray_version)"
    if [ "$NODEGO_CLI" = false ]; then
        confirm "обновить Docker-образ ноды до latest (с откатом при сбое)?" "y" || return 0
    fi
    if [ -x /usr/local/sbin/rw-node-update.sh ]; then
        /usr/local/sbin/rw-node-update.sh | sed 's/^/  /'
    else
        ( cd "$NODE_DIR" && docker compose pull -q && docker compose up -d ) 2>&1 | sed 's/^/  /'
    fi
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
        certsync) load_conf; "$CERT_SYNC" ;;
        preset)
            load_conf
            load_templates
            if [ $# -lt 2 ]; then
                err "укажите имя шаблона: ${TEMPLATE_KEYS[*]}"
                exit 1
            fi
            tmp="$(mktemp)"
            if curl -fsSL --retry 2 "$TEMPLATES_BASE/$2/index.html" -o "$tmp"; then
                mkdir -p "$SELFSTEAL_DIR/html"
                cp "$tmp" "$SELFSTEAL_DIR/html/index.html"
                rm -f "$tmp"
                set_answer TEMPLATE "$2"
                docker restart selfsteal >/dev/null 2>&1 || true
                ok "шаблон «$2» применён"
            else
                rm -f "$tmp"
                err "не удалось скачать шаблон «$2»"
                exit 1
            fi
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
            say "  nodego hysteria ...    status | on | off | cert | core | test"
            say "  nodego preset <имя>    сменить сайт-заглушку"
            say "  nodego doctor          диагностика (7 проверок)"
            say "  nodego backup          бэкап конфигов"
            say "  nodego restore <файл>  восстановление из бэкапа"
            say "  nodego alerts          статус алертов"
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
    exit 0
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
        0|q|Q|"") say ""; dim "выход"; exit 0 ;;
        *) warn "нет такого пункта" ;;
    esac
    load_conf
done
