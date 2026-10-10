"""Read-only Git checkout ownership for project Vault external operations."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess


class OwnershipError(RuntimeError):
    pass


def _git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    # Caller Git directory/discovery overrides must not change the selected project.
    env = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"):
        env.pop(key, None)
    env.update(LC_ALL="C", GIT_DISCOVERY_ACROSS_FILESYSTEM="1", GIT_OPTIONAL_LOCKS="0")
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                          text=True, errors="surrogateescape", env=env, timeout=15)


def _git_value(root: Path, *args: str) -> str:
    result = _git(root, *args)
    if result.returncode:
        raise OwnershipError(result.stderr.strip() or "Git identity query failed")
    return result.stdout.removesuffix("\n")


def resolve_ownership(project_root: Path) -> dict:
    result = {"checkout_kind": "unresolved", "external_ops_allowed": False,
              "primary_checkout_path": None, "ownership_error": None}
    try:
        root = project_root.resolve(strict=True)
        if not root.is_dir():
            raise OwnershipError("Project root is not a directory")
        probe = _git(root, "rev-parse", "--is-bare-repository")
        if probe.returncode:
            # A failed executable, corrupt gitfile, safe.directory denial, or bare
            # administration directory is not an independent non-Git project.
            markers = any((p / ".git").exists() or (p / ".git").is_symlink()
                          or ((p / "HEAD").exists() and (p / "objects").is_dir())
                          for p in (root, *root.parents))
            not_git = "fatal: not a git repository (or any of the parent directories): .git"
            if probe.returncode == 128 and probe.stderr.strip() == not_git and not markers:
                result.update(checkout_kind="standalone", external_ops_allowed=True)
                return result
            raise OwnershipError(probe.stderr.strip() or "Git discovery failed")
        if probe.stdout.strip() != "false":
            raise OwnershipError("Bare repository has no usable primary checkout")
        current = Path(_git_value(root, "rev-parse", "--show-toplevel")).resolve(strict=True)
        common = Path(_git_value(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve(strict=True)
        current_git = Path(_git_value(root, "rev-parse", "--path-format=absolute", "--git-dir")).resolve(strict=True)
        raw = _git_value(root, "worktree", "list", "--porcelain", "-z")
        entries = []
        for record in raw.split("\0\0"):
            fields = record.split("\0")
            if fields[0].startswith("worktree "):
                entries.append((Path(fields[0][9:]).resolve(), "bare" in fields))
        if not entries or entries[0][1]:
            raise OwnershipError("Git worktree topology has no verified primary checkout")
        # A separate git-dir/submodule may list its administrative directory as
        # the first path. Only the non-linked checkout can prove its own root
        # directly by having git-dir == common-dir; never guess for a linked one.
        if current_git == common:
            primary = current
        else:
            if current not in [p for p, _ in entries]:
                raise OwnershipError("Current checkout is absent from Git worktree topology")
            primary = entries[0][0]
        if not primary.is_dir():
            raise OwnershipError("Primary checkout is unavailable")
        primary_top = Path(_git_value(primary, "rev-parse", "--show-toplevel")).resolve(strict=True)
        primary_common = Path(_git_value(primary, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve(strict=True)
        primary_git = Path(_git_value(primary, "rev-parse", "--path-format=absolute", "--git-dir")).resolve(strict=True)
        if primary_top != primary or primary_common != common or primary_git != common:
            raise OwnershipError("Primary checkout administrative identity does not match")
        kind = "primary" if current == primary else "linked"
        result.update(checkout_kind=kind, external_ops_allowed=kind == "primary",
                      primary_checkout_path=str(primary))
    except (OwnershipError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        result["ownership_error"] = str(exc)
    return result


def require_external_owner(project_root: Path) -> dict:
    owner = resolve_ownership(project_root)
    if not owner["external_ops_allowed"]:
        detail = owner["ownership_error"] or "linked Worktrees use local files only"
        raise OwnershipError(f"External Vault operations denied ({owner['checkout_kind']}): {detail}")
    return owner


def validate_vault_path(project_root: Path) -> Path:
    """Resolve the fixed project Vault without permitting whole-Vault symlinks."""
    root = project_root.resolve()
    expected = root / ".maxa"
    if expected.is_symlink():
        raise OwnershipError("A whole-Vault .maxa symlink is not a project-local Vault")
    resolved = expected.resolve()
    if not resolved.is_relative_to(root):
        raise OwnershipError("Vault root must be the selected project's own .maxa directory")
    return resolved
