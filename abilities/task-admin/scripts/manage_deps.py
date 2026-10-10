#!/usr/bin/env python3
"""Add or remove same-tag integer TaskAdmin dependencies."""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner, task_ids


def _has_cycle(graph: dict[int, list[int]]) -> bool:
    visiting: set[int] = set()
    visited: set[int] = set()

    def visit(node: int) -> bool:
        if node in visiting:
            return True
        if node in visited:
            return False
        visiting.add(node)
        for dependency in graph.get(node, []):
            if visit(dependency):
                return True
        visiting.remove(node)
        visited.add(node)
        return False

    return any(visit(node) for node in graph if node not in visited)


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage TaskAdmin task dependencies")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--action", required=True, choices=["add", "remove"])
    parser.add_argument("--id", required=True, help="Positive integer task ID")
    parser.add_argument("--depends-on", required=True, help="Positive integer dependency ID")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        task_id = task_ids.parse_task_id(args.id)
        dependency_id = task_ids.parse_task_id(args.depends_on)
    except ValueError as exc:
        output.error(str(exc))
    if task_id == dependency_id:
        output.error(f"Task cannot depend on itself: {task_id}")

    try:
        tag = paths.require_current_tag(args.project_root)
    except ValueError as exc:
        output.error(str(exc))
    tasks = scanner.scan_tasks(args.project_root, tag)
    by_id = {task["id"]: task for task in tasks}
    if task_id not in by_id:
        output.error(f"Task does not exist: {task_id} (tag: {tag})")
    if args.action == "add" and dependency_id not in by_id:
        output.error(f"Dependency target does not exist: {dependency_id} (tag: {tag})")

    dependencies = list(by_id[task_id].get("dependencies", []))
    if args.action == "add":
        if dependency_id in dependencies:
            output.error(f"Dependency already exists: {task_id} already depends on {dependency_id}")
        candidate = dependencies + [dependency_id]
        graph = {task["id"]: list(task.get("dependencies", [])) for task in tasks}
        graph[task_id] = candidate
        if _has_cycle(graph):
            output.error(f"Adding dependency {task_id} → {dependency_id} would create a circular dependency")
        dependencies = candidate
    else:
        if dependency_id not in dependencies:
            output.error(f"Dependency not found: {task_id} does not depend on {dependency_id}")
        dependencies = [value for value in dependencies if value != dependency_id]

    meta_file = paths.get_task_meta_file(args.project_root, tag, task_id)
    frontmatter.update_metadata(
        str(meta_file), {"dependencies": dependencies}, frontmatter.TASK_META_FIELDS
    )
    output.success(
        {
            "action": args.action,
            "id": task_id,
            "depends_on": dependency_id,
            "tag": tag,
            "dependencies": dependencies,
            "meta_file": str(meta_file),
        }
    )


if __name__ == "__main__":
    main()
