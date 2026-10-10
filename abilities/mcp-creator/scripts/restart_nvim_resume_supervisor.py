#!/usr/bin/env python3
"""tmux supervisor for Maxa Neovim restart-resume.

This process is started detached from the old Neovim process. It waits for the
old PID to exit, then starts a fresh Neovim in the same tmux pane and passes the
pending resume file via --cmd g:maxa_restart_resume_file.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main() -> int:
    parser = argparse.ArgumentParser(description="Restart Neovim in a tmux pane and resume a Maxa chat")
    parser.add_argument("--pane", required=True, help="tmux pane id, e.g. %%3")
    parser.add_argument("--pid", required=True, type=int, help="old Neovim PID")
    parser.add_argument("--cwd", required=True, help="project working directory")
    parser.add_argument("--resume-file", required=True, help="pending resume JSON file")
    parser.add_argument("--nvim", default="nvim", help="Neovim executable")
    parser.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for old Neovim to exit")
    parser.add_argument("--cutover-command-file", help="explicit local JSON argv run after old-process exit, before startup")
    parser.add_argument("--resume-variable", default="maxa_restart_resume_file", help="explicit startup variable for a namespace cutover")
    args = parser.parse_args()

    cwd = Path(args.cwd).expanduser().resolve()
    resume_file = Path(args.resume_file).expanduser().resolve()

    deadline = time.time() + args.timeout
    while time.time() < deadline and pid_alive(args.pid):
        time.sleep(0.1)

    if pid_alive(args.pid):
        print(f"Old Neovim PID {args.pid} did not exit before timeout", file=sys.stderr)
        return 2

    if args.cutover_command_file:
        command = json.loads(Path(args.cutover_command_file).read_text())
        if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
            print("Invalid cutover command argv", file=sys.stderr)
            return 2
        result = subprocess.run(command, cwd=cwd)
        if result.returncode != 0:
            print(f"Cutover failed with exit {result.returncode}; Neovim was not started", file=sys.stderr)
            return result.returncode
        if not resume_file.is_file():
            print("Cutover did not publish its pending resume file", file=sys.stderr)
            return 2

    nvim_cmd = " ".join([
        shlex.quote(args.nvim),
        "--cmd",
        shlex.quote("let g:" + args.resume_variable + "=" + repr(str(resume_file))),
    ])
    shell_cmd = "cd " + shlex.quote(str(cwd)) + " && " + nvim_cmd

    pane_check = run(["tmux", "display-message", "-p", "-t", args.pane, "#{pane_id}"])
    if pane_check.returncode != 0 or not pane_check.stdout.strip():
        print(
            pane_check.stderr or pane_check.stdout or f"target tmux pane no longer exists: {args.pane}",
            file=sys.stderr,
        )
        return pane_check.returncode or 1

    result = run(["tmux", "send-keys", "-t", args.pane, shell_cmd, "Enter"])
    if result.returncode != 0:
        print(result.stderr or result.stdout or "tmux send-keys failed", file=sys.stderr)
        return result.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
