"""Безопасные регрессии: только извлечённые функции и mock-команды, без установки."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")
BASH = os.environ.get("BASH_EXE") or (
    r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")
)


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError(name)
    return match.group()


def shell(body, directory=None):
    # Запускается только переданный фрагмент, никогда не source всего install.sh.
    return subprocess.run([BASH, "--noprofile", "--norc", "-s"],
                          input="set -euo pipefail\n" + body,
                          text=True, encoding="utf-8", capture_output=True,
                          cwd=directory, timeout=20)


def dns_block():
    block = SOURCE.split('# BEGIN DNS_TRANSACTION', 1)[1].split('# END DNS_TRANSACTION', 1)[0]
    return '\n'.join(block.splitlines()[1:])


DNS_MOCKS = '''
    STATE_DIR=./state
    mkdir -p files
    printf original > files/resolved.conf
    printf provider > files/provider
    ln -s provider files/resolv.conf
    printf cloud-original > files/cloud.conf
    dns_path() { printf './files/%s\\n' "$1"; }
    systemctl() {
        case "$1" in is-enabled) echo disabled ;; is-active) echo active ;; esac
        return 0
    }
    # первый flush-caches падает — транзакция откатывается; дальше всё работает
    resolvectl() { if [ -f fail.once ]; then return 0; fi; : > fail.once; return 1; }
    getent() { return 0; }
    timeout() { shift; "$@"; }
    err() { echo "$*"; }; ok() { :; }; warn() { :; }
    set_answer() { :; }
'''


# /etc/default/ufw в тестах не пишем: подменяем только чтение этого файла,
# остальные вызовы grep уходят в настоящий grep.
UFW_POLICY_MOCK = '''
    grep() {
        case "$*" in
            *"/etc/default/ufw"*) printf '%s\n' 'DEFAULT_INPUT_POLICY="DROP"'; return 0 ;;
        esac
        command grep "$@"
    }
'''


class InstallerTests(unittest.TestCase):
    def check(self, result, success=True):
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def dns_shell(self, tail):
        body = dns_block() + DNS_MOCKS + tail
        if os.name == 'nt':
            # Git Bash без Windows Developer Mode эмулирует ln копированием.
            body = (body
                    .replace('ln -s provider files/resolv.conf', 'cp files/provider files/resolv.conf')
                    .replace('ln -sfn /run/systemd/resolve/stub-resolv.conf "$(dns_path resolv.conf)" || return 1',
                             ': > "$(dns_path resolv.conf)" || return 1'))
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return shell(body, tmp.name)

    def test_syntax(self):
        result = subprocess.run([BASH, "-n", "install.sh"], cwd=ROOT,
                                capture_output=True, text=True)
        self.check(result)

    def test_embedded_script_syntax(self):
        for tag in ("EOS", "HEALTH_EOF", "CERT_SYNC_EOF", "CONFIGS_EOF", "SCRIPT_EOF", "BACKUP_EOF"):
            script = SOURCE.split("<<'" + tag + "'\n", 1)[1].split("\n" + tag, 1)[0]
            result = subprocess.run([BASH, "-n"], input=script, text=True,
                                    capture_output=True, encoding="utf-8")
            self.check(result)

    def test_running_and_port_both_required(self):
        for running, port, expected in (("true", True, True), ("false", True, False),
                                         ("true", False, False), ("", False, False)):
            with self.subTest(running=running, port=port):
                body = function("wait_service") + f'''
                    docker() {{ echo '{running}'; }}
                    ss() {{ {'echo LISTEN' if port else ':'}; }}
                    sleep() {{ :; }}
                    check_port_owner() {{ return 0; }}
                    wait_service remnanode 2222 3
                '''
                self.check(shell(body), expected)

    def test_node_start_error_not_masked_by_running_container(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = function("start_node") + '''
                NODE_DIR=.
                NODE_PORT=2222
                warn() { :; }
                compose() { [ "$1" != up ]; }
                wait_service() { echo 'WRONG: reached readiness'; }
                start_node
            '''
            result = shell(body, tmp)
            self.check(result, False)
            self.assertNotIn("WRONG", result.stdout)

    def test_pull_failure_can_use_local_image(self):
        body = function("start_node") + '''
            NODE_DIR=.; NODE_PORT=2222
            warn() { :; }
            compose() { [ "$1" != pull ]; }
            wait_service() { [ "$*" = 'remnanode 2222' ]; }
            start_node
        '''
        self.check(shell(body))

    def test_caddy_invalid_configuration_never_starts(self):
        body = function("start_caddy") + '''
            SELFSTEAL_DIR=.; SELFSTEAL_PORT=9443
            compose() { echo "$*"; [ "$1" != run ]; }
            wait_service() { echo WRONG; }
            start_caddy
        '''
        result = shell(body)
        self.check(result, False)
        self.assertNotIn("up -d", result.stdout)
        self.assertNotIn("WRONG", result.stdout)

    def test_caddy_up_failure_is_fatal(self):
        body = function("start_caddy") + '''
            SELFSTEAL_DIR=.; SELFSTEAL_PORT=9443
            compose() { [ "$1" != up ]; }
            docker() { :; }
            wait_service() { echo WRONG; }
            start_caddy
        '''
        result = shell(body)
        self.check(result, False)
        self.assertNotIn("WRONG", result.stdout)

    def test_port_ownership(self):
        for listeners, allowed in (("", True), ('LISTEN users:(("caddy",pid=42,fd=1))', True),
                                   ('LISTEN users:(("nginx",pid=43,fd=1))', False),
                                   ('LISTEN users:(("caddy",pid=42,fd=1),("other",pid=43,fd=2))', False),
                                   ("LISTEN no-owner", False)):
            with self.subTest(listeners=listeners):
                body = function("check_port_owner") + f'''
                    ss() {{ printf '%s' '{listeners}'; }}
                    docker() {{ printf 'PID\\n42\\n'; }}
                    check_port_owner 80 selfsteal
                '''
                self.check(shell(body), allowed)

    def test_ufw_prior_broad_rules_are_not_panel_only(self):
        cases = (("", True), ("ufw allow 443/tcp", True),
                 ("ufw allow from 1.2.3.4 to any port 2222 proto tcp", True),
                 ("ufw allow 2222/tcp", False), ("ufw allow 2200:2300/tcp", False),
                 ("ufw allow from 9.9.9.9 to any port 2222 proto tcp", False),
                 ("ufw allow SomeApp", False), ("ufw allow 80,2222/tcp", False))
        for rules, allowed in cases:
            with self.subTest(rules=rules):
                body = function("check_api_firewall") + UFW_POLICY_MOCK + f'''
                    NODE_PORT=2222; PANEL_IP=1.2.3.4
                    ufw() {{ printf '%s\\n' '{rules}'; }}
                    warn() {{ echo "$*"; }}
                    check_api_firewall
                '''
                self.check(shell(body), allowed)

    def test_existing_caddy_stack_byte_preserved(self):
        section = SOURCE.split('    hdr "9. Caddy selfsteal"', 1)[1]
        section = section.split('    # --- DNS-проверка', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = {"Caddyfile": "# custom\n(extra) {\n respond 204\n}\nimport sites/*\n",
                     "docker-compose.yml": "custom mounts\n", ".env": "custom env\n",
                     "html/index.html": "original site"}
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            result = shell('SELFSTEAL_DIR=.\n' + section, tmp)
            self.check(result)
            for name, content in files.items():
                self.assertEqual((root / name).read_text(encoding="utf-8"), content)

    def test_disable_prior_timer(self):
        branch = SOURCE.split('    if systemctl cat rw-node-update.timer', 1)[1]
        branch = 'if systemctl cat rw-node-update.timer' + branch.split('\nfi', 1)[0]
        result = shell('systemctl() { echo "$*"; }; note() { :; }; die() { exit 1; };\n' + branch)
        self.check(result)
        # stdout of systemctl is suppressed; verify the actual command is present.
        self.assertIn('disable --now rw-node-update.timer', branch)

    def test_upgrade_opt_in_and_no_global_prune(self):
        self.assertIn('UPGRADE_SYSTEM=false', SOURCE)
        self.assertRegex(SOURCE, r'if \[ "\$UPGRADE_SYSTEM" = true \]; then\n    apt-get upgrade')
        self.assertNotIn('docker image prune', SOURCE)

    def test_update_failed_health_rolls_back_and_returns_failure(self):
        script = SOURCE.split("<<'EOS'\n", 1)[1].split('\nEOS', 1)[0]
        script = script.replace('DIR=/opt/remnanode', 'DIR=.').replace('LOG=/var/log/remnawave-update.log', 'LOG=./update.log')
        mocks = '''
            docker() {
                echo "$*" >> calls
                if [ "$1" = inspect ]; then
                    case "$*" in
                        *State.Running*) echo true ;;
                        *Config.Image*) echo remnawave/node:latest ;;
                        *) echo sha256:old ;;
                    esac
                fi
            }
            ss() { :; }
            sleep() { :; }
            flock() { :; }
        '''
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, '.env').write_text('NODE_PORT=2222\n', encoding='utf-8')
            result = shell(mocks + script, tmp)
            self.check(result, False)
            calls = Path(tmp, 'calls').read_text(encoding='utf-8')
            self.assertIn('tag sha256:old remnawave/node:rollback', calls)
            self.assertIn('--pull never remnanode', calls)
            self.assertNotIn('prune', calls)
            self.assertIn('откат не восстановил API', result.stdout)

    def test_ufw_openssh_profile_ports_checked(self):
        for port, allowed in ((22, True), (2222, False)):
            body = function('check_api_firewall') + UFW_POLICY_MOCK + f'''
                NODE_PORT=2222; PANEL_IP=1.2.3.4
                ufw() {{
                    if [ "$1" = show ]; then echo 'ufw allow OpenSSH';
                    else printf 'Profile: OpenSSH\\nPort:\\n  {port}/tcp\\n'; fi
                }}
                warn() {{ :; }}
                check_api_firewall
            '''
            self.check(shell(body), allowed)

    def test_dns_failure_restores_files_and_symlink(self):
        block = SOURCE.split('# BEGIN DNS_TRANSACTION', 1)[1].split('# END DNS_TRANSACTION', 1)[0]
        block = '\n'.join(block.splitlines()[1:])
        body = block + '''
            STATE_DIR=./state
            mkdir -p files
            printf original > files/resolved.conf
            printf provider > files/provider
            ln -s provider files/resolv.conf
            printf cloud-original > files/cloud.conf
            dns_path() { printf './files/%s\\n' "$1"; }
            systemctl() {
                case "$1" in is-enabled) echo disabled ;; is-active) echo active ;; esac
                return 0
            }
            resolvectl() { return 1; }
            getent() { return 0; }
            timeout() { shift; "$@"; }
            err() { echo "$*"; }; ok() { :; }; warn() { :; }
            set_answer() { echo WRONG; }
            if dns_change on; then exit 2; fi
            [ "$(cat files/resolved.conf)" = original ]
            [ "$(cat files/cloud.conf)" = cloud-original ]
            [ "$(readlink files/resolv.conf)" = provider ]
            [ ! -e files/adguard.conf ]
            [ -f state/dns-backup/complete ]
            [ ! -d state/dns-lock ]
        '''
        if os.name == 'nt':
            # Git Bash без Windows Developer Mode эмулирует ln копированием.
            body = body.replace('ln -s provider files/resolv.conf', 'cp files/provider files/resolv.conf')
            body = body.replace('[ "$(readlink files/resolv.conf)" = provider ]', '[ "$(cat files/resolv.conf)" = provider ]')
        with tempfile.TemporaryDirectory() as tmp:
            result = shell(body, tmp)
            self.check(result)
            self.assertNotIn('WRONG', result.stdout)

    def test_dns_retry_after_failed_enable_is_allowed(self):
        # Неудачное включение уже откатило файлы trap'ом; повторный запуск не
        # должен упираться в оставшийся полный снимок (раньше — «DNS уже настроен»).
        result = self.dns_shell('''
            if dns_change on; then exit 2; fi
            [ "$(cat files/resolved.conf)" = original ] || exit 4
            [ ! -e files/adguard.conf ] || exit 5
            dns_change on || exit 3
            [ -f files/adguard.conf ]
        ''')
        self.check(result)

    def test_dns_retry_refused_when_files_differ(self):
        # Если после сбоя файлы меняли руками, снимок НЕ переиспользуется:
        # ручные правки не перезаписываются (cloud.conf — обычный файл в снимке).
        result = self.dns_shell('''
            if dns_change on; then exit 2; fi
            printf changed-by-admin > files/cloud.conf
            if dns_change on; then exit 3; fi
            [ "$(cat files/cloud.conf)" = changed-by-admin ]
        ''')
        self.check(result)

    def test_healthcheck_alerts_env_wins_over_answers(self):
        # alerts.env (его пишет nodego) должен читаться ПОСЛЕДНИМ: в answers.env
        # лежат ALERTS/TG_* на момент установки и иначе перекрывают настройку.
        script = SOURCE.split("<<'HEALTH_EOF'\n", 1)[1].split("\nHEALTH_EOF", 1)[0]
        preamble = script.split("\nRESULTS=()", 1)[0]
        preamble = (preamble
                    .replace('CONF=/etc/remnawave-setup/alerts.env', 'CONF=./alerts.env')
                    .replace('ANSWERS=/etc/remnawave-setup/answers.env', 'ANSWERS=./answers.env')
                    .replace('NET=/etc/remnawave-setup/net.env', 'NET=./net.env')
                    .replace('NODE_ENV=/opt/remnanode/.env', 'NODE_ENV=./node.env')
                    .replace('STATE_DIR=/var/lib/rw-healthcheck', 'STATE_DIR=./state'))
        body = preamble + '\nprintf "%s|%s|%s|%s|%s\\n" "$ALERTS" "$TG_TOKEN" "$TG_CHAT" "$MODE" "$NODE_PORT"\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'answers.env').write_text(
                "ALERTS='no'\nTG_TOKEN='111:old'\nTG_CHAT='1'\n"
                "NODE_PORT='3000'\nDOMAIN='old.example.com'\n", encoding='utf-8')
            (root / 'net.env').write_text(
                "MODE=dual\nIP1='10.0.0.1'\nIP2='10.0.0.2'\n", encoding='utf-8')
            (root / 'alerts.env').write_text(
                "ALERTS='yes'\nTG_TOKEN='222:new'\nTG_CHAT='2'\n", encoding='utf-8')
            result = shell(body, tmp)
            self.check(result)
            self.assertIn('yes|222:new|2|dual|3000', result.stdout)

    def test_node_start_rollback_restores_configuration(self):
        body = function('snapshot_node') + '\n' + function('rollback_node') + '''
            NODE_DIR="$PWD"
            printf 'NODE_PORT=3000\\n' > .env
            printf original > docker-compose.yml
            docker() { [ "$1" != inspect ] || echo sha256:old; }
            compose() { echo "$*" > calls; }
            wait_service() { [ "$*" = 'remnanode 3000' ]; }
            snapshot_node
            printf 'NODE_PORT=2222\\n' > .env
            printf changed > docker-compose.yml
            rollback_node
            [ "$(cat docker-compose.yml)" = original ]
            grep -q -- '--pull never remnanode' calls
        '''
        with tempfile.TemporaryDirectory() as tmp:
            self.check(shell(body, tmp))

    # ------------------------------------------------------------------ 2-10
    def test_secret_key_with_quote_rejected(self):
        # Ключ уходит в /opt/remnanode/.env без кавычек и раньше писался сырым
        # в answers.env: апостроф/перевод строки/пробел/#/$/\ ломают один из файлов.
        self.assertIn('SECRET_KEY=$(env_quote "$SECRET_KEY")', SOURCE)
        self.assertIn('SECRET_KEY=$SECRET_KEY', SOURCE)

        def allowed(value):
            body = function('secret_key_valid') + '\nsecret_key_valid ' + shlex.quote(value)
            return shell(body)

        self.check(allowed('0123456789abcdef'))
        for bad in ("abc'def", 'abc"def', 'abc def', 'abc#def', 'abc$def',
                    'abc\\def', 'abc\ndef'):
            with self.subTest(key=bad):
                self.check(allowed(bad), False)
        # Валидатор обязан стоять и в интерактиве, и после флагов/answers.env.
        self.assertGreaterEqual(SOURCE.count('secret_key_valid "$SECRET_KEY"'), 2)

    def test_swap_size_suffix_garbage_does_not_abort(self):
        body = function('to_mb') + r'''
            for spec in 2G 512M off 1.5G 0.5g G abcG 1,5G 1024; do
                printf '%s=<%s>\n' "$spec" "$(to_mb "$spec")"
            done
        '''
        result = shell(body)
        self.check(result)
        self.assertIn('2G=<2048>', result.stdout)
        self.assertIn('512M=<512>', result.stdout)
        self.assertIn('off=<>', result.stdout)
        self.assertIn('1024=<1024>', result.stdout)
        for bad in ('1.5G', '0.5g', 'G', 'abcG', '1,5G'):
            with self.subTest(spec=bad):
                self.assertIn(f'{bad}=<>', result.stdout)

    def ssh_firewall_section(self):
        marker = 'SSH_PORTS="$(ssh_ports || true)"'
        tail = SOURCE.split(marker, 1)[1].split('ufw --force enable', 1)[0]
        return '    ' + marker + tail + 'ufw --force enable >/dev/null'

    def test_all_ssh_ports_allowed(self):
        body = (function('ssh_ports') + '\n' + function('check_api_firewall')
                + UFW_POLICY_MOCK + r'''
            is_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
            NODE_PORT=2222; PANEL_IP=1.2.3.4; CONNECT_PORT=443; HYSTERIA=no
            USE_SELFSTEAL=no; DUAL_IP=no
            sshd() { printf 'port 22\nport 2222\n'; }
            ss() { :; }
            netstat() { :; }
            ufw() {
                case "$1" in
                    status) printf 'Status: inactive\n' ;;
                    *) printf '%s\n' "$*" >> ufw.log ;;
                esac
            }
            warn() { echo "$*"; }; note() { :; }; ok() { :; }
            die() { echo "DIE: $*"; exit 1; }
        ''' + self.ssh_firewall_section() + r'''
            grep -q 'allow 22/tcp' ufw.log
            grep -q 'allow 2222/tcp' ufw.log
            grep -q -- '--force enable' ufw.log
        ''')
        with tempfile.TemporaryDirectory() as tmp:
            result = shell(body, tmp)
            self.check(result)
            log = Path(tmp, 'ufw.log').read_text(encoding='utf-8')
            self.assertIn('allow 22/tcp', log)
            self.assertIn('allow 2222/tcp', log)

        # Ни sshd -T, ни ss/netstat не дали портов — не подставляем 22 молча,
        # а падаем до включения ufw (иначе после enable можно остаться без SSH).
        body = (function('ssh_ports') + '\n' + function('check_api_firewall')
                + UFW_POLICY_MOCK + r'''
            is_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
            NODE_PORT=2222; PANEL_IP=1.2.3.4
            sshd() { return 1; }
            ss() { :; }
            netstat() { :; }
            ufw() { case "$1" in status) printf 'Status: inactive\n' ;; *) : ;; esac; }
            warn() { echo "$*"; }; note() { :; }; ok() { :; }
            die() { echo "DIE: $*"; exit 1; }
        ''' + self.ssh_firewall_section())
        with tempfile.TemporaryDirectory() as tmp:
            result = shell(body, tmp)
            self.check(result, False)
            self.assertIn('Не удалось определить SSH-порт', result.stdout)
            self.assertFalse(Path(tmp, 'ufw.log').exists())

    def test_manual_cert_is_wired_on_existing_stack(self):
        section = SOURCE.split('    hdr "9. Caddy selfsteal"', 1)[1]
        section = section.split('    # --- DNS-проверка', 1)[0]
        ours = ("{\n\thttps_port {$SELF_STEAL_PORT}\n}\n\n"
                "https://{$SELF_STEAL_DOMAIN} {\n\tencode gzip\n}\n\n"
                ":{$SELF_STEAL_PORT} {\n\ttls internal\n\trespond 204\n}\n")
        foreign = "# чужой сайт\nexample.com {\n\trespond 200\n}\nimport sites/*\n"

        def prepare(caddyfile):
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            root = Path(tmp.name)
            (root / 'ssl').mkdir()
            (root / 'ssl/fullchain.crt').write_text('cert', encoding='utf-8')
            (root / 'ssl/private.key').write_text('key', encoding='utf-8')
            (root / 'Caddyfile').write_text(caddyfile, encoding='utf-8')
            return root

        def run(root):
            body = ('SELFSTEAL_DIR=. USE_SELFSTEAL=yes DOMAIN=node.example.com '
                    'SELFSTEAL_PORT=9443 BIND_IP=0.0.0.0\n'
                    'ok() { echo "ok $*"; }; warn() { echo "warn $*"; }; note() { :; }\n'
                    + section + 'printf "HAS_CERT=%s\\n" "$HAS_CERT"\n')
            return shell(body, str(root))

        root = prepare(ours)
        result = run(root)
        self.check(result)
        self.assertIn('HAS_CERT=true', result.stdout)
        text = (root / 'Caddyfile').read_text(encoding='utf-8')
        self.assertEqual(text.count('tls /etc/caddy/ssl/fullchain.crt'), 1)
        self.assertIn('https://{$SELF_STEAL_DOMAIN} {\n\ttls /etc/caddy/ssl/fullchain.crt', text)
        # повторный запуск не дублирует tls (grep -qF перед sed)
        result = run(root)
        self.check(result)
        text = (root / 'Caddyfile').read_text(encoding='utf-8')
        self.assertEqual(text.count('tls /etc/caddy/ssl/fullchain.crt'), 1)

        # Чужой Caddyfile не правим и честно сбрасываем HAS_CERT.
        root = prepare(foreign)
        result = run(root)
        self.check(result)
        self.assertIn('HAS_CERT=false', result.stdout)
        self.assertIn('не наш', result.stdout)
        self.assertEqual((root / 'Caddyfile').read_text(encoding='utf-8'), foreign)

    def test_ufw_default_allow_is_not_panel_only(self):
        cases = (('active', 'allow', '', False),
                 ('active', 'deny', '', True),
                 ('inactive', '', 'DROP', True),
                 ('inactive', '', 'ACCEPT', False),
                 ('inactive', '', '', False))
        for status, default, policy, allowed in cases:
            with self.subTest(status=status, default=default, policy=policy):
                body = function('check_api_firewall') + f'''
                    NODE_PORT=2222; PANEL_IP=1.2.3.4
                    ST='{status}'; DEF='{default}'; POLICY='{policy}'
                    ufw() {{
                        case "$1" in
                            status) printf 'Status: %s\\n' "$ST"
                                    [ -n "$DEF" ] && printf 'Default: %s (incoming), allow (outgoing), deny (routed)\\n' "$DEF"
                                    ;;
                            *) : ;;
                        esac
                    }}
                    grep() {{
                        case "$*" in
                            *"/etc/default/ufw"*) [ -n "$POLICY" ] || return 1
                                printf 'DEFAULT_INPUT_POLICY="%s"\\n' "$POLICY" \
                                    | command grep "${{@:1:$#-1}}"; return ;;
                        esac
                        command grep "$@"
                    }}
                    warn() {{ echo "$*"; }}
                    check_api_firewall
                '''
                self.check(shell(body), allowed)

    def test_configs_default_uses_selfsteal(self):
        configs = SOURCE.split("<<'CONFIGS_EOF'\n", 1)[1].split("\nCONFIGS_EOF", 1)[0]
        match = re.search(r"^load_conf\(\) \{.*?^\}", configs, re.M | re.S)
        self.assertIsNotNone(match)
        body = r'''
            ANSWERS=./answers.env
            APL_TARGET="www.apple.com:443"
            APL_NAMES='"www.apple.com", "apple.com"'
        ''' + match.group() + r'''
            load_conf
            printf '%s|%s\n' "$REALITY_TARGET" "$SNI"
        '''
        cases = (
            # старый answers.env без USE_SELFSTEAL — наш пресет selfsteal
            ("CONNECT_PORT='443'\nDOMAIN='node.example.com'\nSELFSTEAL_PORT='9443'\n",
             '127.0.0.1:9443|node.example.com'),
            # явное «no» в answers.env по-прежнему главнее дефолта
            ("CONNECT_PORT='443'\nUSE_SELFSTEAL='no'\nDOMAIN='node.example.com'\n",
             'www.apple.com:443|www.apple.com'),
        )
        for content, expected in cases:
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory() as tmp:
                    Path(tmp, 'answers.env').write_text(content, encoding='utf-8')
                    result = shell(body, tmp)
                    self.check(result)
                    self.assertIn(expected, result.stdout)

    def test_help_lists_negative_flags(self):
        usage = SOURCE.split("cat <<'USAGE'\n", 1)[1].split("\nUSAGE", 1)[0]
        parser = SOURCE.split('while [[ $# -gt 0 ]]; do', 1)[1].split('\ndone', 1)[0]
        for flag in ('--no-selfsteal', '--no-dns', '--no-autoupdate', '--no-alerts', '--dual-ip'):
            with self.subTest(flag=flag):
                self.assertIn(flag, usage)
                # флаг действительно принимается парсером, а не только в справке
                self.assertIn(flag, parser)

    def test_secondary_ip_touches_only_own_rules(self):
        script = SOURCE.split("<<'SCRIPT_EOF'\n", 1)[1].split("\nSCRIPT_EOF", 1)[0]
        script = script.replace('CONF=/etc/remnawave-setup/net.env', 'CONF=./net.env')
        mocks = r'''
            ip() {
                case "$*" in
                    "rule show")
                        if [ -f old_del ]; then
                            :   # старый код: правило уже удалено, чтобы не зациклиться
                        elif [ -f rule_deleted ]; then
                            printf '1001: from 10.0.0.9 lookup 100\n'
                        else
                            printf '1000: from 5.6.7.8 lookup 100\n'
                            printf '1001: from 10.0.0.9 lookup 100\n'
                        fi ;;
                    "rule del priority 1000") echo "ip $*" >> calls; : > rule_deleted ;;
                    # старый код удалял по table: помечаем, чтобы не зациклиться
                    "rule del table 100") echo "ip $*" >> calls; : > old_del ;;
                    "-o -4 addr show"*) printf '2: eth0    inet 1.2.3.4/32 scope global eth0\n' ;;
                    *) echo "ip $*" >> calls ;;
                esac
            }
            iptables() {
                case "$*" in
                    "-t nat -S POSTROUTING")
                        printf '%s\n' '-A POSTROUTING -o eth0 -m conntrack --ctstate NEW -m comment --comment "rw-secondary-ip" -j SNAT --to-source 5.6.7.8'
                        printf '%s\n' '-A POSTROUTING -o eth0 -m conntrack --ctstate NEW -j SNAT --to-source 9.9.9.9'
                        printf '%s\n' '-A POSTROUTING -o eth0 -j MASQUERADE' ;;
                    *) echo "iptables $*" >> calls ;;
                esac
            }
        '''

        def run(mode):
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            Path(tmp.name, 'net.env').write_text(
                f"MODE={mode}\nIP1=1.2.3.4\nIP2=5.6.7.8\nIFACE=eth0\nGW=10.0.0.1\n",
                encoding='utf-8')
            result = shell(mocks + script, tmp.name)
            calls = Path(tmp.name, 'calls').read_text(encoding='utf-8')
            return result, calls

        result, calls = run('dual')
        self.check(result)
        self.assertIn('ip rule del priority 1000', calls)
        self.assertNotIn('rule del table', calls)
        self.assertIn('ip rule add priority 1000', calls)
        self.assertIn('-m comment --comment rw-secondary-ip', calls)
        deletes = [line for line in calls.splitlines() if ' -D POSTROUTING ' in line]
        self.assertTrue(deletes)
        self.assertTrue(all('rw-secondary-ip' in line for line in deletes))
        self.assertFalse(any('9.9.9.9' in line for line in deletes))
        self.assertFalse(any('"rw-secondary-ip"' in line for line in deletes))

        result, calls = run('single')
        self.check(result)
        self.assertIn('режим single', result.stdout)
        self.assertIn('ip rule del priority 1000', calls)
        self.assertNotIn('-A POSTROUTING', calls)

    # ------------------------------------- замечания второго исполнителя
    def test_ip2_rejects_masked_and_leading_zero(self):
        body = (function('is_ipv4') + '\n' + function('is_host_ipv4') + r'''
            is_host_ipv4 198.51.100.5 || exit 1
            is_host_ipv4 10.0.0.1 || exit 2
            is_ipv4 198.51.100.5/24 || exit 3
            for bad in 198.51.100.5/24 0.0.0.0 255.255.255.255 010.0.0.1 198.51.100 198.51.100.256; do
                if is_host_ipv4 "$bad"; then printf 'ACCEPTED %s\n' "$bad"; exit 4; fi
            done
        ''')
        self.check(shell(body))
        # IP2 проверяется строго и при флаге, и в интерактивном вводе.
        self.assertGreaterEqual(SOURCE.count('is_host_ipv4 "$IP2"'), 2)

    def test_answers_env_quotes_survive_source(self):
        body = function('env_quote') + r'''
            printf 'X=%s\n' "$(env_quote localhost)" > answers.env
            . ./answers.env
            [ "$X" = localhost ] || exit 1
            tricky="a'b"
            printf 'Y=%s\n' "$(env_quote "$tricky")" > answers.env
            . ./answers.env
            [ "$Y" = "$tricky" ] || exit 2
            multiline='a
b'
            printf 'Z=%s\n' "$(env_quote "$multiline")" > answers.env
            . ./answers.env
            [ "$Z" = "$multiline" ] || exit 3
        '''
        with tempfile.TemporaryDirectory() as tmp:
            self.check(shell(body, tmp))
        # Оба файла, которые читаются через source, пишутся через env_quote.
        self.assertIn('SECRET_KEY=$(env_quote "$SECRET_KEY")', SOURCE)
        self.assertIn('TG_TOKEN=$(env_quote "$TG_TOKEN")', SOURCE)

    def test_template_choice_treats_leading_zero_as_decimal(self):
        lines = SOURCE.splitlines()
        start = next(i for i, line in enumerate(lines)
                     if 'if [[ "$tsel" =~ ^[0-9]+$ ]]' in line)
        end = next(i for i, line in enumerate(lines)
                   if 'Введите число от 1 до' in line)
        block = '\n'.join(lines[start:end])
        body = ('TEMPLATE_KEYS=(shop studio saas docs blog dashboard restaurant travel forum hosting)\n'
                'TEMPLATE=shop\n'
                'tsel=010\n'
                'while true; do\n'
                + block + '\n'
                'done\n'
                'printf "%s\\n" "$TEMPLATE"\n')
        result = shell(body)
        self.check(result)
        # 010 — это десятый пункт, а не восьмой (bash читает 010 как octal 8).
        self.assertEqual(result.stdout.strip(), 'hosting')

    def test_fetch_has_timeout(self):
        fetch = function('fetch')
        self.assertIn('--connect-timeout 15', fetch)
        self.assertIn('--max-time', fetch)

    def test_dns_helper_matches_nodego(self):
        other = (ROOT / 'nodego.sh').read_text(encoding='utf-8')
        def block(text):
            return text.split('# BEGIN DNS_TRANSACTION', 1)[1].split('# END DNS_TRANSACTION', 1)[0]
        self.assertEqual(block(SOURCE), block(other))


if __name__ == '__main__':
    unittest.main()
