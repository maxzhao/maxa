#!/usr/bin/env python3
"""Sync Obsidian plugin setup from one project Vault to other project Vaults.

Authority source: <source-project>/.maxa/.obsidian/
Discovery source: Syncthing folder registry, using project-admin's smx-knowledge-*
folder-id convention.

This script copies only managed .obsidian runtime assets. It does not copy
Markdown knowledge notes or other project Vault body content.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

PROJECT_FOLDER_PREFIX = "smx-knowledge-"

DEFAULT_MANAGED_FILES = [
    "community-plugins.json",
    "core-plugins.json",
    "appearance.json",
    "templates.json",
]
DEFAULT_MANAGED_DIRS = [
    "plugins",
    "snippets",
    "themes",
]
DEVICE_LOCAL_PATTERNS = [
    "workspace.json",
    "workspace-mobile.json",
    "workspace*.json",
    "hotkeys.json",
    "graph.json",
    "cache/**",
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
DEFAULT_ALLOWLIST = Path(__file__).with_name("obsidian_plugin_sync_allowlist.json")

# These lines were historically written by project-admin default .stignore.
# Plugin sync owns these paths, so they must not remain ignored by Syncthing.
MANAGED_STIGNORE_LINES = {
    ".obsidian/snippets/",
    ".obsidian/themes/",
    ".obsidian/appearance.json",
    ".obsidian/templates.json",
}


class PluginSyncError(RuntimeError):
    pass


def run_text(args: list[str]) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise PluginSyncError(
            (result.stderr or result.stdout or f"Command failed: {args}").strip()
        )
    return result.stdout.strip()


def command_exists(name: str) -> bool:
    return (
        subprocess.run(
            ["bash", "-lc", f"command -v {name} >/dev/null 2>&1"], check=False
        ).returncode
        == 0
    )


def list_syncthing_folders() -> list[str]:
    out = run_text(["syncthing", "cli", "config", "folders", "list"])
    return [line.strip() for line in out.splitlines() if line.strip()]


def folder_dump(folder_id: str) -> dict[str, Any]:
    return json.loads(
        run_text(["syncthing", "cli", "config", "folders", folder_id, "dump-json"])
    )


def is_windows_path(path: str) -> bool:
    return len(path) >= 3 and path[1] == ":" and path[2] in {"\\", "/"}


def to_local_path(raw_path: str) -> Path:
    path = os.path.expandvars(os.path.expanduser(raw_path))
    if is_windows_path(path):
        if command_exists("wslpath"):
            converted = run_text(["wslpath", "-u", path])
            return Path(converted).resolve()
        drive = path[0].lower()
        rest = path[2:].replace("\\", "/").lstrip("/")
        return Path(f"/mnt/{drive}/{rest}").resolve()
    return Path(path).resolve()


def load_allowlist(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"sync_plugin_data": [], "sync_extra_files": []}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        "sync_plugin_data": list(data.get("sync_plugin_data", [])),
        "sync_extra_files": list(data.get("sync_extra_files", [])),
    }


def resolve_source_vault(args: argparse.Namespace) -> Path:
    if args.source_vault:
        vault = to_local_path(args.source_vault)
    else:
        project_root = to_local_path(args.source_project_root)
        vault = project_root / ".maxa"
    if not vault.is_dir():
        raise PluginSyncError(f"Source project Vault not found: {vault}")
    obsidian = vault / ".obsidian"
    if not obsidian.is_dir():
        raise PluginSyncError(f"Source .obsidian directory not found: {obsidian}")
    return vault.resolve()


def discover_project_vaults(
    target_folder_ids: list[str] | None = None,
    source_vault: Path | None = None,
) -> list[dict[str, Any]]:
    if not command_exists("syncthing"):
        raise PluginSyncError("syncthing CLI not found in PATH")
    folder_ids = target_folder_ids or list_syncthing_folders()
    vaults: list[dict[str, Any]] = []
    source_resolved = source_vault.resolve() if source_vault else None
    for folder_id in folder_ids:
        if not folder_id.startswith(PROJECT_FOLDER_PREFIX):
            continue
        data = folder_dump(folder_id)
        raw_path = data.get("path")
        if not raw_path:
            continue
        path = to_local_path(str(raw_path))
        if path.name == "knowledge" and path.parent.name == ".maxa":
            path = path.parent
        meta_path = path / "_meta.yaml"
        obsidian_dir = path / ".obsidian"
        looks_like_project_vault = path.name == ".maxa" or meta_path.exists() or obsidian_dir.exists()
        is_source = source_resolved is not None and path.resolve() == source_resolved
        vaults.append(
            {
                "folder_id": folder_id,
                "label": data.get("label", ""),
                "raw_path": raw_path,
                "path": str(path),
                "exists": path.exists(),
                "meta_exists": meta_path.exists(),
                "obsidian_dir": str(obsidian_dir),
                "is_source": is_source,
                "eligible": path.exists() and looks_like_project_vault and not is_source,
            }
        )
    return vaults


def plugin_excludes(plugin_id: str, allow_data_plugins: set[str]) -> list[str]:
    excludes = set(DEFAULT_PLUGIN_DEV_EXCLUDES)
    if plugin_id not in allow_data_plugins:
        excludes.add(PLUGIN_DATA_FILE)
    return sorted(excludes)


def plugin_ignore(src_plugin_dir: Path, allow_data_plugins: set[str]):
    excludes = set(plugin_excludes(src_plugin_dir.name, allow_data_plugins))

    def ignore(_dir: str, names: list[str]) -> set[str]:
        return {name for name in names if name in excludes}

    return ignore


def copy_file_or_remove(
    src: Path, dst: Path, apply: bool, actions: list[dict[str, str]]
) -> None:
    rel = str(dst)
    if src.exists():
        actions.append({"action": "copy_file", "src": str(src), "dst": rel})
        if apply:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    elif dst.exists():
        actions.append({"action": "remove_missing_file", "dst": rel})
        if apply:
            dst.unlink()


def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def sync_plugins_dir(
    src: Path,
    dst: Path,
    allow_data_plugins: set[str],
    apply: bool,
    actions: list[dict[str, str]],
) -> None:
    actions.append(
        {
            "action": "replace_dir",
            "src": str(src),
            "dst": str(dst),
            "exclude": "runtime files only; data.json except allowlist",
        }
    )
    if not apply:
        return
    preserved_data: dict[str, bytes] = {}
    if dst.exists():
        for plugin_path in sorted([p for p in dst.iterdir() if p.is_dir()]):
            if plugin_path.name in allow_data_plugins:
                continue
            data_file = plugin_path / PLUGIN_DATA_FILE
            if data_file.is_file():
                preserved_data[plugin_path.name] = data_file.read_bytes()
    remove_path(dst)
    if not src.exists():
        return
    dst.mkdir(parents=True, exist_ok=True)
    for plugin_dir in sorted([p for p in src.iterdir() if p.is_dir()]):
        target = dst / plugin_dir.name
        shutil.copytree(
            plugin_dir,
            target,
            ignore=plugin_ignore(plugin_dir, allow_data_plugins),
        )
        if plugin_dir.name in preserved_data:
            (target / PLUGIN_DATA_FILE).write_bytes(preserved_data[plugin_dir.name])


def sync_plain_dir(
    src: Path, dst: Path, apply: bool, actions: list[dict[str, str]]
) -> None:
    actions.append({"action": "replace_dir", "src": str(src), "dst": str(dst)})
    if not apply:
        return
    remove_path(dst)
    if src.exists():
        shutil.copytree(src, dst)


def update_stignore(
    vault_path: Path, apply: bool, actions: list[dict[str, str]]
) -> None:
    stignore = vault_path / ".stignore"
    if not stignore.exists():
        return
    lines = stignore.read_text(encoding="utf-8").splitlines()
    kept = [line for line in lines if line.strip() not in MANAGED_STIGNORE_LINES]
    removed = [line.strip() for line in lines if line.strip() in MANAGED_STIGNORE_LINES]
    if not removed:
        return
    actions.append(
        {
            "action": "update_stignore",
            "path": str(stignore),
            "removed": ",".join(removed),
        }
    )
    if apply:
        stignore.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")


def sync_one(
    source_obsidian: Path, vault: dict[str, Any], allowlist: dict[str, Any], apply: bool
) -> dict[str, Any]:
    vault_path = Path(vault["path"])
    target_obsidian = vault_path / ".obsidian"
    actions: list[dict[str, str]] = []
    allow_data_plugins = set(allowlist.get("sync_plugin_data", []))

    if vault.get("is_source"):
        return {
            **vault,
            "skipped": True,
            "reason": "source project Vault is excluded from targets",
            "actions": [],
        }

    if not vault.get("eligible"):
        return {
            **vault,
            "skipped": True,
            "reason": "folder is not an accessible project knowledge Vault",
            "actions": [],
        }

    for rel in DEFAULT_MANAGED_FILES:
        copy_file_or_remove(
            source_obsidian / rel, target_obsidian / rel, apply, actions
        )

    for rel in DEFAULT_MANAGED_DIRS:
        if rel == "plugins":
            sync_plugins_dir(
                source_obsidian / rel,
                target_obsidian / rel,
                allow_data_plugins,
                apply,
                actions,
            )
        else:
            sync_plain_dir(source_obsidian / rel, target_obsidian / rel, apply, actions)

    for rel in allowlist.get("sync_extra_files", []):
        # Extra files are explicit and may include plugin data or safe plugin config files.
        for src in source_obsidian.glob(rel):
            if src.is_file():
                copy_file_or_remove(
                    src,
                    target_obsidian / src.relative_to(source_obsidian),
                    apply,
                    actions,
                )

    update_stignore(vault_path, apply, actions)
    return {**vault, "skipped": False, "actions": actions}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sync Obsidian plugin setup from one project Vault to other project Vaults"
    )
    parser.add_argument(
        "--source-project-root",
        default=str(Path.cwd()),
        help="Project root whose .maxa/.obsidian/ is the source (default: cwd)",
    )
    parser.add_argument(
        "--source-vault",
        default=None,
        help="Explicit source project Vault path. Overrides --source-project-root",
    )
    parser.add_argument(
        "--allowlist", default=str(DEFAULT_ALLOWLIST), help="JSON allowlist path"
    )
    parser.add_argument(
        "--folder-id",
        action="append",
        help="Limit to specific target Syncthing folder id; repeatable",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply changes. Without this flag the script is dry-run only",
    )
    parser.add_argument(
        "--json", action="store_true", help="Print machine-readable JSON output"
    )
    args = parser.parse_args()

    try:
        source_vault = resolve_source_vault(args)
        source_obsidian = source_vault / ".obsidian"
        allowlist = load_allowlist(Path(args.allowlist).expanduser())
        vaults = discover_project_vaults(args.folder_id, source_vault=source_vault)
        results = [
            sync_one(source_obsidian, vault, allowlist, args.apply) for vault in vaults
        ]
        payload = {
            "mode": "apply" if args.apply else "dry-run",
            "source_vault": str(source_vault),
            "source_obsidian": str(source_obsidian),
            "allowlist": str(Path(args.allowlist).expanduser()),
            "target_count": len(results),
            "targets": results,
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print(f"Mode: {payload['mode']}")
            print(f"Source: {source_obsidian}")
            print(f"Targets: {len(results)}")
            for result in results:
                status = "SKIP" if result.get("skipped") else "OK"
                print(f"- {status} {result['folder_id']} -> {result['path']}")
                if result.get("reason"):
                    print(f"  reason: {result['reason']}")
                for action in result.get("actions", []):
                    dst = action.get("dst") or action.get("path") or ""
                    print(f"  - {action['action']}: {dst}")
        return 0
    except PluginSyncError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
