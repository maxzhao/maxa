#!/usr/bin/env python3
"""Create one complete single-level TaskAdmin task workspace."""

import argparse
import os
import shutil
import sys
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner, task_ids


def _read_required_markdown(path_value: str, label: str) -> str:
    path = Path(path_value)
    if not path.is_file():
        output.error(f"{label} file does not exist: {path}")
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        output.error(f"Cannot read {label} file as UTF-8: {path}: {exc}")
    if not content.strip():
        output.error(f"{label} file must not be empty: {path}")
    return content if content.endswith("\n") else content + "\n"


def _validate_tag_name(tag: str) -> None:
    try:
        paths.validate_tag(tag)
    except ValueError as exc:
        output.error(str(exc))


def _ensure_tag(project_root: str, tag: str) -> None:
    _validate_tag_name(tag)
    tag_dir = paths.get_tasks_dir(project_root, tag)
    if not tag_dir.exists():
        tag_dir.mkdir(parents=True)
        now = frontmatter.now_timestamp()
        frontmatter.write_yaml_file(
            str(paths.get_tag_meta_file(project_root, tag)),
            {"description": "", "created": now, "updated": now, "version": "1"},
            frontmatter.TAG_META_FIELDS,
        )
    state_file = paths.get_state_file(project_root)
    if not state_file.exists():
        frontmatter.write_yaml_file(
            str(state_file),
            {"currentTag": tag, "lastSwitched": frontmatter.now_timestamp()},
            frontmatter.STATE_FIELDS,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a complete TaskAdmin task workspace")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--name", required=True, help="Task name")
    parser.add_argument("--description", default="", help="One-line task description")
    parser.add_argument("--priority", default="medium", choices=["high", "medium", "low"])
    parser.add_argument("--dependencies", default="", help="Comma-separated integer task IDs")
    parser.add_argument("--workspace", help="Optional workspace declaration")
    parser.add_argument("--plan-file", required=True, help="Prepared UTF-8 Markdown implementation plan")
    parser.add_argument("--todo-file", required=True, help="Prepared UTF-8 Markdown TODO/recovery state")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")

    name = args.name.strip()
    if not name:
        output.error("Task name must not be empty")
    plan = _read_required_markdown(args.plan_file, "Plan")
    todo = _read_required_markdown(args.todo_file, "TODO")
    try:
        tag = paths.require_current_tag(args.project_root, allow_empty_store=True)
    except ValueError as exc:
        output.error(str(exc))
    _ensure_tag(args.project_root, tag)

    dependencies: list[int] = []
    for raw in args.dependencies.split(","):
        value = raw.strip()
        if not value:
            continue
        try:
            dependency = task_ids.parse_dep_value(value)
        except ValueError as exc:
            output.error(str(exc))
        if dependency in dependencies:
            output.error(f"Duplicate dependency ID: {dependency}")
        dependencies.append(dependency)

    existing_ids = {task["id"] for task in scanner.scan_tasks(args.project_root, tag)}
    missing = [dependency for dependency in dependencies if dependency not in existing_ids]
    if missing:
        output.error(f"Dependency target(s) do not exist in tag '{tag}': {', '.join(map(str, missing))}")

    task_id = scanner.get_next_task_id(args.project_root, tag)
    if task_id in dependencies:
        output.error(f"Task cannot depend on itself: {task_id}")

    tag_dir = paths.get_tasks_dir(args.project_root, tag)
    final_dir = paths.get_task_dir(args.project_root, tag, task_id)
    temp_dir = tag_dir / f".{final_dir.name}.tmp-{uuid.uuid4().hex}"
    if final_dir.exists():
        output.error(f"Next task ID {task_id} is unexpectedly occupied: {final_dir}")

    meta = frontmatter.create_task_metadata(
        name=name,
        description=args.description,
        priority=args.priority,
        dependencies=dependencies,
        workspace=args.workspace,
    )

    try:
        temp_dir.mkdir()
        frontmatter.write_yaml_file(str(temp_dir / paths.META_FILE), meta, frontmatter.TASK_META_FIELDS)
        (temp_dir / paths.PLAN_FILE).write_text(plan, encoding="utf-8")
        (temp_dir / paths.TODO_FILE).write_text(todo, encoding="utf-8")
        os.replace(temp_dir, final_dir)
    except Exception as exc:
        shutil.rmtree(temp_dir, ignore_errors=True)
        output.error(f"Failed to create complete task workspace: {exc}")

    output.success(
        {
            "id": task_id,
            "name": name,
            "tag": tag,
            "task_dir": str(final_dir),
            "meta_file": str(final_dir / paths.META_FILE),
            "plan_file": str(final_dir / paths.PLAN_FILE),
            "todo_file": str(final_dir / paths.TODO_FILE),
            "workspace": args.workspace,
        }
    )


if __name__ == "__main__":
    main()
