"""Регрессии контрактов CI; не запускают установщик и не меняют систему."""
import json
from pathlib import Path
import tempfile
import unittest

from validate_generated import validate

ROOT = Path(__file__).resolve().parents[1]


def fixture():
    def reality(tag, network):
        return {"tag": tag, "port": 443, "listen": "0.0.0.0", "protocol": "vless",
                "streamSettings": {"security": "reality", "network": network,
                    "realitySettings": {"target": "127.0.0.1:9443", "serverNames": ["node.example.com"],
                        "privateKey": "A" * 43, "shortIds": [f"{i:016x}" for i in range(6)]}}}
    result = {name: {"inbounds": [reality(f"Node000{i}", name)]}
              for i, name in enumerate(("xhttp", "grpc", "tcp"))}
    result["hysteria2"] = {"inbounds": [
        {"tag": "Node0003", "port": 443, "listen": "0.0.0.0", "protocol": "hysteria",
         "settings": {"version": 2}, "streamSettings": {"network": "hysteria", "security": "tls",
            "tlsSettings": {"serverName": "node.example.com", "certificates": [{
                "certificateFile": "/etc/remnanode/cert/fullchain.crt",
                "keyFile": "/etc/remnanode/cert/private.key"}]}}},
        reality("Node0004", "xhttp")]}
    return result


def save(path, configs):
    path.mkdir()
    for name, config in configs.items():
        (path / f"{name}.json").write_text(json.dumps(config), encoding="utf-8")
    (path / "meta.env").write_text("# test fixture\n", encoding="utf-8")


class Contracts(unittest.TestCase):
    def check_bad(self, mutate):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            configs = fixture()
            save(root / "before", configs)
            mutate(configs)
            save(root / "after", configs)
            with self.assertRaises(AssertionError):
                validate(root / "after", root / "before")

    def test_all_five_inbounds_and_stable_identity_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            save(path / "before", fixture())
            save(path / "after", fixture())
            validate(path / "after", path / "before")

    def test_missing_hysteria_tcp_inbound_fails(self):
        self.check_bad(lambda c: c["hysteria2"]["inbounds"].pop())

    def test_wrong_hysteria_tcp_target_fails(self):
        self.check_bad(lambda c: c["hysteria2"]["inbounds"][1]["streamSettings"]["realitySettings"].update(target="wrong:443"))

    def test_rotated_private_key_on_rerun_fails(self):
        self.check_bad(lambda c: c["xhttp"]["inbounds"][0]["streamSettings"]["realitySettings"].update(privateKey="B" * 43))

    def test_rotated_short_ids_on_rerun_fails(self):
        self.check_bad(lambda c: c["tcp"]["inbounds"][0]["streamSettings"]["realitySettings"].update(shortIds=["f" * 16] * 6))

    def test_duplicate_tag_across_profiles_fails(self):
        self.check_bad(lambda c: c["hysteria2"]["inbounds"][1].update(tag="Node0000"))

    def test_dns_transaction_contract_is_shared(self):
        blocks = []
        for filename in ("install.sh", "nodego.sh"):
            text = (ROOT / filename).read_text(encoding="utf-8")
            blocks.append(text.split("# BEGIN DNS_TRANSACTION", 1)[1].split("# END DNS_TRANSACTION", 1)[0])
        self.assertEqual(blocks[0], blocks[1], "Установщик и nodego должны понимать один снимок DNS")


if __name__ == "__main__":
    unittest.main()
