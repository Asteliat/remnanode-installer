"""Регрессии nodego: настоящие функции, команды и пути только в песочнице."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "nodego.sh").read_text(encoding="utf-8")
BASH = os.environ.get("TEST_BASH") or (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) [({].*?^[})]\s*$", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError("Функция не найдена: " + name)
    return match.group(0)


BASE = r'''
set -uo pipefail
cd "$TEST_ROOT" || exit 99
ROOT=$PWD
mkdir -p "$ROOT/tmp" "$ROOT/state" "$ROOT/etc/cloud/cloud.cfg.d" "$ROOT/etc/systemd/resolved.conf.d" "$ROOT/bin"
STATE_DIR="$ROOT/state"
NODE_DIR="$ROOT/node"
SELFSTEAL_DIR="$ROOT/caddy"
UPDATE_LOG="$ROOT/update.log"
HY_CERT="$ROOT/cert"
CERT_SYNC="$ROOT/bin/cert-sync"
C_BLD= C_OFF= C_DIM=
NODEGO_CLI=true
USE_SELFSTEAL=no
HYSTERIA=no
CONNECT_PORT=443
RAW_BASE=https://invalid.test
say() { echo "$*"; }
hdr() { :; }
dim() { :; }
note() { :; }
warn() { echo "WARN $*"; }
err() { echo "ERROR $*"; }
ok() { echo "OK $*"; }
load_conf() { :; }
need_root() { :; }
confirm() { return 0; }
sleep() { :; }
# Не допускаем реального обращения к сети, контейнерам и пакетному менеджеру.
curl() { echo 'unexpected curl' >&2; return 97; }
wget() { echo 'unexpected wget' >&2; return 97; }
apt-get() { echo 'unexpected apt-get' >&2; return 97; }
docker() { return 19; }
systemctl() { return 19; }
resolvectl() { return 19; }
ufw() { return 19; }
sysbench() { return 19; }
getent() { return 19; }
set_answer() { printf '%s=%s\n' "$1" "$2" >> "$ROOT/answers.log"; }
'''

DNS_MOCK = r'''
# dns_path заменяет только карту путей, сама транзакция остаётся исходной.
dns_path() {
    case "$1" in
        resolved.conf) echo "$ROOT/etc/systemd/resolved.conf" ;;
        resolv.conf) echo "$ROOT/etc/resolv.conf" ;;
        cloud.conf) echo "$ROOT/etc/cloud/cloud.cfg.d/99-remnawave-resolv.cfg" ;;
        adguard.conf) echo "$ROOT/etc/systemd/resolved.conf.d/99-adguard-dot.conf" ;;
        *) return 1 ;;
    esac
}
printf 'disabled\n' > "$ROOT/enabled"
printf 'inactive\n' > "$ROOT/active"
printf 'nameserver 192.0.2.53\n' > "$(dns_path resolv.conf)"
printf '[Resolve]\nDNS=192.0.2.53\n' > "$(dns_path resolved.conf)"
printf 'old cloud settings\n' > "$(dns_path cloud.conf)"
systemctl() {
    echo "$*" >> "$ROOT/systemctl.log"
    if [ "${FAIL:-}" = "$1" ] && [ ! -e "$ROOT/failed" ]; then touch "$ROOT/failed"; return 23; fi
    case "$1" in
        is-enabled) cat "$ROOT/enabled" ;;
        is-active) if [ "${2:-}" = --quiet ]; then grep -qx active "$ROOT/active"; else cat "$ROOT/active"; fi ;;
        enable) echo enabled > "$ROOT/enabled" ;;
        disable) echo disabled > "$ROOT/enabled" ;;
        restart) echo active > "$ROOT/active" ;;
        stop) echo inactive > "$ROOT/active" ;;
        *) return 97 ;;
    esac
}
resolvectl() { [ "${FAIL:-}" != resolvectl ]; }
getent() { [ "${FAIL:-}" != dns ]; }
# timeout запускает только заглушки; настоящий DNS не вызывается.
timeout() { shift; "$@"; }
# Git Bash не обязан уметь создавать симлинки; замену здесь моделируем файлом.
ln() {
    [ "${FAIL:-}" != ln ] || return 24
    printf 'stub resolver\n' > "${@: -1}"
}
'''


@unittest.skipUnless(BASH, "Нужен Bash")
class NodegoTests(unittest.TestCase):
    def run_shell(self, names, body, args=(), main=False):
        code = BASE + "\n" + function("pause") + "\n"
        for name in names:
            code += function(name) + "\n"
        # Перенаправляем фиксированные пути внешних скриптов до их запуска.
        code = code.replace("/usr/local/sbin/", "$ROOT/bin/")
        code = code.replace("/tmp/nodego-checks.XXXXXXXXXX", "$ROOT/tmp/nodego-checks.XXXXXXXXXX")
        code += body + "\n"
        if main:
            code += SOURCE.split("# ------------------------------------------------------------------- главное\n", 1)[1].split("\nwhile true; do", 1)[0]
        with tempfile.TemporaryDirectory(prefix="nodego-test-") as tmp:
            env = dict(os.environ, TEST_ROOT=Path(tmp).as_posix())
            result = subprocess.run([BASH, "--noprofile", "--norc", "-s", "--", *args], input=code,
                                    text=True, encoding="utf-8", errors="replace", capture_output=True, env=env, timeout=20)
        return result

    def assert_shell(self, names, body, expected=0, **kwargs):
        result = self.run_shell(names, body, **kwargs)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_main_propagates_cli_errors(self):
        for command in ("update", "restore", "backup", "doctor", "hysteria", "swap"):
            with self.subTest(command=command):
                self.assert_shell(["cli"], r'''
for name in rw-node-update.sh rw-backup.sh rw-healthcheck.sh; do
 printf '#!/usr/bin/env bash\nexit 37\n' > "$ROOT/bin/$name"
 chmod +x "$ROOT/bin/$name"
done
cli_hysteria() { return 37; }
cli_swap() { return 37; }
''', 37, args=(command, "test"), main=True)

    def test_dns_cli_dispatch_and_failure(self):
        for mode in ("on", "off"):
            with self.subTest(mode=mode):
                self.assert_shell(["cli"], 'dns_change() { [ "$1" = "' + mode + '" ] || return 98; return 27; }',
                                  27, args=("dns", mode), main=True)
        self.assert_shell(["cli"], "dns_change() { return 98; }", 1, args=("dns",), main=True)
        self.assert_shell(["cli"], "dns_change() { return 98; }", 1, args=("dns", "unknown"), main=True)

    def test_main_success_and_unknown(self):
        self.assert_shell(["cli"], "", args=("--help",), main=True)
        self.assert_shell(["cli"], "", 1, args=("no-such-command",), main=True)

    def test_pause_preserves_error(self):
        self.assert_shell([], "(exit 29); pause", 29)

    def test_check_private_cleanup_and_status(self):
        self.assert_shell(["check_run"], r'''
ensure_pkgs() { return 0; }
check_dl() {
    echo "$(dirname "$2")" >> "$ROOT/paths"
    [ "$(stat -c %a "$(dirname "$2")")" = 700 ] || return 89
    printf '#!/usr/bin/env bash\nexit 31\n' > "$2"
}
check_run https://invalid.test/../../evil; rc=$?
[ "$rc" = 31 ] || exit 80
check_run https://invalid.test/../../evil; rc=$?
[ "$rc" = 31 ] || exit 81
[ "$(sort -u "$ROOT/paths" | wc -l)" = 2 ] || exit 82
while read -r path; do [ ! -e "$path" ] || exit 83; done < "$ROOT/paths"
''')

    def test_check_download_failure_cleanup(self):
        self.assert_shell(["check_run"], r'''
ensure_pkgs() { return 0; }
check_dl() { echo "$(dirname "$2")" > "$ROOT/path"; return 1; }
check_run https://invalid.test/check; rc=$?
[ "$rc" = 1 ] && [ ! -e "$(cat "$ROOT/path")" ]
''')

    def test_check_signal_cleanup(self):
        self.assert_shell(["check_run"], r'''
ensure_pkgs() { return 0; }
check_dl() {
 echo "$(dirname "$2")" > "$ROOT/path"
 printf '#!/usr/bin/env bash\nkill -TERM "$PPID"\n' > "$2"
}
check_run https://invalid.test/check; rc=$?
[ "$rc" = 143 ] && [ ! -e "$(cat "$ROOT/path")" ]
''')

    def test_wrapped_checks_propagate_errors(self):
        for name in ("check_ip", "check_region", "check_bench_ru", "check_bench_world", "check_yabs", "check_instagram", "check_dpi", "check_cpu", "check_quick"):
            with self.subTest(name=name):
                self.assert_shell([name], 'check_head() { :; }; check_run() { return 32; }; sysbench_cpu() { return 32; }; outbound_check() { :; }; ' + name, 32)

    def test_sysbench_failure(self):
        self.assert_shell(["sysbench_cpu"], "ensure_pkgs() { :; }; sysbench_cpu", 19)

    def test_update_wrapper_failure(self):
        self.assert_shell(["update_now"], r'''
printf '#!/usr/bin/env bash\nexit 34\n' > "$ROOT/bin/rw-node-update.sh"
chmod +x "$ROOT/bin/rw-node-update.sh"
update_now
''', 34)

    def test_restore_wrapper_failure(self):
        self.assert_shell(["restore_menu"], r'''
printf '#!/usr/bin/env bash\nexit 35\n' > "$ROOT/bin/rw-backup.sh"
chmod +x "$ROOT/bin/rw-backup.sh"
touch "$ROOT/archive.tar.gz"
ls() { echo "$ROOT/archive.tar.gz"; }
restore_menu <<<'1'
''', 1)

    def test_restore_restart_failure(self):
        self.assert_shell(["restore_menu"], r'''
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/rw-backup.sh"
chmod +x "$ROOT/bin/rw-backup.sh"
touch "$ROOT/archive.tar.gz"
ls() { echo "$ROOT/archive.tar.gz"; }
restore_menu <<<'1'
''', 1)

    def test_restart_failure_not_hidden_by_running(self):
        self.assert_shell(["restart_node"], 'mkdir "$NODE_DIR"; touch "$NODE_DIR/docker-compose.yml"; node_running() { :; }; restart_node', 1)

    def test_hysteria_wrappers_failure(self):
        self.assert_shell(["hy_test"], "cfg_run() { return 25; }; hy_test", 1)
        self.assert_shell(["hy_core"], "node_xray_version() { :; }; hy_core", 1)

    def test_swap_propagates_script_failure(self):
        self.assert_shell(["swap_apply", "cli_swap"], r'''
mktemp() { command mktemp "$ROOT/tmp/swap.XXXXXXXX"; }
curl() { printf '#!/usr/bin/env bash\nexit 36\n' > "${@: -1}"; }
cli_swap 1G; rc=$?
[ "$rc" = 36 ] || exit 88
[ -z "$(ls -A "$ROOT/tmp")" ]
''')

    def test_firewall_both_source_and_failures(self):
        for source in ("192.0.2.4", ""):
            for fail in ("", "udp"):
                with self.subTest(source=source, fail=fail):
                    self.assert_shell(["ports_add", "is_port", "is_ipv4"], r'''
have() { return 0; }
ufw() { [ "$1" = status ] && return 0; echo "$*" >> "$ROOT/ufw.log"; case "$*" in *udp*) [ -z "$FAIL" ] ;; *) return 0 ;; esac; }
FAIL=''' + repr(fail) + r'''
ports_add <<'INPUT'
8443
both
''' + source + r'''
regression
INPUT
rc=$?
[ "$rc" = ''' + ("1" if fail else "0") + r''' ] || exit 81
[ "$(wc -l < "$ROOT/ufw.log")" = 2 ] || exit 82
! grep -q 'proto both' "$ROOT/ufw.log" || exit 83
grep -q tcp "$ROOT/ufw.log" && grep -q udp "$ROOT/ufw.log"
''')

    def test_autoupdate_failure_does_not_persist(self):
        self.assert_shell(["toggle_autoupdate"], r'''
systemctl() { case "$1" in cat|is-enabled) return 0 ;; *) return 29 ;; esac; }
toggle_autoupdate; rc=$?
[ "$rc" = 1 ] && [ ! -e "$ROOT/answers.log" ]
''')

    def dns(self, body):
        return self.assert_shell(["dns_snapshot", "dns_restore", "dns_probe", "dns_change"], DNS_MOCK + body)

    def test_dns_roundtrip_restores_files_and_service(self):
        self.dns(r'''
dns_change on || exit 80
grep -q 'USE_DNS=yes' "$ROOT/answers.log" || exit 81
[ -f "$STATE_DIR/dns-backup/complete" ] || exit 82
dns_change off || exit 83
grep -qx 'nameserver 192.0.2.53' "$(dns_path resolv.conf)" || exit 84
grep -qx 'DNS=192.0.2.53' "$(dns_path resolved.conf)" || exit 85
grep -qx 'old cloud settings' "$(dns_path cloud.conf)" || exit 86
[ ! -e "$(dns_path adguard.conf)" ] && [ ! -e "$STATE_DIR/dns-backup" ] || exit 87
grep -qx inactive "$ROOT/active" && grep -qx disabled "$ROOT/enabled"
''')

    def test_dns_enable_failures_restore_original(self):
        for fail in ("enable", "restart", "resolvectl", "ln", "dns"):
            with self.subTest(fail=fail):
                self.dns("FAIL=" + fail + r'''
dns_change on; rc=$?
[ "$rc" != 0 ] || exit 80
[ ! -e "$ROOT/answers.log" ] || exit 81
grep -qx 'nameserver 192.0.2.53' "$(dns_path resolv.conf)" || exit 82
[ ! -e "$(dns_path adguard.conf)" ] || exit 83
[ ! -e "$STATE_DIR/dns-lock" ] || exit 84
grep -qx inactive "$ROOT/active" && grep -qx disabled "$ROOT/enabled"
''')

    def test_dns_disable_failure_rolls_back_and_keeps_snapshot(self):
        self.dns(r'''
dns_change on || exit 80
FAIL=dns
dns_change off; rc=$?
[ "$rc" != 0 ] || exit 81
[ -e "$(dns_path adguard.conf)" ] && [ -f "$STATE_DIR/dns-backup/complete" ] || exit 82
! grep -q 'USE_DNS=no' "$ROOT/answers.log" || exit 83
grep -qx active "$ROOT/active"
''')

    def test_legacy_dns_refuses_destructive_restore(self):
        self.dns(r'''
printf 'legacy\n' > "$(dns_path adguard.conf)"
dns_change off; rc=$?
[ "$rc" != 0 ] && grep -qx legacy "$(dns_path adguard.conf)" && [ ! -e "$ROOT/answers.log" ]
''')

    def test_dns_repeated_enable_preserves_original_snapshot(self):
        self.dns(r'''
dns_change on || exit 80
dns_change on; rc=$?
[ "$rc" != 0 ] || exit 81
grep -qx 'nameserver 192.0.2.53' "$STATE_DIR/dns-backup/resolv.conf"
''')

    @unittest.skipIf(os.name == "nt", "Настоящие симлинки и POSIX-права проверяются в Linux CI")
    def test_dns_real_symlink_and_permissions(self):
        self.dns(r'''
unset -f ln
rm -f "$(dns_path resolv.conf)"
printf 'nameserver 192.0.2.53\n' > "$ROOT/original-resolver"
ln -s "$ROOT/original-resolver" "$(dns_path resolv.conf)"
dns_change on || exit 80
[ "$(stat -c %a "$STATE_DIR/dns-backup")" = 700 ] || exit 81
dns_change off || exit 82
[ -L "$(dns_path resolv.conf)" ] || exit 83
[ "$(readlink "$(dns_path resolv.conf)")" = "$ROOT/original-resolver" ] || exit 84
grep -qx 'nameserver 192.0.2.53' "$ROOT/original-resolver"
''')


    def test_net_dual_rejects_non_host_ip(self):
        prelude = r'''
MODE=single; IP1=192.0.2.10; IP2=""; BIND_IP=0.0.0.0; IFACE=""; GW=""
NET_ENV=$ROOT/state/net.env
iface_for_ip() { echo eth0; }
default_iface() { echo eth0; }
default_gw() { echo 192.0.2.1; }
apply_net() { echo applied >> "$ROOT/applied.log"; }
is_host_ipv4 198.51.100.5 || exit 80
is_host_ipv4 10.0.0.1 || exit 81
! is_host_ipv4 198.51.100.5/24 || exit 82
! is_host_ipv4 0.0.0.0 || exit 83
! is_host_ipv4 255.255.255.255 || exit 84
! is_host_ipv4 01.2.3.4 || exit 85
net_dual_enable <<'INPUT'
'''
        invalid = r'''
INPUT
rc=$?
[ "$rc" -ne 0 ] || exit 86
[ -z "${IP2:-}" ] || exit 87
[ ! -e "$ROOT/applied.log" ] || exit 88
[ ! -e "$NET_ENV" ] || exit 89
'''
        for ip in ("198.51.100.5/24", "0.0.0.0", "255.255.255.255", "001.2.3.4"):
            with self.subTest(ip=ip):
                result = self.run_shell(["is_host_ipv4", "ask", "net_dual_enable"], prelude + ip + invalid)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("адрес хоста", result.stdout)
        accepted = prelude + "198.51.100.50" + r'''
INPUT
rc=$?
[ "$rc" = 0 ] || exit 86
[ "$IP2" = 198.51.100.50 ] || exit 87
[ -e "$ROOT/applied.log" ] || exit 88
'''
        result = self.run_shell(["is_host_ipv4", "ask", "net_dual_enable"], accepted)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_preset_copy_failure_not_reported_success(self):
        failure = r'''
SELFSTEAL_DIR=$ROOT/caddy
TEMPLATES_BASE=https://invalid.test
mkdir -p "$SELFSTEAL_DIR"
: > "$SELFSTEAL_DIR/html"
load_templates() { TEMPLATE_KEYS=(shop); TEMPLATE_DESCS=("магазин керамики"); }
curl() { printf '<html>new</html>' > "${@: -1}"; }
docker() { return 0; }
change_preset <<'INPUT'
1
INPUT
rc=$?
[ "$rc" -ne 0 ] || exit 80
[ ! -e "$ROOT/answers.log" ] || exit 81
[ -f "$SELFSTEAL_DIR/html" ] || exit 82
'''
        result = self.run_shell(["change_preset"], failure)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("OK", result.stdout)

        success = r'''
SELFSTEAL_DIR=$ROOT/caddy
TEMPLATES_BASE=https://invalid.test
mkdir -p "$SELFSTEAL_DIR"
load_templates() { TEMPLATE_KEYS=(shop); TEMPLATE_DESCS=("магазин керамики"); }
curl() { printf '<html>new</html>' > "${@: -1}"; }
docker() { return 0; }
change_preset <<'INPUT'
1
INPUT
[ "$TEMPLATE" = shop ] || exit 80
[ -f "$SELFSTEAL_DIR/html/index.html" ] || exit 81
grep -qx 'TEMPLATE=shop' "$ROOT/answers.log" || exit 82
'''
        self.assert_shell(["change_preset"], success)

    def test_set_answer_quote_roundtrip(self):
        self.assert_shell(["env_quote", "sed_repl", "set_answer"], r'''
ANSWERS=$ROOT/state/answers.env
printf "TG_CHAT='старое'\nIP1='192.0.2.10'\n" > "$ANSWERS"
val="a'b c&d|e\\f"
set_answer TG_CHAT "$val" || exit 80
set_answer IP1 192.0.2.11 || exit 81
nl="первая
вторая"
set_answer TG_TOKEN "$nl" || exit 82
set_answer TEMPLATE "x'; EVIL=1; #" || exit 83
set_answer TG_CHAT "$nl" || exit 84
( . "$ANSWERS"
  [ "$TG_CHAT" = "$nl" ] || exit 85
  [ "$IP1" = 192.0.2.11 ] || exit 86
  [ "$TG_TOKEN" = "$nl" ] || exit 87
  [ "$TEMPLATE" = "x'; EVIL=1; #" ] || exit 88
  [ -z "${EVIL:-}" ] || exit 89
) || exit 90
''')

    def test_alerts_env_quote_roundtrip(self):
        self.assert_shell(["env_quote", "write_alerts_env"], r'''
STATE_DIR=$ROOT/state; ALERTS_ENV=$ROOT/state/alerts.env
ALERTS=yes
TG_TOKEN="123:AA'&|\\bar"
TG_CHAT="x'y
z"
write_alerts_env || exit 80
( . "$ALERTS_ENV"
  [ "$ALERTS" = yes ] || exit 81
  [ "$TG_TOKEN" = "123:AA'&|\\bar" ] || exit 82
  [ "$TG_CHAT" = "x'y
z" ] || exit 83
) || exit 84
''')

    def test_net_env_invalid_ip2_resets_scheme(self):
        result = self.run_shell(["is_host_ipv4", "load_conf"], r'''
STATE_DIR=$ROOT/state; ANSWERS=$ROOT/state/answers.env
NET_ENV=$ROOT/state/net.env; ALERTS_ENV=$ROOT/state/alerts.env
printf "MODE=dual\nIP1=192.0.2.10\nIP2=198.51.100.5/24\n" > "$NET_ENV"
load_conf
[ "$MODE" = single ] || exit 80
[ -z "$IP2" ] || exit 81
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("некорректный IP2", result.stdout)

    def test_restore_index_is_decimal(self):
        body = r'''
confirm() { return 1; }
du() { echo 1M; }
ls() { i=1; while [ "$i" -le 12 ]; do printf '/var/backups/remnanode/remnanode-%02d.tar.gz\n' "$i"; i=$((i+1)); done; }
restore_menu <<'INPUT'
'''
        for choice, expected in (("010", "remnanode-10.tar.gz"), ("08", "remnanode-08.tar.gz"),
                                 ("12", "remnanode-12.tar.gz")):
            with self.subTest(choice=choice):
                result = self.run_shell(["restore_menu"], body + choice + "\nINPUT\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("перезаписаны из " + expected, result.stdout)

    def test_preset_index_is_decimal(self):
        body = r'''
SELFSTEAL_DIR=$ROOT/caddy
TEMPLATES_BASE=https://invalid.test
mkdir -p "$SELFSTEAL_DIR"
load_templates() {
    TEMPLATE_KEYS=(); TEMPLATE_DESCS=()
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do TEMPLATE_KEYS+=("k$i"); TEMPLATE_DESCS+=("d$i"); done
}
curl() { printf '<html>new</html>' > "${@: -1}"; }
docker() { return 0; }
change_preset <<'INPUT'
'''
        for choice, expected in (("010", "k10"), ("08", "k08")):
            with self.subTest(choice=choice):
                tail = "\nINPUT\n[ \"$TEMPLATE\" = " + expected + " ] || exit 80\n"
                tail += "grep -qx 'TEMPLATE=" + expected + "' \"$ROOT/answers.log\" || exit 81\n"
                result = self.run_shell(["change_preset"], body + choice + tail)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hy_enable_generate_failure_rolls_back(self):
        result = self.run_shell(["env_quote", "sed_repl", "set_answer", "hy_enable"], r'''
ANSWERS=$ROOT/state/answers.env
printf "HYSTERIA='no'\n" > "$ANSWERS"
USE_SELFSTEAL=yes; DOMAIN=node.example.com
mkdir -p "$ROOT/bin" "$HY_CERT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CERT_SYNC"; chmod +x "$CERT_SYNC"
printf 'cert' > "$HY_CERT/fullchain.crt"; printf 'key' > "$HY_CERT/private.key"
have() { return 1; }
cfg_run() { return 26; }
hy_enable
rc=$?
[ "$rc" -ne 0 ] || exit 80
[ "$HYSTERIA" = no ] || exit 81
( . "$ANSWERS"; [ "$HYSTERIA" = no ] ) || exit 82
! grep -q 'HYSTERIA=yes' "$ANSWERS" || exit 83
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ERROR", result.stdout)

    def test_hy_disable_set_answer_failure_is_error(self):
        result = self.run_shell(["hy_disable"], r'''
HYSTERIA=yes; CONNECT_PORT=443; ANSWERS=$ROOT/state/answers.env
have() { return 1; }
cfg_run() { return 0; }
set_answer() { return 33; }
hy_disable
rc=$?
[ "$rc" -ne 0 ] || exit 80
[ "$HYSTERIA" = yes ] || exit 81
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("OK", result.stdout)

    def test_doctor_propagates_healthcheck_failure(self):
        result = self.run_shell(["doctor"], r'''
printf '#!/usr/bin/env bash\necho "healthcheck report"\nexit 37\n' > "$ROOT/bin/rw-healthcheck.sh"
chmod +x "$ROOT/bin/rw-healthcheck.sh"
doctor
rc=$?
[ "$rc" = 37 ] || exit 80
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("healthcheck report", result.stdout)
        self.assertIn("ERROR", result.stdout)

    def test_logs_interrupt_not_reported_as_missing(self):
        for rc, expect_warn in ((0, False), (130, False), (143, False), (19, True)):
            with self.subTest(rc=rc):
                result = self.run_shell(["logs_node", "logs_caddy"],
                                        'docker() { return ' + str(rc) + '; }\nlogs_node\nlogs_caddy\n')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if expect_warn:
                    self.assertIn("WARN", result.stdout)
                else:
                    self.assertNotIn("WARN", result.stdout)

    def test_preset_cli_download_has_timeout(self):
        self.assert_shell(["cli"], r'''
SELFSTEAL_DIR=$ROOT/caddy
TEMPLATES_BASE=https://invalid.test
TEMPLATE_KEYS=(shop); TEMPLATE_DESCS=("магазин керамики")
load_conf() { :; }
load_templates() { :; }
curl() { printf '%s\n' "$*" >> "$ROOT/curl.args"; printf '<html>new</html>' > "${@: -1}"; }
docker() { return 0; }
cli preset shop
[ "$?" = 0 ] || exit 80
grep -q -- '--max-time' "$ROOT/curl.args" || exit 81
grep -q -- '--connect-timeout' "$ROOT/curl.args" || exit 82
grep -qx 'TEMPLATE=shop' "$ROOT/answers.log" || exit 83
''')

    def test_preset_cli_rejects_unsafe_name(self):
        self.assert_shell(["cli"], r'''
SELFSTEAL_DIR=$ROOT/caddy
TEMPLATES_BASE=https://invalid.test
load_conf() { :; }
load_templates() { :; }
curl() { printf '%s\n' "$*" >> "$ROOT/curl.args"; return 0; }
( cli preset ../evil ); rc=$?
[ "$rc" = 1 ] || exit 80
[ ! -e "$ROOT/curl.args" ] || exit 81
''')

    def test_help_lists_certsync(self):
        result = self.assert_shell(["cli"], "load_conf() { :; }\ncli --help\n")
        expected = ("status", "logs", "restart", "update", "doctor", "backup", "restore",
                    "alerts", "net", "configs", "keys", "ports", "hysteria", "dns",
                    "certsync", "swap", "preset", "check")
        for name in expected:
            with self.subTest(command=name):
                self.assertIn("nodego " + name, result.stdout)


if __name__ == "__main__":
    unittest.main()
