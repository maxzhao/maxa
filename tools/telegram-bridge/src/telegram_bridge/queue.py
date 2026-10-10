from __future__ import annotations

from .store import Store


class EventQueue:
    def __init__(self, store: Store):
        self.store = store

    def enqueue_user_message(self, *, project_root: str, save_id: str, topic_id: int, telegram_message_id: int | None, text: str) -> int:
        return self.store.add_event(
            project_root=project_root,
            save_id=save_id,
            topic_id=topic_id,
            telegram_message_id=telegram_message_id,
            event_type="telegram_user_message",
            payload={"text": text},
            status="pending",
        )
