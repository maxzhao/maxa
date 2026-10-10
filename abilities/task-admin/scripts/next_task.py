#!/usr/bin/env python3
"""Select the next executable peer TaskAdmin task."""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import output, paths, scanner


PRIORITY_ORDER = {"high": 0, "medium": 1, "low": 2}


def dependencies_satisfied(dependencies: list[int], statuses: dict[int, str]) -> bool:
    return all(statuses.get(dependency) == "done" for dependency in dependencies)


def find_next_task(tasks: list[dict]) -> dict | None:
    statuses = {task["id"]: task["status"] for task in tasks}
    candidates = [
        task
        for task in tasks
        if task["status"] in {"pending", "in-progress"}
        and dependencies_satisfied(task.get("dependencies", []), statuses)
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda task: (PRIORITY_ORDER.get(task.get("priority"), 1), task["id"]))
    task = candidates[0]
    return {
        "id": task["id"],
        "name": task["name"],
        "description": task.get("description", ""),
        "status": task["status"],
        "priority": task.get("priority", "medium"),
        "task_dir": task["task_dir"],
        "meta_file": task["meta_file"],
        "plan_file": task["plan_file"],
        "todo_file": task["todo_file"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Get the next executable TaskAdmin task")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--tag", help="Tag (default: current tag from state.yaml)")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        tag = paths.resolve_tag(args.project_root, args.tag)
    except ValueError as exc:
        output.error(str(exc))
    if not paths.get_tasks_dir(args.project_root, tag).is_dir():
        output.error(f"Tag '{tag}' does not exist")

    next_task = find_next_task(scanner.scan_tasks(args.project_root, tag))
    if next_task is None:
        output.success(
            {"tag": tag, "next_task": None, "reason": "No pending or in-progress tasks with satisfied dependencies"}
        )
    output.success({"tag": tag, "next_task": next_task})


if __name__ == "__main__":
    main()
