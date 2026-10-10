#!/usr/bin/env python3
"""List single-level TaskAdmin tasks with optional filtering."""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import output, paths, scanner, task_ids


def main() -> None:
    parser = argparse.ArgumentParser(description="List TaskAdmin tasks")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--tag", help="Tag (default: current tag from state.yaml)")
    parser.add_argument("--status", help="Comma-separated status filter")
    parser.add_argument("--depends-on", help="Find tasks that depend on this integer task ID")
    parser.add_argument("--isolated", action="store_true", help="Find tasks with no dependency edges")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        tag = paths.resolve_tag(args.project_root, args.tag)
    except ValueError as exc:
        output.error(str(exc))
    if not paths.get_tasks_dir(args.project_root, tag).is_dir():
        output.error(f"Tag '{tag}' does not exist")

    tasks = scanner.scan_tasks(args.project_root, tag)
    if args.status:
        statuses = {value.strip() for value in args.status.split(",") if value.strip()}
        tasks = [task for task in tasks if task["status"] in statuses]
    if args.depends_on:
        try:
            dependency = task_ids.parse_task_id(args.depends_on)
        except ValueError as exc:
            output.error(str(exc))
        tasks = [task for task in tasks if dependency in task.get("dependencies", [])]
    if args.isolated:
        referenced = {dep for task in tasks for dep in task.get("dependencies", [])}
        tasks = [task for task in tasks if not task.get("dependencies") and task["id"] not in referenced]

    counts: dict[str, int] = {}
    for task in tasks:
        counts[task["status"]] = counts.get(task["status"], 0) + 1
    output.success({"tag": tag, "tasks": tasks, "total": len(tasks), "by_status": counts})


if __name__ == "__main__":
    main()
