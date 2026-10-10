"""Shared JSON envelope helpers for the web-fetch CLI."""

from __future__ import annotations

import json
import sys
import time
from typing import Any


def now_ms() -> int:
    return int(time.time() * 1000)


def envelope(
    *,
    ok: bool,
    mode: str,
    data: dict[str, Any] | None,
    error: dict[str, Any] | None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "tool": "web-fetch",
        "mode": mode,
        "data": data,
        "error": error,
        "metadata": metadata or {},
    }


def success(mode: str, data: dict[str, Any], metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    return envelope(ok=True, mode=mode, data=data, error=None, metadata=metadata)


def failure(
    mode: str,
    code: str,
    message: str,
    *,
    retryable: bool = False,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return envelope(
        ok=False,
        mode=mode,
        data=None,
        error={"code": code, "message": message, "retryable": retryable},
        metadata=metadata,
    )


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
