#!/usr/bin/env python3
"""Maxa git-workspace Ability script.

This script intentionally uses only the Python standard library and Git CLI.
After load(target="git-workspace"), invoke the cataloged uv-backed entrypoint:
  call(tool="@git-workspace:/scripts/git_workspace.py", params={"args": ["--help"]})
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


CONFIG_REL = Path(".maxa/workspaces.yml")
TASKS_REL = Path(".maxa/tasks")
TASKADMIN_ROOT = Path(__file__).resolve().parents[2] / "task-admin"


class WorkspaceError(Exception):
    pass


def run_git(project_root: Path, args: List[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        ["git", "-C", str(project_root), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise WorkspaceError(f"git {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


def emit(data: Dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    status = data.get("status", "ok")
    print(f"{status.upper()}: {data.get('message', data.get('command', 'git-workspace'))}")
    for key in ("workspace", "path", "branch", "base", "current_path", "expected_path"):
        if key in data and data[key] is not None:
            print(f"{key}: {data[key]}")
    if "taskadmin_tag" in data:
        tag = data["taskadmin_tag"]
        print(f"taskadmin_tag: {tag['status']}" + (f" ({tag['tag']})" if tag.get("tag") else ""))
    if "template" in data:
        print(data["template"])
    for key in ("warnings", "blockers"):
        values = data.get(key) or []
        for value in values:
            print(f"{key[:-1]}: {value}")


def project_root_path(raw: str) -> Path:
    return Path(raw).expanduser().resolve()


def ensure_git_repo(project_root: Path) -> Path:
    proc = run_git(project_root, ["rev-parse", "--show-toplevel"], check=False)
    if proc.returncode != 0:
        raise WorkspaceError(f"not a Git repository: {project_root}")
    return Path(proc.stdout.strip()).resolve()


def git_rel(project_root: Path, path: Path) -> str:
    return path.resolve().relative_to(project_root.resolve()).as_posix()


@dataclass
class AfterCommand:
    command: str
    cwd: str


@dataclass
class WorkspaceDefinition:
    name: str
    path: str
    kind: str
    responsibility: str


@dataclass
class WorkspaceConfig:
    version: int
    root: str
    name_template: str
    branch_template: str
    base: str
    sync_on_create: bool
    sync_source: str
    only_untracked: bool
    existing_target: str
    missing_source: str
    include_patterns: List[str]
    link_patterns: List[str]
    after_commands: List[AfterCommand]
    workspaces: List[WorkspaceDefinition]


def parse_bool(value: str, field: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise WorkspaceError(f"invalid {field}: expected true|false, got {value!r}")


def strip_quotes(value: str) -> str:
    value = value.strip()
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    return value


def load_config(project_root: Path) -> WorkspaceConfig:
    config_path = project_root / CONFIG_REL
    if not config_path.exists():
        raise WorkspaceError(f"missing config: {CONFIG_REL}; run init-config first")
    return parse_config(config_path.read_text(encoding="utf-8"))


def parse_config(text: str) -> WorkspaceConfig:
    section: Optional[str] = None
    multiline_field: Optional[str] = None
    after_commands_mode = False
    current_after_command: Dict[str, str] = {}
    workspace_definitions_mode = False
    saw_workspace_definitions = False
    current_workspace_definition: Dict[str, str] = {}
    include_patterns: List[str] = []
    link_patterns: List[str] = []
    after_commands: List[AfterCommand] = []
    workspaces: List[WorkspaceDefinition] = []
    values: Dict[str, str] = {}

    def finish_after_command() -> None:
        nonlocal current_after_command
        if not current_after_command:
            return
        command = current_after_command.get("command", "")
        cwd = current_after_command.get("cwd", "")
        if not command or not cwd:
            raise WorkspaceError("each create.after_commands item requires command and cwd")
        after_commands.append(AfterCommand(command=command, cwd=cwd))
        current_after_command = {}

    def finish_workspace_definition() -> None:
        nonlocal current_workspace_definition
        if not current_workspace_definition:
            return
        missing = [
            field
            for field in ("name", "path", "type", "responsibility")
            if not current_workspace_definition.get(field, "").strip()
        ]
        if missing:
            raise WorkspaceError(
                "each workspaces item requires name, path, type and responsibility; missing " + ", ".join(missing)
            )
        workspaces.append(
            WorkspaceDefinition(
                name=current_workspace_definition["name"].strip(),
                path=current_workspace_definition["path"].strip(),
                kind=current_workspace_definition["type"].strip(),
                responsibility=current_workspace_definition["responsibility"].strip(),
            )
        )
        current_workspace_definition = {}

    for raw_line in text.splitlines():
        if workspace_definitions_mode:
            if raw_line.startswith("  ") or not raw_line.strip():
                stripped_item = raw_line.strip()
                if not stripped_item or stripped_item.startswith("#"):
                    continue
                if stripped_item.startswith("- "):
                    if not raw_line.startswith("  - "):
                        raise WorkspaceError(f"invalid workspaces item indentation: {raw_line}")
                    finish_workspace_definition()
                    stripped_item = stripped_item[2:].strip()
                elif not current_workspace_definition or not raw_line.startswith("    "):
                    raise WorkspaceError(f"invalid workspaces item: {raw_line}")
                if ":" not in stripped_item:
                    raise WorkspaceError(f"invalid workspaces item: {raw_line}")
                item_key, item_value = stripped_item.split(":", 1)
                item_key = item_key.strip()
                if item_key not in ("name", "path", "type", "responsibility"):
                    raise WorkspaceError(f"invalid workspaces field: {item_key}")
                if item_key in current_workspace_definition:
                    raise WorkspaceError(f"duplicate workspaces field: {item_key}")
                current_workspace_definition[item_key] = strip_quotes(item_value.strip())
                continue
            finish_workspace_definition()
            workspace_definitions_mode = False

        if after_commands_mode:
            if raw_line.startswith("    ") or not raw_line.strip():
                stripped_item = raw_line.strip()
                if not stripped_item or stripped_item.startswith("#"):
                    continue
                if stripped_item.startswith("- "):
                    finish_after_command()
                    stripped_item = stripped_item[2:].strip()
                if ":" not in stripped_item:
                    raise WorkspaceError(f"invalid create.after_commands item: {raw_line}")
                item_key, item_value = stripped_item.split(":", 1)
                item_key = item_key.strip()
                if item_key not in ("command", "cwd"):
                    raise WorkspaceError(f"invalid create.after_commands field: {item_key}")
                current_after_command[item_key] = strip_quotes(item_value.strip())
                continue
            finish_after_command()
            after_commands_mode = False

        if multiline_field:
            if raw_line.startswith("    ") or not raw_line.strip():
                item = raw_line[4:] if raw_line.startswith("    ") else ""
                if item.strip() and not item.lstrip().startswith("#"):
                    if multiline_field == "sync.include_patterns":
                        include_patterns.append(item.rstrip())
                    else:
                        link_patterns.append(item.rstrip())
                continue
            multiline_field = None

        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line.startswith(" ") and stripped == "workspaces:":
            if saw_workspace_definitions:
                raise WorkspaceError("duplicate workspaces section")
            saw_workspace_definitions = True
            section = None
            workspace_definitions_mode = True
            continue
        if not line.startswith(" ") and stripped.endswith(":"):
            section = stripped[:-1]
            continue
        if ":" not in stripped:
            raise WorkspaceError(f"invalid config line: {raw_line}")
        key, value = stripped.split(":", 1)
        value = value.strip()
        full_key = key if section is None else f"{section}.{key}"
        if full_key == "create.after_commands" and value == "":
            after_commands_mode = True
            continue
        if full_key in ("sync.include_patterns", "sync.link_patterns") and value == "|":
            multiline_field = full_key
            continue
        values[full_key] = strip_quotes(value)

    if after_commands_mode:
        finish_after_command()
    if workspace_definitions_mode:
        finish_workspace_definition()

    def required(key: str) -> str:
        if key not in values or values[key] == "":
            raise WorkspaceError(f"missing config field: {key}")
        return values[key]

    version = int(required("version"))
    cfg = WorkspaceConfig(
        version=version,
        root=required("layout.root"),
        name_template=required("layout.name_template"),
        branch_template=required("layout.branch_template"),
        base=required("create.base"),
        sync_on_create=parse_bool(required("sync.on_create"), "sync.on_create"),
        sync_source=required("sync.source"),
        only_untracked=parse_bool(required("sync.only_untracked"), "sync.only_untracked"),
        existing_target=required("sync.existing_target"),
        missing_source=required("sync.missing_source"),
        include_patterns=include_patterns,
        link_patterns=link_patterns,
        after_commands=after_commands,
        workspaces=workspaces,
    )
    validate_config(cfg)
    return cfg


def validate_config(cfg: WorkspaceConfig) -> None:
    if cfg.version != 1:
        raise WorkspaceError("unsupported config version: expected 1")
    if cfg.base != "current_head":
        raise WorkspaceError("unsupported create.base: expected current_head")
    if cfg.sync_source != "current_checkout":
        raise WorkspaceError("unsupported sync.source: expected current_checkout")
    if cfg.existing_target != "skip_warn":
        raise WorkspaceError("unsupported sync.existing_target: expected skip_warn")
    if cfg.missing_source != "warn":
        raise WorkspaceError("unsupported sync.missing_source: expected warn")
    if "{workspace}" not in cfg.name_template:
        raise WorkspaceError("layout.name_template must include {workspace}")
    if "{workspace}" not in cfg.branch_template:
        raise WorkspaceError("layout.branch_template must include {workspace}")
    seen_paths: set[Path] = set()
    for workspace in cfg.workspaces:
        if workspace.kind not in ("main", "child"):
            raise WorkspaceError(f"invalid workspaces.type: expected main|child, got {workspace.kind!r}")
        normalized = normalize_workspace_definition_path(workspace.path)
        if normalized in seen_paths:
            raise WorkspaceError(f"duplicate workspaces.path after normalization: {normalized}")
        seen_paths.add(normalized)


def normalize_workspace_definition_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise WorkspaceError(f"invalid workspaces.path: expected absolute path, got {value!r}")
    try:
        return path.resolve()
    except OSError as exc:
        raise WorkspaceError(f"invalid workspaces.path {value!r}: {exc}") from exc


def find_workspace_definition(cfg: WorkspaceConfig, current_path: Path) -> Optional[WorkspaceDefinition]:
    current = current_path.resolve()
    for workspace in cfg.workspaces:
        if normalize_workspace_definition_path(workspace.path) == current:
            return workspace
    return None


def primary_worktree_root(project_root: Path) -> Path:
    """Return the repository's primary worktree path when discoverable."""
    try:
        items = parse_worktree_list(project_root)
    except Exception:
        return project_root.resolve()
    if items and items[0].get("path"):
        return Path(items[0]["path"]).resolve()
    return project_root.resolve()


