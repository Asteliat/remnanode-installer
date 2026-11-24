"""Проверка всех инбаундов и сохранения идентичности при повторной генерации."""
import argparse
import json
from pathlib import Path
import re


def identity(config):
    result = []
    for inbound in config["inbounds"]:
        reality = inbound.get("streamSettings", {}).get("realitySettings", {})
        result.append((inbound["tag"], reality.get("privateKey"), reality.get("shortIds")))
    return result


def validate(directory, before=None):
    directory = Path(directory)
    configs = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in directory.glob("*.json")}
    assert set(configs) == {"xhttp", "grpc", "tcp", "hysteria2"}, set(configs)
    all_tags = set()
    for name, config in configs.items():
        inbounds = config["inbounds"]
        assert len(inbounds) == (2 if name == "hysteria2" else 1), name
        for index, inbound in enumerate(inbounds):
            tag = inbound["tag"]
            assert tag not in all_tags, f"Повторный tag: {tag}"
            all_tags.add(tag)
            assert re.fullmatch(r"(NodeGo\d\d|GoNode\d\d|Node\d{4}|\d\dNode\d\d)", tag), tag
            assert inbound["port"] == 443, (name, index)
            assert inbound["listen"] == "0.0.0.0", (name, index)
            settings = inbound["streamSettings"]
            if name == "hysteria2" and index == 0:
                assert inbound["protocol"] == "hysteria"
                assert settings["network"] == "hysteria"
                assert settings["security"] == "tls"
                assert inbound["settings"]["version"] == 2
                tls = settings["tlsSettings"]
                assert tls["serverName"] == "node.example.com"
                assert tls["certificates"][0]["certificateFile"] == "/etc/remnanode/cert/fullchain.crt"
                assert tls["certificates"][0]["keyFile"] == "/etc/remnanode/cert/private.key"
            else:
                assert inbound["protocol"] == "vless", (name, index)
                assert settings["security"] == "reality"
                assert settings["network"] == ("xhttp" if name == "hysteria2" else name)
                reality = settings["realitySettings"]
                assert reality["target"] == "127.0.0.1:9443"
                assert reality["serverNames"] == ["node.example.com"]
                assert re.fullmatch(r"[A-Za-z0-9_-]{43}", reality["privateKey"])
                assert len(reality["shortIds"]) == 6
                assert all(re.fullmatch(r"[0-9a-f]{16}", s) for s in reality["shortIds"])
        if before:
            previous = json.loads((Path(before) / f"{name}.json").read_text(encoding="utf-8"))
            assert identity(config) == identity(previous), f"Изменилась идентичность: {name}"
    if before:
        assert (directory / "meta.env").read_bytes() == (Path(before) / "meta.env").read_bytes(), "Изменился meta.env"
    print(f"Проверено: {len(configs)} конфигурации, {len(all_tags)} инбаундов; идентичность сохранена")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--before")
    arguments = parser.parse_args()
    validate(arguments.directory, arguments.before)
