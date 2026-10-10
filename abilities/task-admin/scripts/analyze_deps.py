#!/usr/bin/env python3
"""Validate, repair, or graph single-level TaskAdmin dependencies."""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner


def find_cycles(graph: dict[int, list[int]]) -> list[list[int]]:
    visited: set[int] = set()
    stack: list[int] = []
    active: set[int] = set()
    cycles: list[list[int]] = []

    def visit(node: int) -> None:
        if node in active:
            index = stack.index(node)
            cycle = stack[index:] + [node]
            if cycle not in cycles:
                cycles.append(cycle)
            return
        if node in visited:
            return
        visited.add(node)
        active.add(node)
        stack.append(node)
        for dependency in graph.get(node, []):
            visit(dependency)
        stack.pop()
        active.remove(node)

    for node in graph:
        visit(node)
    return cycles


def validate(tasks: list[dict], tag: str) -> None:
    valid_ids = {task["id"] for task in tasks}
    issues: list[dict] = []
    graph: dict[int, list[int]] = {}
    for task in tasks:
        task_id = task["id"]
        graph[task_id] = list(task.get("dependencies", []))
        for dependency in graph[task_id]:
            if dependency == task_id:
                issues.append({"type": "self_dependency", "task_id": task_id, "dependency_id": dependency})
            elif dependency not in valid_ids:
                issues.append({"type": "missing_dependency", "task_id": task_id, "dependency_id": dependency})
    issues.extend({"type": "circular_dependency", "cycle": cycle} for cycle in find_cycles(graph))
    output.success({"tag": tag, "valid": not issues, "issues": issues, "total_tasks": len(tasks)})


def fix(project_root: str, tag: str, tasks: list[dict]) -> None:
    valid_ids = {task["id"] for task in tasks}
    fixed: list[dict] = []
    for task in tasks:
        task_id = task["id"]
        original = list(task.get("dependencies", []))
        dependencies: list[int] = []
        for dependency in original:
            if dependency in valid_ids and dependency != task_id and dependency not in dependencies:
                dependencies.append(dependency)
        if dependencies != original:
            meta_file = paths.get_task_meta_file(project_root, tag, task_id)
            frontmatter.update_metadata(
                str(meta_file), {"dependencies": dependencies}, frontmatter.TASK_META_FIELDS
            )
            fixed.append({"task_id": task_id, "old": original, "new": dependencies})
    output.success({"tag": tag, "fixed_count": len(fixed), "fixed": fixed})


def graph(tasks: list[dict], tag: str) -> None:
    lines = ["graph TD"]
    for task in tasks:
        task_id = task["id"]
        name = str(task.get("name", ""))[:30].replace('"', "'")
        style = "done" if task["status"] == "done" else "inprogress" if task["status"] == "in-progress" else "pending"
        lines.append(f'    {task_id}["{task_id}. {name}"]:::{style}')
        for dependency in task.get("dependencies", []):
            lines.append(f"    {dependency} --> {task_id}")
    lines.extend(
        [
            "",
            "    classDef done fill:#90EE90",
            "    classDef pending fill:#FFE4B5",
            "    classDef inprogress fill:#87CEEB",
        ]
    )
    output.success({"tag": tag, "format": "mermaid", "graph": "\n".join(lines)})


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze TaskAdmin dependencies")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--tag", help="Tag for validate/graph only (default: current tag)")
    parser.add_argument("--action", required=True, choices=["validate", "fix", "graph"])
    args = parser.parse_args()

    if args.action == "fix" and args.tag is not None:
        parser.error("--tag is not allowed with --action fix; switch the current tag first")
    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    try:
        tag = (
            paths.require_current_tag(args.project_root)
            if args.action == "fix"
            else paths.resolve_tag(args.project_root, args.tag)
        )
    except ValueError as exc:
        output.error(str(exc))
    if not paths.get_tasks_dir(args.project_root, tag).is_dir():
        output.error(f"Tag '{tag}' does not exist")
    tasks = scanner.scan_tasks(args.project_root, tag)
    if args.action == "validate":
        validate(tasks, tag)
    if args.action == "fix":
        fix(args.project_root, tag, tasks)
    graph(tasks, tag)


if __name__ == "__main__":
    main()
