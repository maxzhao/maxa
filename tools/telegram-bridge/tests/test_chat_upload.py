from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from telegram_bridge.api import create_app
from telegram_bridge.bot import TelegramBridgeBot, classify_upload_message
from telegram_bridge.config import BridgeConfig
from telegram_bridge.store import Store
from telegram_bridge.topic import TelegramTopicService, TopicResult
from telegram_bridge.upload_storage import UploadPathError, UploadStorage, UploadTooLarge, safe_filename


class FakeBotDownload:
    def __init__(self, payload: bytes):
        self.payload = payload
        self.calls = []

    async def get_file(self, file_id):
        return SimpleNamespace(file_path=f"remote/{file_id}")

    async def download_file(self, file_path, *, destination, seek=True):
        self.calls.append({"file_path": file_path, "seek": seek})
        destination.write(self.payload)
        if seek:
            destination.seek(0)


class FakeTopicService:
    def __init__(self):
        self.sent = []
        self.download = b"payload"
        self.ensure_calls = []
        self.created_topic_id = 42
        self.missing_topics = set()

    async def ensure_topic(self, *, title, existing_topic_id=None):
        self.ensure_calls.append((title, existing_topic_id))
        return TopicResult(topic_id=existing_topic_id or self.created_topic_id, title=title)

    async def send_text(self, **kwargs):
        self.sent.append(kwargs)
        if kwargs.get("topic_id") in self.missing_topics:
            raise RuntimeError("message thread not found")
        return 91

    async def download_file_stream(self, *, file_id, destination, max_bytes):
        destination.write_bytes(self.download)
        if len(self.download) > max_bytes:
            raise UploadTooLarge()
        return len(self.download)


@pytest.mark.asyncio
async def test_real_topic_download_adapter_disables_aiogram_seek(tmp_path):
    bot = FakeBotDownload(b"telegram-image")
    service = TelegramTopicService(group_id=None, bot=bot)
    destination = tmp_path / "photo.part"

    size = await service.download_file_stream(file_id="photo-id", destination=destination, max_bytes=1024)

    assert size == len(b"telegram-image")
    assert destination.read_bytes() == b"telegram-image"
    assert bot.calls == [{"file_path": "remote/photo-id", "seek": False}]


def open_caller(store: Store, root: Path):
    store.register_instance(instance_id="n1", pid=None, cwd=str(root), project_root=str(root), version=None)
    store.heartbeat(instance_id="n1", open_chats=[{"project_root": str(root), "save_id": "chat-1"}])


def test_chat_upload_accepts_exact_live_caller_when_older_duplicate_is_primary(tmp_path):
    store = Store(":memory:")
    store.register_instance(instance_id="aaa-old", pid=None, cwd=str(tmp_path), project_root=str(tmp_path), version=None)
    store.heartbeat(instance_id="aaa-old", open_chats=[{"project_root": str(tmp_path), "save_id": "chat-1"}])
    store.register_instance(instance_id="zzz-new", pid=None, cwd=str(tmp_path), project_root=str(tmp_path), version=None)
    store.heartbeat(instance_id="zzz-new", open_chats=[{"project_root": str(tmp_path), "save_id": "chat-1"}])
    store.set_ask_topic(str(tmp_path), "chat-1", group_id=-100, topic_id=24, topic_title="Chat")
    service = FakeTopicService()
    client = TestClient(create_app(BridgeConfig(group_id=-100, owner_user_id=7, bridge_token="tok"), store, service))

    created = client.post(
        "/v1/chat-uploads",
        headers={"X-Maxa-Bridge-Token": "tok"},
        json={"instance_id": "zzz-new", "project_root": str(tmp_path), "save_id": "chat-1"},
    )

    assert store.primary_for_session(str(tmp_path), "chat-1", 0)["instance_id"] == "aaa-old"
    assert created.status_code == 200 and created.json()["status"] == "pending"
    assert service.ensure_calls == []
    assert service.sent[-1]["chat_id"] == -100 and service.sent[-1]["topic_id"] == 24
    row = store.get_chat_upload(created.json()["request_id"])
    assert row["chat_id"] == -100 and row["topic_id"] == 24


