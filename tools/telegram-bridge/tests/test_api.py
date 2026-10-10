from __future__ import annotations

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from telegram_bridge.api import create_app
from telegram_bridge.config import BridgeConfig
from telegram_bridge.store import Store
from telegram_bridge.topic import TelegramTopicService, TopicResult


class FakeMissingTopic(Exception):
    pass


class FakeTopic(TelegramTopicService):
    def __init__(self):
        super().__init__(group_id=-100)
        self.sent = []
        self.fail_missing_topic_once_for = None
        self.missing_topics = set()
        self.created_topic_id = 42
        self.ensure_calls = []
        self.topic_exists_calls = []

    async def ensure_topic(self, *, title, existing_topic_id=None):
        self.ensure_calls.append(existing_topic_id)
        await asyncio.sleep(0)
        return TopicResult(topic_id=existing_topic_id or self.created_topic_id, title=title)

    def _raise_missing_topic_once_if_needed(self, topic_id):
        if topic_id in self.missing_topics:
            raise FakeMissingTopic("Bad Request: message thread not found")
        if self.fail_missing_topic_once_for is not None and self.fail_missing_topic_once_for == topic_id:
            self.fail_missing_topic_once_for = None
            raise FakeMissingTopic("Bad Request: message thread not found")

    def _raise_invalid_topic_if_needed(self, topic_id):
        if topic_id in self.missing_topics:
            raise FakeMissingTopic("Bad Request: TOPIC_ID_INVALID")

    def _raise_unknown_if_needed(self, topic_id):
        fail_unknown_for = getattr(self, "fail_unknown_for", None)
        if fail_unknown_for is not None and fail_unknown_for == topic_id:
            raise RuntimeError("Telegram transport failed ambiguously")

    async def topic_exists(self, *, topic_id):
        self.topic_exists_calls.append(topic_id)
        self._raise_invalid_topic_if_needed(topic_id)
        return True

    async def send_text(self, *, chat_id=None, topic_id=None, text="", reply_to_message_id=None, reply_markup=None, parse_mode=None, silent=False):
        self._raise_unknown_if_needed(topic_id)
        self._raise_missing_topic_once_if_needed(topic_id)
        self.sent.append(("text", chat_id, topic_id, text, reply_to_message_id))
        return 10

    async def send_photo(self, *, chat_id=None, topic_id=None, photo=None, caption="", reply_markup=None, parse_mode=None, silent=False):
        self._raise_unknown_if_needed(topic_id)
        self._raise_missing_topic_once_if_needed(topic_id)
        self.sent.append(("photo", chat_id, topic_id, caption))
        return 11

    async def edit_human_assist_message(self, *, chat_id, message_id, text, has_photo=False):
        self.sent.append(("human_assist_edit", chat_id, message_id, text, has_photo))

    async def download_file_bytes(self, *, file_id):
        return b"image"


