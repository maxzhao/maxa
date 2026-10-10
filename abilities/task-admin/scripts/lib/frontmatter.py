"""Minimal YAML helpers for TaskAdmin metadata files.

TaskAdmin interprets bare `_meta.yaml` and `state.yaml` files only. Task plans,
TODOs, and supporting documents remain ordinary Markdown.
"""

import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


TASK_META_FIELDS = [
    "name",
    "description",
    "status",
    "priority",
    "dependencies",
    "created",
    "updated",
    "workspace",
]
TAG_META_FIELDS = ["description", "created", "updated", "version", "workspace"]
STATE_FIELDS = ["currentTag", "lastSwitched"]


def now_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def read_yaml_file(filepath: str) -> Dict[str, Any]:
    """Read one bare YAML metadata file."""
    text = Path(filepath).read_text(encoding="utf-8")
    if text.startswith("---"):
        raise ValueError(f"Frontmatter-wrapped metadata is unsupported: {filepath}")
    return parse_yaml(text)


def parse_yaml(text: str) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)$", line)
        if not match:
            raise ValueError(f"Unsupported YAML line: {raw}")
        result[match.group(1)] = parse_yaml_value(match.group(2).strip())
    return result


def parse_yaml_value(value: str) -> Any:
    if value == "":
        return ""
    if value.startswith("[") and value.endswith("]"):
        return parse_inline_array(value)
    if value.startswith('"') and value.endswith('"'):
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid quoted YAML scalar: {value}") from exc
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "~"}:
        return None
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    return value


def parse_inline_array(value: str) -> List[Any]:
    inner = value[1:-1].strip()
    if not inner:
        return []
    return [parse_yaml_value(item.strip()) for item in inner.split(",") if item.strip()]


def serialize(meta: Dict[str, Any], fields: Optional[list[str]] = None) -> str:
    order = fields or TASK_META_FIELDS
    lines: list[str] = []
    seen: set[str] = set()
    for field in order:
        if field in meta and meta[field] is not None:
            lines.append(f"{field}: {serialize_value(meta[field])}")
            seen.add(field)
    for key, value in meta.items():
        if key not in seen and value is not None:
            lines.append(f"{key}: {serialize_value(value)}")
    return "\n".join(lines)


def serialize_value(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(serialize_value(item) for item in value) + "]"
    text = str(value)
    if needs_quoting(text):
        return json.dumps(text, ensure_ascii=False)
    return text


def needs_quoting(value: str) -> bool:
    if not value:
        return True
    if value[0] in "\"'[]{}|>&*!%@`#,?:-":
        return True
    if any(char in value for char in "\n\r\t:#"):
        return True
    if value.lower() in {"true", "false", "null", "yes", "no", "on", "off", "~"}:
        return True
    if re.fullmatch(r"-?\d+(?:\.\d+)?", value):
        return True
    return False


def write_yaml_file(filepath: str, meta: Dict[str, Any], fields: Optional[list[str]] = None) -> None:
    """Atomically replace one metadata file."""
    path = Path(filepath)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = serialize(meta, fields) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def update_metadata(filepath: str, updates: Dict[str, Any], fields: Optional[list[str]] = None) -> Dict[str, Any]:
    meta = read_yaml_file(filepath)
    for key, value in updates.items():
        if value is None:
            meta.pop(key, None)
        else:
            meta[key] = value
    meta["updated"] = now_timestamp()
    write_yaml_file(filepath, meta, fields)
    return meta


def create_task_metadata(
    name: str,
    description: str = "",
    status: str = "pending",
    priority: str = "medium",
    dependencies: Optional[list[int]] = None,
    workspace: Optional[str] = None,
) -> Dict[str, Any]:
    now = now_timestamp()
    meta: Dict[str, Any] = {
        "name": name,
        "description": description,
        "status": status,
        "priority": priority,
        "dependencies": dependencies or [],
        "created": now,
        "updated": now,
    }
    if workspace:
        meta["workspace"] = workspace
    return meta
