from __future__ import annotations

from typing import Any

from telegram_bridge._vendor.telegramify_markdown import convert, split_entities

TELEGRAM_LIMIT = 4096
SAFE_LIMIT = 3900


def escape_html(text: object) -> str:
    """Legacy helper kept for status/config tests and non-Telegram rendering callers."""
    import html

    return html.escape(str(text or ""), quote=False)


def chunk_text(text: str, limit: int = SAFE_LIMIT) -> list[str]:
    text = str(text or "")
    if limit <= 0:
        raise ValueError("limit must be positive")
    if not text:
        return [""]
    chunks: list[str] = []
    current = ""
    for line in text.splitlines(keepends=True):
        while len(line) > limit:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(line[:limit])
            line = line[limit:]
        if len(current) + len(line) > limit:
            chunks.append(current)
            current = line
        else:
            current += line
    if current or not chunks:
        chunks.append(current)
    return chunks


def telegram_message_entities(content: str, *, limit: int = SAFE_LIMIT) -> list[tuple[str, list[dict[str, Any]]]]:
    """Convert Markdown into Telegram text + MessageEntity dict chunks.

    This is the single rich-formatting path for final assistant messages. It uses
    telegramify-markdown instead of parse_mode so Telegram receives explicit
    entities and tables can be represented as monospace pre blocks.
    """
    text, entities = convert(str(content or ""))
    chunks = split_entities(text, entities, max_utf16_len=limit)
    return [(chunk_text, [entity.to_dict() for entity in chunk_entities]) for chunk_text, chunk_entities in chunks]


def plain_message_chunks(content: str, *, limit: int = SAFE_LIMIT) -> list[str]:
    """Split raw text without Markdown conversion.

    Used only when rich Markdown rendering is disabled by configuration or for
    message classes that must stay predictable, such as terminal errors.
    """
    return chunk_text(str(content or ""), limit)
