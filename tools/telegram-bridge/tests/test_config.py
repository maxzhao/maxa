from __future__ import annotations

from telegram_bridge.__main__ import main
from telegram_bridge.config import load_config


def test_env_config_key_lookup_without_printing_values():
    cfg = load_config({
        "MAXA_TELEGRAM_BOT_TOKEN": "123456:SECRET",
        "MAXA_TELEGRAM_CHAT_ID": "-1001",
        "ALL_PROXY": "socks5://127.0.0.1:10808",
        "MAXA_TELEGRAM_BRIDGE_TOKEN": "local-secret",
    })
    assert cfg.bot_token == "123456:SECRET"
    assert cfg.group_id == -1001
    assert cfg.proxy == "socks5://127.0.0.1:10808"
    assert cfg.bridge_token == "local-secret"
    assert cfg.owner_user_id is None


def test_owner_user_id_is_independent_from_legacy_group_alias():
    cfg = load_config({
        "MAXA_TELEGRAM_CHAT_ID": "-1001",
        "MAXA_TELEGRAM_OWNER_USER_ID": "42",
    })
    assert cfg.group_id == -1001
    assert cfg.owner_user_id == 42


def test_config_command_reports_identifier_presence_only(monkeypatch, capsys):
    monkeypatch.setattr(
        "telegram_bridge.__main__.load_config",
        lambda: load_config({
            "MAXA_TELEGRAM_GROUP_ID": "-100123",
            "MAXA_TELEGRAM_OWNER_USER_ID": "456789",
        }),
    )
    assert main(["config"]) == 0
    output = capsys.readouterr().out
    assert "owner_user_id_configured" in output
    assert "group_id_configured" in output
    assert "456789" not in output
    assert "-100123" not in output


def test_notification_topic_id_can_be_configured():
    cfg = load_config({"MAXA_TELEGRAM_NOTIFICATION_TOPIC_ID": "77"})
    assert cfg.notification_topic_id == 77


def test_group_id_overrides_legacy_chat_id_alias():
    cfg = load_config({
        "MAXA_TELEGRAM_CHAT_ID": "-1001",
        "MAXA_TELEGRAM_GROUP_ID": "-1002",
    })
    assert cfg.group_id == -1002


def test_explicit_env_file_is_loaded_for_injected_env(tmp_path):
    path = tmp_path / ".env"
    path.write_text("\n".join([
        "MAXA_TELEGRAM_BOT_TOKEN=123456:SECRET",
        "MAXA_TELEGRAM_GROUP_ID=-1003",
        "ALL_PROXY=socks5://127.0.0.1:10808",
        "MAXA_TELEGRAM_BRIDGE_TOKEN='local secret'",
        "",
    ]), encoding="utf-8")

    cfg = load_config({"MAXA_ENV_FILE": str(path)})
    assert cfg.bot_token == "123456:SECRET"
    assert cfg.group_id == -1003
    assert cfg.proxy == "socks5://127.0.0.1:10808"
    assert cfg.bridge_token == "local secret"


def test_process_env_overrides_explicit_env_file(tmp_path):
    path = tmp_path / ".env"
    path.write_text("MAXA_TELEGRAM_GROUP_ID=-1001\n", encoding="utf-8")

    cfg = load_config({
        "MAXA_ENV_FILE": str(path),
        "MAXA_TELEGRAM_GROUP_ID": "-1002",
    })
    assert cfg.group_id == -1002


def test_explicit_env_file_overrides_discovered_env(tmp_path, monkeypatch):
    discovered_dir = tmp_path / "project"
    discovered_dir.mkdir()
    discovered = discovered_dir / ".env"
    explicit = tmp_path / "explicit.env"
    discovered.write_text("MAXA_TELEGRAM_GROUP_ID=-1001\n", encoding="utf-8")
    explicit.write_text("MAXA_TELEGRAM_GROUP_ID=-1002\n", encoding="utf-8")
    monkeypatch.chdir(discovered_dir)

    cfg = load_config({"MAXA_ENV_FILE": str(explicit)})
    assert cfg.group_id == -1002
