#!/usr/bin/env python3
"""Manage TaskAdmin tags and current-tag state."""

import argparse
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import frontmatter, output, paths, scanner


ACTIONS = ["create", "list", "delete", "rename", "copy", "switch", "set-workspace", "clear-workspace"]


def _validate_name(name: str) -> None:
    try:
        paths.validate_tag(name)
    except ValueError as exc:
        output.error(str(exc))


def _tag_meta(description: str = "", workspace: str | None = None) -> dict:
    now = frontmatter.now_timestamp()
    meta = {"description": description, "created": now, "updated": now, "version": "1"}
    if workspace:
        meta["workspace"] = workspace
    return meta


def _write_state(project_root: str, name: str) -> None:
    frontmatter.write_yaml_file(
        str(paths.get_state_file(project_root)),
        {"currentTag": name, "lastSwitched": frontmatter.now_timestamp()},
        frontmatter.STATE_FIELDS,
    )


def _ensure_master(project_root: str) -> None:
    master = paths.get_tasks_dir(project_root, paths.DEFAULT_TAG)
    if not master.exists():
        master.mkdir(parents=True)
        frontmatter.write_yaml_file(
            str(paths.get_tag_meta_file(project_root, paths.DEFAULT_TAG)),
            _tag_meta(),
            frontmatter.TAG_META_FIELDS,
        )


def create_tag(project_root: str, name: str, description: str, copy_from: str | None = None, workspace: str | None = None) -> None:
    _validate_name(name)
    tag_dir = paths.get_tasks_dir(project_root, name)
    if tag_dir.exists():
        output.error(f"Tag '{name}' already exists")
    source_dir: Path | None = None
    if copy_from:
        source_dir = paths.get_tasks_dir(project_root, copy_from)
        if not source_dir.is_dir():
            output.error(f"Source tag '{copy_from}' does not exist")

    tag_dir.mkdir(parents=True)
    try:
        frontmatter.write_yaml_file(
            str(paths.get_tag_meta_file(project_root, name)),
            _tag_meta(description, workspace),
            frontmatter.TAG_META_FIELDS,
        )
        if source_dir:
            for entry in source_dir.iterdir():
                if paths.parse_task_dir_name(entry.name) is not None and entry.is_dir():
                    shutil.copytree(entry, tag_dir / entry.name)
        if not paths.get_state_file(project_root).exists():
            _write_state(project_root, name)
    except Exception as exc:
        shutil.rmtree(tag_dir, ignore_errors=True)
        output.error(f"Failed to create tag '{name}': {exc}")

    output.success(
        {
            "name": name,
            "description": description,
            "copied_from": copy_from,
            "workspace": workspace,
            "path": str(tag_dir),
        }
    )


def list_tags(project_root: str) -> None:
    tags = scanner.list_tags(project_root)
    output.success({"current_tag": paths.read_current_tag(project_root), "tags": tags, "total": len(tags)})


def set_tag_workspace(project_root: str, name: str, workspace: str | None) -> None:
    meta_file = paths.get_tag_meta_file(project_root, name)
    if not meta_file.is_file():
        output.error(f"Tag '{name}' does not exist")
    try:
        frontmatter.update_metadata(
            str(meta_file), {"workspace": workspace}, frontmatter.TAG_META_FIELDS
        )
    except (OSError, ValueError) as exc:
        output.error(f"Invalid tag metadata: {meta_file}: {exc}")
    output.success({"name": name, "workspace": workspace, "path": str(meta_file)})


def delete_tag(project_root: str, name: str) -> None:
    if name == paths.DEFAULT_TAG:
        output.error("Cannot delete the 'master' tag")
    tag_dir = paths.get_tasks_dir(project_root, name)
    if not tag_dir.is_dir():
        output.error(f"Tag '{name}' does not exist")
    current = paths.read_current_tag(project_root)
    if current == name:
        _ensure_master(project_root)
        _write_state(project_root, paths.DEFAULT_TAG)
    shutil.rmtree(tag_dir)
    output.success({"deleted": name, "switched_to": paths.DEFAULT_TAG if current == name else None})


def rename_tag(project_root: str, old_name: str, new_name: str) -> None:
    if old_name == paths.DEFAULT_TAG:
        output.error("Cannot rename the 'master' tag")
    _validate_name(new_name)
    old_dir = paths.get_tasks_dir(project_root, old_name)
    new_dir = paths.get_tasks_dir(project_root, new_name)
    if not old_dir.is_dir():
        output.error(f"Tag '{old_name}' does not exist")
    if new_dir.exists():
        output.error(f"Tag '{new_name}' already exists")
    old_dir.rename(new_dir)
    if paths.read_current_tag(project_root) == old_name:
        _write_state(project_root, new_name)
    output.success({"old_name": old_name, "new_name": new_name})


def switch_tag(project_root: str, name: str) -> None:
    if not paths.get_tasks_dir(project_root, name).is_dir():
        output.error(f"Tag '{name}' does not exist")
    _write_state(project_root, name)
    output.success({"current_tag": name})


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage TaskAdmin tags")
    parser.add_argument("--project-root", required=True, help="Project root directory")
    parser.add_argument("--action", required=True, choices=ACTIONS)
    parser.add_argument("--name", help="Tag name")
    parser.add_argument("--new-name", help="New tag name for rename")
    parser.add_argument("--copy-from", help="Source tag for create/copy")
    parser.add_argument("--description", default="", help="Tag description")
    parser.add_argument("--workspace", help="Tag workspace binding")
    args = parser.parse_args()

    if not os.path.isdir(args.project_root):
        output.error(f"Project root does not exist: {args.project_root}")
    if args.action == "list":
        list_tags(args.project_root)
    if args.action == "create":
        if not args.name:
            output.error("--name is required for create")
        create_tag(args.project_root, args.name, args.description, args.copy_from, args.workspace)
    if args.action == "copy":
        if not args.name or not args.copy_from:
            output.error("--name and --copy-from are required for copy")
        create_tag(args.project_root, args.name, f"Copied from {args.copy_from}", args.copy_from)
    if args.action == "delete":
        if not args.name:
            output.error("--name is required for delete")
        delete_tag(args.project_root, args.name)
    if args.action == "rename":
        if not args.name or not args.new_name:
            output.error("--name and --new-name are required for rename")
        rename_tag(args.project_root, args.name, args.new_name)
    if args.action == "switch":
        if not args.name:
            output.error("--name is required for switch")
        switch_tag(args.project_root, args.name)
    if args.action == "set-workspace":
        if not args.name or not args.workspace:
            output.error("--name and --workspace are required for set-workspace")
        set_tag_workspace(args.project_root, args.name, args.workspace)
    if args.action == "clear-workspace":
        if not args.name:
            output.error("--name is required for clear-workspace")
        set_tag_workspace(args.project_root, args.name, None)


if __name__ == "__main__":
    main()
