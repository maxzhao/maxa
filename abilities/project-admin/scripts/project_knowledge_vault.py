#!/usr/bin/env python3
"""Project knowledge vault Obsidian CLI safety wrapper."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
import yaml

from project_vault_ownership import (
    OwnershipError, require_external_owner, resolve_ownership, validate_vault_path,
)


class VaultError(RuntimeError):
    pass


def load_meta(project_root: Path) -> dict:
    meta_path = project_root / ".maxa/_meta.yaml"
    if not meta_path.exists():
        raise VaultError(f"Maxa vault meta not found: {meta_path}")
    data = yaml.safe_load(meta_path.read_text()) or {}
    if not isinstance(data, dict):
        raise VaultError("Maxa vault meta must be a mapping")
    name = data.get("name")
    if not isinstance(name, str) or not name:
        raise VaultError("Maxa vault meta must contain 'name'")
    if name in {".", ".."} or any(char in name for char in "/\\\x00"):
        raise VaultError("Vault name must be a single alias filename")
    vault_path = validate_vault_path(project_root)
    alias_root = Path.home() / ".local/share/maxa/project-vaults"
    alias_path = alias_root / name
    return {
        "name": name,
        "project_root": project_root.resolve(),
        "vault_path": vault_path.resolve(),
        "alias_root": alias_root,
        "alias_path": alias_path,
        "config_path": Path.home() / ".config/obsidian/obsidian.json",
    }


def check_alias(meta: dict) -> None:
    alias = meta["alias_path"]
    if alias.is_symlink():
        if not alias.exists() or alias.resolve() != meta["vault_path"]:
            raise VaultError(f"Project Vault alias conflict: {alias}")
    elif alias.exists():
        raise VaultError(f"Alias path exists and is not a symlink: {alias}")


def ensure_alias(meta: dict) -> None:
    require_external_owner(meta["project_root"])
    check_alias(meta)
    if not meta["vault_path"].is_dir():
        raise VaultError("Project Vault directory does not exist")
    if not meta["alias_path"].is_symlink():
        meta["alias_root"].mkdir(parents=True, exist_ok=True)
        meta["alias_path"].symlink_to(meta["vault_path"], target_is_directory=True)


def ensure_registered(meta: dict) -> dict:
    require_external_owner(meta["project_root"])
    check_alias(meta)
    config_path = meta["config_path"]
    original = config_path.read_text() if config_path.exists() else None
    data = json.loads(original) if original is not None else {"vaults": {}, "cli": True}
    if not isinstance(data, dict) or not isinstance(data.get("vaults", {}), dict):
        raise VaultError("Invalid Obsidian vault registration configuration")
    vaults = data.setdefault("vaults", {})
    matched = False
    for info in vaults.values():
        if not isinstance(info, dict) or not isinstance(info.get("path"), str):
            raise VaultError("Invalid Obsidian vault registration path")
        path = Path(info["path"])
        same_target = path.exists() and path.resolve() == meta["vault_path"]
        same_name = path.name == meta["name"]
        if (same_name or path == meta["alias_path"]) and not same_target:
            raise VaultError(f"Project Vault registration conflict: {path}")
        if same_target:
            matched = True
    # Validate all existing registrations before creating even the alias.
    ensure_alias(meta)
    if not matched:
        vaults[os.urandom(8).hex()] = {
            "path": str(meta["alias_path"]), "ts": int(time.time() * 1000), "open": False,
        }
    data["cli"] = True
    serialized = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if original is None or json.loads(original) != data:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(serialized)
    return {key: str(meta[key]) for key in ("name", "vault_path", "alias_path", "config_path")}


def obsidian_exists() -> bool:
    return subprocess.run(
        ["bash", "-lc", "command -v obsidian >/dev/null 2>&1"], check=False
    ).returncode == 0


def is_wsl() -> bool:
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except FileNotFoundError:
        return False


def local_gui_available() -> bool:
    if subprocess.run(
        ["systemctl", "--user", "is-active", "obsidian"],
        check=False,
        capture_output=True,
    ).returncode == 0:
        return True
    return subprocess.run(
        [
            "bash",
            "-lc",
            "pgrep -fa 'xvfb-run .*Obsidian.AppImage|Obsidian.AppImage --no-sandbox' >/dev/null 2>&1",
        ],
        check=False,
    ).returncode == 0


def obsidian_known_vaults() -> list[dict[str, str]]:
    if not obsidian_exists():
        return []
    try:
        result = subprocess.run(
            ["obsidian", "vaults", "verbose"], text=True, capture_output=True,
            check=False, env=obsidian_env(), timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    lines = ((result.stdout or "") + "\n" + (result.stderr or "")).splitlines()
    known = []
    for line in lines:
        line = line.strip()
        if not line or "\t" not in line:
            continue
        name, path = line.split("\t", 1)
        if name and path:
            known.append({"name": name, "path": path})
    return known


def obsidian_env() -> dict[str, str]:
    env = os.environ.copy()
    xauthority = Path(env.get("OBSIDIAN_XAUTHORITY", Path.home() / ".cache" / "obsidian" / "Xauthority")).expanduser()
    if "DISPLAY" not in env and xauthority.exists():
        env["DISPLAY"] = ":99"
        env.setdefault("XAUTHORITY", str(xauthority))
    return env


def targeted_command(meta: dict, args: list[str]) -> list[str]:
    return ["obsidian", f'vault={meta["name"]}', *args]


def verify_target(meta: dict) -> str:
    """Fail closed unless the live CLI resolves the expected physical Vault."""
    try:
        result = subprocess.run(
            targeted_command(meta, ["vault", "info=path"]),
            text=True, capture_output=True, check=False, env=obsidian_env(), timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise VaultError(f"Cannot verify project Vault: {exc}") from exc
    actual = (result.stdout or "").strip()
    if result.returncode != 0 or not actual or not Path(actual).is_absolute():
        raise VaultError(f"Project Vault could not be resolved: {actual or 'no path returned'}")
    if Path(actual).resolve() != meta["vault_path"].resolve():
        raise VaultError(
            f'Project Vault mismatch: expected {meta["vault_path"]}, got {actual}'
        )
    return actual


def run_obsidian(meta: dict, args: list[str]) -> int:
    if not args:
        raise VaultError("No Obsidian command provided")
    require_external_owner(meta["project_root"])
    if any(arg.startswith("vault=") for arg in args):
        raise VaultError("Vault overrides are not allowed; use --project-root")
    if not obsidian_exists():
        raise VaultError("obsidian CLI not found in PATH")
    check_alias(meta)
    verify_target(meta)

    command = targeted_command(meta, args)
    result = subprocess.run(command, text=True, capture_output=True, env=obsidian_env())

    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)

    output = (result.stdout or "") + (result.stderr or "")
    if "Vault not found" in output:
        raise VaultError(
            "Project Maxa vault cannot be resolved by the local Obsidian CLI. "
            "Ensure a local GUI/headless Obsidian instance is running and target the project vault explicitly."
        )

    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Project Vault: primary Git checkout or independent non-Git project only for external operations.",
        epilog="status is read-only; linked/unresolved projects never contact services. ensure is explicit setup; exec requires verified existing registration and never retargets conflicts.",
    )
    parser.add_argument("--project-root", required=True, help="Selected project root; never redirected to another checkout")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("name")
    sub.add_parser("path")
    sub.add_parser("alias-path")
    sub.add_parser("ensure")
    sub.add_parser("status")
    exec_parser = sub.add_parser("exec")
    exec_parser.add_argument("args", nargs=argparse.REMAINDER)

    ns = parser.parse_args()
    try:
        meta = load_meta(Path(ns.project_root).resolve())
        if ns.subcommand == "name":
            print(meta["name"])
            return 0
        if ns.subcommand == "path":
            print(meta["vault_path"])
            return 0
        if ns.subcommand == "alias-path":
            print(meta["alias_path"])
            return 0
        if ns.subcommand == "ensure":
            print(json.dumps(ensure_registered(meta), ensure_ascii=False, indent=2))
            return 0
        if ns.subcommand == "status":
            owner = resolve_ownership(meta["project_root"])
            if not owner["external_ops_allowed"]:
                print(json.dumps({
                    **owner,
                    **{key: str(meta[key]) for key in ("name", "vault_path", "alias_path", "config_path")},
                    "file_access_ok": meta["vault_path"].is_dir(),
                    "config_exists": None, "config_registered": None, "cli_visible": None,
                    "obsidian_in_path": None, "local_gui_available": None,
                    "resolved_vault_path": None, "target_error": None, "graph_ops_ready": False,
                }, ensure_ascii=False, indent=2))
                return 0
            config_registered = False
            config_exists = meta["config_path"].exists()
            configured_paths: list[str] = []
            if config_exists:
                data = json.loads(meta["config_path"].read_text())
                for info in data.get("vaults", {}).values():
                    path = info.get("path")
                    if path:
                        configured_paths.append(path)
                config_registered = any(
                    Path(path).exists() and Path(path).resolve() == meta["vault_path"]
                    for path in configured_paths
                )
            cli_vaults = obsidian_known_vaults()
            cli_visible = any(v.get("name") == meta["name"] for v in cli_vaults)
            gui_available = local_gui_available()
            resolved_path = None
            target_error = None
            try:
                check_alias(meta)
                resolved_path = verify_target(meta)
            except VaultError as exc:
                target_error = str(exc)
            print(
                json.dumps(
                    {
                        **owner,
                        "name": meta["name"],
                        "vault_path": str(meta["vault_path"]),
                        "alias_path": str(meta["alias_path"]),
                        "config_path": str(meta["config_path"]),
                        "file_access_ok": meta["vault_path"].exists(),
                        "config_exists": config_exists,
                        "config_registered": config_registered,
                        "cli_visible": cli_visible,
                        "obsidian_in_path": obsidian_exists(),
                        "is_wsl": is_wsl(),
                        "local_gui_available": gui_available,
                        "resolved_vault_path": resolved_path,
                        "target_error": target_error,
                        "graph_ops_ready": resolved_path is not None,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if ns.subcommand == "exec":
            args = ns.args
            if args and args[0] == "--":
                args = args[1:]
            return run_obsidian(meta, args)
    except (VaultError, OwnershipError, OSError, ValueError, yaml.YAMLError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
