#!/usr/bin/env python3
"""Regression checks for execute_command supervisor isolation and timeout."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


SUPERVISOR = Path(__file__).with_name("execute_command_supervisor.py")


def run_supervisor(
    command: str | None = None,
    *,
    argv: list[str] | None = None,
    pty: bool,
    timeout: float = 5,
) -> subprocess.CompletedProcess[bytes]:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as config:
        json.dump(
            {
                "command": command,
                "argv": argv,
                "cwd": str(Path.cwd()),
                "shell": "/bin/bash",
                "shellcmdflag": "-c",
                "pty": pty,
                "timeout": timeout,
            },
            config,
        )
        config.flush()
        return subprocess.run(
            [sys.executable, str(SUPERVISOR), config.name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout + 6,
            check=False,
        )


def assert_dead(pid: int) -> None:
    for _ in range(30):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    raise AssertionError(f"descendant still alive after timeout: {pid}")


def main() -> int:
    separated = run_supervisor(
        "printf 'out\\n'; printf 'err\\n' >&2",
        pty=False,
    )
    assert separated.returncode == 0, separated
    assert separated.stdout == b"out\n", separated.stdout
    assert separated.stderr == b"err\n", separated.stderr

    literal_args = ["space value", ";", "$(printf injected)", "'quoted'", ""]
    literal = run_supervisor(
        argv=[sys.executable, "-c", "import json,sys;print(json.dumps(sys.argv[1:]))", *literal_args],
        pty=False,
    )
    assert literal.returncode == 0, literal
    assert json.loads(literal.stdout) == literal_args, literal.stdout

    terminal = run_supervisor("test -t 1 && printf 'tty-ok\n'", pty=True)
    assert terminal.returncode == 0, terminal
    assert b"tty-ok" in terminal.stdout, terminal.stdout

    with tempfile.NamedTemporaryFile("r", encoding="utf-8") as pid_file:
        timed = run_supervisor(
            f"(trap '' TERM; sleep 60) & echo $! > {pid_file.name}; wait",
            pty=False,
            timeout=0.2,
        )
        assert timed.returncode == 124, timed
        pid_file.seek(0)
        descendant_pid = int(pid_file.read().strip())
        assert_dead(descendant_pid)

    group_signal = run_supervisor(
        "trap 'exit 0' TERM; (sleep 0.1; kill -TERM 0) & wait",
        pty=False,
    )
    assert group_signal.returncode == 0, group_signal
    # Reaching this line proves kill(0) remained inside the command's isolated
    # process group instead of signaling this test runner or its terminal.
    print("execute_command supervisor isolation tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
