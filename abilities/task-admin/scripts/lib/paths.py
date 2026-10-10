"""Path utilities for the single-level TaskAdmin workspace."""

import re
from pathlib import Path
from typing import Optional

from .frontmatter import parse_yaml, read_yaml_file
from .task_ids import parse_task_id as parse_integer_task_id


MAXA_DIR = ".maxa"
TASKS_DIR = "tasks"
STATE_FILE = "state.yaml"
META_FILE = "_meta.yaml"
PLAN_FILE = "plan.md"
TODO_FILE = "todo.md"
DEFAULT_TAG = "master"
TASK_DIR_RE = re.compile(r"^task_(\d+)$")
TAG_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def get_maxa_root(project_root: str) -> Path:
    return Path(project_root) / MAXA_DIR


def get_tasks_root(project_root: str) -> Path:
    return get_maxa_root(project_root) / TASKS_DIR


def get_tasks_dir(project_root: str, tag: str) -> Path:
    return get_tasks_root(project_root) / tag


def get_state_file(project_root: str) -> Path:
    return get_tasks_root(project_root) / STATE_FILE


def get_tag_meta_file(project_root: str, tag: str) -> Path:
    return get_tasks_dir(project_root, tag) / META_FILE


def get_task_dir(project_root: str, tag: str, task_id: int) -> Path:
    return get_tasks_dir(project_root, tag) / f"task_{int(task_id):03d}"


def get_task_meta_file(project_root: str, tag: str, task_id: int) -> Path:
    return get_task_dir(project_root, tag, task_id) / META_FILE


def get_task_plan_file(project_root: str, tag: str, task_id: int) -> Path:
    return get_task_dir(project_root, tag, task_id) / PLAN_FILE


def get_task_todo_file(project_root: str, tag: str, task_id: int) -> Path:
    return get_task_dir(project_root, tag, task_id) / TODO_FILE


def read_current_tag(project_root: str) -> str:
    state_file = get_state_file(project_root)
    if state_file.exists():
        try:
            state = parse_yaml(state_file.read_text(encoding="utf-8"))
            value = state.get("currentTag")
            if isinstance(value, str) and value.strip():
                return validate_tag(value.strip())
        except (OSError, ValueError):
            pass
    return DEFAULT_TAG


def require_current_tag(project_root: str, *, allow_empty_store: bool = False) -> str:
    """Resolve ordinary write scope without falling back from invalid state."""
    try:
        tasks_root = get_tasks_root(project_root)
        if allow_empty_store and (
            not tasks_root.exists() or (tasks_root.is_dir() and not any(tasks_root.iterdir()))
        ):
            return DEFAULT_TAG
        state = read_yaml_file(str(get_state_file(project_root)))
        value = state.get("currentTag")
        if not isinstance(value, str) or not value.strip():
            raise ValueError("currentTag must be a nonempty tag name")
        tag = validate_tag(value.strip())
        if not get_tasks_dir(project_root, tag).is_dir() or not get_tag_meta_file(project_root, tag).is_file():
            raise ValueError(f"Current tag '{tag}' has no complete tag metadata")
        return tag
    except (OSError, ValueError) as exc:
        raise ValueError(
            f"Invalid current tag state: {exc}. "
            "Use manage_tag.py --action switch --name <TAG> to select an existing tag."
        ) from exc


def validate_tag(tag: str) -> str:
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise ValueError(f"Invalid tag name: {tag}; expected letters, digits, '-' or '_'")
    return tag


def resolve_tag(project_root: str, tag: Optional[str]) -> str:
    return validate_tag(tag) if tag else read_current_tag(project_root)


def parse_task_id(task_id: str) -> int:
    return parse_integer_task_id(task_id)


def format_task_id(task_id: int) -> str:
    return str(int(task_id))


def parse_task_dir_name(name: str) -> Optional[int]:
    match = TASK_DIR_RE.fullmatch(name)
    if not match:
        return None
    value = int(match.group(1))
    if value <= 0 or name != f"task_{value:03d}":
        return None
    return value


def parse_task_path(filepath: str) -> Optional[dict]:
    """Parse task context from a task directory or one of its core files."""
    path = Path(filepath)
    task_dir = path if path.is_dir() else path.parent
    task_id = parse_task_dir_name(task_dir.name)
    if task_id is None or task_dir.parent.parent.name != TASKS_DIR:
        return None

    kind = "task_dir"
    if path.name == META_FILE:
        kind = "meta"
    elif path.name == PLAN_FILE:
        kind = "plan"
    elif path.name == TODO_FILE:
        kind = "todo"
    elif path != task_dir:
        kind = "supporting"

    return {
        "id": task_id,
        "tag": task_dir.parent.name,
        "kind": kind,
        "task_dir": str(task_dir),
    }
