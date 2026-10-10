#!/usr/bin/env python3
"""Isolated command supervisor for mcpx execute_command.

Every command runs in a fresh session/process group. PTY mode allocates a pseudo
terminal; non-PTY mode keeps stdout and stderr separate. Timeout and cancellation
terminate only the isolated command group, never Neovim's process group.
"""

from __future__ import annotations

import ctypes
import errno
import json
import os
import pty
import select
import selectors
import signal
import subprocess
import sys
import time
from typing import BinaryIO, Optional


proc: Optional[subprocess.Popen[bytes]] = None
command_pgid: Optional[int] = None
master_fd: Optional[int] = None
termination_reason: Optional[str] = None


def _exit_code(returncode: int) -> int:
    return 128 + abs(returncode) if returncode < 0 else returncode


def _set_parent_death_signal() -> None:
    """Kill the direct command child if this supervisor disappears on Linux."""
    if not sys.platform.startswith("linux"):
        return
    libc = ctypes.CDLL(None, use_errno=True)
    PR_SET_PDEATHSIG = 1
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) != 0:
        os._exit(127)


def _validated_command_pgid() -> Optional[int]:
    if proc is None or command_pgid is None or proc.pid <= 1:
        return None
    pgid = command_pgid
    # start_new_session=True must make the child both session and group leader.
    # Refuse broad signaling if that invariant is ever broken. Keep the captured
    # PGID usable after the leader exits so TERM-ignoring descendants are reaped.
    if pgid != proc.pid or pgid in {os.getpgrp(), os.getpid(), os.getppid()}:
        sys.stderr.write(
            f"mcpx supervisor: refusing unsafe process-group signal "
            f"(child={proc.pid}, pgid={pgid}, self_pgid={os.getpgrp()})\n"
        )
        sys.stderr.flush()
        return None
    return pgid


def terminate_group(sig: signal.Signals = signal.SIGTERM) -> None:
    pgid = _validated_command_pgid()
    if pgid is None:
        return
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    except Exception as exc:
        try:
            sys.stderr.write(f"mcpx supervisor: failed to kill process group {pgid}: {exc}\n")
            sys.stderr.flush()
        except Exception:
            pass


def _group_exists() -> bool:
    pgid = _validated_command_pgid()
    if pgid is None:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def terminate_group_with_grace() -> None:
    if proc is None or not _group_exists():
        return
    terminate_group(signal.SIGTERM)
    deadline = time.monotonic() + 2.0
    while _group_exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if _group_exists():
        terminate_group(signal.SIGKILL)
    try:
        proc.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        pass


def handle_signal(signum: int, _frame) -> None:
    global termination_reason
    termination_reason = f"signal:{signum}"
    terminate_group_with_grace()
    raise SystemExit(128 + signum)


def _write(stream: BinaryIO, data: bytes) -> None:
    stream.write(data)
    stream.flush()


def _run_pty(argv: list[str], cwd: str, env: dict[str, str], deadline: Optional[float]) -> int:
    global proc, command_pgid, master_fd, termination_reason
    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            start_new_session=True,
            preexec_fn=_set_parent_death_signal,
        )
    finally:
        os.close(slave_fd)
    command_pgid = proc.pid

    while True:
        if deadline is not None and time.monotonic() >= deadline and proc.poll() is None:
            termination_reason = "timeout"
            terminate_group_with_grace()
        returncode = proc.poll()
        try:
            readable, _, _ = select.select([master_fd], [], [], 0.1)
        except InterruptedError:
            continue
        if readable:
            try:
                data = os.read(master_fd, 8192)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    data = b""
                else:
                    raise
            if data:
                _write(sys.stdout.buffer, data)
            elif returncode is not None:
                break
        elif returncode is not None:
            break

    os.close(master_fd)
    master_fd = None
    return _exit_code(proc.wait())


def _run_piped(argv: list[str], cwd: str, env: dict[str, str], deadline: Optional[float]) -> int:
    global proc, command_pgid, termination_reason
    proc = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=True,
        start_new_session=True,
        preexec_fn=_set_parent_death_signal,
    )
    command_pgid = proc.pid
    assert proc.stdout is not None and proc.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ, sys.stdout.buffer)
    selector.register(proc.stderr, selectors.EVENT_READ, sys.stderr.buffer)

    while selector.get_map():
        if deadline is not None and time.monotonic() >= deadline and proc.poll() is None:
            termination_reason = "timeout"
            terminate_group_with_grace()
        for key, _ in selector.select(0.1):
            data = os.read(key.fileobj.fileno(), 8192)
            if data:
                _write(key.data, data)
            else:
                selector.unregister(key.fileobj)
                key.fileobj.close()
    selector.close()
    return _exit_code(proc.wait())


def main() -> int:
    global termination_reason
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: execute_command_supervisor.py <config.json>\n")
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as config_file:
        config = json.load(config_file)

    command = config.get("command")
    literal_argv = config.get("argv")
    cwd = config["cwd"]
    shell = config.get("shell") or "/bin/sh"
    shellcmdflag = config.get("shellcmdflag") or "-c"
    use_pty = bool(config.get("pty", False))
    timeout = float(config.get("timeout") or 0)
    deadline = time.monotonic() + timeout if timeout > 0 else None
    env = os.environ.copy()
    env.update(config.get("env") or {})
    if literal_argv is not None:
        if (
            not isinstance(literal_argv, list)
            or not literal_argv
            or not all(isinstance(value, str) for value in literal_argv)
            or not literal_argv[0].strip()
        ):
            sys.stderr.write("execute_command_supervisor.py: argv must be a nonempty string array\n")
            return 2
        argv = literal_argv
    elif isinstance(command, str) and command:
        argv = [shell, shellcmdflag, command]
    else:
        sys.stderr.write("execute_command_supervisor.py: command or argv is required\n")
        return 2

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGHUP, handle_signal)

    code = _run_pty(argv, cwd, env, deadline) if use_pty else _run_piped(argv, cwd, env, deadline)
    if termination_reason == "timeout":
        # Machine-readable protocol line for the Lua wrapper. It is filtered from
        # normal output and preserves the public timeout status/result contract.
        sys.stderr.write("__MCPX_COMMAND_TIMEOUT__\n")
        return 124
    return code


if __name__ == "__main__":
    raise SystemExit(main())
