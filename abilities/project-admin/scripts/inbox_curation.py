#!/usr/bin/env python3
"""Inbox curation helper for Obsidian project-local Vaults.

This script performs mechanical, low-ambiguity operations for capture note
curation. It does not decide semantic clusters or write stable knowledge notes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from datetime import date
from pathlib import Path
from typing import Iterable

INBOX_SUBDIRS = ("errors", "learnings", "feature-requests")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def rel_to_vault(path: Path, vault: Path) -> str:
    return path.relative_to(vault).as_posix()


def extract_frontmatter(text: str) -> tuple[dict[str, object], str, str]:
    if not text.startswith("---\n"):
        return {}, "", text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, "", text
    raw = text[4:end]
    body = text[end + 5 :]
    data: dict[str, object] = {}
    lines = raw.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.startswith("#"):
            i += 1
            continue
        if ":" not in line:
            i += 1
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value == "":
            items: list[str] = []
            j = i + 1
            while j < len(lines) and lines[j].startswith("  - "):
                items.append(lines[j][4:].strip())
                j += 1
            data[key] = items
            i = j
        else:
            data[key] = value.strip('"')
            i += 1
    return data, raw, body


def get_scalar(fm: dict[str, object], key: str) -> str:
    value = fm.get(key, "")
    if isinstance(value, list):
        return ", ".join(value)
    return str(value) if value is not None else ""


def get_list(fm: dict[str, object], key: str) -> list[str]:
    value = fm.get(key, [])
    if isinstance(value, list):
        return [str(v) for v in value]
    if value:
        return [str(value)]
    return []


def extract_tldr(text: str) -> str:
    m = re.search(r"^> \*\*TLDR\*\*:\s*(.+)$", text, re.M)
    return m.group(1).strip() if m else ""


def note_wikilink_from_rel(rel: str) -> str:
    if rel.endswith(".md"):
        rel = rel[:-3]
    return f"[[{rel}]]"


@dataclass
class CaptureNote:
    path: str
    title: str
    kind: str
    status: str
    review_status: str
    tldr: str
    merged_into: list[str]
    deprecated_reason: str
    queue: str
    indexed_active: bool


def classify(status: str, review_status: str, merged_into: list[str], deprecated_reason: str) -> str:
    if review_status in {"index", "non_capture"}:
        return "non_capture"
    if status == "merged" and not merged_into:
        return "invalid_resolved"
    if status == "deprecated" and not deprecated_reason:
        return "invalid_resolved"
    if status in {"merged", "deprecated"}:
        return "resolved"
    if review_status == "reviewed" and (merged_into or deprecated_reason):
        return "resolved"
    return "active"


def iter_capture_paths(vault: Path) -> Iterable[Path]:
    inbox = vault / "inbox"
    for sub in INBOX_SUBDIRS:
        base = inbox / sub
        if not base.exists():
            continue
        yield from sorted(base.glob("*.md"))


def load_notes(vault: Path) -> list[CaptureNote]:
    index_text = read_text(vault / "inbox" / "index.md") if (vault / "inbox" / "index.md").exists() else ""
    notes: list[CaptureNote] = []
    for path in iter_capture_paths(vault):
        text = read_text(path)
        fm, _, _ = extract_frontmatter(text)
        rel = rel_to_vault(path, vault)
        title = get_scalar(fm, "title") or path.stem
        status = get_scalar(fm, "status")
        review_status = get_scalar(fm, "review_status")
        merged_into = get_list(fm, "merged_into")
        deprecated_reason = get_scalar(fm, "deprecated_reason")
        queue = classify(status, review_status, merged_into, deprecated_reason)
        indexed_active = title in index_text or path.stem in index_text or note_wikilink_from_rel(rel) in index_text
        notes.append(
            CaptureNote(
                path=rel,
                title=title,
                kind=path.parent.name,
                status=status,
                review_status=review_status,
                tldr=extract_tldr(text),
                merged_into=merged_into,
                deprecated_reason=deprecated_reason,
                queue=queue,
                indexed_active=indexed_active,
            )
        )
    return notes


def notes_by_queue(notes: list[CaptureNote]) -> dict[str, list[CaptureNote]]:
    queues = {"active": [], "resolved": [], "invalid_resolved": [], "reopen_candidates": [], "non_capture": []}
    for note in notes:
        queues.setdefault(note.queue, []).append(note)
    return queues


def print_json(data: object) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def cmd_inventory(args: argparse.Namespace) -> int:
    vault = Path(args.vault).expanduser().resolve()
    notes = load_notes(vault)
    queues = notes_by_queue(notes)
    data = {
        "vault": str(vault),
        "counts": {key: len(value) for key, value in queues.items()},
        "queues": {key: [asdict(note) for note in value] for key, value in queues.items()},
    }
    if args.json:
        print_json(data)
    else:
        print(f"Vault: {vault}")
        for key in ("active", "resolved", "invalid_resolved", "reopen_candidates", "non_capture"):
            print(f"\n## {key} {len(queues.get(key, []))}")
            for note in queues.get(key, []):
                target = f" -> {', '.join(note.merged_into)}" if note.merged_into else ""
                print(f"- {note.path} | {note.title} | status={note.status} review={note.review_status}{target}")
                if args.with_tldr and note.tldr:
                    print(f"  TLDR: {note.tldr}")
    return 0


def cmd_active_list(args: argparse.Namespace) -> int:
    vault = Path(args.vault).expanduser().resolve()
    notes = [note for note in load_notes(vault) if note.queue == "active"]
    if args.json:
        print_json([asdict(note) for note in notes])
    else:
        for note in notes:
            print(f"- {note.path} | {note.title}")
            if args.with_tldr and note.tldr:
                print(f"  TLDR: {note.tldr}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    vault = Path(args.vault).expanduser().resolve()
    notes = load_notes(vault)
    queues = notes_by_queue(notes)
    today = args.date or date.today().isoformat()
    lines = [
        f"# Inbox Curation Report - {today}",
        "",
        "## Summary",
        f"- active captures: {len(queues['active'])}",
        f"- resolved captures: {len(queues['resolved'])}",
        f"- invalid resolved captures: {len(queues['invalid_resolved'])}",
        f"- reopen candidates: {len(queues['reopen_candidates'])}",
        "",
        "## Active Queue",
    ]
    for note in queues["active"]:
        lines.append(f"- {note_wikilink_from_rel(note.path)} — {note.tldr or note.title}")
    lines += ["", "## Invalid Resolved"]
    if queues["invalid_resolved"]:
        for note in queues["invalid_resolved"]:
            lines.append(f"- {note_wikilink_from_rel(note.path)} — status={note.status}; needs metadata repair")
    else:
        lines.append("- none")
    lines += [
        "",
        "## Proposed Clusters",
        "- [TODO: Agent groups Active Queue by theme and selects 1-3 high-value clusters.]",
        "",
        "## Proposed Changes",
        "- [TODO: Agent lists stable notes to create/update and index changes.]",
        "",
        "## Deferred / Human Review",
        "- [TODO: Agent lists captures that should remain active or require user decision.]",
        "",
    ]
    content = "\n".join(lines)
    if args.output:
        out = Path(args.output)
        if not out.is_absolute():
            out = vault / out
        out.parent.mkdir(parents=True, exist_ok=True)
        write_text(out, content)
        print(out)
    else:
        print(content)
    return 0


def update_frontmatter(text: str, updates: dict[str, object]) -> str:
    if not text.startswith("---\n"):
        raise ValueError("missing frontmatter")
    end = text.find("\n---\n", 4)
    if end == -1:
        raise ValueError("unterminated frontmatter")
    raw = text[4:end]
    body = text[end + 5 :]
    lines = raw.splitlines()
    keys = set(updates)
    out: list[str] = []
    i = 0
    handled: set[str] = set()
    while i < len(lines):
        line = lines[i]
        key = line.split(":", 1)[0].strip() if ":" in line else None
        if key in keys:
            value = updates[key]
            if isinstance(value, list):
                out.append(f"{key}:")
                out.extend(f"  - {item}" for item in value)
            else:
                out.append(f"{key}: {value}")
            handled.add(key)
            i += 1
            while i < len(lines) and lines[i].startswith("  - "):
                i += 1
            continue
        out.append(line)
        i += 1
    insert_at = len(out)
    for idx, line in enumerate(out):
        if line.startswith("confidence:"):
            insert_at = idx
            break
    additions: list[str] = []
    for key, value in updates.items():
        if key in handled:
            continue
        if isinstance(value, list):
            additions.append(f"{key}:")
            additions.extend(f"  - {item}" for item in value)
        else:
            additions.append(f"{key}: {value}")
    out[insert_at:insert_at] = additions
    return "---\n" + "\n".join(out).rstrip() + "\n---\n" + body


def cmd_mark_merged(args: argparse.Namespace) -> int:
    vault = Path(args.vault).expanduser().resolve()
    target = args.target
    if target.endswith(".md"):
        target = target[:-3]
    if not (target.startswith("[[") and target.endswith("]]")):
        target = f"[[{target}]]"
    today = args.date or date.today().isoformat()
    changed: list[str] = []
    for item in args.file:
        path = Path(item)
        if not path.is_absolute():
            path = vault / path
        text = read_text(path)
        new_text = update_frontmatter(
            text,
            {
                "status": "merged",
                "review_status": "reviewed",
                "reviewed_at": today,
                "merged_into": [target],
            },
        )
        if args.dry_run:
            print(f"DRY-RUN mark merged: {rel_to_vault(path, vault)} -> {target}")
        else:
            write_text(path, new_text)
            changed.append(rel_to_vault(path, vault))
    if not args.dry_run:
        print_json({"changed": changed, "target": target})
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    vault = Path(args.vault).expanduser().resolve()
    notes = load_notes(vault)
    errors: list[str] = []
    warnings: list[str] = []
    inbox_index = read_text(vault / "inbox" / "index.md") if (vault / "inbox" / "index.md").exists() else ""
    active_index_text = inbox_index.split("\n## Recently Curated", 1)[0]
    for note in notes:
        if note.status == "merged" and not note.merged_into:
            errors.append(f"{note.path}: status=merged but missing merged_into")
        if note.status == "deprecated" and not note.deprecated_reason:
            errors.append(f"{note.path}: status=deprecated but missing deprecated_reason")
        if note.queue == "resolved" and note.title in active_index_text:
            warnings.append(f"{note.path}: resolved note still appears in active sections of inbox/index.md")
        for target in note.merged_into:
            target_path = target.strip().strip("[]")
            if target_path.endswith(".md"):
                candidate = vault / target_path
            else:
                candidate = vault / f"{target_path}.md"
            if not candidate.exists():
                warnings.append(f"{note.path}: merged_into target not found by path check: {target}")
    result = {"errors": errors, "warnings": warnings, "error_count": len(errors), "warning_count": len(warnings)}
    if args.json:
        print_json(result)
    else:
        print(f"errors: {len(errors)}")
        for item in errors:
            print(f"ERROR: {item}")
        print(f"warnings: {len(warnings)}")
        for item in warnings:
            print(f"WARN: {item}")
    return 1 if errors else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Mechanical helper for Obsidian inbox curation")
    parser.add_argument("--vault", default=".maxa", help="Vault root path, default: .maxa")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("inventory", help="List active/resolved/invalid capture queues")
    p.add_argument("--json", action="store_true", help="Output JSON")
    p.add_argument("--with-tldr", action="store_true", help="Include TLDR in text output")
    p.set_defaults(func=cmd_inventory)

    p = sub.add_parser("active-list", help="List only active capture notes for next curation")
    p.add_argument("--json", action="store_true", help="Output JSON")
    p.add_argument("--with-tldr", action="store_true", help="Include TLDR in text output")
    p.set_defaults(func=cmd_active_list)

    p = sub.add_parser("report", help="Generate a markdown curation report draft")
    p.add_argument("--output", help="Output path; relative paths are resolved under vault root")
    p.add_argument("--date", help="Report date, default: today")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("mark-merged", help="Mark capture notes as merged into a stable note")
    p.add_argument("--target", required=True, help="Absorbing content-owner note path or wikilink, e.g. rules/example; not a generated weave node")
    p.add_argument("--file", action="append", required=True, help="Capture note path relative to vault; repeatable")
    p.add_argument("--date", help="Review date, default: today")
    p.add_argument("--dry-run", action="store_true", help="Show changes without writing")
    p.set_defaults(func=cmd_mark_merged)

    p = sub.add_parser("validate", help="Validate resolved capture metadata")
    p.add_argument("--json", action="store_true", help="Output JSON")
    p.set_defaults(func=cmd_validate)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - command-line tool should print concise error
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
