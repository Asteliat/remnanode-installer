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


if __name__ == "__main__":
    unittest.main()