def test_chat_upload_api_has_no_timeout_and_exact_caller_cancel(tmp_path):
    store = Store(":memory:")
    open_caller(store, tmp_path)
    service = FakeTopicService()
    client = TestClient(create_app(BridgeConfig(group_id=-100, owner_user_id=7, bridge_token="tok"), store, service))
    headers = {"X-Maxa-Bridge-Token": "tok"}
    payload = {"instance_id": "n1", "project_root": str(tmp_path), "save_id": "chat-1"}
    created = client.post("/v1/chat-uploads", headers=headers, json=payload)
    assert created.status_code == 200
    body = created.json()
    assert body["status"] == "pending" and "session_id" in body
    row = store.get_chat_upload(body["request_id"])
    assert row["telegram_message_id"] == 91 and "expires_at" not in row.keys()
    assert row["chat_id"] == -100 and row["topic_id"] == 42
    assert store.get_ask_topic(str(tmp_path), "chat-1")["topic_id"] == 42
    assert service.ensure_calls == [("chat-1", None)]
    assert service.sent[-1]["chat_id"] == -100 and service.sent[-1]["topic_id"] == 42
    assert client.get(f"/v1/chat-uploads/{body['request_id']}?timeout=0", headers=headers).json()["status"] == "pending"
    wrong = dict(payload, save_id="other")
    assert client.post(f"/v1/chat-uploads/{body['request_id']}/cancel", headers=headers, json=wrong).status_code == 403
    assert client.post(f"/v1/chat-uploads/{body['request_id']}/cancel", headers=headers, json=payload).json()["status"] == "cancelled"
    assert client.post(f"/v1/chat-uploads/{body['request_id']}/cancel", headers=headers, json=payload).json()["status"] == "cancelled"


@pytest.mark.parametrize("recovery_fails", [False, True])
def test_chat_upload_recovers_stale_topic_without_private_fallback(tmp_path, recovery_fails):
    store = Store(":memory:")
    open_caller(store, tmp_path)
    store.set_ask_topic(str(tmp_path), "chat-1", group_id=-100, topic_id=24, topic_title="Chat")
    service = FakeTopicService()
    service.missing_topics.add(24)
    if recovery_fails:
        service.missing_topics.add(42)
    client = TestClient(create_app(BridgeConfig(group_id=-100, owner_user_id=7, bridge_token="tok"), store, service))
    response = client.post(
        "/v1/chat-uploads",
        headers={"X-Maxa-Bridge-Token": "tok"},
        json={"instance_id": "n1", "project_root": str(tmp_path), "save_id": "chat-1"},
    )
    assert service.ensure_calls == [("Chat", None)]
    assert [(item["chat_id"], item["topic_id"]) for item in service.sent] == [(-100, 24), (-100, 42)]
    assert store.get_ask_topic(str(tmp_path), "chat-1")["topic_id"] == 42
    if recovery_fails:
        assert response.status_code == 503
        row = store.conn.execute("SELECT * FROM chat_upload_requests").fetchone()
        assert row["status"] == "failed" and row["error_code"] == "telegram_send_failed"
    else:
        assert response.status_code == 200
        row = store.get_chat_upload(response.json()["request_id"])
        assert row["chat_id"] == -100 and row["topic_id"] == 42 and row["telegram_message_id"] == 91


@pytest.mark.parametrize("missing", ["group_id", "owner_user_id"])
def test_chat_upload_requires_group_and_owner_before_sending(tmp_path, missing):
    store = Store(":memory:")
    open_caller(store, tmp_path)
    values = {"group_id": -100, "owner_user_id": 7, "bridge_token": "tok"}
    values.pop(missing)
    service = FakeTopicService()
    client = TestClient(create_app(BridgeConfig(**values), store, service))
    response = client.post(
        "/v1/chat-uploads",
        headers={"X-Maxa-Bridge-Token": "tok"},
        json={"instance_id": "n1", "project_root": str(tmp_path), "save_id": "chat-1"},
    )
    assert response.status_code == 400
    assert response.json()["detail"] == f"{missing} is not configured"
    assert service.sent == [] and service.ensure_calls == []


