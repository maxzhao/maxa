#!/usr/bin/env python3
"""Resolve one integer TaskAdmin ID to its task workspace paths."""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib import paths


def main() -> None:
    parser = argparse.ArgumentParser(description="Resolve an integer task ID to workspace paths")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--id", required=True, help="Positive integer task ID, e.g. 3")
    parser.add_argument("--tag", default=None, help="Tag (default: from state.yaml)")
    args = parser.parse_args()

    try:
        task_id = paths.parse_task_id(args.id)
    except ValueError as exc:
        print(json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False, indent=2))
        raise SystemExit(1) from exc

    try:
        tag = paths.resolve_tag(args.project_root, args.tag)
    except ValueError as exc:
        print(json.dumps({"success": False, "error": str(exc)}, ensure_ascii=False, indent=2))
        raise SystemExit(1) from exc
    task_dir = paths.get_task_dir(args.project_root, tag, task_id)
    meta_file = paths.get_task_meta_file(args.project_root, tag, task_id)
    plan_file = paths.get_task_plan_file(args.project_root, tag, task_id)
    todo_file = paths.get_task_todo_file(args.project_root, tag, task_id)
    exists = all(path.is_file() for path in (meta_file, plan_file, todo_file))

    print(
        json.dumps(
            {
                "success": True,
                "data": {
                    "tag": tag,
                    "id": task_id,
                    "task_dir": str(task_dir),
                    "meta_file": str(meta_file),
                    "plan_file": str(plan_file),
                    "todo_file": str(todo_file),
                    "exists": exists,
                },
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
