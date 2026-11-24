"""Безопасные регрессии: только извлечённые функции и mock-команды, без установки."""
import os
from pathlib import Path
import re
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


class InstallerTests(unittest.TestCase):
    def check(self, result, success=True):
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

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
                body = function("check_api_firewall") + f'''
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
            body = function('check_api_firewall') + f'''
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

    def test_dns_helper_matches_nodego(self):
        other = (ROOT / 'nodego.sh').read_text(encoding='utf-8')
        def block(text):
            return text.split('# BEGIN DNS_TRANSACTION', 1)[1].split('# END DNS_TRANSACTION', 1)[0]
        self.assertEqual(block(SOURCE), block(other))


if __name__ == '__main__':
    unittest.main()