@pytest.mark.asyncio
async def test_text_reply_precedes_session_routing_and_completes_once(tmp_path):
    store = Store(":memory:")
    store.create_chat_upload(request_id="r1", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=None)
    store.attach_chat_upload_message("r1", chat_id=7, topic_id=None, telegram_message_id=10)
    bot = TelegramBridgeBot(BridgeConfig(owner_user_id=7), store, FakeTopicService())
    message = SimpleNamespace(text="hello", caption=None, media_group_id=None, document=None, photo=None, video=None, audio=None, voice=None, video_note=None, animation=None, sticker=None)
    status, result = await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=None, reply_to_message_id=10, message=message)
    assert (status, result) == ("completed", {"text": "hello"})
    assert store.get_chat_upload("r1")["status"] == "completed"
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=None, reply_to_message_id=10, message=message))[0] == "unmatched"


@pytest.mark.asyncio
async def test_location_reply_completes_with_latitude_and_longitude(tmp_path):
    store = Store(":memory:")
    store.create_chat_upload(request_id="r-location", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=None)
    store.attach_chat_upload_message("r-location", chat_id=7, topic_id=None, telegram_message_id=10)
    bot = TelegramBridgeBot(BridgeConfig(owner_user_id=7), store, FakeTopicService())
    fields = {name: None for name in ("document", "photo", "video", "audio", "voice", "video_note", "animation", "sticker")}
    message = SimpleNamespace(text=None, caption=None, media_group_id=None, location=SimpleNamespace(latitude=31.2304, longitude=121.4737), **fields)

    text, attachment, error = classify_upload_message(message)
    assert (text, attachment, error) == ("纬度：31.2304\n经度：121.4737", None, None)
    status, result = await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=None, reply_to_message_id=10, message=message)

    assert (status, result) == ("completed", {"text": "纬度：31.2304\n经度：121.4737"})
    assert store.get_chat_upload("r-location")["result_text"] == "纬度：31.2304\n经度：121.4737"


@pytest.mark.parametrize("latitude,longitude", [(91, 0), (-91, 0), (0, 181), (0, -181), ("bad", 1)])
def test_invalid_location_remains_unsupported(latitude, longitude):
    fields = {name: None for name in ("document", "photo", "video", "audio", "voice", "video_note", "animation", "sticker")}
    message = SimpleNamespace(text=None, caption=None, media_group_id=None, location=SimpleNamespace(latitude=latitude, longitude=longitude), **fields)
    assert classify_upload_message(message) == (None, None, "unsupported_payload")


@pytest.mark.asyncio
async def test_attachment_mappings_largest_photo_and_storage(tmp_path):
    store = Store(":memory:")
    store.create_chat_upload(request_id="r1", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=None)
    store.attach_chat_upload_message("r1", chat_id=7, topic_id=None, telegram_message_id=10)
    service = FakeTopicService()
    bot = TelegramBridgeBot(BridgeConfig(owner_user_id=7), store, service)
    photo = [SimpleNamespace(file_id="small", file_size=1), SimpleNamespace(file_id="large", file_size=7)]
    message = SimpleNamespace(text=None, caption="caption", media_group_id=None, document=None, photo=photo, video=None, audio=None, voice=None, video_note=None, animation=None, sticker=None)
    text, attachment, error = classify_upload_message(message)
    assert (text, attachment.file_id, attachment.filename, error) == ("caption", "large", "photo.jpg", None)
    status, result = await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=None, reply_to_message_id=10, message=message)
    assert status == "completed"
    assert result["path"].startswith(".maxa/upload/session123/") and result["text"] == "caption"
    assert (tmp_path / result["path"]).read_bytes() == b"payload"
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=None, reply_to_message_id=10, message=message))[0] == "unmatched"


