#!/usr/bin/env python3
"""Check Obsidian Vault Markdown note sizes.

File-side inspection of ordinary knowledge notes and role-bounded weave files,
excluding target-owned evidence/workspace layers and non-Markdown files.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable

DEFAULT_LIMIT_BYTES = 30_000
EXCLUDED_DIRS = {".obsidian", ".stversions", ".trash", ".git"}
EXCLUDED_TOP_LEVEL_DIRS = {
    "attachments",
    "canvases",
    "tasks",
    "drafts",
    "translate-cache",
    "abilities",
    "fragments",
    "tmp",
    "history",
    "artifacts",
    "handoff",
    "e2e",
}


def iter_markdown_notes(vault: Path) -> Iterable[Path]:
    for path in sorted(vault.rglob("*.md")):
        rel_parts = path.relative_to(vault).parts
        if not rel_parts:
            continue
        if any(part in EXCLUDED_DIRS for part in rel_parts):
            continue
        if rel_parts[0] in EXCLUDED_TOP_LEVEL_DIRS:
            continue
        yield path


def note_limit(vault: Path, path: Path, ordinary_limit: int) -> int:
    parts = path.relative_to(vault).parts
    if vault.name == "weave":
        weave_parts = parts
    elif parts[0] == "weave":
        weave_parts = parts[1:]
    else:
        return ordinary_limit
    if path.name == "index.md":
        return 2048
    if path.name == "log.md":
        return 6144
    return 3072 if weave_parts[0] == "concepts" else 6144


def build_rows(vault: Path, limit_bytes: int) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for path in iter_markdown_notes(vault):
        size = path.stat().st_size
        effective_limit = note_limit(vault, path, limit_bytes)
        if size <= effective_limit:
            continue
        rows.append(
            {
                "path": path.relative_to(vault).as_posix(),
                "bytes": size,
                "limit_bytes": effective_limit,
                "status": "oversized",
                "suggestion": "remove duplication and return detail to its content owner; split only by independent retrieval purpose; evidence/workspace/runtime zones and non-Markdown are exempt",
            }
        )
    return rows


def emit_markdown(rows: list[dict[str, object]]) -> None:
    if not rows:
        print("  ✅ No oversized Markdown notes")
        return
    for row in rows:
        print(f"  ❌ {row['path']} — {row['bytes']} bytes > {row['limit_bytes']} bytes")
    print(f"⚠️  {len(rows)} oversized Markdown note(s) — split or compress")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check complete UTF-8 Markdown files: ordinary notes <= 30000 bytes; weave indexes <= 2048, concepts <= 3072, topics/active logs <= 6144.",
    )
    parser.add_argument(
        "--vault",
        default=".maxa",
        help="Vault root path. Defaults to .maxa under the current directory.",
    )
    parser.add_argument(
        "--limit-bytes",
        type=int,
        default=DEFAULT_LIMIT_BYTES,
        help=f"Ordinary-note maximum (default {DEFAULT_LIMIT_BYTES}); weave role budgets remain fixed. --vault may select .maxa or its weave subtree.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output machine-readable JSON.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    vault = Path(args.vault).expanduser().resolve()
    if not vault.exists() or not vault.is_dir():
        print(f"Vault directory not found: {vault}", file=sys.stderr)
        return 2
    if args.limit_bytes <= 0:
        print("--limit-bytes must be positive", file=sys.stderr)
        return 2

    rows = build_rows(vault, args.limit_bytes)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        emit_markdown(rows)
    return 1 if rows else 0


if __name__ == "__main__":
    raise SystemExit(main())
