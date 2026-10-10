#!/usr/bin/env python3
"""Move one TaskAdmin task workspace between tags."""

import argparse
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner


def main() -> None:
    parser = argparse.ArgumentParser(description="Move one TaskAdmin task to another tag")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--id", required=True, help="Positive integer task ID")
    parser.add_argument("--to-tag", required=True, help="Destination tag")
    parser.add_argument("--force", action="store_true", help="Remove source incoming and destination-missing outgoing dependencies")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        task_id = paths.parse_task_id(args.id)
    except ValueError as exc:
        output.error(str(exc))
    try:
        source_tag = paths.require_current_tag(args.project_root)
        destination_tag = paths.validate_tag(args.to_tag)
    except ValueError as exc:
        output.error(str(exc))
    if source_tag == destination_tag:
        output.error("Source and destination tags are the same")
    if not paths.get_tasks_dir(args.project_root, destination_tag).is_dir():
        output.error(f"Destination tag '{destination_tag}' does not exist")

    source_tasks = scanner.scan_tasks(args.project_root, source_tag)
    source = next((task for task in source_tasks if task["id"] == task_id), None)
    if source is None:
        output.error(f"Task {task_id} does not exist in tag '{source_tag}'")
    destination_tasks = scanner.scan_tasks(args.project_root, destination_tag)
    destination_ids = {task["id"] for task in destination_tasks}
    incoming = [task for task in source_tasks if task_id in task.get("dependencies", [])]
    missing_outgoing = [
        dependency for dependency in source.get("dependencies", []) if dependency not in destination_ids
    ]

    blockers: list[str] = []
    if incoming:
        blockers.append(
            "source task is depended on by " + ", ".join(str(task["id"]) for task in incoming)
        )
    if missing_outgoing:
        blockers.append(
            "outgoing dependencies are absent from destination: "
            + ", ".join(map(str, missing_outgoing))
        )
    if blockers and not args.force:
        output.error("; ".join(blockers) + ". Resolve them first or rerun with --force.")

    new_id = scanner.get_next_task_id(args.project_root, destination_tag)
    source_dir = Path(source["task_dir"])
    destination_dir = paths.get_task_dir(args.project_root, destination_tag, new_id)
    source_backup = source_dir.parent / f".{source_dir.name}.move-{uuid.uuid4().hex}"
    source_meta_backup = (source_dir / paths.META_FILE).read_text(encoding="utf-8")
    incoming_backups: dict[str, str] = {}
    removed_dependencies: list[dict] = []
    published = False

    try:
        source_dir.rename(source_backup)
        if missing_outgoing:
            kept = [
                dependency
                for dependency in source.get("dependencies", [])
                if dependency not in missing_outgoing
            ]
            frontmatter.update_metadata(
                str(source_backup / paths.META_FILE),
                {"dependencies": kept},
                frontmatter.TASK_META_FIELDS,
            )
            removed_dependencies.append(
                {"id": new_id, "tag": destination_tag, "removed": missing_outgoing, "dependencies": kept}
            )

        for task in incoming:
            meta_file = task["meta_file"]
            incoming_backups[meta_file] = Path(meta_file).read_text(encoding="utf-8")
            dependencies = [value for value in task.get("dependencies", []) if value != task_id]
            frontmatter.update_metadata(
                meta_file, {"dependencies": dependencies}, frontmatter.TASK_META_FIELDS
            )
            removed_dependencies.append(
                {"id": task["id"], "tag": source_tag, "removed": [task_id], "dependencies": dependencies}
            )

        os.replace(source_backup, destination_dir)
        published = True
    except Exception as exc:
        if published and destination_dir.exists() and not source_backup.exists():
            try:
                destination_dir.rename(source_backup)
            except OSError:
                pass
        if source_backup.exists():
            try:
                (source_backup / paths.META_FILE).write_text(source_meta_backup, encoding="utf-8")
                source_backup.rename(source_dir)
            except OSError:
                pass
        for filepath, content in incoming_backups.items():
            try:
                Path(filepath).write_text(content, encoding="utf-8")
            except OSError:
                pass
        output.error(f"Failed to move task; original source and dependency state were restored where possible: {exc}")

    output.success(
        {
            "old_id": task_id,
            "new_id": new_id,
            "from_tag": source_tag,
            "to_tag": destination_tag,
            "task_dir": str(destination_dir),
            "removed_dependencies": removed_dependencies,
        }
    )


if __name__ == "__main__":
    main()
