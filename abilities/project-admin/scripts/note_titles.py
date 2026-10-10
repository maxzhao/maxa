#!/usr/bin/env python3
"""Extract Markdown note titles from an Obsidian vault as a table.

The script intentionally performs file-side inspection only. It does not need
Obsidian CLI/index access and is safe for project-local vault health checks.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Iterable

CJK_RE = re.compile(r"[\u4e00-\u9fff]")
LATIN_RE = re.compile(r"[A-Za-z]")
ASCII_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*(?:[ /_-][a-z0-9][a-z0-9_-]*)*$", re.I)
PLACEHOLDER_TITLES = {"index", "untitled", "todo", "readme", "log"}
CHINESE_TYPE_SUFFIX_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _./:+#&'’,-]+（[^）\n]{1,12}）$")


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

def iter_markdown_files(vault: Path) -> Iterable[Path]:
    for path in sorted(vault.rglob("*.md")):
        rel_parts = path.relative_to(vault).parts
        if any(part.startswith(".") for part in rel_parts):
            continue
        if rel_parts and rel_parts[0] in EXCLUDED_TOP_LEVEL_DIRS:
            continue
        yield path


def extract_frontmatter(text: str) -> tuple[str | None, str]:
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end == -1:
        return None, text
    return text[4:end], text[end + 4 :]


def extract_title(path: Path) -> str | None:
    text = path.read_text(encoding="utf-8")
    frontmatter, _body = extract_frontmatter(text)
    if frontmatter is None:
        return None
    match = re.search(r"^title:\s*(.*)$", frontmatter, re.M)
    if not match:
        return None
    raw = match.group(1).strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {'"', "'"}:
        raw = raw[1:-1]
    return raw.strip()


def title_issues(title: str | None) -> list[str]:
    if title is None or title == "":
        return ["missing-title"]

    issues: list[str] = []
    normalized = title.lower().strip()
    if normalized in PLACEHOLDER_TITLES:
        issues.append("placeholder-title")
    if not CJK_RE.search(title):
        issues.append("no-cjk-semantic-title")
    if ASCII_SLUG_RE.match(title) and not CJK_RE.search(title):
        issues.append("pure-slug-or-english")
    if CHINESE_TYPE_SUFFIX_RE.match(title):
        issues.append("english-title-with-chinese-type-suffix")
    return issues


def markdown_escape(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def build_rows(vault: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for path in iter_markdown_files(vault):
        rel = path.relative_to(vault).as_posix()
        title = extract_title(path)
        issues = title_issues(title)
        rows.append(
            {
                "path": rel,
                "title": title or "",
                "issues": ",".join(issues),
                "ok": not issues,
            }
        )
    return rows


def emit_markdown(rows: list[dict[str, object]], *, issues_only: bool) -> None:
    selected = [row for row in rows if (not issues_only or not row["ok"])]
    print("| path | title | issues |")
    print("|---|---|---|")
    for row in selected:
        print(
            "| {path} | {title} | {issues} |".format(
                path=markdown_escape(row["path"]),
                title=markdown_escape(row["title"]),
                issues=markdown_escape(row["issues"]),
            )
        )


def emit_csv(rows: list[dict[str, object]], *, issues_only: bool) -> None:
    selected = [row for row in rows if (not issues_only or not row["ok"])]
    writer = csv.DictWriter(sys.stdout, fieldnames=["path", "title", "issues", "ok"])
    writer.writeheader()
    writer.writerows(selected)


def emit_json(rows: list[dict[str, object]], *, issues_only: bool) -> None:
    selected = [row for row in rows if (not issues_only or not row["ok"])]
    print(json.dumps(selected, ensure_ascii=False, indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract Obsidian Markdown note paths and frontmatter titles as a table.",
    )
    parser.add_argument(
        "--vault",
        default=".maxa",
        help="Vault root path. Defaults to .maxa under the current directory.",
    )
    parser.add_argument(
        "--format",
        choices=["markdown", "csv", "json"],
        default="markdown",
        help="Output format. Defaults to markdown.",
    )
    parser.add_argument(
        "--issues-only",
        action="store_true",
        help="Only show notes whose title violates the semantic title rule, including English titles with a Chinese type suffix.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    vault = Path(args.vault).expanduser().resolve()
    if not vault.exists() or not vault.is_dir():
        print(f"Vault directory not found: {vault}", file=sys.stderr)
        return 2

    rows = build_rows(vault)
    if args.format == "json":
        emit_json(rows, issues_only=args.issues_only)
    elif args.format == "csv":
        emit_csv(rows, issues_only=args.issues_only)
    else:
        emit_markdown(rows, issues_only=args.issues_only)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
