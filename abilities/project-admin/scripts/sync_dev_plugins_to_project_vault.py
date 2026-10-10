#!/usr/bin/env python3
"""Publish self-maintained Obsidian plugin artifacts to a project Vault.

Development source:
  <project-root>/obsidian-plugins/<plugin-id>/

Runtime publish target:
  <project-root>/.maxa/.obsidian/plugins/<plugin-id>/

Plugin target directories are real directories, not symlinks, so Syncthing can
propagate runtime plugin files to other devices and project Vaults.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

DEFAULT_PLUGINS = [
    "disable-unresolved-link",
    "grab-note",
    "semantic-graph-labels",
    "sync-conflict-resolver",
    "todoseq-card-board",
]
PLUGIN_DATA_FILE = "data.json"
DEFAULT_PLUGIN_DEV_EXCLUDES = {
    "node_modules",
    "src",
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lockb",
    "tsconfig.json",
    "esbuild.config.mjs",
    ".gitignore",
}


def default_project_root() -> Path:
    return Path.cwd()


class PublishError(RuntimeError):
    pass


def plugin_excludes(include_data: bool) -> list[str]:
    excludes = set(DEFAULT_PLUGIN_DEV_EXCLUDES)
    if not include_data:
        excludes.add(PLUGIN_DATA_FILE)
    return sorted(excludes)


def plugin_ignore(include_data: bool):
    excludes = set(plugin_excludes(include_data))

    def ignore(_dir: str, names: list[str]) -> set[str]:
        return {name for name in names if name in excludes}

    return ignore


def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def validate_source(plugin_id: str, src: Path) -> list[str]:
    errors: list[str] = []
    if not src.is_dir():
        errors.append(f"source plugin directory missing: {src}")
        return errors
    manifest = src / "manifest.json"
    main_js = src / "main.js"
    if not manifest.is_file():
        errors.append(f"manifest.json missing: {manifest}")
    if not main_js.is_file():
        errors.append(f"main.js missing: {main_js}")
    if manifest.is_file():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            manifest_id = data.get("id")
            if manifest_id != plugin_id:
                errors.append(f"manifest id mismatch for {plugin_id}: {manifest_id!r}")
        except Exception as exc:  # noqa: BLE001 - CLI validation should report parse failures
            errors.append(f"manifest.json invalid for {plugin_id}: {exc}")
    return errors


def publish_one(
    plugin_id: str,
    src_root: Path,
    dst_root: Path,
    apply: bool,
    include_data: bool,
) -> dict[str, Any]:
    src = src_root / plugin_id
    dst = dst_root / plugin_id
    errors = validate_source(plugin_id, src)
    action: dict[str, Any] = {
        "plugin": plugin_id,
        "src": str(src),
        "dst": str(dst),
        "dst_was_symlink": dst.is_symlink(),
        "exclude": plugin_excludes(include_data),
        "apply": apply,
        "errors": errors,
    }
    if errors:
        action["status"] = "error"
        return action

    action["status"] = "would_copy" if not apply else "copied"
    if not apply:
        return action

    preserved_data = None
    if not include_data and (dst / PLUGIN_DATA_FILE).is_file():
        preserved_data = (dst / PLUGIN_DATA_FILE).read_bytes()
        action["data_preserved"] = True
    else:
        action["data_preserved"] = False

    remove_path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst, ignore=plugin_ignore(include_data), symlinks=False)
    if preserved_data is not None:
        (dst / PLUGIN_DATA_FILE).write_bytes(preserved_data)
    action["dst_is_symlink_after"] = dst.is_symlink()
    action["manifest_exists_after"] = (dst / "manifest.json").is_file()
    action["main_exists_after"] = (dst / "main.js").is_file()
    return action


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Publish self-maintained Obsidian plugins from a project "
            "obsidian-plugins/ directory into that project's .maxa/.obsidian/plugins/."
        )
    )
    parser.add_argument("--project-root", default=str(default_project_root()), help="Project root containing obsidian-plugins/ and .maxa/ (default: cwd)")
    parser.add_argument("--plugin", action="append", help="Plugin id to publish. Can be repeated. Default: known self-maintained plugins")
    parser.add_argument("--apply", action="store_true", help="Actually replace project Vault plugin directories. Without this, dry-run only")
    parser.add_argument("--include-data", action="store_true", help="Also copy plugin data.json files. Default: excluded")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_root = Path(args.project_root).expanduser().resolve()
    src_root = project_root / "obsidian-plugins"
    target_vault = project_root / ".maxa"
    target_obsidian = target_vault / ".obsidian"
    dst_root = target_obsidian / "plugins"
    plugins = args.plugin or DEFAULT_PLUGINS

    result: dict[str, Any] = {
        "project_root": str(project_root),
        "target_vault": str(target_vault),
        "target_obsidian": str(target_obsidian),
        "src_root": str(src_root),
        "dst_root": str(dst_root),
        "apply": bool(args.apply),
        "include_data": bool(args.include_data),
        "plugins": [],
    }

    if not src_root.is_dir():
        result["error"] = f"source root missing: {src_root}"
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(result["error"])
        return 1

    if not target_vault.is_dir():
        result["error"] = f"project Vault missing: {target_vault}"
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(result["error"])
        return 1

    if args.apply:
        dst_root.mkdir(parents=True, exist_ok=True)

    had_error = False
    for plugin_id in plugins:
        action = publish_one(plugin_id, src_root, dst_root, args.apply, args.include_data)
        if action.get("status") == "error":
            had_error = True
        result["plugins"].append(action)

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        mode = "APPLY" if args.apply else "DRY-RUN"
        print(f"{mode}: {src_root} -> {dst_root}")
        for action in result["plugins"]:
            status = action["status"]
            marker = "ERROR" if status == "error" else status
            print(f"- {action['plugin']}: {marker}")
            for error in action.get("errors", []):
                print(f"  ! {error}")
            if action.get("dst_was_symlink"):
                print("  note: destination was a symlink and will be replaced with a real directory" if not args.apply else "  note: replaced symlink with real directory")

    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