def repo_name(project_root: Path) -> str:
    return primary_worktree_root(project_root).name


def render_template(template: str, project_root: Path, workspace: str) -> str:
    return template.format(repo_name=repo_name(project_root), workspace=workspace)


def workspace_root(project_root: Path, cfg: WorkspaceConfig) -> Path:
    rendered = cfg.root.format(repo_name=repo_name(project_root))
    p = Path(rendered).expanduser()
    if not p.is_absolute():
        p = primary_worktree_root(project_root) / p
    return p.resolve()


def workspace_path(project_root: Path, cfg: WorkspaceConfig, workspace: str) -> Path:
    return (workspace_root(project_root, cfg) / render_template(cfg.name_template, project_root, workspace)).resolve()


def workspace_branch(project_root: Path, cfg: WorkspaceConfig, workspace: str) -> str:
    return render_template(cfg.branch_template, project_root, workspace)


def parse_worktree_list(project_root: Path) -> List[Dict[str, Any]]:
    proc = run_git(project_root, ["worktree", "list", "--porcelain"])
    items: List[Dict[str, Any]] = []
    current: Dict[str, Any] = {}
    for line in proc.stdout.splitlines():
        if not line:
            if current:
                items.append(current)
                current = {}
            continue
        if line.startswith("worktree "):
            current["path"] = str(Path(line[len("worktree "):]).resolve())
        elif line.startswith("HEAD "):
            current["head"] = line[len("HEAD "):]
        elif line.startswith("branch "):
            current["branch_ref"] = line[len("branch "):]
            current["branch"] = current["branch_ref"].removeprefix("refs/heads/")
        elif line == "bare":
            current["bare"] = True
        elif line.startswith("detached"):
            current["detached"] = True
    if current:
        items.append(current)
    return items


