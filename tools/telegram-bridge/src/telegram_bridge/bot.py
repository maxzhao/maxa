from __future__ import annotations

import json
import secrets
from dataclasses import dataclass
from typing import Any

from .bot_state import COMMAND_CLEAN_TRACKED_TOPICS, COMMAND_PING, COMMAND_SESSIONS
from .config import BridgeConfig
from .queue import EventQueue
from .registry import Registry
from .store import Store
from .timeutil import now_ts
from .topic import NOTIFICATION_TOPIC_TITLE, TelegramTopicService
from .upload_storage import MAX_UPLOAD_BYTES, UploadStorage, UploadTooLarge, extension_for, safe_filename


SESSION_LIST_LIMIT = 20
CLEAN_CONFIRM_SECONDS = 300
SUPPORTED_UPLOAD_KINDS = ("document", "photo", "video", "audio", "voice", "video_note", "animation", "sticker")


@dataclass(frozen=True)
class UploadAttachment:
    kind: str
    file_id: str
    file_size: int | None
    filename: str


def classify_upload_message(message: Any) -> tuple[str | None, UploadAttachment | None, str | None]:
    if getattr(message, "media_group_id", None):
        return None, None, "media_group"
    present = [kind for kind in SUPPORTED_UPLOAD_KINDS if getattr(message, kind, None)]
    location = getattr(message, "location", None)
    if len(present) + (1 if location else 0) > 1:
        return None, None, "multiple_attachments"
    if location:
        try:
            latitude = float(location.latitude)
            longitude = float(location.longitude)
        except (AttributeError, TypeError, ValueError):
            return None, None, "unsupported_payload"
        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            return None, None, "unsupported_payload"
        return f"纬度：{latitude}\n经度：{longitude}", None, None
    if not present:
        text = str(getattr(message, "text", None) or "").strip()
        return (text, None, None) if text else (None, None, "unsupported_payload")
    kind = present[0]
    media = getattr(message, kind)
    if kind == "photo":
        media = max(media, key=lambda item: int(getattr(item, "file_size", 0) or 0))
    mime_type = getattr(media, "mime_type", None)
    fallback_ext = {"photo": ".jpg", "voice": ".ogg", "video_note": ".mp4", "sticker": ".webp"}.get(kind, "")
    if kind == "sticker":
        fallback_ext = ".tgs" if getattr(media, "is_animated", False) else ".webm" if getattr(media, "is_video", False) else ".webp"
    fallback = {"video_note": "video-note"}.get(kind, kind)
    filename = safe_filename(getattr(media, "file_name", None), fallback=fallback, extension=extension_for(mime_type, fallback_ext))
    attachment = UploadAttachment(kind=kind, file_id=str(media.file_id), file_size=_safe_int(getattr(media, "file_size", None)), filename=filename)
    return str(getattr(message, "caption", None) or "").strip() or None, attachment, None


def sessions_view(rows) -> str:
    if not rows:
        return "当前没有在线的 nvim open chats。"
    visible_rows = rows[:SESSION_LIST_LIMIT]
    running_count = sum(1 for row in rows if row["running"])
    listening_count = sum(1 for row in rows if row["notify_active"])
    lines = [
        f"当前发现 {len(rows)} 个在线 nvim open chats。",
        f"运行中：{running_count}；空闲：{len(rows) - running_count}；监听中：{listening_count}",
    ]
    for row in visible_rows:
        title = row["title"] or row["save_id"]
        project = (row["project_root"] or "").rstrip("/").split("/")[-1]
        running = "运行中" if row["running"] else "空闲"
        listening = "监听中" if row["notify_active"] else "未监听"
        lines.append(f"• {project}：{title} [{running} / {listening}]")
    if len(rows) > len(visible_rows):
        lines.append(f"当前仅显示前 {len(visible_rows)} 个。")
    return "\n".join(lines)


def _safe_int(value: Any) -> int | None:
    try:
        if value in (None, ""):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


