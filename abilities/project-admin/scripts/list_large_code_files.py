#!/usr/bin/env python3
"""List large Git-tracked code files in a project using scc for language detection.

The script is intentionally project-agnostic:
- file source is `git ls-files`, so untracked and ignored files are excluded;
- code-file detection is delegated to `scc`;
- file size is read from the filesystem, then filtered by threshold;
- hidden Git-tracked directories are excluded by default to avoid shared runtime noise
  such as .github/, .vscode/ or local convention directories.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


class LargeCodeFilesError(RuntimeError):
    pass


@dataclass(frozen=True)
class CodeFile:
    path: str
    size_bytes: int
    language: str
    lines: int
    code: int
    comments: int
    blanks: int


def top_dir(path: str) -> str:
    return path.split("/", 1)[0] if "/" in path else "."


SIZE_UNITS = {
    "": 1,
    "b": 1,
    "k": 1000,
    "kb": 1000,
    "m": 1000**2,
    "mb": 1000**2,
    "g": 1000**3,
    "gb": 1000**3,
    "ki": 1024,
    "kib": 1024,
    "mi": 1024**2,
    "mib": 1024**2,
    "gi": 1024**3,
    "gib": 1024**3,
}


DEFAULT_EXCLUDE_DIR_PREFIXES = (".", ",")
DEFAULT_EXCLUDE_DIR_NAMES = (
    # Package manager / vendored dependencies
    "node_modules",
    "bower_components",
    "jspm_packages",
    "vendor",
    "vendors",
    "third_party",
    "third-party",
    "external",
    "externals",
    "deps",
    "dependencies",
    # Python / runtime environments and caches
    "venv",
    "env",
    "virtualenv",
    "site-packages",
    "__pycache__",
    # Common build and generated output directories
    "target",
    "dist",
    "build",
    "out",
    "coverage",
    "htmlcov",
    # Unreal Engine generated / binary-heavy directories
    "Binaries",
    "Intermediate",
    "Saved",
    "DerivedDataCache",
)


def parse_size(value: str) -> int:
    raw = value.strip().lower().replace("_", "")
    if not raw:
        raise argparse.ArgumentTypeError("size cannot be empty")

    number = []
    unit = []
    for ch in raw:
        if ch.isdigit() or ch == ".":
            if unit:
                raise argparse.ArgumentTypeError(f"invalid size: {value}")
            number.append(ch)
        else:
            unit.append(ch)

    if not number:
        raise argparse.ArgumentTypeError(f"invalid size: {value}")
    unit_text = "".join(unit)
    if unit_text not in SIZE_UNITS:
        raise argparse.ArgumentTypeError(
            f"unsupported size unit '{unit_text}'. Use B, KB, MB, GB, KiB, MiB or GiB."
        )

    try:
        amount = float("".join(number))
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid size: {value}") from exc
    if amount < 0:
        raise argparse.ArgumentTypeError("size must be non-negative")
    return int(amount * SIZE_UNITS[unit_text])


def human_size(size: int) -> str:
    units = [("GiB", 1024**3), ("MiB", 1024**2), ("KiB", 1024)]
    for suffix, factor in units:
        if size >= factor:
            return f"{size / factor:.1f}{suffix}"
    return f"{size}B"


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)


def resolve_project_root(project_root: str | None) -> Path:
    if project_root:
        root = Path(project_root).expanduser().resolve()
        if not root.exists():
            raise LargeCodeFilesError(f"project root does not exist: {root}")
        return root

    result = run(["git", "rev-parse", "--show-toplevel"], Path.cwd())
    if result.returncode != 0:
        raise LargeCodeFilesError(
            "not inside a Git work tree; pass --project-root for the target project"
        )
    return Path(result.stdout.strip()).resolve()


def ensure_git_repo(root: Path) -> None:
    result = run(["git", "rev-parse", "--is-inside-work-tree"], root)
    if result.returncode != 0 or result.stdout.strip() != "true":
        raise LargeCodeFilesError(f"not a Git work tree: {root}")


def find_scc(explicit: str | None = None) -> str:
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    found = shutil.which("scc")
    if found:
        candidates.append(found)
    candidates.append(str(Path.home() / ".local/bin/scc"))

    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        path = Path(candidate).expanduser()
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
        if os.path.sep not in candidate:
            resolved = shutil.which(candidate)
            if resolved:
                return resolved

    raise LargeCodeFilesError(
        "scc is required but was not found. Install it first or pass --scc-path."
    )


def git_tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=False
    )
    if result.returncode != 0:
        stderr = result.stderr.decode(errors="replace")
        raise LargeCodeFilesError(f"git ls-files failed: {stderr.strip()}")
    return [item.decode(errors="surrogateescape") for item in result.stdout.split(b"\0") if item]


def has_excluded_dir(
    path: str,
    prefixes: tuple[str, ...],
    names: frozenset[str],
) -> str | None:
    parts = Path(path).parts
    # Only directory components are considered; hidden files at project root are not
    # excluded unless they live under a hidden directory.
    for part in parts[:-1]:
        if part in {"", ".", ".."}:
            continue
        if any(part.startswith(prefix) for prefix in prefixes):
            return part
        if part in names:
            return part
    return None


def existing_regular_files(root: Path, files: Iterable[str]) -> list[str]:
    result: list[str] = []
    for rel in files:
        path = root / rel
        try:
            if path.is_file():
                result.append(rel)
        except OSError:
            continue
    return result


def chunk_by_argv_size(files: list[str], limit: int = 120_000) -> Iterable[list[str]]:
    chunk: list[str] = []
    size = 0
    for file in files:
        item_size = len(file.encode(errors="surrogateescape")) + 1
        if chunk and size + item_size > limit:
            yield chunk
            chunk = []
            size = 0
        chunk.append(file)
        size += item_size
    if chunk:
        yield chunk


def scc_files(root: Path, scc: str, files: list[str]) -> dict[str, dict[str, Any]]:
    detected: dict[str, dict[str, Any]] = {}
    if not files:
        return detected

    for chunk in chunk_by_argv_size(files):
        command = [
            scc,
            "--by-file",
            "--format",
            "json",
            "--no-cocomo",
            "--no-complexity",
            "--large-byte-count",
            "0",
            "--large-line-count",
            "0",
            *chunk,
        ]
        result = run(command, root)
        if result.returncode != 0:
            raise LargeCodeFilesError(
                "scc failed while detecting code files:\n" + (result.stderr or result.stdout).strip()
            )
        if not result.stdout.strip():
            continue
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise LargeCodeFilesError("scc returned invalid JSON") from exc

        for language_entry in data:
            language = language_entry.get("Name") or "Unknown"
            for item in language_entry.get("Files") or []:
                location = item.get("Location") or item.get("Filename")
                if not location:
                    continue
                rel = Path(location).as_posix()
                detected[rel] = {
                    "language": item.get("Language") or language,
                    "lines": int(item.get("Lines") or 0),
                    "code": int(item.get("Code") or 0),
                    "comments": int(item.get("Comment") or 0),
                    "blanks": int(item.get("Blank") or 0),
                }
    return detected


def collect_large_code_files(
    root: Path,
    threshold: int,
    scc: str,
    exclude_hidden_dirs: bool,
    exclude_dir_prefixes: tuple[str, ...],
    exclude_dir_names: frozenset[str],
) -> tuple[list[CodeFile], dict[str, int]]:
    tracked = git_tracked_files(root)
    dir_excluded = 0
    excluded_by_dir: dict[str, int] = {}
    if exclude_hidden_dirs or exclude_dir_names:
        filtered = []
        prefixes = exclude_dir_prefixes if exclude_hidden_dirs else ()
        for rel in tracked:
            excluded_dir = has_excluded_dir(rel, prefixes, exclude_dir_names)
            if excluded_dir:
                dir_excluded += 1
                excluded_by_dir[excluded_dir] = excluded_by_dir.get(excluded_dir, 0) + 1
            else:
                filtered.append(rel)
        tracked = filtered

    candidates = existing_regular_files(root, tracked)
    detected = scc_files(root, scc, candidates)

    large: list[CodeFile] = []
    for rel, info in detected.items():
        path = root / rel
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size <= threshold:
            continue
        large.append(
            CodeFile(
                path=rel,
                size_bytes=size,
                language=str(info["language"]),
                lines=int(info["lines"]),
                code=int(info["code"]),
                comments=int(info["comments"]),
                blanks=int(info["blanks"]),
            )
        )

    large.sort(key=lambda item: (-item.size_bytes, item.path))
    stats = {
        "tracked_files": len(git_tracked_files(root)),
        "excluded_files": dir_excluded,
        "excluded_by_dir": dict(sorted(excluded_by_dir.items())),
        "candidate_files": len(candidates),
        "code_files": len(detected),
        "large_code_files": len(large),
    }
    return large, stats


def limited_files(files: list[CodeFile], limit: int | None) -> list[CodeFile]:
    if limit is None or limit <= 0:
        return files
    return files[:limit]


def print_table(files: list[CodeFile], stats: dict[str, int], threshold: int, limit: int | None) -> None:
    print(f"Threshold: {threshold} bytes ({human_size(threshold)})")
    print(
        "Tracked: {tracked_files}, excluded: {excluded_files}, "
        "candidates: {candidate_files}, code files: {code_files}, matched: {large_code_files}".format(
            **stats
        )
    )
    excluded_by_dir = stats.get("excluded_by_dir", {})
    if excluded_by_dir:
        summary = ", ".join(f"{name}={count}" for name, count in excluded_by_dir.items())
        print(f"Excluded by dir: {summary}")
    if not files:
        print("No Git-tracked code files exceed the threshold.")
        return

    headers = ["SIZE", "BYTES", "LANGUAGE", "LINES", "CODE", "PATH"]
    shown_files = limited_files(files, limit)
    if limit and len(files) > len(shown_files):
        print(f"Showing: {len(shown_files)} of {len(files)} matched files. Use --limit 0 to print all rows.")

    rows = [
        [
            human_size(item.size_bytes),
            str(item.size_bytes),
            item.language,
            str(item.lines),
            str(item.code),
            item.path,
        ]
        for item in shown_files
    ]
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def fmt(row: list[str]) -> str:
        return "  ".join(value.ljust(widths[index]) for index, value in enumerate(row))

    print(fmt(headers))
    print(fmt(["-" * width for width in widths]))
    for row in rows:
        print(fmt(row))


def print_summary(
    files: list[CodeFile],
    stats: dict[str, int],
    root: Path,
    threshold: int,
    limit: int | None,
    group_limit: int,
) -> None:
    from collections import Counter

    total_size = sum(item.size_bytes for item in files)
    shown_files = limited_files(files, limit if limit is not None else 20)
    print(f"Project root: {root}")
    print(f"Threshold: {threshold} bytes ({human_size(threshold)})")
    print(
        "Tracked: {tracked_files}, excluded: {excluded_files}, "
        "candidates: {candidate_files}, code files: {code_files}, matched: {large_code_files}".format(
            **stats
        )
    )
    print(f"Matched total size: {total_size} bytes ({human_size(total_size)})")

    excluded_by_dir = stats.get("excluded_by_dir", {})
    if excluded_by_dir:
        summary = ", ".join(f"{name}={count}" for name, count in excluded_by_dir.items())
        print(f"Excluded by dir: {summary}")

    if not files:
        print("No Git-tracked code files exceed the threshold.")
        return

    print("\nBy language:")
    for language, count in Counter(item.language for item in files).most_common(group_limit):
        print(f"- {language}: {count}")

    print("\nBy top directory:")
    for directory, count in Counter(top_dir(item.path) for item in files).most_common(group_limit):
        print(f"- {directory}: {count}")

    print(f"\nTop {len(shown_files)} files by size:")
    print("BYTES\tSIZE\tLANGUAGE\tLINES\tPATH")
    for item in shown_files:
        print(
            f"{item.size_bytes}\t{human_size(item.size_bytes)}\t{item.language}\t{item.lines}\t{item.path}"
        )
    if limit and len(files) > len(shown_files):
        print(f"\nShowing {len(shown_files)} of {len(files)} matched files. Use --limit 0 to print all rows.")


def print_json(files: list[CodeFile], stats: dict[str, int], root: Path, threshold: int, limit: int | None) -> None:
    print(
        json.dumps(
            {
                "project_root": str(root),
                "threshold_bytes": threshold,
                "stats": stats,
                "files": [item.__dict__ for item in limited_files(files, limit)],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def print_csv(files: list[CodeFile], limit: int | None) -> None:
    writer = csv.DictWriter(
        sys.stdout,
        fieldnames=[
            "path",
            "size_bytes",
            "language",
            "lines",
            "code",
            "comments",
            "blanks",
        ],
    )
    writer.writeheader()
    for item in limited_files(files, limit):
        writer.writerow(item.__dict__)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List Git-tracked code files larger than a size limit using scc."
    )
    parser.add_argument(
        "--project-root",
        help="Target project root. Defaults to the current Git work tree root.",
    )
    parser.add_argument(
        "--threshold",
        type=parse_size,
        default=parse_size("50k"),
        help="Minimum code file size in bytes or with units. Default: 50k bytes.",
    )
    parser.add_argument(
        "--format",
        choices=("table", "summary", "json", "csv"),
        default="table",
        help="Output format. Default: table. Use summary for compact Agent-readable diagnostics.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Maximum number of matched files to print. 0 means no limit. In summary format, the default top list is 20 when --limit is omitted.",
    )
    parser.add_argument(
        "--group-limit",
        type=int,
        default=20,
        help="Maximum number of language/top-directory groups to print in summary format. Default: 20.",
    )
    parser.add_argument("--scc-path", help="Explicit path to the scc executable.")
    parser.add_argument(
        "--include-hidden-dirs",
        action="store_true",
        help="Include Git-tracked files under hidden directories. By default, directory components starting with '.' or ',' are excluded.",
    )
    parser.add_argument(
        "--include-third-party-dirs",
        action="store_true",
        help="Include default-excluded third-party, dependency, build and generated directories such as node_modules, vendor, dist, build and Unreal generated directories.",
    )
    parser.add_argument(
        "--no-default-excludes",
        action="store_true",
        help="Disable all default directory exclusions, including hidden directories and common third-party/build/generated directories. Explicit --exclude-dir-prefix and --exclude-dir-name values still apply.",
    )
    parser.add_argument(
        "--exclude-dir-prefix",
        action="append",
        default=[],
        help="Additional directory-name prefix to exclude. Can be repeated.",
    )
    parser.add_argument(
        "--exclude-dir-name",
        action="append",
        default=[],
        help="Additional exact directory name to exclude. Can be repeated.",
    )
    args = parser.parse_args()

    try:
        root = resolve_project_root(args.project_root)
        ensure_git_repo(root)
        scc = find_scc(args.scc_path)
        if args.no_default_excludes:
            prefixes = tuple(args.exclude_dir_prefix)
            exclude_hidden_dirs = False
            excluded_names = frozenset(args.exclude_dir_name)
        else:
            prefixes = tuple(DEFAULT_EXCLUDE_DIR_PREFIXES + tuple(args.exclude_dir_prefix))
            exclude_hidden_dirs = not args.include_hidden_dirs
            default_excluded_names = () if args.include_third_party_dirs else DEFAULT_EXCLUDE_DIR_NAMES
            excluded_names = frozenset(default_excluded_names + tuple(args.exclude_dir_name))
        files, stats = collect_large_code_files(
            root=root,
            threshold=args.threshold,
            scc=scc,
            exclude_hidden_dirs=exclude_hidden_dirs,
            exclude_dir_prefixes=prefixes,
            exclude_dir_names=excluded_names,
        )
        output_limit = args.limit if args.limit and args.limit > 0 else None
        if args.format == "json":
            print_json(files, stats, root, args.threshold, output_limit)
        elif args.format == "csv":
            print_csv(files, output_limit)
        elif args.format == "summary":
            if args.limit is None:
                summary_limit = 20
            elif args.limit <= 0:
                summary_limit = None
            else:
                summary_limit = args.limit
            print_summary(files, stats, root, args.threshold, summary_limit, args.group_limit)
        else:
            print_table(files, stats, args.threshold, output_limit)
        return 0
    except LargeCodeFilesError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