def branch_checked_out(project_root: Path, branch: str) -> Optional[str]:
    for item in parse_worktree_list(project_root):
        if item.get("branch") == branch:
            return item.get("path")
    return None


def detect_workspace(project_root: Path) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    git_dir = run_git(root, ["rev-parse", "--git-dir"]).stdout.strip()
    common_dir = run_git(root, ["rev-parse", "--git-common-dir"]).stdout.strip()
    branch = run_git(root, ["branch", "--show-current"], check=False).stdout.strip()
    is_linked = Path(git_dir).resolve() != Path(common_dir).resolve()
    result: Dict[str, Any] = {
        "status": "ok",
        "message": "detected git checkout",
        "git_root": str(root),
        "git_dir": str((root / git_dir).resolve() if not Path(git_dir).is_absolute() else Path(git_dir).resolve()),
        "git_common_dir": str((root / common_dir).resolve() if not Path(common_dir).is_absolute() else Path(common_dir).resolve()),
        "branch": branch or None,
        "is_linked_worktree": is_linked,
    }
    try:
        cfg = load_config(root)
        definition = find_workspace_definition(cfg, root)
        if definition:
            result["workspace_definition"] = {
                "name": definition.name,
                "type": definition.kind,
                "responsibility": definition.responsibility,
            }
        wr = workspace_root(root, cfg)
        path = root.resolve()
        if str(path).startswith(str(wr)):
            result["configured_workspace_root"] = str(wr)
            result["configured_workspace_name"] = path.name
    except WorkspaceError:
        pass
    return result


