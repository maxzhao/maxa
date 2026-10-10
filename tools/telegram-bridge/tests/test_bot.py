from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from telegram_bridge.bot import TelegramBridgeBot, build_dispatcher, sessions_view
from telegram_bridge.config import BridgeConfig
from telegram_bridge.store import Store


@pytest.mark.asyncio
async def test_human_assist_callback_and_reply_are_completed_once():
    store = Store(":memory:")
    bot = TelegramBridgeBot(BridgeConfig(group_id=-100, owner_user_id=1), store)
    store.create_human_assist_request(
        request_id="prompt1",
        kind="prompt",
        chat_id=-100,
        topic_id=42,
        telegram_message_id=10,
        prompt_text="Choose",
        payload={"buttons": [[{"text": "Retry", "data": "retry"}]]},
        expires_at=9999999999,
    )
    status, result = await bot.handle_human_assist_callback(
        group_id=-100,
        user_id=1,
        telegram_message_id=10,
        callback_data="ha:prompt1:0.0",
    )
    assert status == "completed"
    assert result == {"success": True, "source": "telegram", "selected": "retry", "button_text": "Retry"}
    assert (await bot.handle_human_assist_callback(group_id=-100, user_id=1, telegram_message_id=10, callback_data="ha:prompt1:0.0"))[0] == "expired"

    store.create_human_assist_request(
        request_id="input1",
        kind="input",
        chat_id=-100,
        topic_id=42,
        telegram_message_id=11,
        prompt_text="Reply",
        payload={},
        expires_at=9999999999,
    )
    status, result = await bot.handle_human_assist_reply(
        group_id=-100,
        user_id=1,
        reply_to_message_id=11,
        text="hello",
        photo_file_id="photo-1",
    )
    assert status == "completed"
    assert result == {"success": True, "source": "telegram", "text": "hello", "photo_file_id": "photo-1"}

    store.create_human_assist_request(
        request_id="input-empty",
        kind="input",
        chat_id=-100,
        topic_id=42,
        telegram_message_id=13,
        prompt_text="Reply",
        payload={},
        expires_at=9999999999,
    )
    status, result = await bot.handle_human_assist_reply(
        group_id=-100,
        user_id=1,
        reply_to_message_id=13,
        text="",
        photo_file_id=None,
    )
    assert status == "unmatched"
    assert result is None
    assert store.get_human_assist_request("input-empty")["status"] == "pending"
    status, result = await bot.handle_human_assist_reply(
        group_id=-100,
        user_id=1,
        reply_to_message_id=13,
        text="",
        photo_file_id="photo-only",
    )
    assert status == "completed"
    assert result == {"success": True, "source": "telegram", "text": "", "photo_file_id": "photo-only"}

    store.create_human_assist_request(
        request_id="choice-text",
        kind="prompt",
        chat_id=-100,
        topic_id=42,
        telegram_message_id=12,
        prompt_text="Choose or type",
        payload={"buttons": [[{"text": "Retry", "data": "retry"}]]},
        expires_at=9999999999,
    )
    status, result = await bot.handle_human_assist_reply(
        group_id=-100,
        user_id=1,
        reply_to_message_id=12,
        text="something else",
        photo_file_id="ignored-for-choice",
    )
    assert status == "completed"
    assert result == {"success": True, "source": "telegram", "text": "something else"}


