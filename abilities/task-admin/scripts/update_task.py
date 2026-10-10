#!/usr/bin/env python3
"""Update one TaskAdmin task's script-owned metadata."""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths


VALID_STATUSES = ["pending", "in-progress", "done", "review", "deferred", "cancelled"]
VALID_PRIORITIES = ["high", "medium", "low"]


def _fire_event(event: str, data: dict) -> None:
    payload = json.dumps({"event": event, "data": data}, ensure_ascii=False)
    print(f"__FIRE_EVENT__:{payload}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description="Update TaskAdmin task metadata")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--id", required=True, help="Positive integer task ID")
    parser.add_argument("--status", choices=VALID_STATUSES)
    parser.add_argument("--priority", choices=VALID_PRIORITIES)
    parser.add_argument("--name", help="New task name")
    parser.add_argument("--description", help="New description")
    parser.add_argument("--workspace", help="Set optional workspace declaration")
    parser.add_argument("--clear-workspace", action="store_true", help="Remove task workspace binding")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        task_id = paths.parse_task_id(args.id)
    except ValueError as exc:
        output.error(str(exc))
    if not any(
        [args.status, args.priority, args.name is not None, args.description is not None, args.workspace is not None, args.clear_workspace]
    ):
        output.error("At least one field must be specified")
    if args.workspace is not None and args.clear_workspace:
        output.error("Use either --workspace or --clear-workspace, not both")
    if args.name is not None:
        args.name = args.name.strip()
        if not args.name:
            output.error("Task name must not be empty")

    try:
        tag = paths.require_current_tag(args.project_root)
    except ValueError as exc:
        output.error(str(exc))
    meta_file = paths.get_task_meta_file(args.project_root, tag, task_id)
    if not meta_file.is_file():
        output.error(f"Task does not exist: {task_id} (tag: {tag})")
    try:
        meta = frontmatter.read_yaml_file(str(meta_file))
    except (OSError, ValueError) as exc:
        output.error(f"Invalid task metadata: {meta_file}: {exc}")

    updates: dict = {}
    old_values: dict = {}
    for key in ("status", "priority", "name", "description"):
        value = getattr(args, key)
        if value is not None:
            old_values[key] = meta.get(key)
            updates[key] = value
    if args.workspace is not None:
        old_values["workspace"] = meta.get("workspace")
        updates["workspace"] = args.workspace
    elif args.clear_workspace:
        old_values["workspace"] = meta.get("workspace")
        updates["workspace"] = None

    frontmatter.update_metadata(str(meta_file), updates, frontmatter.TASK_META_FIELDS)
    if args.status:
        prev_status = str(old_values.get("status", "unknown"))
        event_data = {
            "task_id": str(task_id),
            "tag": tag,
            "title": str(meta.get("name", "")),
        }
        _fire_event(
            "TaskStatusChanged",
            {
                **event_data,
                "prev_status": prev_status,
                "new_status": args.status,
            },
        )
        if prev_status != args.status:
            if args.status == "in-progress":
                _fire_event("TaskStarted", event_data)
            elif args.status == "done":
                _fire_event("TaskCompleted", event_data)

    output.success(
        {
            "id": task_id,
            "tag": tag,
            "updated_fields": list(updates.keys()),
            "meta_file": str(meta_file),
        }
    )


if __name__ == "__main__":
    main()