@pytest.mark.asyncio
async def test_event_result_falls_back_to_notification_topic_when_reply_topic_missing():
    cfg = BridgeConfig(group_id=-100, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    topic.created_topic_id = 88
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        event_id = store.add_event(
            project_root="/p",
            save_id="s",
            topic_id=0,
            telegram_message_id=None,
            event_type="telegram_user_message",
            payload={"title": "T", "reply_chat_id": -100, "reply_topic_id": 7, "reply_message_id": 8},
            target_instance_id="i1",
        )
        topic.missing_topics.add(7)
        store.set_notification_topic(group_id=-100, topic_id=66, title="Old notifications")
        topic.missing_topics.add(66)

        result = await client.post(f"/v1/events/{event_id}/result", headers=headers, json={"ok": True, "status": "attached", "message": "done"})

        assert result.status_code == 200
        assert topic.topic_exists_calls == [66]
        assert topic.ensure_calls == [None]
        assert topic.sent[-1] == ("text", -100, 88, "done", None)
        notification = store.get_notification_topic(-100)
        assert notification["topic_id"] == 88
        assert store.get_ask_topic("__notification__", "-100") is None


@pytest.mark.asyncio
async def test_event_result_adopts_configured_notification_topic_without_creating():
    cfg = BridgeConfig(group_id=-100, bridge_token="tok", notification_topic_id=77)
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        event_id = store.add_event(
            project_root="/p",
            save_id="s",
            topic_id=0,
            telegram_message_id=None,
            event_type="telegram_user_message",
            payload={"title": "T", "reply_chat_id": -100},
            target_instance_id="i1",
        )

        result = await client.post(f"/v1/events/{event_id}/result", headers=headers, json={"ok": True, "status": "attached", "message": "done"})

        assert result.status_code == 200
        assert topic.topic_exists_calls == [77]
        assert topic.ensure_calls == [77]
        assert topic.sent[-1] == ("text", -100, 77, "done", None)
        notification = store.get_notification_topic(-100)
        assert notification["topic_id"] == 77
        assert store.get_ask_topic("__notification__", "-100") is None


@pytest.mark.asyncio
async def test_concurrent_notification_topic_creation_is_serialized():
    cfg = BridgeConfig(group_id=-100, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    topic.created_topic_id = 88
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        event_ids = [
            store.add_event(
                project_root="/p",
                save_id=f"s{idx}",
                topic_id=0,
                telegram_message_id=None,
                event_type="telegram_user_message",
                payload={"title": "T", "reply_chat_id": -100},
                target_instance_id="i1",
            )
            for idx in range(2)
        ]

        results = await asyncio.gather(*[
            client.post(f"/v1/events/{event_id}/result", headers=headers, json={"ok": True, "status": "attached", "message": f"done {idx}"})
            for idx, event_id in enumerate(event_ids)
        ])

        assert [result.status_code for result in results] == [200, 200]
        assert topic.ensure_calls == [None, 88]
        assert [item for item in topic.sent if item[0] == "text"] == [
            ("text", -100, 88, "done 0", None),
            ("text", -100, 88, "done 1", None),
        ]
        notification = store.get_notification_topic(-100)
        assert notification["topic_id"] == 88
        assert store.get_ask_topic("__notification__", "-100") is None


@pytest.mark.asyncio
async def test_human_assist_notify_prompt_input_and_file_api():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        notified = await client.post("/v1/human-assist/notify", headers=headers, json={"message": "done"})
        assert notified.json() == {"success": True, "message_id": 10}
        assert topic.sent[-1][:4] == ("text", 1, None, "done")

        created = await client.post("/v1/human-assist/prompts", headers=headers, json={
            "message": "Choose",
            "buttons": [[{"text": "Retry", "data": "retry"}]],
            "timeout": 60,
        })
        assert created.status_code == 200
        request_id = created.json()["request_id"]
        row = store.get_human_assist_request(request_id)
        assert row["kind"] == "prompt"
        assert row["status"] == "pending"
        assert row["chat_id"] == 1
        assert row["topic_id"] is None

        waiting = await client.get(f"/v1/human-assist/requests/{request_id}?timeout=0", headers=headers)
        assert waiting.json()["status"] == "pending"
        store.complete_human_assist_request(request_id, result={"success": True, "selected": "retry", "button_text": "Retry"})
        completed = await client.get(f"/v1/human-assist/requests/{request_id}?timeout=0", headers=headers)
        assert completed.json()["result"]["selected"] == "retry"

        created_input = await client.post("/v1/human-assist/inputs", headers=headers, json={
            "request_id": "input-fixed",
            "message": "Reply",
            "timeout": 60,
        })
        input_id = created_input.json()["request_id"]
        assert input_id == "input-fixed"
        store.complete_human_assist_request(input_id, result={"success": True, "text": "ok", "photo_file_id": "file-1"})
        downloaded = await client.get(f"/v1/human-assist/files/{input_id}", headers=headers)
        assert downloaded.content == b"image"


@pytest.mark.asyncio
async def test_human_assist_chat_completion_is_atomic_and_closes_telegram():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/v1/human-assist/prompts", headers=headers, json={
            "request_id": "chat-wins",
            "message": "Choose",
            "buttons": [[{"text": "Retry", "data": "retry"}]],
            "timeout": 60,
        })
        assert created.status_code == 200
        completed = await client.post(
            "/v1/human-assist/requests/chat-wins/complete",
            headers=headers,
            json={"source": "chat"},
        )
        assert completed.json()["status"] == "completed"
        assert completed.json()["result"] == {"success": True, "source": "chat"}
        assert topic.sent[-1][0] == "human_assist_edit"

        created = await client.post("/v1/human-assist/inputs", headers=headers, json={
            "request_id": "telegram-wins",
            "message": "Reply",
            "timeout": 60,
        })
        assert created.status_code == 200
        telegram_result = {"success": True, "source": "telegram", "text": "first"}
        assert store.complete_human_assist_request("telegram-wins", result=telegram_result)
        late_chat = await client.post(
            "/v1/human-assist/requests/telegram-wins/complete",
            headers=headers,
            json={"source": "chat"},
        )
        assert late_chat.json()["result"] == telegram_result