def config_template(project_root: Path, include_patterns: List[str]) -> str:
    patterns = include_patterns or []
    if patterns:
        body = "\n".join(f"    {p}" for p in patterns)
    else:
        body = "    # Add project-specific untracked files/directories after user confirmation.\n    # .env\n    # .env.local\n    # .mcp.json\n    # .vscode/"
    return f'''version: 1

# Optional explicit identities used by detect and generated model context.
# Paths are local absolute paths; create does not add entries automatically.
# workspaces:
#   - name: main
#     path: /absolute/path/to/primary-checkout
#     type: main
#     responsibility: Shared integration and governance

layout:
  root: "../{{repo_name}}-workspaces"
  name_template: "{{repo_name}}-{{workspace}}"
  branch_template: "workspace/{{workspace}}"

create:
  base: current_head
  after_commands:
    # - command: just prepare-local
    #   cwd: .

sync:
  on_create: true
  source: current_checkout
  only_untracked: true
  existing_target: skip_warn
  missing_source: warn
  include_patterns: |
{body}
  link_patterns: |
    # Add files that must link to the primary worktree instead of being copied.
'''


def candidate_untracked(project_root: Path) -> List[str]:
    candidates = [".env", ".env.local", ".mcp.json", ".claude", ".vscode"]
    found: List[str] = []
    for rel in candidates:
        p = project_root / rel
        if p.exists() and not is_tracked(project_root, p):
            found.append(rel + ("/" if p.is_dir() else ""))
    return found


def init_config(project_root: Path, args: argparse.Namespace) -> Dict[str, Any]:
    ensure_git_repo(project_root)
    config_path = primary_worktree_root(project_root) / CONFIG_REL
    includes = args.include_pattern or []
    text = config_template(project_root, includes)
    if args.write:
        if config_path.exists() and not args.overwrite:
            raise WorkspaceError(f"config already exists: {CONFIG_REL}")
        if not includes:
            raise WorkspaceError("refusing to write config without confirmed --include-pattern values; pass at least one or use --print-template")
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(text, encoding="utf-8")
        return {
            "status": "ok",
            "message": "wrote workspace config",
            "path": str(config_path),
            "candidate_untracked": candidate_untracked(project_root),
        }
    return {
        "status": "ok",
        "message": "workspace config template",
        "path": str(config_path),
        "template": text,
        "candidate_untracked": candidate_untracked(project_root),
        "requires_confirmation": [
            "layout.root",
            "layout.name_template",
            "layout.branch_template",
            "create.base",
            "sync.include_patterns",
            "sync.existing_target",
        ],
    }


def is_tracked(project_root: Path, path: Path) -> bool:
    try:
        rel = git_rel(project_root, path)
    except ValueError:
        return False
    proc = run_git(project_root, ["ls-files", "--error-unmatch", "--", rel], check=False)
    return proc.returncode == 0


def iter_pattern_matches(source_root: Path, pattern: str) -> List[Path]:
    pattern = pattern.strip()
    if not pattern or pattern.startswith("#"):
        return []
    if ".." in Path(pattern).parts:
        raise WorkspaceError(f"invalid include pattern outside checkout: {pattern}")
    if pattern.endswith("/"):
        base = source_root / pattern[:-1]
        return [base] if base.exists() else []
    matches = list(source_root.glob(pattern)) if any(ch in pattern for ch in "*?[") else [source_root / pattern]
    return [p for p in matches if p.exists()]


