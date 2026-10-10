from __future__ import annotations

import os
import shlex
from pathlib import Path
from typing import Mapping

from pydantic import BaseModel, Field


class BridgeConfig(BaseModel):
    enabled: bool = False
    host: str = "127.0.0.1"
    port: int = 8765
    bridge_token: str = ""
    bot_token: str = ""
    group_id: int | None = None
    owner_user_id: int | None = None
    notification_topic_id: int | None = None
    sqlite_path: Path = Field(default_factory=lambda: Path.home() / ".local/share/maxa/telegram-bridge.sqlite3")
    proxy: str | None = None
    heartbeat_ttl: int = 90
    poll_timeout: int = 30

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"


def _truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or key.startswith("#"):
            continue
        if " #" in value and not (value.startswith("'") or value.startswith('"')):
            value = value.split(" #", 1)[0].rstrip()
        try:
            parts = shlex.split(value, posix=True)
            if len(parts) == 1:
                value = parts[0]
        except ValueError:
            value = value.strip('"').strip("'")
        values[key] = value
    return values


def _candidate_env_files(anchor: Path, process_env: Mapping[str, str]) -> list[Path]:
    explicit = process_env.get("MAXA_ENV_FILE")
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    for start in (Path.cwd(), anchor):
        start = start.resolve()
        if start.is_file():
            start = start.parent
        for current in (start, *start.parents):
            candidates.append(current / ".env")

    deduped: list[Path] = []
    seen: set[str] = set()
    for item in candidates:
        key = str(item)
        if key not in seen:
            seen.add(key)
            deduped.append(item)
    return deduped


def _load_dotenv(process_env: Mapping[str, str], *, implicit_search: bool) -> dict[str, str]:
    explicit = process_env.get("MAXA_ENV_FILE")
    if implicit_search:
        candidates = _candidate_env_files(Path(__file__), process_env)
    elif explicit:
        candidates = [Path(explicit).expanduser()]
    else:
        candidates = []

    values: dict[str, str] = {}
    for path in reversed(candidates):
        values.update(_parse_env_file(path))
    return values


def _int_or_none(value: str | None) -> int | None:
    if value in (None, ""):
        return None
    return int(value)


def _resolve_env(env: Mapping[str, str] | None = None) -> dict[str, str]:
    process_env = dict(os.environ if env is None else env)
    resolved = _load_dotenv(process_env, implicit_search=env is None)
    resolved.update({k: v for k, v in process_env.items() if v is not None})
    return resolved


def load_config(env: Mapping[str, str] | None = None) -> BridgeConfig:
    resolved = _resolve_env(env)
    group_id = resolved.get("MAXA_TELEGRAM_GROUP_ID") or resolved.get("MAXA_TELEGRAM_CHAT_ID")
    sqlite_path = resolved.get("MAXA_TELEGRAM_SQLITE_PATH")

    return BridgeConfig(
        enabled=_truthy(resolved.get("MAXA_TELEGRAM_BRIDGE_ENABLED")),
        host=resolved.get("MAXA_TELEGRAM_BRIDGE_HOST", "127.0.0.1"),
        port=int(resolved.get("MAXA_TELEGRAM_BRIDGE_PORT", "8765")),
        bridge_token=resolved.get("MAXA_TELEGRAM_BRIDGE_TOKEN") or "",
        bot_token=resolved.get("MAXA_TELEGRAM_BOT_TOKEN") or "",
        group_id=_int_or_none(group_id),
        owner_user_id=_int_or_none(resolved.get("MAXA_TELEGRAM_OWNER_USER_ID")),
        notification_topic_id=_int_or_none(resolved.get("MAXA_TELEGRAM_NOTIFICATION_TOPIC_ID")),
        sqlite_path=Path(sqlite_path).expanduser() if sqlite_path else Path.home() / ".local/share/maxa/telegram-bridge.sqlite3",
        proxy=resolved.get("ALL_PROXY") or resolved.get("HTTPS_PROXY") or resolved.get("HTTP_PROXY") or None,
        heartbeat_ttl=int(resolved.get("MAXA_TELEGRAM_HEARTBEAT_TTL", "90")),
        poll_timeout=int(resolved.get("MAXA_TELEGRAM_POLL_TIMEOUT", "30")),
    )
