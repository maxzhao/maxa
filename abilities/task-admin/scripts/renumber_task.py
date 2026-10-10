#!/usr/bin/env python3
"""Move or swap single-level TaskAdmin task IDs within one tag."""

import argparse
import os
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner


def _rewrite_dependencies(project_root: str, tag: str, mapping: dict[int, int]) -> None:
    for task in scanner.scan_tasks(project_root, tag):
        original = list(task.get("dependencies", []))
        rewritten = [mapping.get(value, value) for value in original]
        if rewritten != original:
            frontmatter.update_metadata(
                task["meta_file"], {"dependencies": rewritten}, frontmatter.TASK_META_FIELDS
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Renumber or swap TaskAdmin task IDs")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--id", required=True, help="Current positive integer task ID")
    parser.add_argument("--to", required=True, help="Target positive integer task ID")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        old_id = paths.parse_task_id(args.id)
        new_id = paths.parse_task_id(args.to)
    except ValueError as exc:
        output.error(str(exc))
    if old_id == new_id:
        output.error("Source and target task IDs are the same")

    try:
        tag = paths.require_current_tag(args.project_root)
    except ValueError as exc:
        output.error(str(exc))
    tag_dir = paths.get_tasks_dir(args.project_root, tag)
    old_dir = paths.get_task_dir(args.project_root, tag, old_id)
    new_dir = paths.get_task_dir(args.project_root, tag, new_id)
    if scanner.parse_task_dir(old_dir, args.project_root, tag) is None:
        output.error(f"Task {old_id} does not exist or is incomplete in tag '{tag}'")
    target_exists = new_dir.exists()
    if target_exists and scanner.parse_task_dir(new_dir, args.project_root, tag) is None:
        output.error(f"Target ID {new_id} is occupied by an incomplete task workspace")

    metadata_backups = {
        task["meta_file"]: Path(task["meta_file"]).read_text(encoding="utf-8")
        for task in scanner.scan_tasks(args.project_root, tag)
    }
    staging = tag_dir / f".renumber-{uuid.uuid4().hex}"

    with tempfile.TemporaryDirectory(prefix=".taskadmin-renumber-backup-", dir=str(tag_dir)) as backup_root_value:
        backup_root = Path(backup_root_value)
        shutil.copytree(old_dir, backup_root / "old")
        if target_exists:
            shutil.copytree(new_dir, backup_root / "new")
        try:
            if target_exists:
                old_dir.rename(staging)
                new_dir.rename(old_dir)
                staging.rename(new_dir)
                mapping = {old_id: new_id, new_id: old_id}
                operation = "swap"
            else:
                old_dir.rename(new_dir)
                mapping = {old_id: new_id}
                operation = "move"
            _rewrite_dependencies(args.project_root, tag, mapping)
        except Exception as exc:
            shutil.rmtree(staging, ignore_errors=True)
            shutil.rmtree(old_dir, ignore_errors=True)
            shutil.rmtree(new_dir, ignore_errors=True)
            shutil.copytree(backup_root / "old", old_dir)
            if target_exists:
                shutil.copytree(backup_root / "new", new_dir)
            for filepath, content in metadata_backups.items():
                path = Path(filepath)
                if path.exists():
                    path.write_text(content, encoding="utf-8")
            output.error(f"Failed to renumber task; original directories and dependencies were restored: {exc}")

    output.success(
        {
            "operation": operation,
            "tag": tag,
            "old_id": old_id,
            "new_id": new_id,
            "task_dir": str(new_dir),
        }
    )


if __name__ == "__main__":
    main()