def copy_path(src: Path, dst: Path) -> None:
    if src.is_dir():
        for child in src.rglob("*"):
            if child.is_symlink():
                continue
            rel = child.relative_to(src)
            target = dst / rel
            if child.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(child, target)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def validate_link_sources(project_root: Path, cfg: WorkspaceConfig) -> None:
    primary = primary_worktree_root(project_root)
    for pattern in cfg.link_patterns:
        matches = iter_pattern_matches(primary, pattern)
        if not matches:
            raise WorkspaceError(f"missing primary-worktree link source for pattern: {pattern}")
        for src in matches:
            if src.is_dir():
                raise WorkspaceError(f"link source must be a file: {src.relative_to(primary).as_posix()}")


def sync_to_target(project_root: Path, cfg: WorkspaceConfig, target: Path) -> Dict[str, Any]:
    source = project_root.resolve()
    target = target.resolve()
    copied: List[str] = []
    skipped_existing: List[str] = []
    skipped_tracked: List[str] = []
    skipped_symlink: List[str] = []
    missing_patterns: List[str] = []
    warnings: List[str] = []

    for pattern in cfg.include_patterns:
        matches = iter_pattern_matches(source, pattern)
        if not matches:
            missing_patterns.append(pattern)
            warnings.append(f"missing source for pattern: {pattern}")
            continue
        for src in matches:
            if not src.resolve().is_relative_to(source):
                raise WorkspaceError(f"matched path escapes source checkout: {src}")
            rel = src.resolve().relative_to(source)
            if src.is_dir():
                for child in src.rglob("*"):
                    child_rel = child.resolve().relative_to(source)
                    child_dst = target / child_rel
                    if child.is_symlink():
                        skipped_symlink.append(child_rel.as_posix())
                        warnings.append(f"skipped symlink: {child_rel.as_posix()}")
                        continue
                    if child.is_dir():
                        continue
                    if cfg.only_untracked and is_tracked(source, child):
                        skipped_tracked.append(child_rel.as_posix())
                        continue
                    if child_dst.exists():
                        skipped_existing.append(child_rel.as_posix())
                        warnings.append(f"target exists, skipped: {child_rel.as_posix()}")
                        continue
                    child_dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(child, child_dst)
                    copied.append(child_rel.as_posix())
                continue
            dst = target / rel
            if cfg.only_untracked and is_tracked(source, src):
                skipped_tracked.append(rel.as_posix())
                continue
            if src.is_symlink():
                skipped_symlink.append(rel.as_posix())
                warnings.append(f"skipped symlink: {rel.as_posix()}")
                continue
            if dst.exists():
                skipped_existing.append(rel.as_posix())
                warnings.append(f"target exists, skipped: {rel.as_posix()}")
                continue
            copy_path(src, dst)
            copied.append(rel.as_posix())

    linked: List[str] = []
    primary = primary_worktree_root(project_root)
    validate_link_sources(project_root, cfg)
    for pattern in cfg.link_patterns:
        matches = iter_pattern_matches(primary, pattern)
        for src in matches:
            rel = src.relative_to(primary)
            dst = target / rel
            if dst.exists() or dst.is_symlink():
                skipped_existing.append(rel.as_posix())
                warnings.append(f"target exists, skipped link: {rel.as_posix()}")
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
            linked.append(rel.as_posix())

    return {
        "copied": copied,
        "linked": linked,
        "skipped_existing": skipped_existing,
        "skipped_tracked": skipped_tracked,
        "skipped_symlink": skipped_symlink,
        "missing_patterns": missing_patterns,
        "warnings": warnings,
    }


def resolve_workspace_or_path(project_root: Path, cfg: WorkspaceConfig, value: str) -> Tuple[str, Path]:
    p = Path(value).expanduser()
    if p.is_absolute() or "/" in value or value.startswith("."):
        return p.name, p.resolve()
    return value, workspace_path(project_root, cfg, value)


