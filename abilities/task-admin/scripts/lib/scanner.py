"""Directory scanning utilities for single-level TaskAdmin workspaces."""

from pathlib import Path
from typing import Any, Dict, List, Optional

from . import frontmatter, paths, task_ids


def _task_paths(project_root: str, tag: str, task_id: int) -> dict[str, str]:
    task_dir = paths.get_task_dir(project_root, tag, task_id)
    return {
        "task_dir": str(task_dir),
        "meta_file": str(task_dir / paths.META_FILE),
        "plan_file": str(task_dir / paths.PLAN_FILE),
        "todo_file": str(task_dir / paths.TODO_FILE),
    }


def parse_task_dir(task_dir: Path, project_root: str, tag: str) -> Optional[Dict[str, Any]]:
    task_id = paths.parse_task_dir_name(task_dir.name)
    if task_id is None or not task_dir.is_dir():
        return None
    meta_file = task_dir / paths.META_FILE
    plan_file = task_dir / paths.PLAN_FILE
    todo_file = task_dir / paths.TODO_FILE
    if not meta_file.is_file() or not plan_file.is_file() or not todo_file.is_file():
        return None
    try:
        meta = frontmatter.read_yaml_file(str(meta_file))
        dependencies = task_ids.normalize_deps(list(meta.get("dependencies", [])))
    except (OSError, ValueError, TypeError):
        return None
    info: Dict[str, Any] = {
        "id": task_id,
        "name": str(meta.get("name", "")),
        "description": str(meta.get("description", "")),
        "status": str(meta.get("status", "pending")),
        "priority": str(meta.get("priority", "medium")),
        "dependencies": dependencies,
        "created": meta.get("created", ""),
        "updated": meta.get("updated", ""),
        "workspace": meta.get("workspace"),
    }
    info.update(_task_paths(project_root, tag, task_id))
    return info


def scan_tasks(project_root: str, tag: str) -> List[Dict[str, Any]]:
    tag_dir = paths.get_tasks_dir(project_root, tag)
    if not tag_dir.exists():
        return []
    tasks: list[Dict[str, Any]] = []
    for entry in tag_dir.iterdir():
        task_id = paths.parse_task_dir_name(entry.name)
        if task_id is None:
            continue
        info = parse_task_dir(entry, project_root, tag)
        if info is not None:
            tasks.append(info)
    tasks.sort(key=lambda task: task["id"])
    return tasks


def get_next_task_id(project_root: str, tag: str) -> int:
    tag_dir = paths.get_tasks_dir(project_root, tag)
    if not tag_dir.exists():
        return 1
    ids = [
        task_id
        for entry in tag_dir.iterdir()
        if (task_id := paths.parse_task_dir_name(entry.name)) is not None
    ]
    return max(ids, default=0) + 1


def get_task(project_root: str, tag: str, task_id: int) -> Optional[Dict[str, Any]]:
    task_dir = paths.get_task_dir(project_root, tag, task_id)
    info = parse_task_dir(task_dir, project_root, tag)
    if info is None:
        return None
    info["plan"] = (task_dir / paths.PLAN_FILE).read_text(encoding="utf-8")
    info["todo"] = (task_dir / paths.TODO_FILE).read_text(encoding="utf-8")
    return info


def list_tags(project_root: str) -> List[Dict[str, Any]]:
    tasks_root = paths.get_tasks_root(project_root)
    if not tasks_root.exists():
        return []
    current_tag = paths.read_current_tag(project_root)
    tags: list[Dict[str, Any]] = []
    for tag_dir in sorted(tasks_root.iterdir(), key=lambda value: value.name):
        if not tag_dir.is_dir() or tag_dir.name.startswith("."):
            continue
        meta: dict[str, Any] = {}
        meta_file = tag_dir / paths.META_FILE
        if meta_file.is_file():
            try:
                meta = frontmatter.read_yaml_file(str(meta_file))
            except (OSError, ValueError):
                meta = {}
        task_count = sum(
            1
            for entry in tag_dir.iterdir()
            if paths.parse_task_dir_name(entry.name) is not None and entry.is_dir()
        )
        tags.append(
            {
                "name": tag_dir.name,
                "description": meta.get("description", ""),
                "task_count": task_count,
                "created": meta.get("created", ""),
                "updated": meta.get("updated", ""),
                "version": meta.get("version"),
                "workspace": meta.get("workspace"),
                "is_current": tag_dir.name == current_tag,
            }
        )
    return tags
