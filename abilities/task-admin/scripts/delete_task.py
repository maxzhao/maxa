#!/usr/bin/env python3
"""Delete one TaskAdmin task workspace with dependency guards."""

import argparse
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner


def main() -> None:
    parser = argparse.ArgumentParser(description="Delete one TaskAdmin task workspace")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--id", required=True, help="Positive integer task ID")
    parser.add_argument("--force", action="store_true", help="Remove incoming dependency edges and acknowledge outgoing edges")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        task_id = paths.parse_task_id(args.id)
    except ValueError as exc:
        output.error(str(exc))
    try:
        tag = paths.require_current_tag(args.project_root)
    except ValueError as exc:
        output.error(str(exc))
    tasks = scanner.scan_tasks(args.project_root, tag)
    by_id = {task["id"]: task for task in tasks}
    task = by_id.get(task_id)
    if task is None:
        output.error(f"Task {task_id} does not exist in tag '{tag}'")

    incoming = [item for item in tasks if task_id in item.get("dependencies", [])]
    outgoing = list(task.get("dependencies", []))
    blockers: list[str] = []
    if outgoing:
        blockers.append(f"Task {task_id} has dependencies: {', '.join(map(str, outgoing))}")
    if incoming:
        blockers.append(
            f"Task {task_id} is depended on by task(s): {', '.join(str(item['id']) for item in incoming)}"
        )
    if blockers and not args.force:
        output.error("; ".join(blockers) + ". Resolve them first or rerun with --force.")

    backups: dict[str, str] = {}
    removed: list[dict] = []
    try:
        for item in incoming:
            meta_file = item["meta_file"]
            backups[meta_file] = Path(meta_file).read_text(encoding="utf-8")
            dependencies = [value for value in item.get("dependencies", []) if value != task_id]
            frontmatter.update_metadata(
                meta_file, {"dependencies": dependencies}, frontmatter.TASK_META_FIELDS
            )
            removed.append({"id": item["id"], "removed": [task_id], "dependencies": dependencies})
        shutil.rmtree(task["task_dir"])
    except Exception as exc:
        for filepath, content in backups.items():
            try:
                with open(filepath, "w", encoding="utf-8") as handle:
                    handle.write(content)
            except OSError:
                pass
        output.error(f"Failed to delete task {task_id}; dependency changes were restored where possible: {exc}")

    output.success(
        {
            "id": task_id,
            "tag": tag,
            "deleted_dir": task["task_dir"],
            "acknowledged_outgoing_dependencies": outgoing if args.force else [],
            "removed_dependencies": removed,
        }
    )


if __name__ == "__main__":
    main()
