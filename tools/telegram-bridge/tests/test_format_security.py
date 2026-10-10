from __future__ import annotations

from telegram_bridge.format import chunk_text, escape_html, plain_message_chunks, telegram_message_entities
from telegram_bridge.security import redact_mapping, redact_text


def test_chunk_text_respects_limit():
    chunks = chunk_text("a" * 10, limit=3)
    assert chunks == ["aaa", "aaa", "aaa", "a"]


def test_escape_html():
    assert escape_html("<x>&") == "&lt;x&gt;&amp;"


def test_telegram_message_entities_render_markdown_table_as_aligned_text_and_code():
    chunks = telegram_message_entities("""### Result

| 项目 | Status | Notes |
|---|:---:|---:|
| Markdown | **yes** | 123 |
| 中文宽字符 | ok | 45 |

```python
print('<x>')
```
""")
    text = "\n".join(chunk for chunk, _ in chunks)
    entities = [entity for _, chunk_entities in chunks for entity in chunk_entities]
    assert "Result" in text
    assert "| 项目" in text
    assert "| -------" in text
    assert "| Markdown" in text
    assert "| 中文宽字符" in text
    assert "print('<x>')" in text
    assert "1. 项目:" not in text
    assert any(entity["type"] == "bold" for entity in entities)
    assert sum(1 for entity in entities if entity["type"] == "pre") == 1


def test_regular_markdown_links_are_clickable_without_visible_url():
    chunks = telegram_message_entities("[OpenAI](https://openai.com) and [文档](https://example.com/a?x=1&y=2)")
    text = "\n".join(chunk for chunk, _ in chunks)
    entities = [entity for _, chunk_entities in chunks for entity in chunk_entities]
    assert text == "OpenAI and 文档"
    assert {entity["url"] for entity in entities if entity["type"] == "text_link"} == {
        "https://openai.com",
        "https://example.com/a?x=1&y=2",
    }


def test_table_links_stay_clickable_in_original_cell_without_visible_url():
    chunks = telegram_message_entities("""| 分类 | 新闻 | 具体文章链接 |
|---|---|---|
| 🚀 航天 | **我国成功发射通信技术试验卫星二十六号 A 星** | [新华社：我国成功发射通信技术试验卫星二十六号A星](https://www.xinhuanet.com/tech/20260623/80dc8e8e584c44c981fdb73cda287357/c.html) |
| 🚀 航天 | **长七改火箭成功发射通信技术试验卫星二十六号 A 星** | [科技日报：长七改火箭成功发射通信技术试验卫星二十六号A星](https://www.stdaily.com/web/gdxw/2026-06/23/content_536042.html) |
""")
    text = "\n".join(chunk for chunk, _ in chunks)
    entities = [entity for _, chunk_entities in chunks for entity in chunk_entities]
    assert "| 分类" in text
    assert "| 🚀 航天" in text
    assert "新华社：我国成功发射通信技术试验卫星二十六号A星" in text
    assert "https://www.xinhuanet.com" not in text
    assert "链接：" not in text
    assert not any(entity["type"] == "pre" for entity in entities)
    assert {entity["url"] for entity in entities if entity["type"] == "text_link"} == {
        "https://www.xinhuanet.com/tech/20260623/80dc8e8e584c44c981fdb73cda287357/c.html",
        "https://www.stdaily.com/web/gdxw/2026-06/23/content_536042.html",
    }


def test_plain_message_chunks_do_not_escape_or_render_markdown():
    assert plain_message_chunks("**x** <tag>") == ["**x** <tag>"]


def test_redaction():
    assert "SECRET" not in redact_text("Authorization: Bearer SECRETSECRET")
    redacted = redact_mapping({"bot_token": "123:secret", "nested": {"bridge_secret": "x"}})
    assert redacted["bot_token"] == "<redacted>"
    assert redacted["nested"]["bridge_secret"] == "<redacted>"