@pytest.mark.asyncio
async def test_human_assist_authorization_is_owner_only_and_destination_aware():
    store = Store(":memory:")
    bot = TelegramBridgeBot(BridgeConfig(group_id=-100, owner_user_id=1), store)
    store.create_human_assist_request(
        request_id="private-prompt",
        kind="prompt",
        chat_id=1,
        topic_id=None,
        telegram_message_id=20,
        prompt_text="Choose",
        payload={"buttons": [[{"text": "Yes", "data": "yes"}]]},
        expires_at=9999999999,
    )
    assert (await bot.handle_human_assist_callback(group_id=1, user_id=2, telegram_message_id=20, callback_data="ha:private-prompt:0.0"))[0] == "unauthorized"
    assert (await bot.handle_human_assist_callback(group_id=-100, user_id=1, telegram_message_id=20, callback_data="ha:private-prompt:0.0"))[0] == "unauthorized"
    status, result = await bot.handle_human_assist_callback(group_id=1, user_id=1, telegram_message_id=20, callback_data="ha:private-prompt:0.0")
    assert status == "completed"
    assert result["selected"] == "yes"

    store.create_human_assist_request(
        request_id="private-input",
        kind="input",
        chat_id=1,
        topic_id=None,
        telegram_message_id=21,
        prompt_text="Reply",
        payload={},
        expires_at=9999999999,
    )
    assert (await bot.handle_human_assist_reply(group_id=1, user_id=2, reply_to_message_id=21, text="bad"))[0] == "unauthorized"
    assert (await bot.handle_human_assist_reply(group_id=-100, user_id=1, reply_to_message_id=21, text="wrong chat"))[0] == "unmatched"
    assert (await bot.handle_human_assist_reply(group_id=1, user_id=1, reply_to_message_id=999, text="ordinary"))[0] == "unmatched"
    assert store.get_human_assist_request("private-input")["status"] == "pending"
    assert await bot.handle_topic_text(group_id=1, user_id=1, topic_id=0, telegram_message_id=22, text="ordinary") == "unauthorized"
    private_only_bot = TelegramBridgeBot(BridgeConfig(owner_user_id=1), store)
    assert await private_only_bot.handle_topic_text(group_id=1, user_id=1, topic_id=0, telegram_message_id=23, text="ordinary") == "unauthorized"


@pytest.mark.asyncio
async def test_handle_topic_text_requires_idle_notify_and_never_queues_busy_input():
    store = Store(":memory:")
    bot = TelegramBridgeBot(BridgeConfig(group_id=-100, owner_user_id=1), store)
    store.set_ask_topic("/p", "s", group_id=-100, topic_id=42, topic_title="Session")
    assert await bot.handle_topic_text(group_id=-200, user_id=1, topic_id=42, telegram_message_id=1, text="hi") == "unauthorized"
    assert await bot.handle_topic_text(group_id=-100, user_id=2, topic_id=42, telegram_message_id=1, text="hi") == "unauthorized"
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=43, telegram_message_id=1, text="hi") == "unknown"
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=1, text="hi") == "inactive"
    store.register_instance(instance_id="i", pid=None, cwd=None, project_root="/p", version=None)
    store.heartbeat(instance_id="i", open_chats=[{"project_root": "/p", "save_id": "s", "running": False}])
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=1, text="hi") == "not_listening"
    store.heartbeat(instance_id="i", open_chats=[{"project_root": "/p", "save_id": "s", "running": True, "notify_active": True}])
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=2, text="hi") == "busy"
    store.heartbeat(instance_id="i", open_chats=[{"project_root": "/p", "save_id": "s", "running": False, "notify_active": True}])
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=3, text="hi") == "pending"
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=4, text="second") == "busy"
    assert len(store.poll_events(project_root="/p", save_id="s")) == 1
    store.ack_event(int(store.poll_events(project_root="/p", save_id="s")[0]["id"]))
    assert await bot.handle_topic_text(group_id=-100, user_id=1, topic_id=42, telegram_message_id=5, text="next") == "pending"


@pytest.mark.asyncio
async def test_admitted_tg_text_gets_immediate_pending_receipt(monkeypatch):
    from aiogram.types import Chat, Message, User

    replies = []

    async def answer(self, text, **kwargs):
        replies.append(text)

    monkeypatch.setattr(Message, "answer", answer)
    store = Store(":memory:")
    store.set_ask_topic("/p", "s", group_id=-100, topic_id=42, topic_title="Session")
    store.register_instance(instance_id="i", pid=None, cwd=None, project_root="/p", version=None)
    store.heartbeat(instance_id="i", open_chats=[{"project_root": "/p", "save_id": "s", "notify_active": True, "running": False}])
    router = build_dispatcher(BridgeConfig(group_id=-100, owner_user_id=1), store).sub_routers[0]
    handler = next(item.callback for item in router.message.handlers if item.callback.__name__ == "text")
    msg = Message(message_id=12, date=datetime.now(timezone.utc), chat=Chat(id=-100, type="supergroup"),
                  from_user=User(id=1, is_bot=False, first_name="Owner"), message_thread_id=42, text="hello")
    await handler(msg)
    assert replies == ["✅ 已收到 Telegram 消息，正在提交到 Chat；若提交前 Chat 状态变化，会另行告知。"]
    assert len(store.poll_events(project_root="/p", save_id="s")) == 1