def run_after_commands(target: Path, commands: List[AfterCommand]) -> List[Dict[str, str]]:
    completed: List[Dict[str, str]] = []
    for item in commands:
        cwd = (target / item.cwd).resolve()
        if not cwd.is_relative_to(target.resolve()):
            raise WorkspaceError(f"create.after_commands cwd escapes workspace: {item.cwd}")
        if not cwd.is_dir():
            raise WorkspaceError(f"create.after_commands cwd is not a directory: {item.cwd}")
        proc = subprocess.run(
            ["bash", "-lc", item.command],
            cwd=cwd,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if proc.returncode != 0:
            raise WorkspaceError(
                f"create.after_commands failed with exit {proc.returncode} in {cwd}: {item.command}; workspace retained"
            )
        completed.append({"command": item.command, "cwd": item.cwd})
    return completed


def taskadmin_tag_command(project_root: Path, action: str, name: Optional[str] = None, workspace: Optional[str] = None) -> Dict[str, Any]:
    script = TASKADMIN_ROOT / "scripts/manage_tag.py"
    if not script.is_file():
        raise WorkspaceError(f"TaskAdmin tag script unavailable: {script}")
    args = ["uv", "run", "--project", str(TASKADMIN_ROOT), "python", str(script),
            "--project-root", str(project_root), "--action", action]
    if name is not None:
        args.extend(["--name", name])
    if workspace is not None:
        args.extend(["--workspace", workspace])
    try:
        proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise WorkspaceError(f"TaskAdmin tag command unavailable: {exc}") from exc
    if proc.returncode:
        raise WorkspaceError(f"TaskAdmin tag {action} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    try:
        result = json.loads(proc.stdout)
    except ValueError as exc:
        raise WorkspaceError(f"TaskAdmin tag {action} returned invalid JSON") from exc
    if result.get("success") is not True:
        raise WorkspaceError(f"TaskAdmin tag {action} failed: {result.get('error', proc.stdout.strip())}")
    return result["data"]


def child_tag_preflight(project_root: Path, workspace: str) -> bool:
    """Validate the source tag and return whether TaskAdmin is initialized."""
    tasks_root = project_root / TASKS_REL
    if not tasks_root.exists():
        return False
    if not (tasks_root / "state.yaml").is_file():
        raise WorkspaceError(f"TaskAdmin state missing: {tasks_root / 'state.yaml'}")
    if not workspace or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in workspace):
        raise WorkspaceError(f"invalid TaskAdmin tag '{workspace}': expected letters, digits, '-' or '_'")
    tags = taskadmin_tag_command(project_root, "list")["tags"]
    existing = next((tag for tag in tags if tag["name"] == workspace), None)
    if existing:
        binding = existing.get("workspace")
        if binding not in (None, workspace) or (not binding and existing["task_count"]):
            raise WorkspaceError(f"TaskAdmin tag '{workspace}' is not available for workspace '{workspace}': binding={binding!r}, tasks={existing['task_count']}")
    return True


def configure_child_tag(target: Path, workspace: str, initialized: bool) -> Dict[str, Any]:
    if not initialized:
        return {"status": "skipped", "reason": "TaskAdmin not initialized"}
    tags = taskadmin_tag_command(target, "list")["tags"]
    tag = next((item for item in tags if item["name"] == workspace), None)
    if tag:
        binding = tag.get("workspace")
        if binding not in (None, workspace) or (not binding and tag["task_count"]):
            raise WorkspaceError(f"TaskAdmin tag '{workspace}' has an incompatible binding in new checkout")
        if not binding:
            taskadmin_tag_command(target, "set-workspace", workspace, workspace)
    else:
        taskadmin_tag_command(target, "create", workspace, workspace)
    taskadmin_tag_command(target, "switch", workspace)
    return {"status": "configured", "tag": workspace, "workspace": workspace}


def create_workspace(project_root: Path, workspace: str) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    target = workspace_path(root, cfg, workspace)
    branch = workspace_branch(root, cfg, workspace)
    if target.exists():
        raise WorkspaceError(f"target path already exists: {target}")
    checked = branch_checked_out(root, branch)
    if checked:
        raise WorkspaceError(f"branch already checked out in worktree: {branch} at {checked}")
    taskadmin_enabled = child_tag_preflight(root, workspace)
    validate_link_sources(root, cfg)
    target.parent.mkdir(parents=True, exist_ok=True)
    base = run_git(root, ["rev-parse", "HEAD"]).stdout.strip()
    run_git(root, ["worktree", "add", "-b", branch, str(target), "HEAD"])
    sync_result = sync_to_target(root, cfg, target) if cfg.sync_on_create else {"warnings": []}
    try:
        tag_result = configure_child_tag(target, workspace, taskadmin_enabled)
    except WorkspaceError as exc:
        raise WorkspaceError(f"{exc}; workspace retained at {target} with incomplete TaskAdmin tag setup") from exc
    completed_commands = run_after_commands(target, cfg.after_commands)
    return {
        "status": "ok",
        "message": "created workspace",
        "workspace": workspace,
        "path": str(target),
        "branch": branch,
        "base": base,
        "taskadmin_tag": tag_result,
        "after_commands_completed": completed_commands,
        **sync_result,
    }


def list_workspaces(project_root: Path) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    wr = workspace_root(root, cfg)
    items = parse_worktree_list(root)
    for item in items:
        p = Path(item.get("path", "")).resolve()
        item["configured_workspace"] = str(p).startswith(str(wr))
        if item["configured_workspace"]:
            item["workspace_name"] = p.name
    return {"status": "ok", "message": "listed workspaces", "workspace_root": str(wr), "worktrees": items}


def sync_workspace(project_root: Path, value: str) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    name, target = resolve_workspace_or_path(root, cfg, value)
    if not target.exists():
        raise WorkspaceError(f"workspace path does not exist: {target}")
    result = sync_to_target(root, cfg, target)
    return {"status": "ok", "message": "synced workspace", "workspace": name, "path": str(target), **result}


def status_workspace(project_root: Path, value: str) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    name, target = resolve_workspace_or_path(root, cfg, value)
    if not target.exists():
        raise WorkspaceError(f"workspace path does not exist: {target}")
    branch = run_git(target, ["branch", "--show-current"], check=False).stdout.strip()
    porcelain = run_git(target, ["status", "--porcelain"], check=False).stdout.splitlines()
    untracked = [line for line in porcelain if line.startswith("??")]
    dirty = [line for line in porcelain if not line.startswith("??")]
    unique_count, unique_state = unique_commit_count(target)
    return {
        "status": "ok",
        "message": "workspace status",
        "workspace": name,
        "path": str(target),
        "branch": branch or None,
        "dirty_count": len(dirty),
        "untracked_count": len(untracked),
        "unique_commit_count": unique_count,
        "unique_commit_state": unique_state,
        "is_clean": not dirty and not untracked and unique_count == 0,
    }


def unique_commit_count(repo: Path) -> Tuple[int, str]:
    branch = run_git(repo, ["branch", "--show-current"], check=False).stdout.strip()
    refs_proc = run_git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], check=False)
    refs = [r for r in refs_proc.stdout.splitlines() if r and r != f"refs/heads/{branch}"]
    if not refs:
        return 0, "no_comparison_refs"
    proc = run_git(repo, ["rev-list", "--count", "HEAD", "--not", *refs], check=False)
    if proc.returncode != 0:
        return 0, "unknown"
    return int(proc.stdout.strip() or "0"), "ok"


