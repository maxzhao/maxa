#!/usr/bin/env python3
"""Export Maxa session traces to Obsidian Canvas and Markdown.

After load(target="session"), call @session:/scripts/trace_visualize.py
with params.args = ["--project-root", "<PROJECT_ROOT>", "--root-trace-id", "<id>"].
Substitute actual paths/IDs; the cataloged executor owns Python/uv.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
GENERATOR = "session-admin trace_visualize.py"
DEFAULT_MAX_EVENTS = 200
DEFAULT_EXCERPT_CHARS = 220
TRUNCATE_SUFFIX = "...[truncated]"
SUPPORTED_FORMATS = {"canvas", "markdown"}
SUPPORTED_NODE_TYPES = {"text", "file", "link", "group"}
STIGNORE_VISUALIZATION_RULES = [
    "!/history",
    "!/history/traces",
    "!/history/traces/*",
    "!/history/traces/*/visualization",
    "!/history/traces/*/visualization/**",
]
RAW_HISTORY_IGNORE_RULES = ["(?d)/history", "(?d)/history/**"]
NATURAL_TURN_KINDS = {"main_turn.user_prompt", "main_turn.agent_reply", "main_turn.agent_error"}
ACTION_KINDS = {
    "trace.started",
    "trace.backfilled",
    "session.linked",
    "fork.created",
    "scratch.created",
    "scratch.saved",
    "scratch.merged",
    "fragment.inserted",
    "subagent.started",
    "subagent.completed",
    "subagent.error",
    "ask_llm.completed",
    "multi_agent.completed",
    "compression.archive_created",
    "compression.applied",
}
ROLE_COLORS = {
    "root": "1",
    "fork": "2",
    "scratch": "3",
    "promoted_scratch": "3",
    "subagent": "4",
    "resumed": "5",
    "synthesized": "6",
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stable_id(*parts: Any) -> str:
    text = "\x1f".join(str(p) for p in parts if p is not None)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def safe_trace_id(value: str, label: str) -> str:
    if not value or "/" in value or "\\" in value or value in {".", ".."}:
        raise ValueError(f"{label} must be a non-empty path-safe id")
    return value


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json_atomic(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    atomic_write_text(path, payload)


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as tmp:
            tmp.write(text)
        os.replace(tmp_name, path)
    finally:
        try:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        except OSError:
            pass


def truncate_text(value: Any, max_chars: int) -> str:
    if value is None:
        text = ""
    elif isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, ensure_ascii=False, sort_keys=True)
        except TypeError:
            text = str(value)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if max_chars < 1:
        return ""
    if len(text) <= max_chars:
        return text
    keep = max(0, max_chars - len(TRUNCATE_SUFFIX))
    return text[:keep] + TRUNCATE_SUFFIX


def md_escape_cell(value: Any) -> str:
    text = truncate_text(value, 1000)
    text = text.replace("|", "\\|").replace("\n", "<br>")
    return text


def yaml_scalar(value: Any) -> str:
    text = str(value if value is not None else "")
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def read_jsonl(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    events: list[dict[str, Any]] = []
    parse_errors: list[dict[str, Any]] = []
    if not path.exists():
        return events, [{"line": 0, "error": f"events file not found: {path}"}]
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                events.append(value)
            else:
                parse_errors.append({"line": line_no, "error": "event line is not an object"})
        except json.JSONDecodeError as exc:
            parse_errors.append({"line": line_no, "error": str(exc)})
    return events, parse_errors


def is_visible_conversation_message(msg: dict[str, Any]) -> bool:
    role = msg.get("role")
    if role not in {"user", "llm", "assistant"}:
        return False
    if msg.get("context") or msg.get("visible") is False:
        return False
    if msg.get("tools") or msg.get("tool_calls") or msg.get("tool_call_id"):
        return False
    meta = msg.get("_meta") if isinstance(msg.get("_meta"), dict) else {}
    if meta.get("inserted_from_fragment"):
        return False
    tags = set(meta.get("tags") or [])
    ignored = {"system_prompt_from_config", "rules", "file", "variable", "compact_summary", "agent_boundary"}
    return not bool(tags & ignored)


def message_to_synth_event(save_id: str, chat_data: dict[str, Any], msg: dict[str, Any], index: int, span_id: str) -> dict[str, Any] | None:
    role = msg.get("role")
    content = msg.get("content", "")
    if role == "user":
        kind = "main_turn.user_prompt"
        message_role = "user"
    elif role in {"llm", "assistant"}:
        kind = "main_turn.agent_reply"
        message_role = "assistant"
    else:
        return None
    dedupe_key = f"synth:{save_id}:{index}:{kind}:{hashlib.sha256(str(content).encode('utf-8')).hexdigest()}"
    return {
        "schema_version": SCHEMA_VERSION,
        "event_id": "synth_" + stable_id(dedupe_key),
        "root_trace_id": save_id,
        "kind": kind,
        "created_at": chat_data.get("updated_at"),
        "span_id": span_id,
        "parent_span_id": None,
        "session": {"save_id": save_id, "temporary": False, "role": "synthesized"},
        "message": {"role": message_role, "content": content, "message_index": index},
        "synthesized": True,
        "evidence": {"save_id": save_id, "message_index": index},
        "dedupe_key": dedupe_key,
    }


@dataclass
class TraceData:
    source: str
    root_trace_id: str
    manifest: dict[str, Any]
    events: list[dict[str, Any]]
    total_events: int
    archives: list[dict[str, Any]] = field(default_factory=list)
    gaps: list[Any] = field(default_factory=list)
    parse_errors: list[Any] = field(default_factory=list)
    requested_save_id: str | None = None
    resolution: str | None = None


@dataclass
class SpanModel:
    span_id: str
    parent_span_id: str | None = None
    role: str = "session"
    temporary: bool = False
    save_ids: set[str] = field(default_factory=set)
    event_count: int = 0
    turn_count: int = 0
    action_count: int = 0
    archive_count: int = 0
    first_index: int = 10**9
    last_index: int = -1
    first_event_at: Any = None
    last_event_at: Any = None
    kinds: Counter = field(default_factory=Counter)


def project_maxa(project_root: Path) -> Path:
    maxa = project_root / ".maxa"
    if not maxa.is_dir():
        raise ValueError(f"project root must contain .maxa: {project_root}")
    return maxa


def trace_dir(project_root: Path, root_trace_id: str) -> Path:
    return project_maxa(project_root) / "history" / "traces" / root_trace_id


def chat_path(project_root: Path, save_id: str) -> Path:
    return project_maxa(project_root) / "history" / "chats" / f"{save_id}.json"


def load_recorded_trace(project_root: Path, root_trace_id: str, include_archives: bool) -> TraceData:
    root_trace_id = safe_trace_id(root_trace_id, "root_trace_id")
    tdir = trace_dir(project_root, root_trace_id)
    manifest_path = tdir / "manifest.json"
    events_path = tdir / "events.jsonl"
    if not manifest_path.exists() or not events_path.exists():
        raise FileNotFoundError(f"recorded trace not found: {tdir}")
    manifest = read_json(manifest_path)
    events, parse_errors = read_jsonl(events_path)
    archives: list[dict[str, Any]] = []
    if include_archives:
        archives_dir = tdir / "archives"
        for file in sorted(archives_dir.glob("*.json")):
            try:
                archive = read_json(file)
                if isinstance(archive, dict):
                    archive["path"] = str(file)
                    archives.append(archive)
            except Exception as exc:  # noqa: BLE001 - reported as warning
                parse_errors.append({"path": str(file), "error": str(exc)})
    return TraceData(
        source="recorded",
        root_trace_id=root_trace_id,
        manifest=manifest,
        events=events,
        total_events=len(events),
        archives=archives,
        parse_errors=parse_errors,
    )


def read_chat(project_root: Path, save_id: str) -> dict[str, Any]:
    path = chat_path(project_root, save_id)
    if not path.exists():
        raise FileNotFoundError(f"saved chat not found: {path}")
    data = read_json(path)
    if not isinstance(data, dict):
        raise ValueError(f"saved chat JSON is not an object: {path}")
    return data


def resolve_trace_id_for_save_id(project_root: Path, save_id: str) -> tuple[str | None, str | None]:
    save_id = safe_trace_id(save_id, "save_id")
    if (trace_dir(project_root, save_id) / "manifest.json").exists():
        return save_id, "direct"
    chat_file = chat_path(project_root, save_id)
    if chat_file.exists():
        data = read_json(chat_file)
        meta = data.get("_meta") if isinstance(data, dict) else None
        membership = meta.get("session_trace") if isinstance(meta, dict) else None
        root = membership.get("root_trace_id") if isinstance(membership, dict) else None
        if root and (trace_dir(project_root, root) / "manifest.json").exists():
            return root, "chat_meta"
    traces = project_maxa(project_root) / "history" / "traces"
    if traces.is_dir():
        for idx in sorted(traces.glob("*/index.json")):
            try:
                data = read_json(idx)
            except Exception:
                continue
            save_ids = data.get("save_ids") if isinstance(data, dict) else None
            if isinstance(save_ids, dict) and save_ids.get(save_id):
                root = idx.parent.name
                if (idx.parent / "manifest.json").exists():
                    return root, "index"
    return None, None


def synthesize_trace(project_root: Path, save_id: str) -> TraceData:
    save_id = safe_trace_id(save_id, "save_id")
    chat = read_chat(project_root, save_id)
    span_id = "synth_" + stable_id(save_id)
    events: list[dict[str, Any]] = []
    for index, msg in enumerate(chat.get("messages") or [], 1):
        if isinstance(msg, dict) and is_visible_conversation_message(msg):
            event = message_to_synth_event(save_id, chat, msg, index, span_id)
            if event:
                events.append(event)
        meta = msg.get("_meta") if isinstance(msg, dict) and isinstance(msg.get("_meta"), dict) else None
        if meta and meta.get("inserted_from_fragment"):
            events.append(
                {
                    "schema_version": SCHEMA_VERSION,
                    "event_id": "synth_fragment_" + stable_id(save_id, index),
                    "root_trace_id": save_id,
                    "kind": "fragment.inserted",
                    "created_at": chat.get("updated_at"),
                    "span_id": span_id,
                    "parent_span_id": None,
                    "session": {"save_id": save_id, "temporary": False, "role": "synthesized"},
                    "fragment": meta.get("inserted_from_fragment"),
                    "synthesized": True,
                    "evidence": {"save_id": save_id, "message_index": index},
                }
            )
    gaps: list[dict[str, str]] = [
        {
            "kind": "unrecorded_runtime_lineage",
            "detail": "Synthesis reads only saved chat messages; temporary child sessions, deleted scratch chats, and unarchived compressed raw ranges may be unrecoverable.",
        }
    ]
    meta = chat.get("_meta") if isinstance(chat.get("_meta"), dict) else {}
    if any(key in meta for key in ["compaction", "compact", "session_compression"]):
        gaps.append(
            {
                "kind": "compression_raw_range_may_be_missing",
                "detail": "Saved chat contains compression metadata but no recorded trace archive for missing raw prompt/reply pairs.",
            }
        )
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "root_trace_id": save_id,
        "root_save_id": save_id,
        "root_title": chat.get("title"),
        "status": "synthesized",
        "created_at": chat.get("created_at"),
        "updated_at": chat.get("updated_at"),
        "source": "saved_chat_history",
    }
    return TraceData("synthesized", save_id, manifest, events, len(events), gaps=gaps, requested_save_id=save_id)


def load_trace(project_root: Path, root_trace_id: str | None, save_id: str | None, include_archives: bool, synthesize_if_missing: bool) -> TraceData:
    if root_trace_id:
        root_trace_id = safe_trace_id(root_trace_id, "root_trace_id")
        try:
            return load_recorded_trace(project_root, root_trace_id, include_archives)
        except FileNotFoundError:
            if not synthesize_if_missing:
                raise
            return synthesize_trace(project_root, save_id or root_trace_id)
    if not save_id:
        raise ValueError("--root-trace-id or --save-id is required")
    save_id = safe_trace_id(save_id, "save_id")
    resolved, resolution = resolve_trace_id_for_save_id(project_root, save_id)
    if resolved:
        data = load_recorded_trace(project_root, resolved, include_archives)
        data.requested_save_id = save_id
        data.resolution = resolution
        return data
    if not synthesize_if_missing:
        raise FileNotFoundError(f"recorded trace not found for save_id: {save_id}")
    return synthesize_trace(project_root, save_id)


def event_session(event: dict[str, Any]) -> dict[str, Any]:
    session = event.get("session")
    return session if isinstance(session, dict) else {}


def event_span_id(event: dict[str, Any], fallback_root: str) -> str:
    span = event.get("span_id")
    if isinstance(span, str) and span:
        return span
    session = event_session(event)
    save_id = session.get("save_id")
    if isinstance(save_id, str) and save_id:
        return "span_" + stable_id(save_id)
    return "span_" + stable_id(fallback_root)


def event_parent_span_id(event: dict[str, Any]) -> str | None:
    parent = event.get("parent_span_id")
    return parent if isinstance(parent, str) and parent else None


def event_role(event: dict[str, Any]) -> str:
    session = event_session(event)
    role = session.get("role")
    return str(role) if role else "session"


def build_model(trace: TraceData, max_events: int) -> dict[str, Any]:
    spans: dict[str, SpanModel] = {}
    kind_counts: Counter = Counter()
    action_events: list[dict[str, Any]] = []
    natural_events: list[dict[str, Any]] = []
    warnings: list[str] = []
    if trace.parse_errors:
        warnings.append(f"Trace has {len(trace.parse_errors)} parse warning(s).")
    for gap in trace.gaps:
        if isinstance(gap, dict):
            warnings.append(f"Gap: {gap.get('kind', 'unknown')} — {gap.get('detail', '')}")
        else:
            warnings.append(f"Gap: {gap}")

    for idx, event in enumerate(trace.events, 1):
        kind = str(event.get("kind") or "unknown")
        kind_counts[kind] += 1
        span_id = event_span_id(event, trace.root_trace_id)
        session = event_session(event)
        span = spans.setdefault(span_id, SpanModel(span_id=span_id))
        parent = event_parent_span_id(event)
        if parent and not span.parent_span_id:
            span.parent_span_id = parent
        span.role = event_role(event)
        span.temporary = bool(session.get("temporary"))
        save_id = session.get("save_id")
        if isinstance(save_id, str) and save_id:
            span.save_ids.add(save_id)
        span.event_count += 1
        span.first_index = min(span.first_index, idx)
        span.last_index = max(span.last_index, idx)
        created = event.get("created_at")
        if span.first_event_at is None:
            span.first_event_at = created
        span.last_event_at = created
        span.kinds[kind] += 1
        if kind in NATURAL_TURN_KINDS:
            span.turn_count += 1
            natural_events.append(event)
        else:
            span.action_count += 1
            if kind in ACTION_KINDS or kind != "unknown":
                action_events.append(event)
        if kind == "compression.archive_created":
            span.archive_count += 1

        child = event.get("child") if isinstance(event.get("child"), dict) else None
        child_save = child.get("save_id") if child else None
        child_span = None
        if kind in {"fork.created", "scratch.created"}:
            child_span = span_id
        elif kind == "subagent.started":
            child_span = span_id
        if child_span and child_save:
            spans[child_span].save_ids.add(str(child_save))

    if not spans:
        root_span = "span_" + stable_id(trace.root_trace_id)
        spans[root_span] = SpanModel(span_id=root_span, role=trace.source, event_count=0, first_index=0, last_index=0)

    for archive in trace.archives:
        span_id = archive.get("span_id")
        if isinstance(span_id, str) and span_id in spans:
            spans[span_id].archive_count += 1

    ordered_events = trace.events[: max(0, max_events)]
    if len(trace.events) > len(ordered_events):
        warnings.append(f"Event detail table truncated to {len(ordered_events)} of {len(trace.events)} events.")

    return {
        "trace": trace,
        "spans": spans,
        "kind_counts": kind_counts,
        "actions": action_events[:max_events],
        "natural_events": natural_events[:max_events],
        "events": ordered_events,
        "archives": trace.archives,
        "warnings": warnings,
    }


def span_depths(spans: dict[str, SpanModel]) -> dict[str, int]:
    depths: dict[str, int] = {}

    def depth(span_id: str, seen: set[str] | None = None) -> int:
        if span_id in depths:
            return depths[span_id]
        seen = seen or set()
        if span_id in seen:
            depths[span_id] = 0
            return 0
        seen.add(span_id)
        parent = spans[span_id].parent_span_id
        if parent and parent in spans:
            depths[span_id] = depth(parent, seen) + 1
        else:
            depths[span_id] = 0
        return depths[span_id]

    for sid in spans:
        depth(sid)
    return depths


def canvas_text_for_span(span: SpanModel) -> str:
    return "\n".join(
        [
            f"## {span.role} span",
            f"`{span.span_id}`",
            f"events: {span.event_count}",
            f"turns: {span.turn_count}",
            f"actions: {span.action_count}",
            f"archives: {span.archive_count}",
            f"save_ids: {', '.join(sorted(span.save_ids)) if span.save_ids else '-'}",
        ]
    )


def action_label(event: dict[str, Any]) -> str:
    kind = str(event.get("kind") or "event")
    if kind.startswith("subagent."):
        tool = event.get("tool") if isinstance(event.get("tool"), dict) else {}
        mode = tool.get("mode") or tool.get("name") or "subagent"
        return f"{kind}\n{mode}"
    if kind.startswith("compression."):
        comp = event.get("compression") if isinstance(event.get("compression"), dict) else {}
        return f"{kind}\n{comp.get('action') or comp.get('mode') or ''}".strip()
    return kind


def render_canvas(model: dict[str, Any]) -> dict[str, Any]:
    trace: TraceData = model["trace"]
    spans: dict[str, SpanModel] = model["spans"]
    depths = span_depths(spans)
    ordered_spans = sorted(spans.values(), key=lambda s: (depths.get(s.span_id, 0), s.first_index, s.span_id))
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    span_node_ids: dict[str, str] = {}
    group_ids: dict[str, str] = {}

    lane_next_y: dict[int, int] = defaultdict(lambda: 0)
    for span in ordered_spans:
        depth = depths.get(span.span_id, 0)
        x = depth * 620
        y = lane_next_y[depth]
        height = min(520, 220 + max(0, span.action_count) * 30)
        group_id = stable_id("group", trace.root_trace_id, span.span_id)
        node_id = stable_id("span", trace.root_trace_id, span.span_id)
        group_ids[span.span_id] = group_id
        span_node_ids[span.span_id] = node_id
        nodes.append(
            {
                "id": group_id,
                "type": "group",
                "x": x,
                "y": y,
                "width": 540,
                "height": height,
                "label": f"{span.role}: {span.span_id[:24]}",
                "color": ROLE_COLORS.get(span.role, "6"),
            }
        )
        nodes.append(
            {
                "id": node_id,
                "type": "text",
                "x": x + 30,
                "y": y + 50,
                "width": 480,
                "height": 160,
                "text": canvas_text_for_span(span),
                "color": ROLE_COLORS.get(span.role, "6"),
            }
        )
        lane_next_y[depth] = y + height + 100

    root_summary_id = stable_id("summary", trace.root_trace_id)
    root_text = [
        f"# Trace {trace.root_trace_id}",
        f"source: {trace.source}",
        f"events: {trace.total_events}",
        f"spans: {len(spans)}",
        f"archives: {len(trace.archives)}",
        "Open `trace-summary.md` for tables and excerpts.",
    ]
    nodes.insert(
        0,
        {
            "id": root_summary_id,
            "type": "file",
            "x": -560,
            "y": 0,
            "width": 420,
            "height": 180,
            "file": "history/traces/{}/visualization/trace-summary.md".format(trace.root_trace_id),
            "color": "1",
        },
    )
    nodes.insert(
        1,
        {
            "id": stable_id("root-text", trace.root_trace_id),
            "type": "text",
            "x": -560,
            "y": 220,
            "width": 420,
            "height": 180,
            "text": "\n".join(root_text),
            "color": "1",
        },
    )

    for span in ordered_spans:
        if span.parent_span_id and span.parent_span_id in span_node_ids:
            edges.append(
                {
                    "id": stable_id("edge", "span", span.parent_span_id, span.span_id),
                    "fromNode": span_node_ids[span.parent_span_id],
                    "fromSide": "right",
                    "toNode": span_node_ids[span.span_id],
                    "toSide": "left",
                    "toEnd": "arrow",
                    "label": span.role[:32],
                }
            )
        elif span_node_ids.get(span.span_id):
            edges.append(
                {
                    "id": stable_id("edge", "root", span.span_id),
                    "fromNode": root_summary_id,
                    "fromSide": "right",
                    "toNode": span_node_ids[span.span_id],
                    "toSide": "left",
                    "toEnd": "arrow",
                    "label": "trace",
                }
            )

    action_offsets: dict[str, int] = defaultdict(int)
    for event in model["actions"]:
        kind = str(event.get("kind") or "event")
        if kind in {"main_turn.user_prompt", "main_turn.agent_reply", "main_turn.agent_error", "trace.backfilled"}:
            continue
        span_id = event_span_id(event, trace.root_trace_id)
        if span_id not in group_ids:
            continue
        group = next(n for n in nodes if n["id"] == group_ids[span_id])
        offset = action_offsets[span_id]
        action_offsets[span_id] += 1
        action_id = stable_id("action", trace.root_trace_id, event.get("event_id") or kind, offset)
        y = group["y"] + 230 + offset * 90
        nodes.append(
            {
                "id": action_id,
                "type": "text",
                "x": group["x"] + 50,
                "y": y,
                "width": 440,
                "height": 70,
                "text": f"**{action_label(event)}**\n`{str(event.get('event_id', ''))[:32]}`",
                "color": "5" if kind.startswith("compression") else "2",
            }
        )
        edges.append(
            {
                "id": stable_id("edge", "action", span_id, action_id),
                "fromNode": span_node_ids[span_id],
                "fromSide": "bottom",
                "toNode": action_id,
                "toSide": "top",
                "toEnd": "arrow",
                "label": kind.split(".")[0],
            }
        )

    canvas = {"nodes": nodes, "edges": edges}
    validate_canvas(canvas)
    return canvas


def validate_canvas(canvas: dict[str, Any]) -> None:
    if not isinstance(canvas.get("nodes"), list) or not isinstance(canvas.get("edges"), list):
        raise ValueError("canvas must contain nodes and edges arrays")
    node_ids: set[str] = set()
    edge_ids: set[str] = set()
    for node in canvas["nodes"]:
        node_id = node.get("id")
        if not node_id or node_id in node_ids:
            raise ValueError(f"duplicate or missing canvas node id: {node_id}")
        node_ids.add(node_id)
        if node.get("type") not in SUPPORTED_NODE_TYPES:
            raise ValueError(f"unsupported canvas node type: {node.get('type')}")
        for key in ["x", "y", "width", "height"]:
            if not isinstance(node.get(key), int):
                raise ValueError(f"canvas node {node_id} missing integer {key}")
        if node["type"] == "text" and "text" not in node:
            raise ValueError(f"text node {node_id} missing text")
        if node["type"] == "file" and "file" not in node:
            raise ValueError(f"file node {node_id} missing file")
        if node["type"] == "link" and "url" not in node:
            raise ValueError(f"link node {node_id} missing url")
    for edge in canvas["edges"]:
        edge_id = edge.get("id")
        if not edge_id or edge_id in edge_ids:
            raise ValueError(f"duplicate or missing canvas edge id: {edge_id}")
        edge_ids.add(edge_id)
        if edge.get("fromNode") not in node_ids or edge.get("toNode") not in node_ids:
            raise ValueError(f"canvas edge {edge_id} references missing node")


def rel_to_vault(project_root: Path, path: Path) -> str:
    maxa = project_maxa(project_root).resolve()
    return path.resolve().relative_to(maxa).as_posix()


def render_markdown(model: dict[str, Any], project_root: Path, output_dir: Path, excerpt_chars: int, command: str) -> str:
    trace: TraceData = model["trace"]
    spans: dict[str, SpanModel] = model["spans"]
    generated = utc_now_iso()
    canvas_path = output_dir / "trace-overview.canvas"
    md_lines: list[str] = [
        "---",
        f"title: {yaml_scalar('Trace Visualization ' + trace.root_trace_id)}",
        f"created: {yaml_scalar(generated)}",
        f"updated: {yaml_scalar(generated)}",
        "type: generated-trace-visualization",
        f"root_trace_id: {yaml_scalar(trace.root_trace_id)}",
        f"source: {yaml_scalar(trace.source)}",
        f"generated_by: {yaml_scalar(GENERATOR)}",
        "---",
        "",
        f"> **TLDR**: Generated static visualization for trace `{trace.root_trace_id}` with {trace.total_events} events, {len(spans)} spans, and {len(trace.archives)} archives.",
        "",
        "## Artifacts",
        "",
        f"- Canvas: [[{rel_to_vault(project_root, canvas_path)}|trace-overview.canvas]]",
        f"- Summary: [[{rel_to_vault(project_root, output_dir / 'trace-summary.md')}|trace-summary.md]]",
    ]
    trace_base = trace_dir(project_root, trace.root_trace_id)
    if trace.source == "recorded":
        md_lines.extend(
            [
                f"- Manifest: [[{rel_to_vault(project_root, trace_base / 'manifest.json')}|manifest.json]]",
                f"- Events: [[{rel_to_vault(project_root, trace_base / 'events.jsonl')}|events.jsonl]]",
                f"- Archives: [[{rel_to_vault(project_root, trace_base / 'archives')}|archives/]]",
            ]
        )
    md_lines.extend(
        [
            "",
            "## Trace Metadata",
            "",
            "| Field | Value |",
            "| --- | --- |",
            f"| root_trace_id | `{md_escape_cell(trace.root_trace_id)}` |",
            f"| source | `{md_escape_cell(trace.source)}` |",
            f"| root_title | {md_escape_cell(trace.manifest.get('root_title') or '')} |",
            f"| status | {md_escape_cell(trace.manifest.get('status') or '')} |",
            f"| total_events | {trace.total_events} |",
            f"| rendered_events | {len(model['events'])} |",
            f"| span_count | {len(spans)} |",
            f"| archive_count | {len(trace.archives)} |",
            "",
            "## Event Kind Counts",
            "",
            "| Kind | Count |",
            "| --- | ---: |",
        ]
    )
    for kind, count in sorted(model["kind_counts"].items()):
        md_lines.append(f"| `{md_escape_cell(kind)}` | {count} |")

    md_lines.extend(["", "## Spans / Sessions", "", "| Span | Parent | Role | Save IDs | Events | Turns | Actions | Archives |", "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |"])
    for span in sorted(spans.values(), key=lambda s: (s.first_index, s.span_id)):
        save_ids = "<br>".join(f"`{md_escape_cell(s)}`" for s in sorted(span.save_ids)) or "-"
        md_lines.append(
            f"| `{md_escape_cell(span.span_id)}` | `{md_escape_cell(span.parent_span_id or '')}` | {md_escape_cell(span.role)} | {save_ids} | {span.event_count} | {span.turn_count} | {span.action_count} | {span.archive_count} |"
        )

    md_lines.extend(["", "## Key Action Timeline", "", "| # | Kind | Span | Details |", "| ---: | --- | --- | --- |"])
    for idx, event in enumerate(model["actions"], 1):
        details = summarize_event_details(event, excerpt_chars)
        md_lines.append(f"| {idx} | `{md_escape_cell(event.get('kind'))}` | `{md_escape_cell(event_span_id(event, trace.root_trace_id))}` | {md_escape_cell(details)} |")

    md_lines.extend(["", "## Prompt / Reply Excerpts", "", "| # | Kind | Span | Message Index | Excerpt |", "| ---: | --- | --- | ---: | --- |"])
    for idx, event in enumerate(model["natural_events"], 1):
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        content = message.get("content") or event.get("content") or ""
        excerpt = truncate_text(content, excerpt_chars)
        if len(str(content)) > len(excerpt):
            excerpt = f"{excerpt} _(excerpt)_"
        md_lines.append(
            f"| {idx} | `{md_escape_cell(event.get('kind'))}` | `{md_escape_cell(event_span_id(event, trace.root_trace_id))}` | {message.get('message_index') or ''} | {md_escape_cell(excerpt)} |"
        )

    md_lines.extend(["", "## Archives", "", "| Archive | Span | Source Save ID | Range | Turns |", "| --- | --- | --- | --- | ---: |"])
    if trace.archives:
        for archive in trace.archives:
            path = Path(str(archive.get("path", ""))) if archive.get("path") else None
            link = md_escape_cell(path.name if path else archive.get("event_id") or "archive")
            if path and path.exists():
                try:
                    link = f"[[{rel_to_vault(project_root, path)}|{md_escape_cell(path.name)}]]"
                except Exception:
                    link = md_escape_cell(path.name)
            rng = archive.get("range") if isinstance(archive.get("range"), dict) else {}
            md_lines.append(
                f"| {link} | `{md_escape_cell(archive.get('span_id') or '')}` | `{md_escape_cell(archive.get('source_save_id') or '')}` | {md_escape_cell(rng)} | {archive.get('turn_count') or len(archive.get('turns') or [])} |"
            )
    else:
        md_lines.append("| - | - | - | - | 0 |")

    md_lines.extend(["", "## Gaps / Warnings", ""])
    if model["warnings"]:
        for warning in model["warnings"]:
            md_lines.append(f"- {warning}")
    else:
        md_lines.append("- None recorded by exporter.")

    md_lines.extend(
        [
            "",
            "## Validation / Export Command",
            "",
            "- Canvas JSON parsed and edge references were validated before write.",
            "- Existing generated files require `--overwrite` to replace.",
            "- Raw trace source files were read-only inputs for this export.",
            "",
            "```bash",
            command,
            "```",
            "",
        ]
    )
    return "\n".join(md_lines)


def summarize_event_details(event: dict[str, Any], excerpt_chars: int) -> str:
    kind = str(event.get("kind") or "")
    if kind in {"fork.created", "scratch.created"}:
        child = event.get("child") if isinstance(event.get("child"), dict) else {}
        return f"child={child.get('save_id') or child.get('title') or '-'}"
    if kind == "scratch.merged":
        return f"appended={event.get('appended_count')} range={event.get('merged_range') or event.get('parent_appended_range')}"
    if kind == "fragment.inserted":
        return f"fragment={event.get('fragment')} appended={event.get('appended_count')} range={event.get('inserted_range')}"
    if kind.startswith("subagent"):
        tool = event.get("tool") if isinstance(event.get("tool"), dict) else {}
        result = event.get("result") if isinstance(event.get("result"), dict) else {}
        content = result.get("content") or result.get("status") or ""
        return f"tool={tool.get('name')} mode={tool.get('mode')} result={truncate_text(content, excerpt_chars)}"
    if kind in {"ask_llm.completed", "multi_agent.completed"}:
        result = event.get("result") if isinstance(event.get("result"), dict) else {}
        return truncate_text(result.get("content") or result, excerpt_chars)
    if kind.startswith("compression"):
        return f"compression={event.get('compression')} archive={event.get('archive')}"
    message = event.get("message") if isinstance(event.get("message"), dict) else {}
    if message:
        return truncate_text(message.get("content") or message, excerpt_chars)
    return truncate_text({k: v for k, v in event.items() if k not in {"dedupe_key"}}, excerpt_chars)


def validate_output_dir(project_root: Path, root_trace_id: str, output_dir_arg: str | None) -> Path:
    base = trace_dir(project_root, root_trace_id).resolve()
    if output_dir_arg:
        raw = Path(output_dir_arg)
        if raw.is_absolute():
            raise ValueError("--output-dir must be project-relative or trace-relative, not absolute")
        candidate = (project_root / raw).resolve()
        if not str(candidate).startswith(str(base) + os.sep) and candidate != base:
            candidate = (base / raw).resolve()
        if not (str(candidate).startswith(str(base) + os.sep) or candidate == base):
            raise ValueError("--output-dir must stay inside .maxa/history/traces/<root_trace_id>/")
        return candidate
    return base / "visualization"


def strip_prefixes(pattern: str) -> tuple[bool, str]:
    p = pattern.strip()
    include = p.startswith("!") or p.startswith("(?i)!") or p.startswith("(?d)!")
    p = re.sub(r"^\(\?[a-z]+\)", "", p)
    if p.startswith("!"):
        include = True
        p = p[1:]
    return include, p


def syncthing_glob_match(pattern: str, rel_path: str) -> bool:
    """Approximate Syncthing glob semantics for validation.

    Unlike Python fnmatch, Syncthing `*` and `?` do not match path separators;
    `**` may match separators. This is intentionally small and covers the
    project .stignore patterns used by the exporter.
    """
    regex = []
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                regex.append(".*")
                i += 2
            else:
                regex.append("[^/]*")
                i += 1
        elif ch == "?":
            regex.append("[^/]")
            i += 1
        else:
            regex.append(re.escape(ch))
            i += 1
    return re.fullmatch("".join(regex), rel_path) is not None


def stignore_match(pattern: str, rel_path: str) -> bool:
    include, p = strip_prefixes(pattern)
    _ = include
    if not p or p.startswith("#") or p.startswith("//"):
        return False
    rel_path = rel_path.strip("/")
    rooted = p.startswith("/")
    p = p.lstrip("/")
    if p.endswith("/"):
        p = p.rstrip("/") + "/**"
    if rooted:
        return syncthing_glob_match(p, rel_path)
    return syncthing_glob_match(p, rel_path) or any(syncthing_glob_match(p, part) for part in rel_path.split("/"))


def stignore_is_ignored(lines: list[str], rel_path: str) -> bool:
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("//"):
            continue
        include, _pattern = strip_prefixes(stripped)
        if stignore_match(stripped, rel_path):
            return not include
    return False


def ensure_stignore_rules(project_root: Path) -> tuple[bool, list[str]]:
    maxa = project_maxa(project_root)
    local_stignore = maxa / ".stignore"
    shared_stignore = maxa / ".stignore-shared"
    stignore = shared_stignore if shared_stignore.exists() else local_stignore
    if stignore.exists():
        lines = stignore.read_text(encoding="utf-8").splitlines()
    else:
        lines = []
    missing = [rule for rule in STIGNORE_VISUALIZATION_RULES if rule not in lines]
    changed = False
    if missing:
        insert_at = next((i for i, line in enumerate(lines) if line.strip() in RAW_HISTORY_IGNORE_RULES), len(lines))
        block = [
            "",
            "# Trace visualization outputs are generated for Obsidian/Syncthing review; raw history remains ignored below.",
            *missing,
        ]
        lines[insert_at:insert_at] = block
        atomic_write_text(stignore, "\n".join(lines).rstrip() + "\n")
        changed = True
    return changed, lines if not changed else stignore.read_text(encoding="utf-8").splitlines()


def validate_stignore(project_root: Path, root_trace_id: str) -> tuple[str, list[str]]:
    changed, lines = ensure_stignore_rules(project_root)
    warnings: list[str] = []
    viz_md = f"history/traces/{root_trace_id}/visualization/trace-summary.md"
    viz_canvas = f"history/traces/{root_trace_id}/visualization/trace-overview.canvas"
    raw_events = f"history/traces/{root_trace_id}/events.jsonl"
    raw_chat = "history/chats/example.json"
    if stignore_is_ignored(lines, viz_md) or stignore_is_ignored(lines, viz_canvas):
        warnings.append("Syncthing ignore simulation still marks visualization files ignored; inspect .maxa/.stignore-shared ordering.")
    if not stignore_is_ignored(lines, raw_events):
        warnings.append("Syncthing ignore simulation does not ignore raw trace events.jsonl.")
    if not stignore_is_ignored(lines, raw_chat):
        warnings.append("Syncthing ignore simulation does not ignore raw chat history.")
    return ("updated" if changed else "present"), warnings


def check_conflicts(paths: Iterable[Path], overwrite: bool) -> None:
    existing = [str(path) for path in paths if path.exists()]
    if existing and not overwrite:
        raise FileExistsError("generated file(s) already exist; pass --overwrite to replace: " + ", ".join(existing))


def export_trace(args: argparse.Namespace) -> dict[str, Any]:
    project_root = Path(args.project_root).resolve()
    project_maxa(project_root)
    formats = set(args.format or []) or set(SUPPORTED_FORMATS)
    unknown = formats - SUPPORTED_FORMATS
    if unknown:
        raise ValueError(f"unsupported --format value(s): {', '.join(sorted(unknown))}")
    include_archives = args.include_archives
    trace = load_trace(project_root, args.root_trace_id, args.save_id, include_archives, args.synthesize_if_missing)
    output_dir = validate_output_dir(project_root, trace.root_trace_id, args.output_dir)
    model = build_model(trace, args.max_events)
    files: dict[str, str] = {}
    target_paths: list[Path] = []
    if "canvas" in formats:
        target_paths.append(output_dir / "trace-overview.canvas")
    if "markdown" in formats:
        target_paths.append(output_dir / "trace-summary.md")
    check_conflicts(target_paths, args.overwrite)

    stignore_status, stignore_warnings = validate_stignore(project_root, trace.root_trace_id)
    model["warnings"].extend(stignore_warnings)

    validation: dict[str, str] = {}
    if "canvas" in formats:
        canvas = render_canvas(model)
        canvas_path = output_dir / "trace-overview.canvas"
        write_json_atomic(canvas_path, canvas)
        files["canvas"] = str(canvas_path)
        validation["canvas_json"] = "passed"
        validation["edges"] = "passed"
    if "markdown" in formats:
        command = " ".join(sys.argv)
        markdown = render_markdown(model, project_root, output_dir, args.excerpt_chars, command)
        md_path = output_dir / "trace-summary.md"
        atomic_write_text(md_path, markdown)
        files["markdown"] = str(md_path)
        validation["markdown"] = "passed"

    counts = {
        "events": trace.total_events,
        "rendered_events": len(model["events"]),
        "spans": len(model["spans"]),
        "archives": len(trace.archives),
        "actions": len(model["actions"]),
    }
    return {
        "root_trace_id": trace.root_trace_id,
        "source": trace.source,
        "output_dir": str(output_dir),
        "files": files,
        "counts": counts,
        "warnings": model["warnings"],
        "validation": validation,
        "stignore": stignore_status,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export Maxa session traces to Obsidian Canvas and Markdown.")
    parser.add_argument("--project-root", required=True, help="Project root containing .maxa/.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--root-trace-id", help="Recorded trace root id.")
    source.add_argument("--save-id", help="Saved chat id; resolves a recorded trace or synthesizes fallback.")
    parser.add_argument("--output-dir", help="Project-relative or trace-relative output directory inside the trace artifact boundary.")
    parser.add_argument("--format", action="append", choices=sorted(SUPPORTED_FORMATS), help="Output format to generate; repeatable. Default: canvas and markdown.")
    parser.add_argument("--mode", choices=["summary", "full"], default="summary", help="Accepted for compatibility; output remains bounded by exporter limits.")
    parser.add_argument("--include-archives", dest="include_archives", action="store_true", default=True, help="Include archive metadata/content when available (default).")
    parser.add_argument("--no-include-archives", dest="include_archives", action="store_false", help="Do not read trace archive JSON files.")
    parser.add_argument("--synthesize-if-missing", dest="synthesize_if_missing", action="store_true", default=True, help="Synthesize from saved chat when recorded trace is absent (default).")
    parser.add_argument("--no-synthesize-if-missing", dest="synthesize_if_missing", action="store_false", help="Fail when no recorded trace exists.")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing generated files.")
    parser.add_argument("--max-events", type=int, default=DEFAULT_MAX_EVENTS, help=f"Maximum events in detail tables/action nodes. Default: {DEFAULT_MAX_EVENTS}.")
    parser.add_argument("--excerpt-chars", type=int, default=DEFAULT_EXCERPT_CHARS, help=f"Maximum prompt/reply excerpt length. Default: {DEFAULT_EXCERPT_CHARS}.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON summary to stdout.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.max_events < 1:
        parser.error("--max-events must be positive")
    if args.excerpt_chars < 0:
        parser.error("--excerpt-chars must be non-negative")
    try:
        result = export_trace(args)
    except Exception as exc:  # noqa: BLE001 - CLI should return concise diagnostics
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"Wrote trace visualization to {result['output_dir']}")
        for key, path in result["files"].items():
            print(f"- {key}: {path}")
        for warning in result.get("warnings", []):
            print(f"WARNING: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