def test_sessions_view_is_read_only_and_lists_running_and_listening():
    rows = [
        {"running": False, "notify_active": True, "title": "Chat", "save_id": "s", "project_root": "/projects/demo"},
        {"running": True, "notify_active": False, "title": "Worker", "save_id": "b", "project_root": "/projects/demo"},
    ]
    text = sessions_view(rows)
    assert "运行中：1；空闲：1；监听中：1" in text
    assert "Chat [空闲 / 监听中]" in text
    assert "Worker [运行中 / 未监听]" in text
    assert "绑定" not in text
    assert sessions_view([]) == "当前没有在线的 nvim open chats。"


@pytest.mark.asyncio
async def test_command_scope_exposes_only_general_commands(monkeypatch):
    from aiogram.types import Chat, Message, User

    replies = []

    async def answer(self, text, **kwargs):
        replies.append(text)

    monkeypatch.setattr(Message, "answer", answer)
    store = Store(":memory:")
    router = build_dispatcher(BridgeConfig(group_id=-100, owner_user_id=1), store).sub_routers[0]
    handlers = {handler.callback.__name__: handler.callback for handler in router.message.handlers}
    callbacks = {handler.callback.__name__: handler.callback for handler in router.callback_query.handlers}

    def message(thread_id):
        return Message(message_id=10, date=datetime.now(timezone.utc), chat=Chat(id=-100, type="supergroup"),
                       from_user=User(id=1, is_bot=False, first_name="Owner"), message_thread_id=thread_id)

    for name in ("ping", "sessions", "clean_tracked_topics"):
        await handlers[name](message(42))
        assert replies[-1] == "请在 General 中执行此命令。"
    assert not {"history", "status", "detach", "unbind", "close", "reset"} & handlers.keys()
    assert "session_toggle_callback" not in callbacks

    alerts = []

    async def callback_answer(text, **kwargs):
        alerts.append(text)

    callback = SimpleNamespace(message=message(42), from_user=User(id=1, is_bot=False, first_name="Owner"), answer=callback_answer)
    callback.data = "clean_topics:confirm:old"
    await callbacks["clean_tracked_topics_callback"](callback)
    assert alerts == ["仅可在 General 中操作"]


@pytest.mark.asyncio
async def test_clean_tracked_topics_refuses_without_live_nvim(monkeypatch):
    from aiogram.types import Chat, Message, User

    replies = []

    async def answer(self, text, **kwargs):
        replies.append(text)

    monkeypatch.setattr(Message, "answer", answer)
    store = Store(":memory:")
    store.track_topic(-100, 42)
    service = SimpleNamespace(bot=object())
    router = build_dispatcher(BridgeConfig(group_id=-100, owner_user_id=1), store, service).sub_routers[0]
    handler = next(item.callback for item in router.message.handlers if item.callback.__name__ == "clean_tracked_topics")
    message = Message(message_id=10, date=datetime.now(timezone.utc), chat=Chat(id=-100, type="supergroup"),
                      from_user=User(id=1, is_bot=False, first_name="Owner"))
    await handler(message)
    assert "没有在线 nvim 实例" in replies[-1]
    assert store.list_tracked_topics(-100) == [42]