def check_workspace(project_root: Path, workspace: str) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    expected = workspace_path(root, cfg, workspace)
    current = root.resolve()
    ok = current == expected
    return {
        "status": "ok" if ok else "blocked",
        "message": "workspace check passed" if ok else "current checkout is not expected workspace",
        "workspace": workspace,
        "expected_path": str(expected),
        "current_path": str(current),
        "matches": ok,
        "blockers": [] if ok else ["wrong current workspace"],
    }


def cleanup_workspace(project_root: Path, value: str) -> Dict[str, Any]:
    root = ensure_git_repo(project_root)
    cfg = load_config(root)
    name, target = resolve_workspace_or_path(root, cfg, value)
    st = status_workspace(root, str(target))
    blockers: List[str] = []
    if st["dirty_count"]:
        blockers.append("workspace has staged or unstaged changes")
    if st["untracked_count"]:
        blockers.append("workspace has untracked files")
    if st["unique_commit_count"]:
        blockers.append("workspace has commits not present on other refs")
    wr = workspace_root(root, cfg)
    if not target.resolve().is_relative_to(wr):
        blockers.append("workspace path is outside configured workspace root")
    if blockers:
        return {"status": "blocked", "message": "cleanup refused", "workspace": name, "path": str(target), "blockers": blockers}
    run_git(root, ["worktree", "remove", str(target)])
    return {"status": "ok", "message": "removed workspace", "workspace": name, "path": str(target)}


