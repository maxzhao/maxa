from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .config import BridgeConfig


@dataclass(frozen=True)
class BotCommandSpec:
    command: str
    description: str


COMMAND_PING = "ping"
COMMAND_SESSIONS = "sessions"
COMMAND_CLEAN_TRACKED_TOPICS = "clean_tracked_topics"

BRIDGE_BOT_COMMANDS: tuple[BotCommandSpec, ...] = (
    BotCommandSpec(COMMAND_PING, "检查 Telegram Bridge 是否在线"),
    BotCommandSpec(COMMAND_SESSIONS, "列出在线 Maxa 会话与监听状态"),
    BotCommandSpec(COMMAND_CLEAN_TRACKED_TOPICS, "清理可识别的非活跃会话主题"),
)


class BotStateError(RuntimeError):
    pass


def bridge_command_names() -> tuple[str, ...]:
    return tuple(spec.command for spec in BRIDGE_BOT_COMMANDS)


def command_specs_as_dicts(specs: tuple[BotCommandSpec, ...] = BRIDGE_BOT_COMMANDS) -> list[dict[str, str]]:
    return [{"command": spec.command, "description": spec.description} for spec in specs]


def validate_bot_commands(specs: tuple[BotCommandSpec, ...] = BRIDGE_BOT_COMMANDS) -> None:
    import re

    seen: set[str] = set()
    pattern = re.compile(r"^[a-z0-9_]{1,32}$")
    for spec in specs:
        if not pattern.fullmatch(spec.command):
            raise BotStateError(f"invalid Telegram bot command: {spec.command!r}")
        description = spec.description.strip()
        if len(description) < 3 or len(description) > 256:
            raise BotStateError(f"invalid Telegram bot command description for {spec.command!r}")
        if spec.command in seen:
            raise BotStateError(f"duplicate Telegram bot command: {spec.command!r}")
        seen.add(spec.command)


def _obj_attr(obj: Any, name: str, default: Any = None) -> Any:
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _command_dicts_from_remote(commands: list[Any]) -> list[dict[str, str]]:
    return [
        {
            "command": str(_obj_attr(command, "command", "")),
            "description": str(_obj_attr(command, "description", "")),
        }
        for command in commands
    ]


def _safe_webhook_info(info: Any) -> dict[str, Any]:
    url = str(_obj_attr(info, "url", "") or "")
    return {
        "has_webhook": bool(url),
        "pending_update_count": int(_obj_attr(info, "pending_update_count", 0) or 0),
        "allowed_updates": _obj_attr(info, "allowed_updates", None),
        "last_error_date": str(_obj_attr(info, "last_error_date", "") or "") or None,
        "last_synchronization_error_date": str(_obj_attr(info, "last_synchronization_error_date", "") or "") or None,
    }


def _safe_member_permissions(member: Any) -> dict[str, Any]:
    fields = (
        "status",
        "can_manage_topics",
        "can_pin_messages",
        "can_delete_messages",
        "can_manage_chat",
        "can_post_messages",
        "can_edit_messages",
    )
    return {field: _obj_attr(member, field, None) for field in fields if _obj_attr(member, field, None) is not None}


def _scope_summary(scope: Any) -> dict[str, Any]:
    scope_type = _obj_attr(scope, "type", "chat")
    value = getattr(scope_type, "value", scope_type)
    return {"type": str(value), "chat_id": _obj_attr(scope, "chat_id", None)}


async def _build_bot(config: BridgeConfig):
    if not config.bot_token:
        return None
    from aiogram import Bot
    from aiogram.client.session.aiohttp import AiohttpSession

    session = AiohttpSession(proxy=config.proxy) if config.proxy else None
    return Bot(token=config.bot_token, session=session)


def _build_aiogram_commands(specs: tuple[BotCommandSpec, ...] = BRIDGE_BOT_COMMANDS):
    from aiogram.types import BotCommand

    return [BotCommand(command=spec.command, description=spec.description) for spec in specs]


async def reconcile_bot_state(config: BridgeConfig, *, bot: Any | None = None, request_timeout: int = 30) -> dict[str, Any]:
    """Reconcile Telegram server-side bot state for the bridge.

    The operation is intentionally idempotent and non-chatty: it does not create
    topics, send messages, pin messages, or drop pending updates. Commands are
    scoped to the configured Maxa group to avoid overwriting a shared bot's
    global command menu.
    """

    validate_bot_commands()
    if not config.bot_token:
        raise BotStateError("missing MAXA_TELEGRAM_BOT_TOKEN")
    if config.group_id is None:
        raise BotStateError("missing MAXA_TELEGRAM_GROUP_ID")

    close_created_bot = False
    if bot is None:
        bot = await _build_bot(config)
        close_created_bot = True
    if bot is None:
        raise BotStateError("failed to create Telegram bot client")

    try:
        from aiogram.types import BotCommandScopeChat

        scope = BotCommandScopeChat(chat_id=config.group_id)
        expected_commands = command_specs_as_dicts()
        aiogram_commands = _build_aiogram_commands()

        me = await bot.get_me(request_timeout=request_timeout)
        webhook_before = await bot.get_webhook_info(request_timeout=request_timeout)
        delete_webhook_ok = await bot.delete_webhook(drop_pending_updates=False, request_timeout=request_timeout)
        set_commands_ok = await bot.set_my_commands(aiogram_commands, scope=scope, request_timeout=request_timeout)
        remote_commands = await bot.get_my_commands(scope=scope, request_timeout=request_timeout)
        remote_command_dicts = _command_dicts_from_remote(remote_commands)
        member = await bot.get_chat_member(chat_id=config.group_id, user_id=int(_obj_attr(me, "id")), request_timeout=request_timeout)

        return {
            "ok": True,
            "bot": {
                "id": _obj_attr(me, "id"),
                "is_bot": _obj_attr(me, "is_bot", None),
                "username": _obj_attr(me, "username", None),
                "first_name": _obj_attr(me, "first_name", None),
            },
            "scope": _scope_summary(scope),
            "webhook_before": _safe_webhook_info(webhook_before),
            "delete_webhook": {
                "ok": bool(delete_webhook_ok),
                "drop_pending_updates": False,
            },
            "commands": {
                "set": bool(set_commands_ok),
                "expected": expected_commands,
                "remote": remote_command_dicts,
                "matches": remote_command_dicts == expected_commands,
            },
            "permissions": _safe_member_permissions(member),
        }
    finally:
        if close_created_bot:
            session = getattr(bot, "session", None)
            close = getattr(session, "close", None)
            if close is not None:
                await close()