@pytest.mark.asyncio
async def test_clean_tracked_topics_confirms_once_and_preserves_failures(monkeypatch):
    from aiogram.types import Chat, Message, User

    replies = []

    async def answer(self, text, **kwargs):
        replies.append((text, kwargs))

    async def edit_reply_markup(self, **kwargs):
        pass

    monkeypatch.setattr(Message, "answer", answer)
    monkeypatch.setattr(Message, "edit_reply_markup", edit_reply_markup)

    class TopicService:
        bot = object()

        def __init__(self):
            self.deleted = []

        async def delete_topic(self, *, topic_id):
            if topic_id == 47:
                raise RuntimeError("cannot delete")
            self.deleted.append(topic_id)

    store = Store(":memory:")
    store.track_topic(-100, 42)
    store.track_topic(-100, 44)
    store.track_topic(-200, 99)
    store.set_ask_topic("/active", "s", group_id=-100, topic_id=43, topic_title="Open")
    store.set_ask_topic("/inactive", "s", group_id=-100, topic_id=45, topic_title="History only")
    store.set_ask_topic("/restored", "s", group_id=-100, topic_id=46, topic_title="Restored after preview")
    store.set_ask_topic("/failed", "s", group_id=-100, topic_id=47, topic_title="Delete fails")
    store.set_ask_topic("/unbound-live", "s", group_id=-100, topic_id=48, topic_title="Ask/notify for open chat")
    store.track_topic(-100, 49, project_root="/unbound-inactive", save_id="s")
    store.register_instance(instance_id="nvim", pid=None, cwd=None, project_root="/active", version=None)
    store.heartbeat(instance_id="nvim", open_chats=[
        {"project_root": "/active", "save_id": "s", "running": False},
        {"project_root": "/unbound-live", "save_id": "s", "running": False},
    ])
    service = TopicService()
    router = build_dispatcher(BridgeConfig(group_id=-100, owner_user_id=1), store, service).sub_routers[0]
    handlers = {handler.callback.__name__: handler.callback for handler in router.message.handlers}
    callbacks = {handler.callback.__name__: handler.callback for handler in router.callback_query.handlers}
    owner = User(id=1, is_bot=False, first_name="Owner")
    message = Message(message_id=10, date=datetime.now(timezone.utc), chat=Chat(id=-100, type="supergroup"), from_user=owner)
    await handlers["clean_tracked_topics"](message)
    assert "4 个未在在线 nvim 中打开" in replies[-1][0]
    assert "保留 2 个在线 chat" in replies[-1][0]
    assert "跳过 2 个归属未知" in replies[-1][0]
    token_callback = replies[-1][1]["reply_markup"].inline_keyboard[0][0].callback_data
    # Restoring a history chat after preview must protect its topic at confirm time.
    store.heartbeat(instance_id="nvim", open_chats=[
        {"project_root": "/active", "save_id": "s", "running": False},
        {"project_root": "/unbound-live", "save_id": "s", "running": False},
        {"project_root": "/restored", "save_id": "s", "running": False},
    ])
    alerts = []

    async def callback_answer(text, **kwargs):
        alerts.append(text)

    callback = SimpleNamespace(message=message, from_user=owner, data=token_callback, answer=callback_answer)
    await callbacks["clean_tracked_topics_callback"](callback)
    assert service.deleted == [45, 49]
    assert store.list_tracked_topics(-100) == [42, 43, 44, 46, 47, 48]
    assert store.list_tracked_topics(-200) == [99]
    assert store.get_ask_topic("/active", "s") is not None
    assert store.get_ask_topic("/restored", "s") is not None
    assert store.get_tracked_topic(-100, 48)["project_root"] == "/unbound-live"
    assert store.get_ask_topic("/unbound-live", "s")["topic_id"] == 48
    assert store.get_ask_topic("/inactive", "s") is None
    assert store.conn.execute("SELECT 1 FROM open_chats WHERE project_root='/active' AND save_id='s'").fetchone()
    assert store.conn.execute("SELECT 1 FROM pending_events").fetchone() is None
    assert "新激活而保留 1 个" in replies[-1][0]
    assert "归属不明而跳过 0 个" in replies[-1][0]
    assert "失败 1 个" in replies[-1][0]
    assert "在线 nvim chat 保持打开" in replies[-1][0]
    await callbacks["clean_tracked_topics_callback"](callback)
    assert alerts[-1] == "确认已过期，请重新执行命令"
    assert service.deleted == [45, 49]