def parse_flat_yaml(path: Path) -> Dict[str, str]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    if text.startswith("---"):
        parts = text.split("---", 2)
        text = parts[1] if len(parts) >= 3 else ""
    result: Dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = strip_quotes(value.strip())
        if value:
            result[key.strip()] = value
    return result


def task_meta_file(project_root: Path, tag: str, task_id: str) -> Tuple[int, Path]:
    value = task_id.strip()
    if not value.isdigit() or int(value) <= 0:
        raise WorkspaceError(f"invalid TaskAdmin task ID '{task_id}': expected a positive integer")
    parsed = int(value)
    return parsed, project_root / TASKS_REL / tag / f"task_{parsed:03d}" / "_meta.yaml"


def task_binding(project_root: Path, tag: str, task_id: str) -> Dict[str, Any]:
    if not tag or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in tag):
        raise WorkspaceError(f"invalid TaskAdmin tag '{tag}': expected letters, digits, '-' or '_'")
    root = project_root.resolve()
    tag_meta = parse_flat_yaml(root / TASKS_REL / tag / "_meta.yaml")
    tag_workspace = tag_meta.get("workspace")
    parsed_id, meta_file = task_meta_file(root, tag, task_id)
    if not meta_file.exists():
        raise WorkspaceError(f"task metadata not found for {tag}/{parsed_id}: {meta_file}")
    task_meta = parse_flat_yaml(meta_file)
    task_workspace = task_meta.get("workspace")
    effective = task_workspace or tag_workspace
    source = "task" if task_workspace else "tag" if tag_workspace else None
    return {
        "status": "ok",
        "message": "resolved task workspace binding",
        "tag": tag,
        "task_id": parsed_id,
        "workspace": effective,
        "source": source,
        "tag_workspace": tag_workspace,
        "task_workspace": task_workspace,
    }


def main(argv: Optional[List[str]] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    else:
        argv = list(argv)
    # Allow --json before or after subcommands for Agent ergonomics.
    json_requested = False
    while "--json" in argv:
        argv.remove("--json")
        json_requested = True
    if json_requested:
        argv.insert(0, "--json")

    parser = argparse.ArgumentParser(description="Manage Maxa Git workspaces")
    parser.add_argument("--project-root", required=True, help="Project root / checkout path")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("detect")
    sub.add_parser("list")

    p_init = sub.add_parser("init-config")
    p_init.add_argument("--print-template", action="store_true", help="Print proposed config data")
    p_init.add_argument("--write", action="store_true", help="Write .maxa/workspaces.yml after user confirmation")
    p_init.add_argument("--overwrite", action="store_true", help="Replace existing config")
    p_init.add_argument("--include-pattern", action="append", help="Confirmed include-copy pattern; repeatable")

    p_create = sub.add_parser("create")
    p_create.add_argument("workspace")

    p_sync = sub.add_parser("sync")
    p_sync.add_argument("workspace_or_path")

    p_status = sub.add_parser("status")
    p_status.add_argument("workspace_or_path")

    p_check = sub.add_parser("check")
    p_check.add_argument("workspace")

    p_cleanup = sub.add_parser("cleanup")
    p_cleanup.add_argument("workspace_or_path")

    p_bind = sub.add_parser("task-binding")
    p_bind.add_argument("--tag", required=True)
    p_bind.add_argument("--id", required=True)

    args = parser.parse_args(argv)
    project_root = project_root_path(args.project_root)

    try:
        if args.command == "detect":
            data = detect_workspace(project_root)
        elif args.command == "init-config":
            data = init_config(project_root, args)
        elif args.command == "list":
            data = list_workspaces(project_root)
        elif args.command == "create":
            data = create_workspace(project_root, args.workspace)
        elif args.command == "sync":
            data = sync_workspace(project_root, args.workspace_or_path)
        elif args.command == "status":
            data = status_workspace(project_root, args.workspace_or_path)
        elif args.command == "check":
            data = check_workspace(project_root, args.workspace)
            if data.get("status") == "blocked":
                emit(data, args.json)
                return 2
        elif args.command == "cleanup":
            data = cleanup_workspace(project_root, args.workspace_or_path)
            if data.get("status") == "blocked":
                emit(data, args.json)
                return 2
        elif args.command == "task-binding":
            data = task_binding(project_root, args.tag, args.id)
        else:
            raise WorkspaceError(f"unknown command: {args.command}")
        emit(data, args.json)
        return 0
    except WorkspaceError as exc:
        if args.json:
            print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False, indent=2))
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