@pytest.mark.parametrize("kind,fallback", [("document", "document"), ("video", "video"), ("audio", "audio"), ("voice", "voice.ogg"), ("video_note", "video-note.mp4"), ("animation", "animation"), ("sticker", "sticker.webp")])
def test_supported_attachment_fallbacks(kind, fallback):
    media = SimpleNamespace(file_id="f", file_size=1, file_name=None, mime_type=None, is_animated=False, is_video=False)
    fields = {name: None for name in ("document", "photo", "video", "audio", "voice", "video_note", "animation", "sticker")}
    fields[kind] = media
    _, attachment, error = classify_upload_message(SimpleNamespace(text=None, caption=None, media_group_id=None, **fields))
    assert error is None and attachment.kind == kind and attachment.filename == fallback


@pytest.mark.asyncio
async def test_storage_collision_cleanup_and_limit(tmp_path):
    storage = UploadStorage(tmp_path, "session123", max_bytes=3)
    assert safe_filename("../../bad\\name.txt", fallback="file") == "name.txt"
    async def good(path, limit):
        path.write_bytes(b"abc")
        return 3
    first = await storage.store("x.txt", good)
    second = await storage.store("x.txt", good)
    assert first.relative_path.endswith("/x.txt") and second.relative_path.endswith("/x-2.txt")
    async def bad(path, limit):
        path.write_bytes(b"abcd")
        raise UploadTooLarge()
    with pytest.raises(UploadTooLarge):
        await storage.store("bad.txt", bad)
    assert not list(storage.session_dir.glob("*.part"))


@pytest.mark.asyncio
async def test_storage_publication_collision_race_never_clobbers(tmp_path, monkeypatch):
    storage = UploadStorage(tmp_path, "session123")
    async def download(path, limit):
        path.write_bytes(b"new")
        return 3
    original_link = __import__("os").link
    raced = False
    def racing_link(source, target):
        nonlocal raced
        if not raced and Path(target).name == "x.txt":
            raced = True
            Path(target).write_bytes(b"winner")
        return original_link(source, target)
    monkeypatch.setattr("telegram_bridge.upload_storage.os.link", racing_link)
    stored = await storage.store("x.txt", download)
    assert (storage.session_dir / "x.txt").read_bytes() == b"winner"
    assert stored.absolute_path.name == "x-2.txt" and stored.absolute_path.read_bytes() == b"new"


@pytest.mark.asyncio
async def test_wrong_reply_identity_and_recoverable_invalid_then_valid(tmp_path):
    store = Store(":memory:")
    store.create_chat_upload(request_id="r1", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=4)
    store.attach_chat_upload_message("r1", chat_id=7, topic_id=4, telegram_message_id=10)
    bot = TelegramBridgeBot(BridgeConfig(owner_user_id=7), store, FakeTopicService())
    text = SimpleNamespace(text="ok", caption=None, media_group_id=None, document=None, photo=None, video=None, audio=None, voice=None, video_note=None, animation=None, sticker=None)
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=8, topic_id=4, reply_to_message_id=10, message=text))[0] == "unauthorized"
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=5, reply_to_message_id=10, message=text))[0] == "unmatched"
    invalid = SimpleNamespace(text=None, caption=None, media_group_id="album", document=None, photo=None, video=None, audio=None, voice=None, video_note=None, animation=None, sticker=None)
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=4, reply_to_message_id=10, message=invalid))[0] == "media_group"
    assert store.get_chat_upload("r1")["status"] == "pending"
    assert (await bot.handle_chat_upload_reply(chat_id=7, user_id=7, topic_id=4, reply_to_message_id=10, message=text))[0] == "completed"


