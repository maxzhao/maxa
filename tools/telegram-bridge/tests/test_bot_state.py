from __future__ import annotations

import pytest

from telegram_bridge.bot_state import (
    BRIDGE_BOT_COMMANDS,
    BotStateError,
    bridge_command_names,
    command_specs_as_dicts,
    reconcile_bot_state,
    validate_bot_commands,
)
from telegram_bridge.config import BridgeConfig


class FakeObj:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class FakeBot:
    def __init__(self):
        self.calls = []
        self.session = FakeObj(close=self.close_session)
        self.closed = False

    async def close_session(self):
        self.closed = True

    async def get_me(self, **kwargs):
        self.calls.append(("get_me", kwargs))
        return FakeObj(id=123, is_bot=True, username="maxa_test_bot", first_name="Maxa")

    async def get_webhook_info(self, **kwargs):
        self.calls.append(("get_webhook_info", kwargs))
        return FakeObj(url="https://example.invalid/webhook", pending_update_count=7, allowed_updates=["message"])

    async def delete_webhook(self, **kwargs):
        self.calls.append(("delete_webhook", kwargs))
        return True

    async def set_my_commands(self, commands, **kwargs):
        self.calls.append(("set_my_commands", commands, kwargs))
        return True

    async def get_my_commands(self, **kwargs):
        self.calls.append(("get_my_commands", kwargs))
        return [FakeObj(command=item.command, description=item.description) for item in BRIDGE_BOT_COMMANDS]

    async def get_chat_member(self, **kwargs):
        self.calls.append(("get_chat_member", kwargs))
        return FakeObj(status="administrator", can_manage_topics=True, can_pin_messages=True)


@pytest.mark.asyncio
async def test_reconcile_bot_state_uses_chat_scope_and_preserves_pending_updates():
    fake = FakeBot()
    cfg = BridgeConfig(bot_token="123456:SECRET", group_id=-100123)

    result = await reconcile_bot_state(cfg, bot=fake, request_timeout=12)

    assert result["ok"] is True
    assert result["bot"]["username"] == "maxa_test_bot"
    assert result["webhook_before"]["has_webhook"] is True
    assert result["delete_webhook"] == {"ok": True, "drop_pending_updates": False}
    assert result["commands"]["matches"] is True
    assert result["scope"] == {"type": "chat", "chat_id": -100123}
    assert result["permissions"]["can_manage_topics"] is True

    delete_call = next(call for call in fake.calls if call[0] == "delete_webhook")
    assert delete_call[1]["drop_pending_updates"] is False
    assert delete_call[1]["request_timeout"] == 12

    set_call = next(call for call in fake.calls if call[0] == "set_my_commands")
    commands = set_call[1]
    kwargs = set_call[2]
    assert [(item.command, item.description) for item in commands] == [(item.command, item.description) for item in BRIDGE_BOT_COMMANDS]
    assert kwargs["scope"].chat_id == -100123
    assert getattr(kwargs["scope"].type, "value", kwargs["scope"].type) == "chat"

    member_call = next(call for call in fake.calls if call[0] == "get_chat_member")
    assert member_call[1]["chat_id"] == -100123
    assert member_call[1]["user_id"] == 123


@pytest.mark.asyncio
async def test_reconcile_requires_token_and_group_id():
    with pytest.raises(BotStateError, match="MAXA_TELEGRAM_BOT_TOKEN"):
        await reconcile_bot_state(BridgeConfig(group_id=-100), bot=FakeBot())
    with pytest.raises(BotStateError, match="MAXA_TELEGRAM_GROUP_ID"):
        await reconcile_bot_state(BridgeConfig(bot_token="123456:SECRET"), bot=FakeBot())


def test_declared_commands_are_valid_and_serializable():
    validate_bot_commands()
    assert bridge_command_names() == ("ping", "sessions", "clean_tracked_topics")
    assert command_specs_as_dicts() == [
        {"command": "ping", "description": "检查 Telegram Bridge 是否在线"},
        {"command": "sessions", "description": "列出在线 Maxa 会话与监听状态"},
        {"command": "clean_tracked_topics", "description": "清理可识别的非活跃会话主题"},
    ]


def test_bot_handlers_import_the_shared_command_constants():
    import telegram_bridge.bot as bot_module

    source_names = {
        bot_module.COMMAND_PING,
        bot_module.COMMAND_SESSIONS,
        bot_module.COMMAND_CLEAN_TRACKED_TOPICS,
    }
    assert source_names == set(bridge_command_names())
