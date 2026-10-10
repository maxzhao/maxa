"""Functional URL fetch core for the new web-fetch URL modes.

This module is intentionally output-model agnostic: it fetches bytes/text plus
metadata for direct/readable/browser/stealth. Formatting, pattern extraction and
inline/file output are handled by later CLI layers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import time
from typing import Any
from urllib.parse import urlparse

import requests

from dynamic_fetch_adapter import fetch_dynamic
from open_websearch_adapter import fetch_web
from static_fetch_adapter import DEFAULT_USER_AGENT

DEFAULT_MAX_BYTES = 2 * 1024 * 1024
RETRYABLE_STATUS = {408, 425, 429, 500, 502, 503, 504}
TEXTUAL_CONTENT_TYPES = (
    "text/",
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-javascript",
    "application/ld+json",
    "application/rss+xml",
    "application/atom+xml",
    "image/svg+xml",
)


class FetchCoreError(Exception):
    """Typed error raised by functional fetch modes."""

    def __init__(self, code: str, message: str, *, retryable: bool = False, exit_code: int = 1, metadata: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.exit_code = exit_code
        self.metadata = metadata or {}


@dataclass(slots=True)
class FetchCoreResult:
    """Unified result returned by functional fetch modes."""

    mode: str
    content: bytes
    content_type: str = ""
    final_url: str = ""
    status_code: int | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def byte_length(self) -> int:
        return len(self.content)

    def text(self, encoding: str = "utf-8") -> str:
        return self.content.decode(encoding, errors="replace")

    def is_textual(self) -> bool:
        if _is_text_content_type(self.content_type):
            return True
        return _looks_like_text(self.content)

    def to_json_data(self) -> dict[str, Any]:
        """Compatibility helper for the interim JSON-envelope CLI layer."""

        data: dict[str, Any] = {
            "url": self.metadata.get("url") or self.final_url,
            "final_url": self.final_url,
            "content_type": self.content_type,
            "status_code": self.status_code,
            "byte_length": self.byte_length,
            "is_text": self.is_textual(),
        }
        if self.is_textual():
            data["content"] = self.text()
        return data


def _validate_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise FetchCoreError("invalid_arguments", "url must be an absolute http(s) URL", retryable=False, exit_code=2)


def _validate_limits(max_bytes: int, timeout: float) -> None:
    if max_bytes <= 0:
        raise FetchCoreError("invalid_arguments", "max-bytes must be > 0", retryable=False, exit_code=2)
    if timeout <= 0:
        raise FetchCoreError("invalid_arguments", "timeout must be > 0", retryable=False, exit_code=2)


def _proxy_config(proxy_url: str | None) -> dict[str, str] | None:
    return {"http": proxy_url, "https": proxy_url} if proxy_url else None


def _is_text_content_type(content_type: str) -> bool:
    lowered = (content_type or "").split(";", 1)[0].strip().lower()
    return any(lowered.startswith(prefix) for prefix in TEXTUAL_CONTENT_TYPES)


def _looks_like_text(content: bytes) -> bool:
    if not content:
        return True
    sample = content[:4096]
    if b"\x00" in sample:
        return False
    try:
        sample.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def _read_limited_response(response: requests.Response, *, max_bytes: int, url: str) -> bytes:
    chunks: list[bytes] = []
    total = 0
    for chunk in response.iter_content(chunk_size=65536):
        if not chunk:
            continue
        total += len(chunk)
        if total > max_bytes:
            raise FetchCoreError(
                "max_bytes_exceeded",
                f"Response from {url} exceeded --max-bytes ({max_bytes} bytes)",
                retryable=False,
                exit_code=1,
                metadata={"max_bytes": max_bytes, "bytes_read": total},
            )
        chunks.append(chunk)
    return b"".join(chunks)


def fetch_direct(*, url: str, max_bytes: int = DEFAULT_MAX_BYTES, timeout: float = 30, proxy_url: str | None = None) -> FetchCoreResult:
    """Fetch raw HTTP(S) response bytes without Markdown/readability conversion."""

    started = time.perf_counter()
    _validate_url(url)
    _validate_limits(max_bytes, timeout)
    try:
        response = requests.get(
            url,
            headers={"User-Agent": DEFAULT_USER_AGENT},
            allow_redirects=True,
            timeout=timeout,
            proxies=_proxy_config(proxy_url),
            stream=True,
        )
        status_code = response.status_code
        content_type = response.headers.get("content-type", "")
        if status_code >= 400:
            raise FetchCoreError(
                "network_error",
                f"Failed to fetch {url} - status code {status_code}",
                retryable=status_code in RETRYABLE_STATUS,
                exit_code=1,
                metadata={"status_code": status_code, "final_url": response.url, "content_type": content_type},
            )
        content = _read_limited_response(response, max_bytes=max_bytes, url=url)
        return FetchCoreResult(
            mode="direct",
            content=content,
            content_type=content_type,
            final_url=response.url,
            status_code=status_code,
            metadata={
                "source": "direct-http",
                "strategy": "direct",
                "url": url,
                "final_url": response.url,
                "status_code": status_code,
                "content_type": content_type,
                "bytes": len(content),
                "max_bytes": max_bytes,
                "elapsed_ms": int((time.perf_counter() - started) * 1000),
            },
        )
    except requests.exceptions.Timeout as exc:
        raise FetchCoreError("timeout", f"Failed to fetch {url}: {exc}", retryable=True, exit_code=4) from exc
    except requests.exceptions.RequestException as exc:
        raise FetchCoreError("network_error", f"Failed to fetch {url}: {exc}", retryable=True, exit_code=1) from exc


def fetch_readable(*, url: str, max_bytes: int = DEFAULT_MAX_BYTES, timeout: float = 30, proxy_url: str | None = None) -> FetchCoreResult:
    """Fetch readable page text via the vendored open-websearch runtime."""

    started = time.perf_counter()
    _validate_url(url)
    _validate_limits(max_bytes, timeout)
    payload = fetch_web(url=url, max_chars=max_bytes, readability=True, include_links=False, proxy_url=proxy_url, timeout=timeout)
    metadata = dict(payload.get("metadata") or {})
    metadata.update({"source": "open-websearch", "strategy": "readable", "url": url})
    if not payload.get("ok"):
        error = payload.get("error") if isinstance(payload.get("error"), dict) else {}
        code = str(error.get("code") or "extraction_failed")
        message = str(error.get("message") or "open-websearch readable fetch failed")
        raise FetchCoreError(code, f"open-websearch readable fetch failed: {message}", retryable=bool(error.get("retryable")), exit_code=4 if code == "timeout" else 1, metadata=metadata)

    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    content = str(data.get("content") or "")
    encoded = content.encode("utf-8")
    if len(encoded) > max_bytes:
        raise FetchCoreError(
            "max_bytes_exceeded",
            f"Readable content from {url} exceeded --max-bytes ({max_bytes} bytes)",
            retryable=False,
            exit_code=1,
            metadata={**metadata, "bytes": len(encoded), "max_bytes": max_bytes},
        )
    final_url = str(data.get("url") or data.get("finalUrl") or url)
    metadata.update(
        {
            "final_url": final_url,
            "bytes": len(encoded),
            "max_bytes": max_bytes,
            "elapsed_ms": int((time.perf_counter() - started) * 1000),
        }
    )
    return FetchCoreResult(
        mode="readable",
        content=encoded,
        content_type="text/plain; charset=utf-8",
        final_url=final_url,
        status_code=None,
        metadata=metadata,
    )


def _fetch_dynamic_mode(*, public_mode: str, scrapling_mode: str, url: str, max_bytes: int, timeout: float, proxy_url: str | None) -> FetchCoreResult:
    del proxy_url  # The current vendored dynamic adapter does not expose per-request proxy support yet.
    started = time.perf_counter()
    _validate_url(url)
    _validate_limits(max_bytes, timeout)
    payload = fetch_dynamic(url=url, mode=scrapling_mode, output_format="html", max_length=max_bytes, start_index=0)
    metadata = dict(payload.get("metadata") or {})
    metadata.update({"source": "scrapling-fetch", "strategy": public_mode, "scrapling_mode": scrapling_mode, "url": url})
    if not payload.get("ok"):
        error = payload.get("error") if isinstance(payload.get("error"), dict) else {}
        code = str(error.get("code") or "extraction_failed")
        message = str(error.get("message") or "scrapling fetch failed")
        if code == "dependency_missing":
            message = (
                f"{message}. Install/enable scrapling browser dependencies for `{public_mode}`, "
                "or use `web-fetch direct`/`web-fetch readable` for non-browser pages."
            )
        raise FetchCoreError(code, message, retryable=bool(error.get("retryable")), exit_code=3 if code == "dependency_missing" else 1, metadata=metadata)

    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    content = str(data.get("content") or "")
    encoded = content.encode("utf-8")
    if len(encoded) > max_bytes:
        raise FetchCoreError(
            "max_bytes_exceeded",
            f"{public_mode} content from {url} exceeded --max-bytes ({max_bytes} bytes)",
            retryable=False,
            exit_code=1,
            metadata={**metadata, "bytes": len(encoded), "max_bytes": max_bytes},
        )
    final_url = str(data.get("final_url") or url)
    metadata.update({"final_url": final_url, "bytes": len(encoded), "max_bytes": max_bytes, "elapsed_ms": int((time.perf_counter() - started) * 1000)})
    return FetchCoreResult(mode=public_mode, content=encoded, content_type="text/html; charset=utf-8", final_url=final_url, status_code=None, metadata=metadata)


def fetch_browser(*, url: str, max_bytes: int = DEFAULT_MAX_BYTES, timeout: float = 60, proxy_url: str | None = None) -> FetchCoreResult:
    """Fetch pages that need a browser/JS-capable strategy.

    `browser` intentionally maps to a real scrapling browser strategy instead of
    basic HTTP fallback so missing browser dependencies fail clearly.
    """

    return _fetch_dynamic_mode(public_mode="browser", scrapling_mode="stealth", url=url, max_bytes=max_bytes, timeout=timeout, proxy_url=proxy_url)


def fetch_stealth(*, url: str, max_bytes: int = DEFAULT_MAX_BYTES, timeout: float = 60, proxy_url: str | None = None) -> FetchCoreResult:
    """Fetch anti-bot pages with the strongest available scrapling strategy."""

    return _fetch_dynamic_mode(public_mode="stealth", scrapling_mode="max-stealth", url=url, max_bytes=max_bytes, timeout=timeout, proxy_url=proxy_url)


def fetch_by_mode(mode: str, *, url: str, max_bytes: int = DEFAULT_MAX_BYTES, timeout: float | None = None, proxy_url: str | None = None) -> FetchCoreResult:
    if mode == "direct":
        return fetch_direct(url=url, max_bytes=max_bytes, timeout=30 if timeout is None else timeout, proxy_url=proxy_url)
    if mode == "readable":
        return fetch_readable(url=url, max_bytes=max_bytes, timeout=30 if timeout is None else timeout, proxy_url=proxy_url)
    if mode == "browser":
        return fetch_browser(url=url, max_bytes=max_bytes, timeout=60 if timeout is None else timeout, proxy_url=proxy_url)
    if mode == "stealth":
        return fetch_stealth(url=url, max_bytes=max_bytes, timeout=60 if timeout is None else timeout, proxy_url=proxy_url)
    raise FetchCoreError("invalid_arguments", f"unsupported fetch mode: {mode}", retryable=False, exit_code=2)