class TelegramBridgeBot:
    def __init__(self, config: BridgeConfig, store: Store, topic_service: TelegramTopicService | None = None):
        self.config = config
        self.store = store
        self.registry = Registry(store, config.heartbeat_ttl)
        self.queue = EventQueue(store)
        self.topic_service = topic_service or TelegramTopicService(group_id=config.group_id)

    def _authorized(self, *, group_id: int | None, user_id: int | None) -> bool:
        if self.config.group_id is None or group_id != self.config.group_id:
            return False
        if self.config.owner_user_id is not None and user_id != self.config.owner_user_id:
            return False
        return True

    def _human_assist_authorized(self, row, *, chat_id: int, user_id: int | None) -> bool:
        return (
            self.config.owner_user_id is not None
            and user_id == self.config.owner_user_id
            and row is not None
            and int(row["chat_id"]) == int(chat_id)
        )

    def _complete_human_assist(self, row, result: dict[str, Any]) -> bool:
        return self.store.complete_human_assist_request(row["request_id"], result=result)

    async def handle_human_assist_callback(self, *, group_id: int, user_id: int | None, telegram_message_id: int, callback_data: str) -> tuple[str, dict[str, Any] | None]:
        parts = callback_data.split(":", 2)
        if len(parts) != 3 or parts[0] != "ha":
            return "invalid", None
        request_id, button_ref = parts[1], parts[2]
        row = self.store.get_human_assist_request(request_id)
        if not row or row["status"] != "pending" or row["kind"] != "prompt":
            return "expired", None
        if not self._human_assist_authorized(row, chat_id=group_id, user_id=user_id):
            return "unauthorized", None
        if row["expires_at"] is not None and now_ts() >= int(row["expires_at"]):
            self.store.expire_human_assist_request(request_id, result={"success": False, "error": "timeout"})
            return "expired", None
        if row["telegram_message_id"] is not None and int(row["telegram_message_id"]) != int(telegram_message_id):
            return "expired", None
        try:
            row_index, button_index = (int(value) for value in button_ref.split(".", 1))
            button = json.loads(row["payload_json"])["buttons"][row_index][button_index]
            selected = str(button["data"])
            button_text = str(button.get("text") or selected)
        except (KeyError, IndexError, TypeError, ValueError):
            return "invalid", None
        result = {"success": True, "source": "telegram", "selected": selected, "button_text": button_text}
        return ("completed", result) if self._complete_human_assist(row, result) else ("expired", None)

    async def handle_human_assist_reply(self, *, group_id: int, user_id: int | None, reply_to_message_id: int, text: str, photo_file_id: str | None = None) -> tuple[str, dict[str, Any] | None]:
        row = self.store.find_pending_human_assist_by_message(chat_id=group_id, telegram_message_id=reply_to_message_id)
        if not row or row["kind"] not in {"prompt", "input"}:
            return "unmatched", None
        if not self._human_assist_authorized(row, chat_id=group_id, user_id=user_id):
            return "unauthorized", None
        if row["expires_at"] is not None and now_ts() >= int(row["expires_at"]):
            self.store.expire_human_assist_request(row["request_id"], result={"success": False, "error": "timeout"})
            return "expired", None
        if not text.strip() and (row["kind"] == "prompt" or not photo_file_id):
            return "unmatched", None
        result: dict[str, Any] = {"success": True, "source": "telegram", "text": text}
        if row["kind"] == "input" and photo_file_id:
            result["photo_file_id"] = photo_file_id
        return ("completed", result) if self._complete_human_assist(row, result) else ("expired", None)

    async def handle_chat_upload_reply(self, *, chat_id: int, user_id: int | None, topic_id: int | None, reply_to_message_id: int, message: Any) -> tuple[str, dict[str, Any] | None]:
        row = self.store.find_pending_chat_upload_by_message(chat_id=chat_id, topic_id=topic_id, telegram_message_id=reply_to_message_id)
        if not row:
            return "unmatched", None
        if self.config.owner_user_id is None or user_id != self.config.owner_user_id:
            return "unauthorized", None
        text, attachment, error = classify_upload_message(message)
        if error:
            return error, None
        if attachment is None:
            completed = self.store.complete_chat_upload(row["request_id"], path=None, text=text, expected_status="pending")
            return ("completed", {"text": text}) if completed else ("duplicate", None)
        if attachment.file_size is not None and attachment.file_size > MAX_UPLOAD_BYTES:
            return "file_too_large", None
        if not self.store.claim_chat_upload_download(row["request_id"]):
            return "duplicate", None
        storage = UploadStorage(row["project_root"], row["session_id"])
        try:
            stored = await storage.store(
                attachment.filename,
                lambda destination, limit: self.topic_service.download_file_stream(file_id=attachment.file_id, destination=destination, max_bytes=limit),
            )
        except UploadTooLarge:
            self.store.restore_chat_upload_pending(row["request_id"], error_code="file_too_large", error_message="file exceeds 20 MB")
            return "file_too_large", None
        except Exception:
            self.store.restore_chat_upload_pending(row["request_id"], error_code="download_failed", error_message="file download failed")
            return "download_failed", None
        completed = self.store.complete_chat_upload(row["request_id"], path=stored.relative_path, text=text, expected_status="downloading")
        return ("completed", {"path": stored.relative_path, "text": text}) if completed else ("duplicate", None)

    async def handle_topic_text(self, *, group_id: int, user_id: int | None, topic_id: int, telegram_message_id: int | None, text: str) -> str:
        if not self._authorized(group_id=group_id, user_id=user_id) or self.config.owner_user_id is None:
            return "unauthorized"
        topic = self.store.get_ask_topic_by_topic(group_id, topic_id)
        if not topic:
            return "unknown"
        project_root, save_id = topic["project_root"], topic["save_id"]
        primary = self.registry.primary_for(project_root, save_id)
        if not primary:
            return "inactive"
        chat = self.store.open_chat_for_instance(
            instance_id=primary, project_root=project_root, save_id=save_id, alive_after=self.registry.alive_after
        )
        if not chat or not chat["notify_active"]:
            return "not_listening"
        if chat["running"] or self.store.has_inflight_user_message(project_root, save_id):
            return "busy"
        self.queue.enqueue_user_message(
            project_root=project_root,
            save_id=save_id,
            topic_id=topic_id,
            telegram_message_id=telegram_message_id,
            text=text,
        )
        return "pending"


