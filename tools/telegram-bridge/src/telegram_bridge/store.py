from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any

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


SCHEMA = """
CREATE TABLE IF NOT EXISTS nvim_instances (
  instance_id TEXT PRIMARY KEY,
  pid INTEGER,
  cwd TEXT,
  project_root TEXT,
  started_at INTEGER NOT NULL,
  registered_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  version TEXT
);

CREATE TABLE IF NOT EXISTS open_chats (
  instance_id TEXT NOT NULL,
  project_root TEXT NOT NULL,
  save_id TEXT NOT NULL,
  title TEXT,
  adapter TEXT,
  model TEXT,
  running INTEGER NOT NULL DEFAULT 0,
  notify_active INTEGER NOT NULL DEFAULT 0,
  message_count INTEGER,
  token_count INTEGER,
  token_limit INTEGER,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (instance_id, project_root, save_id)
);

CREATE TABLE IF NOT EXISTS pending_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_root TEXT NOT NULL,
  save_id TEXT NOT NULL,
  topic_id INTEGER NOT NULL,
  telegram_message_id INTEGER,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  target_instance_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  delivered_at INTEGER
);

CREATE TABLE IF NOT EXISTS dedupe (
  key TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS notification_topics (
  group_id INTEGER PRIMARY KEY,
  topic_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS ask_topics (
  project_root TEXT NOT NULL,
  save_id TEXT NOT NULL,
  group_id INTEGER NOT NULL,
  topic_id INTEGER NOT NULL,
  topic_title TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (project_root, save_id)
);

CREATE TABLE IF NOT EXISTS tracked_topics (
  group_id INTEGER NOT NULL,
  topic_id INTEGER NOT NULL,
  project_root TEXT,
  save_id TEXT,
  PRIMARY KEY (group_id, topic_id)
);

CREATE TABLE IF NOT EXISTS human_assist_requests (
  request_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  chat_id INTEGER NOT NULL,
  topic_id INTEGER,
  telegram_message_id INTEGER,
  prompt_text TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  result_json TEXT,
  expires_at INTEGER,
  created_at INTEGER NOT NULL,
  completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_human_assist_message
  ON human_assist_requests(chat_id, telegram_message_id, status);

CREATE TABLE IF NOT EXISTS human_assist_cancellations (
  request_id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_upload_requests (
  request_id TEXT PRIMARY KEY,
  instance_id TEXT NOT NULL,
  project_root TEXT NOT NULL,
  save_id TEXT NOT NULL,
  session_id TEXT NOT NULL UNIQUE,
  chat_id INTEGER NOT NULL,
  topic_id INTEGER,
  telegram_message_id INTEGER,
  status TEXT NOT NULL DEFAULT 'creating',
  result_path TEXT,
  result_text TEXT,
  error_code TEXT,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_chat_upload_message
  ON chat_upload_requests(chat_id, topic_id, telegram_message_id, status);
CREATE INDEX IF NOT EXISTS idx_chat_upload_caller
  ON chat_upload_requests(instance_id, project_root, save_id, status);

CREATE TABLE IF NOT EXISTS schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""


class Store:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        if self.path != Path(":memory:"):
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.init_schema()
        self.recover_interrupted_chat_uploads()

    def init_schema(self) -> None:
        self.conn.executescript(SCHEMA)
        open_chat_columns = {row["name"] for row in self.conn.execute("PRAGMA table_info(open_chats)")}
        if "notify_active" not in open_chat_columns:
            self.conn.execute("ALTER TABLE open_chats ADD COLUMN notify_active INTEGER NOT NULL DEFAULT 0")
        pending_event_columns = {row["name"] for row in self.conn.execute("PRAGMA table_info(pending_events)")}
        if "target_instance_id" not in pending_event_columns:
            self.conn.execute("ALTER TABLE pending_events ADD COLUMN target_instance_id TEXT")
        human_assist_columns = list(self.conn.execute("PRAGMA table_info(human_assist_requests)"))
        expires_column = next((row for row in human_assist_columns if row["name"] == "expires_at"), None)
        if expires_column and int(expires_column["notnull"] or 0) == 1:
            legacy_exists = self.conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='human_assist_requests_legacy'"
            ).fetchone()
            if legacy_exists:
                raise RuntimeError("incomplete human_assist_requests migration: legacy table exists")
            self.conn.executescript(
                """
                BEGIN IMMEDIATE;
                DROP INDEX IF EXISTS idx_human_assist_message;
                ALTER TABLE human_assist_requests RENAME TO human_assist_requests_legacy;
                CREATE TABLE human_assist_requests (
                  request_id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  chat_id INTEGER NOT NULL,
                  topic_id INTEGER,
                  telegram_message_id INTEGER,
                  prompt_text TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  result_json TEXT,
                  expires_at INTEGER,
                  created_at INTEGER NOT NULL,
                  completed_at INTEGER
                );
                INSERT INTO human_assist_requests
                SELECT * FROM human_assist_requests_legacy;
                DROP TABLE human_assist_requests_legacy;
                CREATE INDEX idx_human_assist_message
                  ON human_assist_requests(chat_id, telegram_message_id, status);
                COMMIT;
                """
            )
        tracked_columns = {row["name"] for row in self.conn.execute("PRAGMA table_info(tracked_topics)")}
        if "project_root" not in tracked_columns:
            self.conn.execute("ALTER TABLE tracked_topics ADD COLUMN project_root TEXT")
        if "save_id" not in tracked_columns:
            self.conn.execute("ALTER TABLE tracked_topics ADD COLUMN save_id TEXT")
        # Retain exact ask/notify topic identity; observed topics without one
        # cannot safely be classified as inactive sessions.
        for table in ("ask_topics",):
            self.conn.execute(
                "INSERT OR IGNORE INTO tracked_topics(group_id, topic_id, project_root, save_id) "
                f"SELECT group_id, topic_id, project_root, save_id FROM {table} WHERE topic_id > 1"
            )
            self.conn.execute(
                "UPDATE tracked_topics SET "
                f"project_root=(SELECT s.project_root FROM {table} s WHERE s.group_id=tracked_topics.group_id AND s.topic_id=tracked_topics.topic_id LIMIT 1), "
                f"save_id=(SELECT s.save_id FROM {table} s WHERE s.group_id=tracked_topics.group_id AND s.topic_id=tracked_topics.topic_id LIMIT 1) "
                f"WHERE project_root IS NULL AND EXISTS (SELECT 1 FROM {table} s WHERE s.group_id=tracked_topics.group_id AND s.topic_id=tracked_topics.topic_id)"
            )
        self.conn.execute(
            "INSERT OR IGNORE INTO tracked_topics(group_id, topic_id) "
            "SELECT group_id, topic_id FROM notification_topics WHERE topic_id > 1"
        )
        # Retire pre-change binding events only once; new TG input events must
        # survive subsequent service restarts. Preserve ask/notify/TG state.
        migrated = self.conn.execute("SELECT 1 FROM schema_meta WHERE key='notify_only_migration'").fetchone()
        if not migrated:
            self.conn.execute("DROP TABLE IF EXISTS bindings")
            self.conn.execute(
                "DELETE FROM pending_events WHERE event_type IN "
                "('telegram_user_message', 'telegram_bridge_attach_request', 'telegram_bridge_detach_request', "
                "'telegram_bridge_unbind_request', 'telegram_bridge_close_request', "
                "'telegram_bridge_reset_request', 'telegram_bridge_history_attach_request')"
            )
            self.conn.execute("INSERT INTO schema_meta(key, value) VALUES ('notify_only_migration', '1')")
        self.conn.execute("INSERT OR REPLACE INTO schema_meta(key, value) VALUES ('version', '1')")
        self.conn.commit()

    def track_topic(self, group_id: int, topic_id: int, *, project_root: str | None = None, save_id: str | None = None) -> None:
        if group_id and topic_id > 1:
            self.conn.execute("INSERT OR IGNORE INTO tracked_topics(group_id, topic_id) VALUES (?, ?)", (group_id, topic_id))
            if project_root is not None and save_id is not None:
                self.conn.execute(
                    "UPDATE tracked_topics SET project_root=?, save_id=? WHERE group_id=? AND topic_id=?",
                    (project_root, save_id, group_id, topic_id),
                )
            self.conn.commit()

    def get_tracked_topic(self, group_id: int, topic_id: int) -> sqlite3.Row | None:
        return self.conn.execute(
            "SELECT * FROM tracked_topics WHERE group_id=? AND topic_id=?", (group_id, topic_id)
        ).fetchone()

    def list_tracked_topics(self, group_id: int) -> list[int]:
        return [int(row["topic_id"]) for row in self.conn.execute(
            "SELECT topic_id FROM tracked_topics WHERE group_id=? AND topic_id > 1 ORDER BY topic_id", (group_id,)
        )]

    def forget_topic(self, group_id: int, topic_id: int) -> None:
        with self.conn:
            self.conn.execute("DELETE FROM tracked_topics WHERE group_id=? AND topic_id=?", (group_id, topic_id))
            self.conn.execute("DELETE FROM ask_topics WHERE group_id=? AND topic_id=?", (group_id, topic_id))
            self.conn.execute("DELETE FROM notification_topics WHERE group_id=? AND topic_id=?", (group_id, topic_id))

    def close(self) -> None:
        self.conn.close()

    def register_instance(self, *, instance_id: str, pid: int | None, cwd: str | None, project_root: str | None, version: str | None) -> None:
        ts = now_ts()
        self.conn.execute(
            """
            INSERT INTO nvim_instances(instance_id, pid, cwd, project_root, started_at, registered_at, last_seen_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(instance_id) DO UPDATE SET
              pid=excluded.pid, cwd=excluded.cwd, project_root=excluded.project_root,
              last_seen_at=excluded.last_seen_at, version=excluded.version
            """,
            (instance_id, pid, cwd, project_root, ts, ts, ts, version),
        )
        self.conn.commit()

    def heartbeat(self, *, instance_id: str, open_chats: list[dict[str, Any]]) -> None:
        ts = now_ts()
        with self.conn:
            self.conn.execute("UPDATE nvim_instances SET last_seen_at=? WHERE instance_id=?", (ts, instance_id))
            self.conn.execute("DELETE FROM open_chats WHERE instance_id=?", (instance_id,))
            for chat in open_chats:
                self.conn.execute(
                    """
                    INSERT INTO open_chats(instance_id, project_root, save_id, title, adapter, model, running, notify_active, message_count, token_count, token_limit, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        instance_id,
                        chat["project_root"],
                        chat["save_id"],
                        chat.get("title"),
                        chat.get("adapter"),
                        chat.get("model"),
                        1 if chat.get("running") else 0,
                        1 if chat.get("notify_active") else 0,
                        chat.get("message_count"),
                        chat.get("token_count"),
                        chat.get("token_limit"),
                        ts,
                    ),
                )

    def get_ask_topic(self, project_root: str, save_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM ask_topics WHERE project_root=? AND save_id=?", (project_root, save_id)).fetchone()

    def get_ask_topic_by_topic(self, group_id: int, topic_id: int) -> sqlite3.Row | None:
        return self.conn.execute(
            "SELECT * FROM ask_topics WHERE group_id=? AND topic_id=?", (group_id, topic_id)
        ).fetchone()

    def set_ask_topic(self, project_root: str, save_id: str, *, group_id: int, topic_id: int, topic_title: str | None) -> None:
        ts = now_ts()
        self.conn.execute(
            """INSERT INTO ask_topics(project_root, save_id, group_id, topic_id, topic_title, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(project_root, save_id) DO UPDATE SET
                 group_id=excluded.group_id, topic_id=excluded.topic_id, topic_title=excluded.topic_title, updated_at=excluded.updated_at""",
            (project_root, save_id, group_id, topic_id, topic_title, ts, ts),
        )
        self.conn.commit()
        self.track_topic(group_id, topic_id, project_root=project_root, save_id=save_id)

    def delete_ask_topic(self, project_root: str, save_id: str) -> None:
        self.conn.execute("DELETE FROM ask_topics WHERE project_root=? AND save_id=?", (project_root, save_id))
        self.conn.commit()

    def get_open_chat_title(self, project_root: str, save_id: str) -> str | None:
        row = self.conn.execute(
            "SELECT title FROM open_chats WHERE project_root=? AND save_id=? AND title IS NOT NULL ORDER BY updated_at DESC LIMIT 1",
            (project_root, save_id),
        ).fetchone()
        return str(row["title"]) if row else None

    def list_open_chats(self) -> list[sqlite3.Row]:
        return list(self.conn.execute("SELECT * FROM open_chats ORDER BY project_root, title, save_id"))

    def list_live_open_chats(self, alive_after: int) -> list[sqlite3.Row]:
        rows = list(self.conn.execute(
            """
            SELECT
              oc.*,
              ni.registered_at,
              ni.last_seen_at,
              ni.pid
            FROM open_chats oc
            JOIN nvim_instances ni ON ni.instance_id = oc.instance_id
            WHERE ni.last_seen_at >= ?
            ORDER BY oc.project_root, COALESCE(oc.title, ''), oc.save_id, ni.registered_at ASC, oc.instance_id ASC
            """,
            (alive_after,),
        ))
        return [row for row in rows if _pid_is_alive(row["pid"])]

    def list_live_instances(self, alive_after: int, project_root: str | None = None) -> list[sqlite3.Row]:
        if project_root is None:
            rows = list(self.conn.execute(
                """
                SELECT * FROM nvim_instances
                WHERE last_seen_at >= ?
                ORDER BY registered_at ASC, instance_id ASC
                """,
                (alive_after,),
            ))
        else:
            rows = list(self.conn.execute(
                """
                SELECT * FROM nvim_instances
                WHERE project_root=? AND last_seen_at >= ?
                ORDER BY registered_at ASC, instance_id ASC
                """,
                (project_root, alive_after),
            ))
        return [row for row in rows if _pid_is_alive(row["pid"])]

    def open_chats_for_session(self, project_root: str, save_id: str, alive_after: int) -> list[sqlite3.Row]:
        rows = list(self.conn.execute(
            """
            SELECT oc.*, ni.registered_at, ni.last_seen_at, ni.pid
            FROM open_chats oc
            JOIN nvim_instances ni ON ni.instance_id = oc.instance_id
            WHERE oc.project_root=? AND oc.save_id=? AND ni.last_seen_at >= ?
            ORDER BY ni.registered_at ASC, ni.instance_id ASC
            """,
            (project_root, save_id, alive_after),
        ))
        return rows

    def primary_for_session(self, project_root: str, save_id: str, alive_after: int) -> sqlite3.Row | None:
        rows = self.open_chats_for_session(project_root, save_id, alive_after)
        return rows[0] if rows else None

    def open_chat_for_instance(self, *, instance_id: str, project_root: str, save_id: str, alive_after: int) -> sqlite3.Row | None:
        return self.conn.execute(
            """
            SELECT oc.*, ni.registered_at, ni.last_seen_at, ni.pid
            FROM open_chats oc
            JOIN nvim_instances ni ON ni.instance_id = oc.instance_id
            WHERE oc.instance_id=? AND oc.project_root=? AND oc.save_id=? AND ni.last_seen_at >= ?
            """,
            (instance_id, project_root, save_id, alive_after),
        ).fetchone()

    def has_inflight_user_message(self, project_root: str, save_id: str) -> bool:
        return self.conn.execute(
            "SELECT 1 FROM pending_events WHERE project_root=? AND save_id=? "
            "AND event_type='telegram_user_message' AND status IN ('pending', 'delivered') LIMIT 1",
            (project_root, save_id),
        ).fetchone() is not None

    def add_event(self, *, project_root: str, save_id: str, topic_id: int, telegram_message_id: int | None, event_type: str, payload: dict[str, Any], status: str = "pending", target_instance_id: str | None = None) -> int:
        cur = self.conn.execute(
            """
            INSERT INTO pending_events(project_root, save_id, topic_id, telegram_message_id, event_type, payload_json, target_instance_id, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (project_root, save_id, topic_id, telegram_message_id, event_type, json.dumps(payload, ensure_ascii=False), target_instance_id, status, now_ts()),
        )
        self.conn.commit()
        return int(cur.lastrowid)

    def poll_events(self, *, project_root: str, save_id: str, limit: int = 10, delivery_timeout: int = 120) -> list[sqlite3.Row]:
        stale_before = now_ts() - delivery_timeout
        return list(self.conn.execute(
            """
            SELECT * FROM pending_events
            WHERE project_root=? AND save_id=?
              AND target_instance_id IS NULL
              AND (status='pending' OR (status='delivered' AND COALESCE(delivered_at, 0) <= ?))
            ORDER BY id ASC LIMIT ?
            """,
            (project_root, save_id, stale_before, limit),
        ))

    def get_event(self, event_id: int) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM pending_events WHERE id=?", (event_id,)).fetchone()

    def mark_delivered(self, event_id: int) -> None:
        self.conn.execute("UPDATE pending_events SET status='delivered', delivered_at=? WHERE id=? AND status IN ('pending', 'delivered')", (now_ts(), event_id))
        self.conn.commit()

    def ack_event(self, event_id: int) -> None:
        self.conn.execute("UPDATE pending_events SET status='acked' WHERE id=?", (event_id,))
        self.conn.commit()

    def get_notification_topic(self, group_id: int) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM notification_topics WHERE group_id=?", (int(group_id),)).fetchone()

    def set_notification_topic(self, *, group_id: int, topic_id: int, title: str) -> None:
        ts = now_ts()
        self.conn.execute(
            """
            INSERT INTO notification_topics(group_id, topic_id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(group_id) DO UPDATE SET topic_id=excluded.topic_id, title=excluded.title, updated_at=excluded.updated_at
            """,
            (int(group_id), int(topic_id), title, ts, ts),
        )
        self.conn.commit()
        self.track_topic(group_id, topic_id)

    def reserve_human_assist_cancellation(self, request_id: str) -> None:
        ts = now_ts()
        with self.conn:
            self.conn.execute("DELETE FROM human_assist_cancellations WHERE created_at < ?", (ts - 86400,))
            self.conn.execute(
                "INSERT OR IGNORE INTO human_assist_cancellations(request_id, created_at) VALUES (?, ?)",
                (request_id, ts),
            )

    def has_human_assist_cancellation(self, request_id: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM human_assist_cancellations WHERE request_id=?",
            (request_id,),
        ).fetchone()
        return row is not None

    def create_human_assist_request(self, *, request_id: str, kind: str, chat_id: int, topic_id: int | None, telegram_message_id: int | None, prompt_text: str, payload: dict[str, Any], expires_at: int | None) -> None:
        self.conn.execute(
            """
            INSERT INTO human_assist_requests(request_id, kind, chat_id, topic_id, telegram_message_id, prompt_text, payload_json, status, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
            """,
            (request_id, kind, int(chat_id), topic_id, telegram_message_id, prompt_text, json.dumps(payload, ensure_ascii=False), int(expires_at) if expires_at is not None else None, now_ts()),
        )
        self.conn.commit()

    def get_human_assist_request(self, request_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM human_assist_requests WHERE request_id=?", (request_id,)).fetchone()

    def set_human_assist_destination(self, request_id: str, *, chat_id: int, topic_id: int | None) -> None:
        self.conn.execute(
            "UPDATE human_assist_requests SET chat_id=?, topic_id=? WHERE request_id=? AND status='pending'",
            (int(chat_id), topic_id, request_id),
        )
        self.conn.commit()

    def attach_human_assist_message(self, request_id: str, *, chat_id: int, topic_id: int | None, telegram_message_id: int) -> bool:
        cur = self.conn.execute(
            "UPDATE human_assist_requests SET chat_id=?, topic_id=?, telegram_message_id=? WHERE request_id=? AND status='pending'",
            (int(chat_id), topic_id, int(telegram_message_id), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def delete_human_assist_request(self, request_id: str) -> None:
        self.conn.execute("DELETE FROM human_assist_requests WHERE request_id=?", (request_id,))
        self.conn.commit()

    def find_pending_human_assist_by_message(self, *, chat_id: int, telegram_message_id: int) -> sqlite3.Row | None:
        return self.conn.execute(
            """
            SELECT * FROM human_assist_requests
            WHERE chat_id=? AND telegram_message_id=? AND status='pending'
            ORDER BY created_at DESC LIMIT 1
            """,
            (int(chat_id), int(telegram_message_id)),
        ).fetchone()

    def complete_human_assist_request(self, request_id: str, *, result: dict[str, Any]) -> bool:
        cur = self.conn.execute(
            """
            UPDATE human_assist_requests
            SET status='completed', result_json=?, completed_at=?
            WHERE request_id=? AND status='pending'
            """,
            (json.dumps(result, ensure_ascii=False), now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def cancel_human_assist_request(self, request_id: str, *, result: dict[str, Any]) -> bool:
        cur = self.conn.execute(
            """
            UPDATE human_assist_requests
            SET status='cancelled', result_json=?, completed_at=?
            WHERE request_id=? AND status='pending'
            """,
            (json.dumps(result, ensure_ascii=False), now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def expire_human_assist_request(self, request_id: str, *, result: dict[str, Any]) -> bool:
        cur = self.conn.execute(
            """
            UPDATE human_assist_requests
            SET status='expired', result_json=?, completed_at=?
            WHERE request_id=? AND status='pending'
            """,
            (json.dumps(result, ensure_ascii=False), now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def recover_interrupted_chat_uploads(self) -> int:
        from .upload_storage import UploadPathError, safe_session_dir

        rows = list(self.conn.execute("SELECT request_id, project_root, session_id FROM chat_upload_requests WHERE status='downloading'"))
        recovered = 0
        with self.conn:
            for row in rows:
                code = "download_interrupted"
                message = "download interrupted by bridge restart"
                session_dir = None
                try:
                    _, session_dir = safe_session_dir(str(row["project_root"]), str(row["session_id"]), create=False)
                except (OSError, UploadPathError):
                    code = "unsafe_upload_path"
                    message = "upload session path is unsafe after bridge restart"
                if session_dir is not None and session_dir.is_dir():
                    # Only traverse a proven lexical, non-symlink session owned by
                    # the upload root. Final files never match the staged pattern.
                    for partial in session_dir.glob(".upload-*.part"):
                        try:
                            if partial.is_file() and not partial.is_symlink():
                                partial.unlink()
                        except OSError:
                            pass
                cur = self.conn.execute(
                    "UPDATE chat_upload_requests SET status='pending', error_code=?, error_message=?, updated_at=? WHERE request_id=? AND status='downloading'",
                    (code, message, now_ts(), str(row["request_id"])),
                )
                recovered += cur.rowcount
        return recovered

    def create_chat_upload(self, *, request_id: str, instance_id: str, project_root: str, save_id: str, session_id: str, chat_id: int, topic_id: int | None) -> None:
        ts = now_ts()
        self.conn.execute(
            """INSERT INTO chat_upload_requests(request_id, instance_id, project_root, save_id, session_id, chat_id, topic_id, status, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, 'creating', ?, ?)""",
            (request_id, instance_id, project_root, save_id, session_id, int(chat_id), topic_id, ts, ts),
        )
        self.conn.commit()

    def get_chat_upload(self, request_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM chat_upload_requests WHERE request_id=?", (request_id,)).fetchone()

    def attach_chat_upload_message(self, request_id: str, *, chat_id: int, topic_id: int | None, telegram_message_id: int) -> bool:
        cur = self.conn.execute(
            "UPDATE chat_upload_requests SET chat_id=?, topic_id=?, telegram_message_id=?, status='pending', updated_at=? WHERE request_id=? AND status='creating'",
            (int(chat_id), topic_id, int(telegram_message_id), now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def find_pending_chat_upload_by_message(self, *, chat_id: int, topic_id: int | None, telegram_message_id: int) -> sqlite3.Row | None:
        return self.conn.execute(
            """SELECT * FROM chat_upload_requests
               WHERE chat_id=? AND COALESCE(topic_id, 0)=COALESCE(?, 0) AND telegram_message_id=? AND status='pending'
               ORDER BY created_at DESC LIMIT 1""",
            (int(chat_id), topic_id, int(telegram_message_id)),
        ).fetchone()

    def claim_chat_upload_download(self, request_id: str) -> bool:
        cur = self.conn.execute(
            "UPDATE chat_upload_requests SET status='downloading', updated_at=? WHERE request_id=? AND status='pending'",
            (now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def restore_chat_upload_pending(self, request_id: str, *, error_code: str | None = None, error_message: str | None = None) -> bool:
        cur = self.conn.execute(
            "UPDATE chat_upload_requests SET status='pending', error_code=?, error_message=?, updated_at=? WHERE request_id=? AND status='downloading'",
            (error_code, error_message, now_ts(), request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def complete_chat_upload(self, request_id: str, *, path: str | None, text: str | None, expected_status: str = "pending") -> bool:
        ts = now_ts()
        cur = self.conn.execute(
            """UPDATE chat_upload_requests SET status='completed', result_path=?, result_text=?, error_code=NULL, error_message=NULL, updated_at=?, completed_at=?
               WHERE request_id=? AND status=?""",
            (path, text, ts, ts, request_id, expected_status),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def cancel_chat_upload(self, request_id: str, *, instance_id: str, project_root: str, save_id: str) -> bool:
        ts = now_ts()
        cur = self.conn.execute(
            """UPDATE chat_upload_requests SET status='cancelled', updated_at=?, completed_at=?
               WHERE request_id=? AND instance_id=? AND project_root=? AND save_id=? AND status IN ('creating','pending','downloading')""",
            (ts, ts, request_id, instance_id, project_root, save_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def fail_chat_upload(self, request_id: str, *, code: str, message: str) -> bool:
        ts = now_ts()
        cur = self.conn.execute(
            """UPDATE chat_upload_requests SET status='failed', error_code=?, error_message=?, updated_at=?, completed_at=?
               WHERE request_id=? AND status IN ('creating','pending','downloading')""",
            (code[:64], message[:512], ts, ts, request_id),
        )
        self.conn.commit()
        return cur.rowcount == 1

    def cancel_orphaned_chat_uploads(self, *, alive_after: int) -> int:
        ts = now_ts()
        cur = self.conn.execute(
            """UPDATE chat_upload_requests SET status='cancelled', error_code='caller_inactive', error_message='caller chat is no longer active', updated_at=?, completed_at=?
               WHERE status IN ('creating','pending','downloading') AND NOT EXISTS (
                 SELECT 1 FROM open_chats oc JOIN nvim_instances ni ON ni.instance_id=oc.instance_id
                 WHERE oc.instance_id=chat_upload_requests.instance_id AND oc.project_root=chat_upload_requests.project_root
                   AND oc.save_id=chat_upload_requests.save_id AND ni.last_seen_at>=?
               )""",
            (ts, ts, int(alive_after)),
        )
        self.conn.commit()
        return cur.rowcount

    def claim_dedupe(self, key: str) -> bool:
        try:
            self.conn.execute("INSERT INTO dedupe(key, created_at) VALUES (?, ?)", (key, now_ts()))
            self.conn.commit()
            return True
        except sqlite3.IntegrityError:
            return False
