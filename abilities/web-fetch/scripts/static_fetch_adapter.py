"""Static fetch adapter for `web-fetch fetch`.

This module implements the core capability previously exposed as the
`fetch__fetch` MCP tool, without starting an MCP server or speaking stdio
JSON-RPC. It keeps the behavior intentionally close to mcp-server-fetch:
HTTP(S) GET, optional raw response, HTML正文/Markdown-ish extraction, and
`max_length`/`start_index` pagination.
"""

from __future__ import annotations

import html
import re
import time
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urlparse

import requests

from schema import failure, success

DEFAULT_USER_AGENT = (
    "ModelContextProtocol/1.0 (User-Specified; "
    "+https://github.com/modelcontextprotocol/servers)"
)


class WebFetchError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


class _ReadableTextParser(HTMLParser):
    """Small stdlib fallback for readable text extraction.

    The original package uses readabilipy + markdownify. Those dependencies are
    not guaranteed to exist in every Neovim/Python runtime, so this fallback
    removes noisy tags and emits a stable Markdown-like plain text output.
    """

    BLOCK_TAGS = {
        "address",
        "article",
        "aside",
        "blockquote",
        "br",
        "dd",
        "div",
        "dl",
        "dt",
        "fieldset",
        "figcaption",
        "figure",
        "footer",
        "form",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hr",
        "li",
        "main",
        "nav",
        "ol",
        "p",
        "pre",
        "section",
        "table",
        "td",
        "th",
        "tr",
        "ul",
    }
    SKIP_TAGS = {"script", "style", "noscript", "template", "svg", "canvas"}
    TITLE_TAGS = {"h1": "# ", "h2": "## ", "h3": "### ", "h4": "#### ", "h5": "##### ", "h6": "###### "}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0
        self.in_title = False
        self.title_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in self.SKIP_TAGS:
            self.skip_depth += 1
            return
        if tag == "title":
            self.in_title = True
            return
        if self.skip_depth:
            return
        if tag in self.BLOCK_TAGS:
            self._newline()
        if tag in self.TITLE_TAGS:
            self.parts.append(self.TITLE_TAGS[tag])
        if tag == "li":
            self.parts.append("- ")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self.SKIP_TAGS and self.skip_depth:
            self.skip_depth -= 1
            return
        if tag == "title":
            self.in_title = False
            return
        if self.skip_depth:
            return
        if tag in self.BLOCK_TAGS or tag in self.TITLE_TAGS:
            self._newline()

    def handle_data(self, data: str) -> None:
        if self.skip_depth:
            return
        text = html.unescape(data)
        if self.in_title:
            self.title_parts.append(text)
            return
        text = re.sub(r"\s+", " ", text).strip()
        if text:
            self.parts.append(text + " ")

    def _newline(self) -> None:
        if self.parts and not self.parts[-1].endswith("\n"):
            self.parts.append("\n\n")

    def text(self) -> str:
        content = "".join(self.parts)
        content = re.sub(r"[ \t]+\n", "\n", content)
        content = re.sub(r"\n{3,}", "\n\n", content)
        content = re.sub(r"[ \t]{2,}", " ", content)
        return content.strip()

    def title(self) -> str | None:
        title = re.sub(r"\s+", " ", " ".join(self.title_parts)).strip()
        return title or None


def _validate_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise WebFetchError("invalid_arguments", "url must be an absolute http(s) URL", False)


def _extract_markdown(html_text: str) -> tuple[str, str | None]:
    # Prefer the original dependencies when present.
    try:
        import markdownify  # type: ignore
        import readabilipy.simple_json  # type: ignore

        ret = readabilipy.simple_json.simple_json_from_html_string(html_text, use_readability=True)
        title = ret.get("title") if isinstance(ret, dict) else None
        readable = ret.get("content") if isinstance(ret, dict) else None
        if readable:
            content = markdownify.markdownify(readable, heading_style=markdownify.ATX).strip()
            return content, title
    except Exception:
        # Fall through to the stdlib extractor. Missing optional dependencies or
        # readability failures should not make static fetch unusable.
        pass

    parser = _ReadableTextParser()
    parser.feed(html_text)
    return parser.text(), parser.title()


def _slice_content(content: str, start_index: int, max_length: int) -> tuple[str, bool]:
    if start_index < 0:
        raise WebFetchError("invalid_arguments", "start-index must be >= 0", False)
    if max_length <= 0:
        raise WebFetchError("invalid_arguments", "max-length must be > 0", False)
    sliced = content[start_index : start_index + max_length]
    truncated = start_index + max_length < len(content)
    return sliced, truncated


def fetch_static(
    *,
    url: str,
    raw: bool = False,
    max_length: int = 5000,
    start_index: int = 0,
    proxy_url: str | None = None,
    timeout: float = 30,
) -> dict[str, Any]:
    started = time.perf_counter()
    metadata: dict[str, Any] = {
        "source": "fetch",
        "start_index": start_index,
        "max_length": max_length,
        "truncated": False,
    }

    try:
        _validate_url(url)
        proxies = {"http": proxy_url, "https": proxy_url} if proxy_url else None
        response = requests.get(
            url,
            headers={"User-Agent": DEFAULT_USER_AGENT},
            allow_redirects=True,
            timeout=timeout,
            proxies=proxies,
        )
        final_url = response.url
        metadata["status_code"] = response.status_code
        metadata["final_url"] = final_url
        if response.status_code >= 400:
            raise WebFetchError(
                "network_error",
                f"Failed to fetch {url} - status code {response.status_code}",
                response.status_code in {408, 425, 429, 500, 502, 503, 504},
            )

        content_type = response.headers.get("content-type", "")
        response.encoding = response.encoding or response.apparent_encoding
        page_raw = response.text
        is_html = "<html" in page_raw[:200].lower() or "text/html" in content_type.lower() or not content_type

        title = None
        if raw or not is_html:
            content = page_raw
        else:
            content, title = _extract_markdown(page_raw)
            if not content:
                raise WebFetchError("extraction_failed", "Page failed to be simplified from HTML", False)

        content_slice, truncated = _slice_content(content, start_index, max_length)
        metadata.update(
            {
                "elapsed_ms": int((time.perf_counter() - started) * 1000),
                "truncated": truncated,
                "content_type": content_type,
                "content_length": len(content),
            }
        )
        return success(
            "fetch",
            {
                "url": url,
                "final_url": final_url,
                "title": title,
                "content": content_slice,
                "raw": raw or not is_html,
            },
            metadata,
        )
    except requests.exceptions.Timeout as exc:
        metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("fetch", "timeout", f"Failed to fetch {url}: {exc}", retryable=True, metadata=metadata)
    except requests.exceptions.RequestException as exc:
        metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("fetch", "network_error", f"Failed to fetch {url}: {exc}", retryable=True, metadata=metadata)
    except WebFetchError as exc:
        metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("fetch", exc.code, exc.message, retryable=exc.retryable, metadata=metadata)
    except Exception as exc:  # noqa: BLE001 - CLI must always return an envelope.
        metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("fetch", "extraction_failed", str(exc), retryable=False, metadata=metadata)
