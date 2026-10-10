#!/usr/bin/env python3
"""Project Maxa root Vault sync manager (Syncthing).

Owner model:
- WSL/Linux-native projects are managed by WSL Syncthing.
- Windows-mounted projects under /mnt/<drive>/... are managed by Windows Syncthing.
- A project Vault must be registered on exactly one side; scan/ensure/status follow that owner.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import yaml

from project_vault_ownership import (
    OwnershipError, require_external_owner, resolve_ownership, validate_vault_path,
)

DEFAULT_SYNCTHING_REST_TIMEOUT = 180
DEFAULT_RESCAN_INTERVAL_S = 300
DEFAULT_FS_WATCHER_ENABLED = True
DEFAULT_FS_WATCHER_DELAY_S = 10

DEFAULT_STIGNORE_INCLUDE = "#include .stignore-shared\n"

DEFAULT_STIGNORE_SHARED = """# Maxa root Vault - shared local/runtime exclusions
# Publishable/syncable content intentionally NOT ignored: /tasks, /drafts, /translate-cache
# Root-anchored patterns without trailing slash ignore the directory entry itself.
# (?d) allows Syncthing to delete already-synced ignored paths on other devices.

# Obsidian local state
/.obsidian/workspace.json
/.obsidian/workspace-mobile.json
/.obsidian/workspace*.json
/.obsidian/hotkeys.json
(?d)/.obsidian/cache
(?d)/.obsidian/cache/**
(?d)/.trash
(?d)/.trash/**

# Syncthing runtime/version data
(?d)/.stversions
(?d)/.stversions/**
/.stfolder

# Maxa runtime/local zones
/mcp.json
(?d)/abilities
(?d)/abilities/**
(?d)/fragments
(?d)/fragments/**
(?d)/tmp
(?d)/tmp/**
(?d)/history
(?d)/history/**
(?d)/artifacts
(?d)/artifacts/**
(?d)/handoff
(?d)/handoff/**
(?d)/e2e
(?d)/e2e/**

# Retired v0 Vault path; must not be reintroduced under the v1 root Vault
(?d)/knowledge
(?d)/knowledge/**
"""


class SyncError(RuntimeError):
    pass


def load_meta(project_root: Path) -> dict[str, Any]:
    meta_path = project_root / ".maxa/_meta.yaml"
    if not meta_path.exists():
        raise SyncError(f"Maxa vault meta not found: {meta_path}")
    data = yaml.safe_load(meta_path.read_text()) or {}
    if not isinstance(data, dict):
        raise SyncError("Maxa vault meta must be a mapping")
    name = data.get("name")
    if not isinstance(name, str) or not name:
        raise SyncError("Maxa vault meta must contain 'name'")
    vault_path = validate_vault_path(project_root)
    folder_id = data.get("syncthing_folder_id") or derive_folder_id(name)
    project_root_resolved = project_root.resolve()
    vault_path_resolved = vault_path.resolve()
    manager_side = detect_manager_side(vault_path_resolved)
    return {
        "name": name,
        "project_root": project_root_resolved,
        "vault_path": vault_path_resolved,
        "folder_id": folder_id,
        "label": f"Project Maxa Vault ({derive_project_slug(name)})",
        "manager_side": manager_side,
    }


def derive_project_slug(name: str) -> str:
    parts = name.split("::")
    if len(parts) >= 3 and parts[0] == "smx-knowledge":
        return parts[1]
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "project"


def derive_folder_id(name: str) -> str:
    parts = name.split("::")
    if len(parts) >= 3 and parts[0] == "smx-knowledge":
        return f"smx-knowledge-{derive_project_slug(name)}-{parts[2]}"
    raw = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    return (raw or "smx-knowledge-project")[:63]


def detect_manager_side(vault_path: Path) -> str:
    text = str(vault_path)
    if re.match(r"^/mnt/[A-Za-z](?:/|$)", text):
        return "windows"
    return "wsl"


def syncthing_rest_timeout() -> int:
    raw = os.environ.get("PROJECT_KNOWLEDGE_SYNC_REST_TIMEOUT", "")
    if not raw:
        return DEFAULT_SYNCTHING_REST_TIMEOUT
    try:
        value = int(raw)
    except ValueError as exc:
        raise SyncError(
            "PROJECT_KNOWLEDGE_SYNC_REST_TIMEOUT must be an integer number of seconds"
        ) from exc
    if value <= 0:
        raise SyncError("PROJECT_KNOWLEDGE_SYNC_REST_TIMEOUT must be greater than 0")
    return value


def run_text(args: list[str]) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise SyncError((result.stderr or result.stdout or "command failed").strip())
    return result.stdout.strip()


def run_json(args: list[str]) -> Any:
    return json.loads(run_text(args))


def command_exists(command: str) -> bool:
    return subprocess.run(
        ["bash", "-lc", f"command -v {command} >/dev/null 2>&1"], check=False
    ).returncode == 0


def ensure_stignore(vault_path: Path) -> tuple[bool, bool]:
    """Ensure a local include file and a Syncthing-distributed shared rules file."""
    stignore = vault_path / ".stignore"
    shared = vault_path / ".stignore-shared"
    local_text = stignore.read_text(errors="ignore") if stignore.exists() else ""
    local_changed = local_text != DEFAULT_STIGNORE_INCLUDE
    shared_changed = False

    if shared.exists():
        shared_text = shared.read_text(errors="ignore")
        legacy_rules = [
            line
            for line in local_text.splitlines()
            if line.strip()
            and not line.lstrip().startswith(("#", "//"))
            and not line.lstrip().startswith("#include ")
        ]
        missing_legacy_rules = [line for line in legacy_rules if line not in shared_text.splitlines()]
        if missing_legacy_rules:
            shared_text = (
                shared_text.rstrip()
                + "\n\n# Rules migrated from the former local .stignore\n"
                + "\n".join(missing_legacy_rules)
                + "\n"
            )
            shared_changed = True
    else:
        legacy_has_rules = any(
            line.strip()
            and not line.lstrip().startswith(("#", "//"))
            and not line.lstrip().startswith("#include ")
            for line in local_text.splitlines()
        )
        shared_text = local_text if legacy_has_rules else DEFAULT_STIGNORE_SHARED
        shared_changed = True

    additions = [
        line
        for line in ["/mcp.json", "(?d)/knowledge", "(?d)/knowledge/**"]
        if line not in shared_text.splitlines()
    ]
    if additions:
        shared_text = shared_text.rstrip() + "\n\n" + "\n".join(additions) + "\n"
        shared_changed = True

    if shared_changed:
        shared.write_text(shared_text.rstrip() + "\n")
    if local_changed:
        stignore.write_text(DEFAULT_STIGNORE_INCLUDE)
    return local_changed, shared_changed


def ensure_marker(vault_path: Path) -> bool:
    marker = vault_path / ".stfolder"
    if marker.exists():
        return False
    marker.mkdir(parents=True, exist_ok=True)
    return True


# ---------------------------------------------------------------------------
# WSL Syncthing owner


def wsl_syncthing_exists() -> bool:
    return command_exists("syncthing")


def wsl_service_active() -> bool:
    return subprocess.run(
        ["systemctl", "--user", "is-active", "syncthing"],
        check=False,
        capture_output=True,
    ).returncode == 0


def wsl_syncthing_config_path() -> Path:
    candidates = [
        Path.home() / ".local/state/syncthing/config.xml",
        Path.home() / ".config/syncthing/config.xml",
    ]
    for path in candidates:
        if path.exists():
            return path
    raise SyncError("WSL Syncthing config.xml not found")


def wsl_syncthing_api_key() -> str:
    root = ET.parse(wsl_syncthing_config_path()).getroot()
    api_key = root.findtext("gui/apikey") or ""
    if not api_key:
        raise SyncError("WSL Syncthing GUI API key not found in config.xml")
    return api_key


def wsl_syncthing_rest(path: str, method: str = "GET") -> Any:
    req = urllib.request.Request(
        "http://127.0.0.1:8384/rest/" + path,
        headers={"X-API-Key": wsl_syncthing_api_key()},
        method=method,
    )
    timeout = syncthing_rest_timeout()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode()
    except Exception as exc:  # noqa: BLE001 - expose actionable sync error
        raise SyncError(f"WSL Syncthing REST request failed after {timeout}s: {exc}") from exc
    return json.loads(raw) if raw else {}


def wsl_list_folders() -> list[str]:
    out = run_text(["syncthing", "cli", "config", "folders", "list"])
    return [line.strip() for line in out.splitlines() if line.strip()]


def wsl_list_devices() -> list[str]:
    out = run_text(["syncthing", "cli", "config", "devices", "list"])
    return [line.strip() for line in out.splitlines() if line.strip()]


def wsl_folder_dump(folder_id: str) -> dict[str, Any]:
    return run_json(["syncthing", "cli", "config", "folders", folder_id, "dump-json"])


def wsl_build_folder_config(meta: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    folders = wsl_list_folders()
    template_id = next((folder for folder in folders if folder.startswith("smx-knowledge-")), None)
    if template_id is None and folders:
        template_id = folders[0]
    if template_id:
        base = wsl_folder_dump(template_id)
        base["id"] = meta["folder_id"]
        base["label"] = meta["label"]
        base["path"] = str(meta["vault_path"])
        return base, template_id

    devices = [{"deviceID": did, "introducedBy": ""} for did in wsl_list_devices()]
    base = {
        "id": meta["folder_id"],
        "label": meta["label"],
        "path": str(meta["vault_path"]),
        "type": "sendreceive",
        "devices": devices,
        "rescanIntervalS": DEFAULT_RESCAN_INTERVAL_S,
        "fsWatcherEnabled": DEFAULT_FS_WATCHER_ENABLED,
        "fsWatcherDelayS": DEFAULT_FS_WATCHER_DELAY_S,
        "ignorePerms": False,
        "autoNormalize": True,
        "versioning": {"type": "simple", "params": {"keep": "5"}},
    }
    return base, None


def wsl_ensure_folder_defaults(folder_id: str, data: dict[str, Any]) -> bool:
    changed = False
    desired = {
        "rescanIntervalS": DEFAULT_RESCAN_INTERVAL_S,
        "fsWatcherEnabled": DEFAULT_FS_WATCHER_ENABLED,
        "fsWatcherDelayS": DEFAULT_FS_WATCHER_DELAY_S,
    }
    for key, value in desired.items():
        if data.get(key) != value:
            data[key] = value
            changed = True
    if changed:
        subprocess.run(
            [
                "syncthing",
                "cli",
                "config",
                "folders",
                folder_id,
                "edit",
                "--set",
                json.dumps(data, ensure_ascii=False),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    return changed


def wsl_ensure_folder(meta: dict[str, Any]) -> tuple[bool, str | None]:
    folders = wsl_list_folders()
    if meta["folder_id"] in folders:
        data = wsl_folder_dump(meta["folder_id"])
        current_path = Path(data.get("path", "")).resolve()
        if current_path != meta["vault_path"]:
            raise SyncError(
                f"WSL Syncthing folder id '{meta['folder_id']}' already points elsewhere: {current_path}"
            )
        defaults_updated = wsl_ensure_folder_defaults(meta["folder_id"], data)
        return defaults_updated, meta["folder_id"]

    payload, template_id = wsl_build_folder_config(meta)
    subprocess.run(
        [
            "syncthing",
            "cli",
            "config",
            "folders",
            "add-json",
            json.dumps(payload, ensure_ascii=False),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return True, template_id


def wsl_status(meta: dict[str, Any]) -> dict[str, Any]:
    info = base_status(meta)
    info["syncthing_in_path"] = wsl_syncthing_exists()
    if not info["syncthing_in_path"]:
        return info
    info["service_active"] = wsl_service_active()
    folders = wsl_list_folders()
    if meta["folder_id"] not in folders:
        return info
    folder = wsl_folder_dump(meta["folder_id"])
    current_path = Path(folder.get("path", "")).resolve()
    info.update(folder_status_fields(folder, current_path == meta["vault_path"]))
    return info


def wsl_trigger_scan(meta: dict[str, Any]) -> dict[str, Any]:
    current = wsl_status(meta)
    if not current.get("syncthing_in_path"):
        raise SyncError("WSL syncthing CLI not found in PATH")
    if not current.get("service_active"):
        raise SyncError("WSL syncthing service is not active")
    if not current.get("folder_registered") or not current.get("path_matches"):
        raise SyncError("project Maxa vault folder is not registered correctly on WSL Syncthing")
    query = urllib.parse.urlencode({"folder": meta["folder_id"]})
    wsl_syncthing_rest("db/scan?" + query, method="POST")
    result = wsl_status(meta)
    result["scan_triggered"] = True
    return result


# ---------------------------------------------------------------------------
# Windows Syncthing owner, called from WSL through powershell.exe.


def windows_available() -> bool:
    return command_exists("powershell.exe")


def wsl_to_windows_path(path: Path) -> str:
    return run_text(["wslpath", "-w", str(path)])


def run_powershell_json(script: str) -> Any:
    if not windows_available():
        raise SyncError("powershell.exe not found; Windows Syncthing is unavailable from WSL")
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        text=True,
        capture_output=True,
        check=False,
        timeout=syncthing_rest_timeout(),
    )
    if result.returncode != 0:
        raise SyncError((result.stderr or result.stdout or "Windows PowerShell command failed").strip())
    raw = result.stdout.strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SyncError(f"Windows PowerShell did not return JSON: {raw[:500]}") from exc


def ps_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def windows_common_ps() -> str:
    return (Path(__file__).with_name("windows_vault_path.ps1").read_text() + r"""
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Windows Syncthing config.xml not found: $configPath" }
[xml]$xml = Get-Content -LiteralPath $configPath
$api = $xml.configuration.gui.apikey
if ([string]::IsNullOrWhiteSpace($api)) { throw 'Windows Syncthing GUI API key not found in config.xml' }
$address = [string]$xml.configuration.gui.address
if ([string]::IsNullOrWhiteSpace($address)) { $address = '127.0.0.1:8385' }
if ($address -match ':(\d+)$') { $port = $Matches[1] } else { $port = '8385' }
$base = 'http://127.0.0.1:' + $port
$headers = @{ 'X-API-Key' = $api }
""")


def windows_status(meta: dict[str, Any]) -> dict[str, Any]:
    info = base_status(meta)
    info["syncthing_in_path"] = windows_available()
    if not info["syncthing_in_path"]:
        return info
    win_path = wsl_to_windows_path(meta["vault_path"])
    script = windows_common_ps() + f"""
try {{
  $cfg = Invoke-RestMethod -Uri ($base + '/rest/config') -Headers $headers -TimeoutSec 10
  $folder = $cfg.folders | Where-Object {{ $_.id -eq {ps_literal(meta['folder_id'])} }} | Select-Object -First 1
  if ($folder) {{
    $pathMatches = Test-SameVaultDirectory ([string]$folder.path) {ps_literal(win_path)}
    $out = [ordered]@{{
      service_active = $true
      folder_registered = $true
      path_matches = $pathMatches
      device_count = @($folder.devices).Count
      versioning_type = $folder.versioning.type
      rescan_interval_s = $folder.rescanIntervalS
      fs_watcher_enabled = $folder.fsWatcherEnabled
      fs_watcher_delay_s = $folder.fsWatcherDelayS
    }}
  }} else {{
    $out = [ordered]@{{ service_active = $true }}
  }}
  $out | ConvertTo-Json -Compress -Depth 10
}} catch {{
  ([ordered]@{{ service_active = $false; error = $_.Exception.Message }}) | ConvertTo-Json -Compress -Depth 10
}}
"""
    data = run_powershell_json(script)
    info.update(data)
    return info


def windows_ensure_folder(meta: dict[str, Any]) -> tuple[bool, str | None]:
    win_path = wsl_to_windows_path(meta["vault_path"])
    script = windows_common_ps() + f"""
$cfg = Invoke-RestMethod -Uri ($base + '/rest/config') -Headers $headers -TimeoutSec 10
$self = (Invoke-RestMethod -Uri ($base + '/rest/system/status') -Headers $headers -TimeoutSec 10).myID
$changed = $false
function FolderDevice($id) {{ [pscustomobject]@{{ deviceID = $id; introducedBy = '' }} }}
function VersioningSimple() {{ [pscustomobject]@{{ type = 'simple'; params = [pscustomobject]@{{ keep = '5' }}; cleanupIntervalS = 3600; fsPath = ''; fsType = 'filesystem' }} }}
$folder = $cfg.folders | Where-Object {{ $_.id -eq {ps_literal(meta['folder_id'])} }} | Select-Object -First 1
if ($folder) {{
  if (-not (Test-SameVaultDirectory ([string]$folder.path) {ps_literal(win_path)})) {{
    throw "Windows Syncthing folder id already points elsewhere: $($folder.path)"
  }}
  if ($folder.rescanIntervalS -ne {DEFAULT_RESCAN_INTERVAL_S}) {{ $folder.rescanIntervalS = {DEFAULT_RESCAN_INTERVAL_S}; $changed = $true }}
  if ($folder.fsWatcherEnabled -ne $true) {{ $folder.fsWatcherEnabled = $true; $changed = $true }}
  if ($folder.fsWatcherDelayS -ne {DEFAULT_FS_WATCHER_DELAY_S}) {{ $folder.fsWatcherDelayS = {DEFAULT_FS_WATCHER_DELAY_S}; $changed = $true }}
}} else {{
  $devices = @()
  foreach ($device in $cfg.devices) {{ $devices += (FolderDevice $device.deviceID) }}
  if (-not ($devices | Where-Object {{ $_.deviceID -eq $self }})) {{ $devices += (FolderDevice $self) }}
  $folder = [pscustomobject]@{{
    id = {ps_literal(meta['folder_id'])}
    label = {ps_literal(meta['label'])}
    filesystemType = 'basic'
    path = {ps_literal(win_path)}
    type = 'sendreceive'
    devices = $devices
    rescanIntervalS = {DEFAULT_RESCAN_INTERVAL_S}
    fsWatcherEnabled = $true
    fsWatcherDelayS = {DEFAULT_FS_WATCHER_DELAY_S}
    ignorePerms = $false
    autoNormalize = $true
    minDiskFree = [pscustomobject]@{{ value = 1; unit = '%' }}
    versioning = (VersioningSimple)
    copiers = 0
    pullerMaxPendingKiB = 0
    hashers = 0
    order = 'random'
    ignoreDelete = $false
    scanProgressIntervalS = 0
    pullerPauseS = 0
    maxConflicts = 10
    disableSparseFiles = $false
    disableTempIndexes = $false
    paused = $false
    weakHashThresholdPct = 25
    markerName = '.stfolder'
    copyOwnershipFromParent = $false
    modTimeWindowS = 0
    maxConcurrentWrites = 2
    disableFsync = $false
    blockPullOrder = 'standard'
    copyRangeMethod = 'standard'
    caseSensitiveFS = $false
    junctionsAsDirs = $false
    syncOwnership = $false
    sendOwnership = $false
    syncXattrs = $false
    sendXattrs = $false
    xattrFilter = [pscustomobject]@{{ entries = @(); maxSingleEntrySize = 1024; maxTotalSize = 4096 }}
  }}
  $cfg.folders += $folder
  $changed = $true
}}
if ($changed) {{
  $json = $cfg | ConvertTo-Json -Depth 100
  Invoke-RestMethod -Uri ($base + '/rest/config') -Method Put -Headers $headers -Body $json -ContentType 'application/json' -TimeoutSec 20 | Out-Null
}}
([ordered]@{{ changed = $changed; template_source = $null }}) | ConvertTo-Json -Compress -Depth 10
"""
    data = run_powershell_json(script)
    return bool(data.get("changed")), data.get("template_source")


def windows_trigger_scan(meta: dict[str, Any]) -> dict[str, Any]:
    current = windows_status(meta)
    if not current.get("syncthing_in_path"):
        raise SyncError("Windows Syncthing is unavailable from WSL")
    if not current.get("service_active"):
        raise SyncError(f"Windows Syncthing REST is not active: {current.get('error') or ''}".strip())
    if not current.get("folder_registered") or not current.get("path_matches"):
        raise SyncError("project Maxa vault folder is not registered correctly on Windows Syncthing")
    folder_encoded = urllib.parse.quote(meta["folder_id"], safe="")
    script = windows_common_ps() + f"""
Invoke-RestMethod -Uri ($base + '/rest/db/scan?folder={folder_encoded}') -Method Post -Headers $headers -TimeoutSec 60 | Out-Null
([ordered]@{{ ok = $true }}) | ConvertTo-Json -Compress
"""
    run_powershell_json(script)
    result = windows_status(meta)
    result["scan_triggered"] = True
    return result


# ---------------------------------------------------------------------------
# Shared command dispatch


def base_status(meta: dict[str, Any]) -> dict[str, Any]:
    return {
        "folder_id": meta["folder_id"],
        "vault_path": str(meta["vault_path"]),
        "manager_side": meta["manager_side"],
        "syncthing_in_path": False,
        "service_active": False,
        "stignore_exists": (meta["vault_path"] / ".stignore").exists(),
        "stignore_shared_exists": (meta["vault_path"] / ".stignore-shared").exists(),
        "marker_exists": (meta["vault_path"] / ".stfolder").exists(),
        "folder_registered": False,
        "path_matches": False,
        "device_count": 0,
        "versioning_type": None,
        "rescan_interval_s": None,
        "fs_watcher_enabled": None,
        "fs_watcher_delay_s": None,
    }


def folder_status_fields(folder: dict[str, Any], path_matches: bool) -> dict[str, Any]:
    return {
        "folder_registered": True,
        "path_matches": path_matches,
        "device_count": len(folder.get("devices", [])),
        "versioning_type": (folder.get("versioning") or {}).get("type"),
        "rescan_interval_s": folder.get("rescanIntervalS"),
        "fs_watcher_enabled": folder.get("fsWatcherEnabled"),
        "fs_watcher_delay_s": folder.get("fsWatcherDelayS"),
    }


def status(meta: dict[str, Any]) -> dict[str, Any]:
    owner = resolve_ownership(meta["project_root"])
    if not owner["external_ops_allowed"]:
        info = base_status(meta)
        for key in ("syncthing_in_path", "service_active", "folder_registered", "path_matches",
                    "device_count", "versioning_type", "rescan_interval_s",
                    "fs_watcher_enabled", "fs_watcher_delay_s"):
            info[key] = None
        return {**info, **owner}
    info = windows_status(meta) if meta["manager_side"] == "windows" else wsl_status(meta)
    return {**info, **owner}


def preflight_folder(meta: dict[str, Any]) -> None:
    """Reject existing path conflicts before ignore/marker or registration writes."""
    require_external_owner(meta["project_root"])
    if meta["manager_side"] == "windows":
        current = windows_status(meta)
        if not current.get("service_active"):
            raise SyncError("Cannot verify Windows Syncthing registration")
        if current.get("folder_registered") and not current.get("path_matches"):
            raise SyncError("Windows Syncthing folder id already points elsewhere")
    elif meta["folder_id"] in wsl_list_folders():
        data = wsl_folder_dump(meta["folder_id"])
        if Path(data.get("path", "")).resolve() != meta["vault_path"]:
            raise SyncError("WSL Syncthing folder id already points elsewhere")


def ensure_folder(meta: dict[str, Any]) -> tuple[bool, str | None]:
    require_external_owner(meta["project_root"])
    if meta["manager_side"] == "windows":
        return windows_ensure_folder(meta)
    return wsl_ensure_folder(meta)


def trigger_scan(meta: dict[str, Any]) -> dict[str, Any]:
    require_external_owner(meta["project_root"])
    if meta["manager_side"] == "windows":
        return windows_trigger_scan(meta)
    return wsl_trigger_scan(meta)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Project Syncthing: primary Git checkout or independent non-Git project only for ensure/scan.",
        epilog="status is read-only and does not contact services for linked/unresolved projects. ensure never retargets an existing Folder ID. scan requires an explicit user request; ordinary edits use filesystem watching.",
    )
    parser.add_argument("--project-root", required=True, help="Selected project root; never redirected to another checkout")
    sub = parser.add_subparsers(dest="subcommand", required=True)
    sub.add_parser("folder-id")
    sub.add_parser("status")
    sub.add_parser("ensure")
    sub.add_parser("scan")
    ns = parser.parse_args()

    try:
        meta = load_meta(Path(ns.project_root).resolve())
        if ns.subcommand == "folder-id":
            print(meta["folder_id"])
            return 0
        if ns.subcommand == "status":
            print(json.dumps(status(meta), ensure_ascii=False, indent=2))
            return 0
        if ns.subcommand == "ensure":
            preflight_folder(meta)
            stignore_created, stignore_shared_created = ensure_stignore(meta["vault_path"])
            marker_created = ensure_marker(meta["vault_path"])
            folder_created, template_source = ensure_folder(meta)
            result = status(meta)
            result.update(
                {
                    "stignore_created": stignore_created,
                    "stignore_shared_created": stignore_shared_created,
                    "marker_created": marker_created,
                    "folder_created": folder_created,
                    "template_source": template_source,
                }
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if ns.subcommand == "scan":
            result = trigger_scan(meta)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
    except (SyncError, OwnershipError, OSError, ValueError, yaml.YAMLError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