def build_dispatcher(config: BridgeConfig, store: Store, topic_service: TelegramTopicService | None = None) -> Any:
    # Import lazily so tests and offline syntax checks do not require aiogram at import time.
    from aiogram import Dispatcher, F, Router
    from aiogram.filters import Command
    from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, Message

    topic_service = topic_service or TelegramTopicService(group_id=config.group_id)
    bridge_bot = TelegramBridgeBot(config, store, topic_service)
    router = Router()
    pending_clean: dict[str, tuple[int, int, int, tuple[int, ...]]] = {}

    def topic_id_for(message: Message) -> int:
        return int(getattr(message, "message_thread_id", None) or 0)

    def is_general(message: Message) -> bool:
        # Telegram's General topic may use thread 1; ordinary General messages
        # can also omit message_thread_id entirely.
        return topic_id_for(message) <= 1

    @router.message.outer_middleware()
    async def track_seen_topic(handler, message: Message, data):
        if int(message.chat.id) == config.group_id:
            topic_id = topic_id_for(message)
            if not topic_id and getattr(message, "forum_topic_created", None):
                topic_id = int(message.message_id)
            store.track_topic(int(message.chat.id), topic_id)
        return await handler(message, data)

    def message_ids(message: Message) -> tuple[int, int | None, int]:
        chat_id = int(message.chat.id)
        user_id = int(message.from_user.id) if message.from_user else None
        return chat_id, user_id, topic_id_for(message)

    async def ensure_command_authorized(message: Message) -> bool:
        chat_id, user_id, _ = message_ids(message)
        if not bridge_bot._authorized(group_id=chat_id, user_id=user_id):
            await message.answer("未授权。")
            return False
        return True

    async def ensure_command_scope(message: Message, *, general: bool) -> bool:
        if not await ensure_command_authorized(message):
            return False
        if is_general(message) != general:
            await message.answer("请在 General 中执行此命令。" if general else "请在非 General 的目标 topic 中执行此命令。")
            return False
        return True

    async def ensure_general_callback(callback) -> bool:
        message = callback.message
        if not isinstance(message, Message):
            await callback.answer("无法确认消息所在主题", show_alert=True)
            return False
        chat_id = int(message.chat.id)
        user_id = int(callback.from_user.id) if callback.from_user else None
        if not bridge_bot._authorized(group_id=chat_id, user_id=user_id):
            await callback.answer("未授权", show_alert=True)
            return False
        if not is_general(message):
            await callback.answer("仅可在 General 中操作", show_alert=True)
            return False
        return True

    @router.message(Command(COMMAND_PING))
    async def ping(message: Message) -> None:
        if not await ensure_command_scope(message, general=True):
            return
        await message.answer("pong")

    async def render_sessions_message(message: Message) -> None:
        rows = store.list_live_open_chats(bridge_bot.registry.alive_after)
        await message.answer(sessions_view(rows))

    @router.message(Command(COMMAND_SESSIONS))
    async def sessions(message: Message) -> None:
        if not await ensure_command_scope(message, general=True):
            return
        await render_sessions_message(message)

    @router.callback_query(F.data.startswith("ha:"))
    async def human_assist_callback(callback) -> None:
        message = callback.message
        if message is None:
            await callback.answer("missing message", show_alert=True)
            return
        chat_id = int(message.chat.id)
        user_id = int(callback.from_user.id) if callback.from_user else None
        status, result = await bridge_bot.handle_human_assist_callback(
            group_id=chat_id,
            user_id=user_id,
            telegram_message_id=int(message.message_id),
            callback_data=str(callback.data or ""),
        )
        if status == "unauthorized":
            await callback.answer("未授权", show_alert=True)
            return
        if status != "completed" or not result:
            await callback.answer("该请求已处理或已过期", show_alert=True)
            return
        selected_text = result.get("button_text") or result.get("selected") or ""
        await callback.answer(f"已收到: {selected_text}")
        original = str(getattr(message, "text", None) or getattr(message, "caption", None) or "").rstrip()
        status_text = f"✅ 已收到选择：{selected_text}\n状态：该请求已响应，正在处理中…"
        try:
            await topic_service.edit_human_assist_message(
                chat_id=chat_id,
                message_id=int(message.message_id),
                text=f"{original}\n\n{status_text}" if original else status_text,
                has_photo=bool(getattr(message, "photo", None)),
            )
        except Exception:
            try:
                await message.edit_reply_markup(reply_markup=None)
            except Exception:
                pass

    def tracked_session(chat_id: int, topic_id: int):
        tracked = store.get_tracked_topic(chat_id, topic_id)
        if tracked and tracked["project_root"] is not None and tracked["save_id"] is not None:
            return tracked["project_root"], tracked["save_id"]
        return None

    def live_sessions() -> set[tuple[str, str]]:
        # Same live open-chat source as /sessions, including restored history chats.
        return {(row["project_root"], row["save_id"]) for row in store.list_live_open_chats(bridge_bot.registry.alive_after)}

    @router.message(Command(COMMAND_CLEAN_TRACKED_TOPICS))
    async def clean_tracked_topics(message: Message) -> None:
        if not await ensure_command_scope(message, general=True):
            return
        chat_id, user_id, _ = message_ids(message)
        if config.owner_user_id is None or user_id != config.owner_user_id:
            await message.answer("批量清理需要配置 MAXA_TELEGRAM_OWNER_USER_ID 并由该用户执行。")
            return
        if getattr(topic_service, "bot", None) is None:
            await message.answer("Telegram Bot 不在线，无法清理主题。")
            return
        if not store.list_live_instances(bridge_bot.registry.alive_after):
            await message.answer("当前没有在线 nvim 实例，无法安全判断哪些 chat 已打开；未清理任何主题。")
            return
        tracked_ids = store.list_tracked_topics(chat_id)
        active = live_sessions()
        topic_ids = []
        protected = 0
        unknown = 0
        for topic_id in tracked_ids:
            session = tracked_session(chat_id, topic_id)
            if session is None:
                unknown += 1
            elif session in active:
                protected += 1
            else:
                topic_ids.append(topic_id)
        if not topic_ids:
            await message.answer(f"没有可安全清理的非活跃会话主题；保留 {protected} 个在线 chat 主题，跳过 {unknown} 个归属未知或系统主题。未记录的主题不会被清理。")
            return
        pending_clean.clear()
        token = secrets.token_urlsafe(12)
        pending_clean[token] = (chat_id, user_id, now_ts() + CLEAN_CONFIRM_SECONDS, topic_ids)
        markup = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="确认删除", callback_data=f"clean_topics:confirm:{token}"),
             InlineKeyboardButton(text="取消", callback_data=f"clean_topics:cancel:{token}")],
        ])
        await message.answer(
            f"将清理 {len(topic_ids)} 个未在在线 nvim 中打开的已跟踪会话主题及其消息；"
            f"保留 {protected} 个在线 chat 主题（含从历史恢复后打开的 chat），跳过 {unknown} 个归属未知或系统主题。"
            "\n未记录的主题不会被清理；此操作不可撤销。请在 5 分钟内确认。",
            reply_markup=markup,
        )

    @router.callback_query(F.data.startswith("clean_topics:"))
    async def clean_tracked_topics_callback(callback) -> None:
        if not await ensure_general_callback(callback):
            return
        message = callback.message
        user_id = int(callback.from_user.id) if callback.from_user else None
        if config.owner_user_id is None or user_id != config.owner_user_id:
            await callback.answer("仅配置的 owner 可执行批量清理", show_alert=True)
            return
        parts = str(callback.data).split(":", 2)
        if len(parts) != 3 or parts[1] not in {"confirm", "cancel"}:
            await callback.answer("无效操作", show_alert=True)
            return
        action, token = parts[1:]
        pending = pending_clean.pop(token, None)
        if not pending or pending[0] != int(message.chat.id) or pending[1] != user_id or now_ts() > pending[2]:
            await callback.answer("确认已过期，请重新执行命令", show_alert=True)
            return
        await callback.answer("已取消" if action == "cancel" else "正在清理")
        await message.edit_reply_markup(reply_markup=None)
        if action == "cancel":
            return
        if not store.list_live_instances(bridge_bot.registry.alive_after):
            await message.answer("确认时没有在线 nvim 实例，无法安全判断哪些 chat 已打开；未清理任何主题。")
            return
        deleted: list[int] = []
        kept: list[int] = []
        unknown: list[int] = []
        failed: list[int] = []
        chat_id = int(message.chat.id)
        for topic_id in pending[3]:
            if topic_id not in store.list_tracked_topics(chat_id):
                continue
            session = tracked_session(chat_id, topic_id)
            if session is None:
                unknown.append(topic_id)
                continue
            # A history chat may have been restored since the confirmation was shown.
            if session in live_sessions():
                kept.append(topic_id)
                continue
            try:
                await topic_service.delete_topic(topic_id=topic_id)
                store.forget_topic(chat_id, topic_id)
                deleted.append(topic_id)
            except Exception:
                failed.append(topic_id)
        await message.answer(
            f"已删除 {len(deleted)} 个非活跃会话主题；新激活而保留 {len(kept)} 个；"
            f"归属不明而跳过 {len(unknown)} 个；失败 {len(failed)} 个。在线 nvim chat 保持打开。"
            + (f"\n失败主题 ID：{', '.join(map(str, failed))}。可重新执行命令重试。" if failed else "")
        )

    async def answer_topic_result(message: Message, result: str) -> None:
        replies = {
            "pending": "✅ 已收到 Telegram 消息，正在提交到 Chat；若提交前 Chat 状态变化，会另行告知。",
            "busy": "会话正在运行或已有 Telegram 消息待处理；本条消息未提交，请在本轮结束后重新发送。",
            "inactive": "会话未打开；本条消息未提交。",
            "not_listening": "当前 chat 未开启 notify 监听；本条消息未提交。",
            "unknown": "当前主题未关联 ask/notify 会话；本条消息未提交。",
            "unauthorized": "未授权。",
        }
        if result in replies:
            await message.answer(replies[result])

    @router.message(F.reply_to_message)
    async def human_assist_reply(message: Message) -> None:
        chat_id = int(message.chat.id)
        user_id = int(message.from_user.id) if message.from_user else None
        reply_to_message_id = int(message.reply_to_message.message_id)
        topic_id = int(message.message_thread_id or 0) or None
        upload_status, _ = await bridge_bot.handle_chat_upload_reply(
            chat_id=chat_id,
            user_id=user_id,
            topic_id=topic_id,
            reply_to_message_id=reply_to_message_id,
            message=message,
        )
        if upload_status == "completed":
            if getattr(message, "location", None):
                acknowledgement = "✅ 已收到定位信息，正在写入 Chat。"
            elif any(getattr(message, kind, None) for kind in SUPPORTED_UPLOAD_KINDS):
                acknowledgement = "✅ 文件已接收，正在写入 Chat。"
            else:
                acknowledgement = "✅ 已收到文字，正在写入 Chat。"
            await message.answer(acknowledgement)
            return
        if upload_status in {"media_group", "multiple_attachments"}:
            await message.answer("一次只能发送一个文件，请重新回复原消息。")
            return
        if upload_status == "file_too_large":
            await message.answer("文件超过 20 MB，请回复较小的文件或纯文字。")
            return
        if upload_status in {"unsupported_payload", "download_failed"}:
            await message.answer("请回复一个受支持的文件、纯文字或定位信息。")
            return
        if upload_status in {"unauthorized", "duplicate"}:
            return
        photo_file_id = str(message.photo[-1].file_id) if message.photo else None
        status, _ = await bridge_bot.handle_human_assist_reply(
            group_id=chat_id,
            user_id=user_id,
            reply_to_message_id=reply_to_message_id,
            text=message.text or message.caption or "",
            photo_file_id=photo_file_id,
        )
        if status == "completed":
            await message.answer("✅ 已收到您的回复，正在处理中...")
            original_message = message.reply_to_message
            original = str(getattr(original_message, "text", None) or getattr(original_message, "caption", None) or "").rstrip()
            status_text = "✅ 已收到回复\n状态：该请求已响应，正在处理中…"
            try:
                await topic_service.edit_human_assist_message(
                    chat_id=chat_id,
                    message_id=reply_to_message_id,
                    text=f"{original}\n\n{status_text}" if original else status_text,
                    has_photo=bool(getattr(original_message, "photo", None)),
                )
            except Exception:
                try:
                    await original_message.edit_reply_markup(reply_markup=None)
                except Exception:
                    pass
            return
        if status == "unauthorized":
            await message.answer("未授权。")
            return
        if (message.text or "").startswith("/"):
            await message.answer("不支持的 Telegram 命令。")
            return
        topic_id = int(message.message_thread_id or 0)
        result = await bridge_bot.handle_topic_text(
            group_id=chat_id,
            user_id=user_id,
            topic_id=topic_id,
            telegram_message_id=int(message.message_id),
            text=message.text or message.caption or "",
        )
        await answer_topic_result(message, result)

    @router.message(F.text.startswith("/"))
    async def unsupported_command(message: Message) -> None:
        if await ensure_command_authorized(message):
            await message.answer("不支持的 Telegram 命令。")

    @router.message(F.text)
    async def text(message: Message) -> None:
        chat_id = int(message.chat.id)
        user_id = int(message.from_user.id) if message.from_user else None
        topic_id = int(message.message_thread_id or 0)
        result = await bridge_bot.handle_topic_text(
            group_id=chat_id,
            user_id=user_id,
            topic_id=topic_id,
            telegram_message_id=int(message.message_id),
            text=message.text or "",
        )
        await answer_topic_result(message, result)

    dp = Dispatcher()
    dp.include_router(router)
    return dp
