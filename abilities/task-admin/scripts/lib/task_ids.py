"""TaskAdmin integer task-ID and dependency helpers."""

from typing import Any


def parse_task_id(value: Any) -> int:
    """Parse a positive decimal task ID.

    Dotted IDs are intentionally invalid: TaskAdmin has one task level.
    """
    if isinstance(value, bool):
        raise ValueError(f"Invalid task ID format: {value}")
    text = str(value).strip()
    if not text.isdigit() or int(text) <= 0:
        raise ValueError(f"Invalid task ID format: {value}; expected a positive integer")
    return int(text)


def normalize_dep(value: Any) -> int:
    """Normalize one dependency to an integer task ID."""
    return parse_task_id(value)


def normalize_deps(values: list[Any]) -> list[int]:
    """Normalize dependencies while preserving order."""
    return [normalize_dep(value) for value in values]


def dep_key(value: Any) -> int:
    """Return the canonical comparison key for a task/dependency ID."""
    return parse_task_id(value)


def parse_dep_value(value: str) -> int:
    """Parse one CLI dependency value."""
    return parse_task_id(value)