@pytest.mark.asyncio
async def test_human_assist_no_timeout_and_cancel_api():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/v1/human-assist/prompts", headers=headers, json={
            "message": "Choose",
            "buttons": [[{"text": "Stop", "data": "interrupt"}]],
            "timeout": 0,
        })
        assert created.status_code == 200
        request_id = created.json()["request_id"]
        assert store.get_human_assist_request(request_id)["expires_at"] is None

        waiting = await client.get(f"/v1/human-assist/requests/{request_id}?timeout=0", headers=headers)
        assert waiting.json()["status"] == "pending"

        cancelled = await client.post(f"/v1/human-assist/requests/{request_id}/cancel", headers=headers)
        assert cancelled.json()["status"] == "cancelled"
        assert cancelled.json()["result"]["error"] == "cancelled"
        assert topic.sent[-1][0] == "human_assist_edit"

        repeated = await client.post(f"/v1/human-assist/requests/{request_id}/cancel", headers=headers)
        assert repeated.json()["status"] == "cancelled"

        missing = await client.post("/v1/human-assist/requests/missing/cancel", headers=headers)
        assert missing.status_code == 200
        assert missing.json()["status"] == "cancelled"
        late_create = await client.post("/v1/human-assist/prompts", headers=headers, json={
            "request_id": "missing",
            "message": "Too late",
            "buttons": [[{"text": "Stop", "data": "interrupt"}]],
            "timeout": 0,
        })
        assert late_create.status_code == 409
        assert store.get_human_assist_request("missing") is None


