#!/usr/bin/env python3
"""Wait for the next pending Obsidian feedback file.

This script is intentionally small and dependency-free. It does not process
feedback itself; it only resolves the target vault, checks
inbox/feedback/pending, and blocks until a Markdown feedback file is available.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Iterable

DEFAULT_FEEDBACK_DIR = "inbox/feedback"
STATE_DIRS = ("pending", "done", "failed", "archive")
CHAT_BUFFER_CHECK_INTERVAL = 2.0
CHAT_CLOSED_EXIT_CODE = 3
REMOTE_EXPR_TIMEOUT = 2.0
IGNORED_SUFFIXES = (
    ".swp",
    ".swo",
    ".tmp",
    ".temp",
    ".part",
    ".crdownload",
)


class ChatBufferClosed(RuntimeError):
    """Raised when the Maxa AI Chat buffer that started the wait is gone."""


def _remote_expr(server: str, expr: str) -> str | None:
    """Evaluate a Vim expression through Neovim RPC.

    The feedback watcher is commonly launched from inside MaxaAI. In that
    case Neovim exports the listening socket as $NVIM. Querying the host editor
    lets this long-running helper stop itself once the originating chat buffer is
    closed, without requiring callers to pass a buffer id explicitly.
    """

    if not server:
        return None

    try:
        completed = subprocess.run(
            ["nvim", "--server", server, "--remote-expr", expr],
            check=False,
            capture_output=True,
            text=True,
            timeout=REMOTE_EXPR_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


class NvimChatBufferWatch:
    """Best-effort lifecycle watch for the active Maxa AI chat buffer."""

    def __init__(
        self,
        server: str,
        bufnr: int,
        interval: float = CHAT_BUFFER_CHECK_INTERVAL,
    ):
        self.server = server
        self.bufnr = bufnr
        self.interval = interval
        self._next_check = time.monotonic() + interval

    @classmethod
    def discover(cls) -> "NvimChatBufferWatch | None":
        server = os.environ.get("NVIM") or os.environ.get("NVIM_LISTEN_ADDRESS")
        if not server:
            return None

        expr = "luaeval('(function() local function is_chat_buf(buf) if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return false end if vim.bo[buf].filetype ~= \"maxa_ai\" then return false end local ok, cc = pcall(require, \"maxa_ai\") if ok and type(cc.buf_get_chat) == \"function\" then local ok2, chat = pcall(cc.buf_get_chat, buf) return ok2 and chat ~= nil end return true end local cur = vim.api.nvim_get_current_buf() if is_chat_buf(cur) then return cur end for _, win in ipairs(vim.api.nvim_list_wins()) do local ok, buf = pcall(vim.api.nvim_win_get_buf, win) if ok and is_chat_buf(buf) then return buf end end local found = {} for _, buf in ipairs(vim.api.nvim_list_bufs()) do if is_chat_buf(buf) then table.insert(found, buf) end end if #found == 1 then return found[1] end local ok, cc = pcall(require, \"maxa_ai\") if ok and type(cc.last_chat) == \"function\" then local ok2, chat = pcall(cc.last_chat) if ok2 and chat and chat.bufnr and is_chat_buf(chat.bufnr) then return chat.bufnr end end if #found > 0 then return found[#found] end return 0 end)()')"
        output = _remote_expr(server, expr)
        try:
            bufnr = int(output or "0")
        except ValueError:
            bufnr = 0

        if bufnr <= 0:
            return None
        return cls(server, bufnr)

    def _query_alive(self) -> bool | None:
        expr = "luaeval('(function(buf) if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then return 0 end if vim.bo[buf].filetype ~= \"maxa_ai\" then return 0 end local ok, cc = pcall(require, \"maxa_ai\") if ok and type(cc.buf_get_chat) == \"function\" then local ok2, chat = pcall(cc.buf_get_chat, buf) if not ok2 or chat == nil then return 0 end end return 1 end)(" + str(self.bufnr) + ")')"
        output = _remote_expr(self.server, expr)
        if output is None:
            # Remote checks are a best-effort guard. If Neovim is temporarily busy
            # or unreachable, do not kill an otherwise valid feedback wait.
            return None
        return output.strip() == "1"

    def raise_if_closed(self, *, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now < self._next_check:
            return
        self._next_check = now + self.interval
        alive = self._query_alive()
        if alive is False:
            raise ChatBufferClosed


def expand_path(value: str | os.PathLike[str]) -> Path:
    return Path(value).expanduser().resolve()


def resolve_vault(vault_arg: str | None) -> Path:
    if vault_arg:
        vault = expand_path(vault_arg)
        if not vault.exists() or not vault.is_dir():
            raise SystemExit(f"Vault does not exist or is not a directory: {vault}")
        return vault

    project_vault = (Path.cwd() / ".maxa").resolve()
    if project_vault.exists() and project_vault.is_dir():
        return project_vault

    raise SystemExit(
        "Unable to infer vault. Pass --vault <path>, or run from a project "
        "with .maxa."
    )


def ensure_feedback_dirs(feedback_root: Path, create_dirs: bool) -> None:
    if not create_dirs:
        return
    for name in STATE_DIRS:
        (feedback_root / name).mkdir(parents=True, exist_ok=True)


def is_feedback_file(path: Path) -> bool:
    if not path.is_file():
        return False
    name = path.name
    if name.startswith("."):
        return False
    if path.suffix.lower() != ".md":
        return False
    return not any(name.endswith(suffix) for suffix in IGNORED_SUFFIXES)


def pending_files(pending_dir: Path) -> list[Path]:
    if not pending_dir.exists():
        return []
    files = [p for p in pending_dir.iterdir() if is_feedback_file(p)]
    files.sort(key=lambda p: (p.stat().st_mtime_ns, p.name))
    return files


def wait_until_stable(
    path: Path,
    stable_seconds: float,
    chat_watch: NvimChatBufferWatch | None = None,
) -> bool:
    """Return True once size/mtime stay unchanged for stable_seconds."""
    if chat_watch:
        chat_watch.raise_if_closed()

    if stable_seconds <= 0:
        return path.exists() and path.is_file()

    last_signature: tuple[int, int] | None = None
    stable_since = time.monotonic()

    while True:
        if chat_watch:
            chat_watch.raise_if_closed()

        try:
            stat = path.stat()
        except FileNotFoundError:
            return False

        signature = (stat.st_size, stat.st_mtime_ns)
        now = time.monotonic()
        if signature != last_signature:
            last_signature = signature
            stable_since = now

        if now - stable_since >= stable_seconds:
            return True

        time.sleep(min(0.1, max(stable_seconds / 3, 0.01)))


def sleep_with_chat_watch(seconds: float, chat_watch: NvimChatBufferWatch | None) -> None:
    """Sleep while periodically aborting when the originating chat buffer closes."""
    deadline = time.monotonic() + max(seconds, 0.0)
    while True:
        if chat_watch:
            chat_watch.raise_if_closed()

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 0.5))


def build_result(
    *,
    status: str,
    vault: Path,
    feedback_root: Path,
    pending_dir: Path,
    paths: Iterable[Path],
    total_pending: int,
) -> dict[str, object]:
    path_list = [str(p) for p in paths]
    return {
        "status": status,
        "vault": str(vault),
        "feedback_dir": str(feedback_root),
        "pending_dir": str(pending_dir),
        "count": len(path_list),
        "total_pending": total_pending,
        "path": path_list[0] if path_list else None,
        "paths": path_list,
    }


def emit(result: dict[str, object], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        return

    paths = result.get("paths") or []
    if paths:
        for path in paths:
            print(path, flush=True)
    else:
        print(result.get("status", "unknown"), flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Return pending Obsidian feedback Markdown files immediately, or "
            "block until one appears. By default it waits forever."
        )
    )
    parser.add_argument(
        "--vault",
        help=(
            "Vault root. Defaults to ./.maxa when present, "
            "otherwise the current directory's .maxa."
        ),
    )
    parser.add_argument(
        "--feedback-dir",
        default=DEFAULT_FEEDBACK_DIR,
        help="Feedback root relative to the vault. Default: inbox/feedback",
    )
    parser.add_argument(
        "--pending-dir",
        help=(
            "Explicit pending directory. May be absolute or relative to the "
            "vault. Overrides --feedback-dir/pending."
        ),
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Return all currently pending feedback files instead of only the oldest one.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON.",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=1.0,
        help="Polling interval in seconds while waiting. Default: 1.0",
    )
    parser.add_argument(
        "--stable-seconds",
        type=float,
        default=0.3,
        help="Require file size/mtime to be stable before returning. Default: 0.3",
    )
    parser.add_argument(
        "--wait-timeout",
        type=float,
        default=None,
        help=(
            "Maximum seconds to wait. Omit or pass a negative value to wait "
            "forever. Use 0 for a non-blocking check."
        ),
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Check once and exit if no pending feedback exists.",
    )
    parser.add_argument(
        "--no-create-dirs",
        action="store_true",
        help="Do not create inbox/feedback/{pending,done,failed,archive} when missing.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])

    if args.poll_interval <= 0:
        raise SystemExit("--poll-interval must be > 0")
    if args.stable_seconds < 0:
        raise SystemExit("--stable-seconds must be >= 0")

    vault = resolve_vault(args.vault)
    feedback_root = vault / args.feedback_dir

    if args.pending_dir:
        pending_dir = Path(args.pending_dir).expanduser()
        if not pending_dir.is_absolute():
            pending_dir = vault / pending_dir
        pending_dir = pending_dir.resolve()
        feedback_root = pending_dir.parent

    ensure_feedback_dirs(feedback_root, create_dirs=not args.no_create_dirs)
    pending_dir = pending_dir if args.pending_dir else feedback_root / "pending"

    timeout = args.wait_timeout
    wait_forever = timeout is None or timeout < 0
    deadline = None if wait_forever else time.monotonic() + timeout
    chat_watch = NvimChatBufferWatch.discover()

    try:
        while True:
            if chat_watch:
                chat_watch.raise_if_closed()

            files = pending_files(pending_dir)
            total_pending = len(files)
            if files:
                selected = files if args.all else files[:1]
                stable = [
                    p
                    for p in selected
                    if wait_until_stable(p, args.stable_seconds, chat_watch)
                ]
                if stable:
                    emit(
                        build_result(
                            status="pending",
                            vault=vault,
                            feedback_root=feedback_root,
                            pending_dir=pending_dir,
                            paths=stable,
                            total_pending=total_pending,
                        ),
                        args.json,
                    )
                    return 0

            if args.once or (deadline is not None and time.monotonic() >= deadline):
                emit(
                    build_result(
                        status="timeout" if not args.once else "none",
                        vault=vault,
                        feedback_root=feedback_root,
                        pending_dir=pending_dir,
                        paths=[],
                        total_pending=0,
                    ),
                    args.json,
                )
                return 2

            if deadline is None:
                sleep_for = args.poll_interval
            else:
                sleep_for = min(args.poll_interval, max(deadline - time.monotonic(), 0.0))
            sleep_with_chat_watch(sleep_for, chat_watch)
    except ChatBufferClosed:
        emit(
            build_result(
                status="chat_closed",
                vault=vault,
                feedback_root=feedback_root,
                pending_dir=pending_dir,
                paths=[],
                total_pending=0,
            ),
            args.json,
        )
        return CHAT_CLOSED_EXIT_CODE


if __name__ == "__main__":
    raise SystemExit(main())