@pytest.mark.asyncio
@pytest.mark.parametrize("size,accepted", [(3, True), (4, False)])
async def test_observed_size_exact_boundary(tmp_path, size, accepted):
    storage = UploadStorage(tmp_path, "session123", max_bytes=3)
    async def download(path, limit):
        path.write_bytes(b"x" * size)
        if size > limit:
            raise UploadTooLarge()
        return size
    if accepted:
        stored = await storage.store("x.bin", download)
        assert stored.size == 3
    else:
        with pytest.raises(UploadTooLarge):
            await storage.store("x.bin", download)
        assert not list(storage.session_dir.glob("*.part"))


@pytest.mark.parametrize("target_kind", ["project_root", "internal", "outside"])
@pytest.mark.asyncio
async def test_storage_rejects_redirected_session_without_write(tmp_path, target_kind):
    session = tmp_path / ".maxa" / "upload" / "session123"
    session.parent.mkdir(parents=True)
    outside = tmp_path.parent / (tmp_path.name + "-outside")
    outside.mkdir(exist_ok=True)
    internal = tmp_path / "other"
    internal.mkdir()
    target = {"project_root": tmp_path, "internal": internal, "outside": outside}[target_kind]
    session.symlink_to(target, target_is_directory=True)
    marker = target / "marker.txt"
    marker.write_text("safe")
    async def download(path, limit):
        path.write_bytes(b"unsafe")
        return 6
    with pytest.raises(UploadPathError):
        storage = UploadStorage(tmp_path, "session123")
        await storage.store("file.txt", download)
    assert marker.read_text() == "safe" and not (target / "file.txt").exists()


def test_storage_rejects_symlinked_upload_root(tmp_path):
    redirected = tmp_path / "redirected"
    redirected.mkdir()
    maxa = tmp_path / ".maxa"
    maxa.mkdir()
    (maxa / "upload").symlink_to(redirected, target_is_directory=True)
    with pytest.raises(UploadPathError):
        UploadStorage(tmp_path, "session123")


def test_restart_recovers_downloading_and_cleans_only_partials(tmp_path):
    database = tmp_path / "bridge.sqlite3"
    store = Store(database)
    store.create_chat_upload(request_id="r1", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=None)
    store.attach_chat_upload_message("r1", chat_id=7, topic_id=None, telegram_message_id=10)
    assert store.claim_chat_upload_download("r1")
    session = tmp_path / ".maxa" / "upload" / "session123"
    session.mkdir(parents=True)
    (session / ".upload-deadbeef.part").write_bytes(b"partial")
    (session / "final.txt").write_bytes(b"final")
    store.close()
    reopened = Store(database)
    row = reopened.get_chat_upload("r1")
    assert row["status"] == "pending" and row["error_code"] == "download_interrupted"
    assert not (session / ".upload-deadbeef.part").exists()
    assert (session / "final.txt").read_bytes() == b"final"


@pytest.mark.parametrize("target_kind", ["project_root", "internal", "outside"])
def test_restart_unsafe_session_converges_without_traversal_or_deletion(tmp_path, target_kind):
    database = tmp_path / "bridge.sqlite3"
    store = Store(database)
    store.create_chat_upload(request_id="r1", instance_id="n1", project_root=str(tmp_path), save_id="s", session_id="session123", chat_id=7, topic_id=None)
    store.attach_chat_upload_message("r1", chat_id=7, topic_id=None, telegram_message_id=10)
    assert store.claim_chat_upload_download("r1")
    store.close()
    upload_root = tmp_path / ".maxa" / "upload"
    upload_root.mkdir(parents=True, exist_ok=True)
    outside = tmp_path.parent / (tmp_path.name + "-restart-outside")
    outside.mkdir(exist_ok=True)
    internal = tmp_path / "other"
    internal.mkdir(exist_ok=True)
    target = {"project_root": tmp_path, "internal": internal, "outside": outside}[target_kind]
    marker = target / ".upload-must-remain.part"
    marker.write_bytes(b"do-not-delete")
    (upload_root / "session123").symlink_to(target, target_is_directory=True)
    reopened = Store(database)
    row = reopened.get_chat_upload("r1")
    assert row["status"] == "pending" and row["error_code"] == "unsafe_upload_path"
    assert marker.read_bytes() == b"do-not-delete"
