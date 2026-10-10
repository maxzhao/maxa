"""Dynamic fetch adapter for `web-fetch dynamic` and `web-fetch pattern`.

This module implements the core capability previously exposed as the
`scrapling-fetch__s_fetch_page` and `scrapling-fetch__s_fetch_pattern` MCP tools,
without starting an MCP server or speaking stdio JSON-RPC.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import re
import sys
import time
from functools import reduce
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import requests

from schema import failure, success
from static_fetch_adapter import DEFAULT_USER_AGENT, _extract_markdown

VALID_MODES = {"basic", "stealth", "max-stealth"}
VALID_FORMATS = {"markdown", "html"}
VENDOR_DIR = Path(__file__).resolve().parents[1] / "vendor" / "scrapling-fetch-mcp"


class DynamicFetchError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


def _validate_common(url: str, mode: str, output_format: str, max_length: int) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise DynamicFetchError("invalid_arguments", "url must be an absolute http(s) URL", False)
    if mode not in VALID_MODES:
        raise DynamicFetchError("invalid_arguments", "mode must be one of: basic, stealth, max-stealth", False)
    if output_format not in VALID_FORMATS:
        raise DynamicFetchError("invalid_arguments", "format must be one of: markdown, html", False)
    if max_length <= 0:
        raise DynamicFetchError("invalid_arguments", "max-length must be > 0", False)


def _ensure_vendor_importable() -> None:
    if not (VENDOR_DIR / "scrapling_fetch_mcp" / "_fetcher.py").exists():
        raise DynamicFetchError("dependency_missing", f"vendored scrapling-fetch-mcp source not found: {VENDOR_DIR}", False)
    vendor_path = str(VENDOR_DIR)
    if vendor_path not in sys.path:
        sys.path.insert(0, vendor_path)


def _missing_dependencies() -> list[str]:
    missing: list[str] = []
    for module_name in ("bs4", "lxml", "markdownify", "scrapling"):
        if importlib.util.find_spec(module_name) is None:
            missing.append(module_name)
    return missing


def _parse_legacy_result(result: str) -> tuple[dict[str, Any], str]:
    prefix = "METADATA: "
    if not result.startswith(prefix):
        return {}, result
    metadata_part, _, content = result[len(prefix) :].partition("\n\n")
    try:
        metadata = json.loads(metadata_part)
    except json.JSONDecodeError:
        metadata = {}
    return metadata, content


def _normalise_metadata(
    legacy_metadata: dict[str, Any],
    *,
    source_mode: str,
    command_mode: str,
    elapsed_ms: int,
    max_length: int,
    start_index: int | None = None,
    context_chars: int | None = None,
) -> dict[str, Any]:
    total_length = int(legacy_metadata.get("total_length", 0) or 0)
    returned_length = int(legacy_metadata.get("retrieved_length", 0) or 0)
    truncated = bool(legacy_metadata.get("is_truncated", False))
    metadata: dict[str, Any] = {
        "source": "scrapling-fetch",
        "elapsed_ms": elapsed_ms,
        "scrapling_mode": source_mode,
        "format": command_mode,
        "max_length": max_length,
        "total_length": total_length,
        "returned_length": returned_length,
        "content_length": total_length,
        "truncated": truncated,
    }
    if start_index is not None:
        metadata["start_index"] = start_index
    if context_chars is not None:
        metadata["context_chars"] = context_chars
    if "match_count" in legacy_metadata:
        metadata["match_count"] = int(legacy_metadata.get("match_count", 0) or 0)
    if "percent_retrieved" in legacy_metadata:
        metadata["percent_retrieved"] = legacy_metadata.get("percent_retrieved")
    if "fallback" in legacy_metadata:
        metadata["fallback"] = legacy_metadata.get("fallback")
    return metadata


async def _call_fetch_page(url: str, mode: str, output_format: str, max_length: int, start_index: int) -> str:
    _ensure_vendor_importable()
    from scrapling_fetch_mcp._fetcher import fetch_page_impl  # type: ignore

    return await fetch_page_impl(url, mode, output_format, max_length, start_index)


async def _call_fetch_pattern(
    url: str,
    search_pattern: str,
    mode: str,
    output_format: str,
    max_length: int,
    context_chars: int,
) -> str:
    _ensure_vendor_importable()
    from scrapling_fetch_mcp._fetcher import fetch_pattern_impl  # type: ignore

    return await fetch_pattern_impl(url, search_pattern, mode, output_format, max_length, context_chars)


def _fetch_basic_content(url: str, output_format: str, timeout: float = 30) -> str:
    response = requests.get(
        url,
        headers={"User-Agent": DEFAULT_USER_AGENT},
        allow_redirects=True,
        timeout=timeout,
    )
    if response.status_code >= 400:
        raise DynamicFetchError(
            "network_error",
            f"Failed to fetch {url} - status code {response.status_code}",
            response.status_code in {408, 425, 429, 500, 502, 503, 504},
        )
    response.encoding = response.encoding or response.apparent_encoding
    html_text = response.text
    if output_format == "html":
        return html_text
    content, _title = _extract_markdown(html_text)
    if not content:
        raise DynamicFetchError("extraction_failed", "Page failed to be simplified from HTML", False)
    return content


def _legacy_metadata_json(
    *,
    total_length: int,
    returned_length: int,
    truncated: bool,
    start_index: int | None = None,
    match_count: int | None = None,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "total_length": total_length,
        "retrieved_length": returned_length,
        "is_truncated": truncated,
        "percent_retrieved": round((returned_length / total_length) * 100, 2) if total_length > 0 else 100,
    }
    if start_index is not None:
        metadata["start_index"] = start_index
    if match_count is not None:
        metadata["match_count"] = match_count
    return metadata


def _search_content(content: str, pattern: str, context_chars: int) -> tuple[str, int]:
    matches = list(re.compile(pattern).finditer(content))
    if not matches:
        return "", 0
    chunks = [
        (max(0, match.start() - context_chars), min(len(content), match.end() + context_chars))
        for match in matches
    ]
    merged_chunks = reduce(
        lambda acc, chunk: (
            [*acc[:-1], (acc[-1][0], max(acc[-1][1], chunk[1]))]
            if acc and chunk[0] <= acc[-1][1]
            else [*acc, chunk]
        ),
        chunks,
        [],
    )
    sections = [f"॥๛॥\n[Position: {start}-{end}]\n{content[start:end]}" for start, end in merged_chunks]
    return "\n".join(sections), len(matches)


def fetch_dynamic(
    *,
    url: str,
    mode: str = "basic",
    output_format: str = "markdown",
    max_length: int = 5000,
    start_index: int = 0,
) -> dict[str, Any]:
    started = time.perf_counter()
    base_metadata: dict[str, Any] = {
        "source": "scrapling-fetch",
        "scrapling_mode": mode,
        "format": output_format,
        "max_length": max_length,
        "start_index": start_index,
        "truncated": False,
    }
    try:
        _validate_common(url, mode, output_format, max_length)
        if start_index < 0:
            raise DynamicFetchError("invalid_arguments", "start-index must be >= 0", False)
        missing = _missing_dependencies()
        if missing and mode != "basic":
            raise DynamicFetchError(
                "dependency_missing",
                "Missing Python dependencies for dynamic fetch: " + ", ".join(missing),
                False,
            )

        if missing:
            full_content = _fetch_basic_content(url, output_format)
            content = full_content[start_index : start_index + max_length]
            legacy_metadata = _legacy_metadata_json(
                total_length=len(full_content),
                returned_length=len(content),
                truncated=len(full_content) > start_index + max_length,
                start_index=start_index,
            )
            legacy_metadata["fallback"] = "basic-http"
        else:
            result = asyncio.run(_call_fetch_page(url, mode, output_format, max_length, start_index))
            legacy_metadata, content = _parse_legacy_result(result)
        metadata = _normalise_metadata(
            legacy_metadata,
            source_mode=mode,
            command_mode=output_format,
            elapsed_ms=int((time.perf_counter() - started) * 1000),
            max_length=max_length,
            start_index=start_index,
        )
        return success(
            "dynamic",
            {"url": url, "content": content, "format": output_format, "scrapling_mode": mode},
            metadata,
        )
    except DynamicFetchError as exc:
        base_metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("dynamic", exc.code, exc.message, retryable=exc.retryable, metadata=base_metadata)
    except Exception as exc:  # noqa: BLE001 - CLI must always return an envelope.
        base_metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        message = str(exc)
        if mode != "basic" and isinstance(exc, ModuleNotFoundError):
            message = (
                f"Missing Python dependencies for dynamic fetch: {exc.name}. "
                "Install/enable scrapling browser dependencies for browser/stealth modes."
            )
            return failure("dynamic", "dependency_missing", message, retryable=False, metadata=base_metadata)
        return failure("dynamic", "extraction_failed", message, retryable=mode != "max-stealth", metadata=base_metadata)


def fetch_pattern(
    *,
    url: str,
    search_pattern: str,
    mode: str = "basic",
    output_format: str = "markdown",
    max_length: int = 5000,
    context_chars: int = 200,
) -> dict[str, Any]:
    started = time.perf_counter()
    base_metadata: dict[str, Any] = {
        "source": "scrapling-fetch",
        "scrapling_mode": mode,
        "format": output_format,
        "max_length": max_length,
        "context_chars": context_chars,
        "truncated": False,
        "match_count": 0,
    }
    try:
        _validate_common(url, mode, output_format, max_length)
        if context_chars < 0:
            raise DynamicFetchError("invalid_arguments", "context-chars must be >= 0", False)
        try:
            re.compile(search_pattern)
        except re.error as exc:
            raise DynamicFetchError("invalid_arguments", f"Invalid regex pattern: {exc}", False) from exc
        missing = _missing_dependencies()
        if missing and mode != "basic":
            raise DynamicFetchError(
                "dependency_missing",
                "Missing Python dependencies for dynamic fetch: " + ", ".join(missing),
                False,
            )

        if missing:
            full_content = _fetch_basic_content(url, output_format)
            matched_content, match_count = _search_content(full_content, search_pattern, context_chars)
            content = matched_content[:max_length]
            legacy_metadata = _legacy_metadata_json(
                total_length=len(full_content),
                returned_length=len(content),
                truncated=len(matched_content) > max_length,
                match_count=match_count,
            )
            legacy_metadata["fallback"] = "basic-http"
        else:
            result = asyncio.run(_call_fetch_pattern(url, search_pattern, mode, output_format, max_length, context_chars))
            legacy_metadata, content = _parse_legacy_result(result)
        metadata = _normalise_metadata(
            legacy_metadata,
            source_mode=mode,
            command_mode=output_format,
            elapsed_ms=int((time.perf_counter() - started) * 1000),
            max_length=max_length,
            context_chars=context_chars,
        )
        return success(
            "pattern",
            {
                "url": url,
                "search_pattern": search_pattern,
                "content": content,
                "format": output_format,
                "scrapling_mode": mode,
                "match_count": metadata.get("match_count", 0),
            },
            metadata,
        )
    except DynamicFetchError as exc:
        base_metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("pattern", exc.code, exc.message, retryable=exc.retryable, metadata=base_metadata)
    except Exception as exc:  # noqa: BLE001 - CLI must always return an envelope.
        base_metadata["elapsed_ms"] = int((time.perf_counter() - started) * 1000)
        return failure("pattern", "extraction_failed", str(exc), retryable=mode != "max-stealth", metadata=base_metadata)
