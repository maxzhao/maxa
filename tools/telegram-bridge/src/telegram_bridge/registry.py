from __future__ import annotations

import os

from .store import Store
from .timeutil import now_ts


def _pid_is_alive(pid: int | None) -> bool:
    if pid is None:
        return True
    try:
        pid_int = int(pid)
    except (TypeError, ValueError):
        return True
    if pid_int <= 0:
        return False
    try:
        os.kill(pid_int, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class Registry:
    def __init__(self, store: Store, heartbeat_ttl: int = 90):
        self.store = store
        self.heartbeat_ttl = heartbeat_ttl

    @property
    def alive_after(self) -> int:
        return now_ts() - self.heartbeat_ttl

    def primary_for(self, project_root: str, save_id: str) -> str | None:
        return self.session_status(project_root, save_id)[1]

    def is_primary(self, instance_id: str, project_root: str, save_id: str) -> bool:
        return self.primary_for(project_root, save_id) == instance_id

    def session_status(self, project_root: str, save_id: str) -> tuple[str, str | None]:
        rows = [row for row in self.store.open_chats_for_session(project_root, save_id, self.alive_after) if _pid_is_alive(row["pid"])]
        if not rows:
            return "bound_inactive", None
        primary = rows[0]["instance_id"]
        if len(rows) > 1:
            return "bound_duplicate", primary
        running = bool(rows[0]["running"])
        return ("running" if running else "bound_active"), primary