@pytest.mark.asyncio
async def test_human_assist_requires_owner_before_private_or_session_send():
    cfg = BridgeConfig(group_id=-100, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        for path, payload in (
            ("/v1/human-assist/notify", {"message": "done", "caller_context": {"project_root": "/p", "save_id": "s"}}),
            ("/v1/human-assist/prompts", {"message": "Choose", "buttons": [[{"text": "Retry", "data": "retry"}]]}),
            ("/v1/human-assist/inputs", {"message": "Reply"}),
        ):
            response = await client.post(path, headers=headers, json=payload)
            assert response.status_code == 400
            assert response.json()["detail"] == "owner_user_id is not configured"
    assert topic.sent == []


@pytest.mark.asyncio
async def test_ask_topic_is_reused_without_binding():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    context = {"caller_context": {"project_root": "/p", "save_id": "s"}, "ask_route": True}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first, second = await asyncio.gather(*(
            client.post("/v1/human-assist/notify", headers=headers, json={"message": word, **context})
            for word in ("first", "second")
        ))
        assert first.status_code == second.status_code == 200
        assert topic.ensure_calls == [None]
        assert store.get_ask_topic("/p", "s")["topic_id"] == 42
        assert all(item[:3] == ("text", -100, 42) for item in topic.sent)
        listener = await client.post("/v1/human-assist/notify", headers=headers, json={"message": "listener"})
        assert listener.status_code == 200
        assert topic.sent[-1][:4] == ("text", 1, None, "listener")


@pytest.mark.asyncio
async def test_ask_group_failures_do_not_send_privately():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    context = {"caller_context": {"project_root": "/p", "save_id": "s"}, "ask_route": True}
    async with AsyncClient(transport=ASGITransport(app=app, raise_app_exceptions=False), base_url="http://test") as client:
        missing = await client.post("/v1/human-assist/notify", headers=headers, json={"message": "unknown", "ask_route": True})
        assert missing.status_code == 400
        assert topic.sent == []
        assert (await client.post("/v1/human-assist/notify", headers=headers, json={"message": "first", **context})).status_code == 200
        topic.missing_topics.add(42)
        topic.created_topic_id = 99
        recovered = await client.post("/v1/human-assist/inputs", headers=headers, json={"message": "recovered", **context})
        assert recovered.status_code == 200
        assert store.get_ask_topic("/p", "s")["topic_id"] == 99
        topic.missing_topics.add(99)
        topic.created_topic_id = 100
        topic.missing_topics.add(100)
        failed = await client.post("/v1/human-assist/inputs", headers=headers, json={"message": "failed", **context})
        assert failed.status_code >= 500
        assert not any(item[:3] == ("text", 1, None) for item in topic.sent)
    no_group = create_app(BridgeConfig(owner_user_id=1, bridge_token="tok"), Store(":memory:"), FakeTopic())
    async with AsyncClient(transport=ASGITransport(app=no_group), base_url="http://test") as client:
        missing_group = await client.post("/v1/human-assist/notify", headers=headers, json={"message": "x", **context})
        assert missing_group.status_code == 400


@pytest.mark.asyncio
async def test_human_assist_poll_expires_and_closes_message():
    cfg = BridgeConfig(group_id=-100, owner_user_id=1, bridge_token="tok")
    store = Store(":memory:")
    topic = FakeTopic()
    app = create_app(cfg, store, topic)
    headers = {"X-Maxa-Bridge-Token": "tok"}
    store.create_human_assist_request(
        request_id="expired",
        kind="prompt",
        chat_id=-100,
        topic_id=42,
        telegram_message_id=12,
        prompt_text="Choose",
        payload={"photo": None},
        expires_at=0,
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/human-assist/requests/expired?timeout=0", headers=headers)
    assert response.json()["status"] == "expired"
    assert response.json()["result"]["error"] == "timeout"
    assert topic.sent[-1][0] == "human_assist_edit"


@pytest.mark.asyncio
async def test_auth_required_when_token_configured():
    app = create_app(BridgeConfig(bridge_token="tok"), Store(":memory:"), FakeTopic())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        res = await client.post("/v1/instances/register", json={"instance_id": "i"})
        assert res.status_code == 401


@pytest.mark.asyncio
async def test_topic_exists_accepts_already_open_topic_not_modified():
    class AlreadyOpenBot:
        async def reopen_forum_topic(self, **kwargs):
            raise RuntimeError("Telegram server says - Bad Request: TOPIC_NOT_MODIFIED")

    topic = TelegramTopicService(bot=AlreadyOpenBot(), group_id=-100)

    assert await topic.topic_exists(topic_id=77) is True


@pytest.mark.asyncio
async def test_topic_management_operations_are_idempotent_for_target_state():
    class IdempotentTopicBot:
        async def delete_forum_topic(self, **kwargs):
            raise RuntimeError("Telegram server says - Bad Request: message thread not found")

        async def reopen_forum_topic(self, **kwargs):
            raise RuntimeError("Telegram server says - Bad Request: TOPIC_NOT_MODIFIED")

    topic = TelegramTopicService(bot=IdempotentTopicBot(), group_id=-100)

    await topic.delete_topic(topic_id=77)
    await topic.reopen_topic(topic_id=77)
    assert await topic.topic_exists(topic_id=77) is True
