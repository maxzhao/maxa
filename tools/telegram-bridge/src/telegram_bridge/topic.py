from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
from pathlib import Path


NOTIFICATION_TOPIC_TITLE = "消息通知"


def is_missing_topic_error(exc: Exception) -> bool:
    text = str(exc).lower()
    return "message thread not found" in text or "topic_id_invalid" in text or "message thread id invalid" in text


def is_topic_not_modified_error(exc: Exception) -> bool:
    text = str(exc).lower()
    return "topic_not_modified" in text or "topic not modified" in text


@dataclass
class TopicResult:
    topic_id: int
    title: str | None = None


class TelegramTopicService:
    """Thin aiogram adapter.

    Tests can replace this class with a fake. Runtime methods intentionally keep
    secrets out of return values and exceptions.
    """

    def __init__(self, bot=None, group_id: int | None = None):
        self.bot = bot
        self.group_id = group_id

    async def ensure_topic(self, *, title: str | None, existing_topic_id: int | None = None) -> TopicResult:
        if existing_topic_id:
            return TopicResult(topic_id=existing_topic_id, title=title)
        if not self.bot or self.group_id is None:
            # Offline/test fallback keeps HTTP API testable without Telegram.
            return TopicResult(topic_id=0, title=title)
        result = await self.bot.create_forum_topic(chat_id=self.group_id, name=(title or "CodeCompanion")[:128])
        return TopicResult(topic_id=int(result.message_thread_id), title=title)

    async def topic_exists(self, *, topic_id: int) -> bool:
        if not topic_id:
            return False
        if not self.bot or self.group_id is None:
            # Offline/test fallback cannot verify Telegram state, so preserve the
            # existing topic unless a fake/test adapter says otherwise.
            return True
        # There is no read-only Bot API endpoint for forum topic existence.
        # Reopening an already-open topic is a bounded probe: Telegram returns
        # missing-topic errors for stale/deleted topics. An already-open topic is
        # also a live topic; reopen_topic treats that idempotent state as success.
        await self.reopen_topic(topic_id=topic_id)
        return True

    async def ensure_notification_topic(self) -> TopicResult:
        return await self.ensure_topic(title=NOTIFICATION_TOPIC_TITLE, existing_topic_id=None)

    async def send_text(self, *, chat_id: int | None = None, topic_id: int | None = None, text: str, reply_to_message_id: int | None = None, reply_markup=None, parse_mode: str | None = None, silent: bool = False) -> int | None:
        target_chat_id = chat_id if chat_id is not None else self.group_id
        if not self.bot or target_chat_id is None:
            return None
        kwargs = {"chat_id": target_chat_id, "text": text, "parse_mode": parse_mode}
        if topic_id:
            kwargs["message_thread_id"] = topic_id
        if reply_to_message_id:
            kwargs["reply_to_message_id"] = reply_to_message_id
        if reply_markup is not None:
            kwargs["reply_markup"] = reply_markup
        if silent:
            kwargs["disable_notification"] = True
        msg = await self.bot.send_message(**kwargs)
        return int(msg.message_id)

    async def send_photo(self, *, chat_id: int | None = None, topic_id: int | None = None, photo, caption: str = "", reply_markup=None, parse_mode: str | None = None, silent: bool = False) -> int | None:
        target_chat_id = chat_id if chat_id is not None else self.group_id
        if not self.bot or target_chat_id is None:
            return None
        kwargs = {"chat_id": target_chat_id, "photo": photo, "caption": caption or None, "parse_mode": parse_mode}
        if topic_id:
            kwargs["message_thread_id"] = topic_id
        if reply_markup is not None:
            kwargs["reply_markup"] = reply_markup
        if silent:
            kwargs["disable_notification"] = True
        msg = await self.bot.send_photo(**kwargs)
        return int(msg.message_id)

    async def edit_human_assist_message(self, *, chat_id: int, message_id: int, text: str, has_photo: bool = False) -> None:
        if not self.bot:
            return
        if has_photo:
            await self.bot.edit_message_caption(chat_id=chat_id, message_id=message_id, caption=text, reply_markup=None, parse_mode=None)
        else:
            await self.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=text, reply_markup=None, parse_mode=None)

    async def download_file_stream(self, *, file_id: str, destination: Path, max_bytes: int) -> int:
        if not self.bot:
            raise RuntimeError("Telegram bot is unavailable")
        file = await self.bot.get_file(file_id)

        class LimitedWriter:
            def __init__(self, path: Path, limit: int):
                self.handle = path.open("xb")
                self.limit = limit
                self.size = 0

            def write(self, data):
                self.size += len(data)
                if self.size > self.limit:
                    from .upload_storage import UploadTooLarge
                    raise UploadTooLarge("observed download exceeds limit")
                return self.handle.write(data)

            def flush(self):
                return self.handle.flush()

            def close(self):
                return self.handle.close()

        writer = LimitedWriter(destination, max_bytes)
        try:
            await self.bot.download_file(file.file_path, destination=writer, seek=False)
            writer.flush()
            return writer.size
        finally:
            writer.close()

    async def download_file_bytes(self, *, file_id: str) -> bytes:
        if not self.bot:
            raise RuntimeError("Telegram bot is unavailable")
        file = await self.bot.get_file(file_id)
        buffer = BytesIO()
        await self.bot.download_file(file.file_path, destination=buffer)
        return buffer.getvalue()

    async def delete_topic(self, *, topic_id: int) -> None:
        if self.bot and self.group_id is not None and topic_id:
            try:
                await self.bot.delete_forum_topic(chat_id=self.group_id, message_thread_id=topic_id)
            except Exception as exc:
                if is_missing_topic_error(exc):
                    return
                raise

    async def delete_messages(self, *, message_ids: list[int]) -> None:
        if not self.bot or self.group_id is None or not message_ids:
            return
        if hasattr(self.bot, "delete_messages"):
            await self.bot.delete_messages(chat_id=self.group_id, message_ids=message_ids)
            return
        for message_id in message_ids:
            await self.bot.delete_message(chat_id=self.group_id, message_id=message_id)

    async def reopen_topic(self, *, topic_id: int) -> None:
        if self.bot and self.group_id is not None and topic_id:
            try:
                await self.bot.reopen_forum_topic(chat_id=self.group_id, message_thread_id=topic_id)
            except Exception as exc:
                if is_topic_not_modified_error(exc):
                    return
                raise
