from __future__ import annotations

import re
from collections.abc import Mapping

SECRET_KEYS = ("token", "authorization", "secret", "password", "api_key", "bot_token")
_TOKEN_PATTERNS = [
    re.compile(r"(?i)(bot\d{6,}:[A-Za-z0-9_-]{20,})"),
    re.compile(r"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)(X-Maxa-Bridge-Token\s*[:=]\s*)[^\s]+"),
]


def redact_text(text: object) -> str:
    value = str(text or "")
    for pattern in _TOKEN_PATTERNS:
        if pattern.pattern.startswith("(?i)(Bearer") or "X-Maxa" in pattern.pattern:
            value = pattern.sub(r"\1<redacted>", value)
        else:
            value = pattern.sub("<redacted-token>", value)
    return value


def redact_mapping(data: Mapping[str, object] | None) -> dict[str, object]:
    out: dict[str, object] = {}
    for key, value in (data or {}).items():
        lower = key.lower()
        if any(part in lower for part in SECRET_KEYS):
            out[key] = "<redacted>"
        elif isinstance(value, Mapping):
            out[key] = redact_mapping(value)
        elif isinstance(value, str):
            out[key] = redact_text(value)
        else:
            out[key] = value
    return out


def constant_time_equal(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    if len(left) != len(right):
        return False
    result = 0
    for a, b in zip(left.encode(), right.encode(), strict=True):
        result |= a ^ b
    return result == 0
