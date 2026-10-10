from __future__ import annotations

import sqlite3

from telegram_bridge.registry import Registry
from telegram_bridge.store import Store


def test_human_assist_expiry_column_migrates_to_nullable(tmp_path):
    path = tmp_path / "bridge.sqlite3"
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE human_assist_requests (
          request_id TEXT PRIMARY KEY, kind TEXT NOT NULL, chat_id INTEGER NOT NULL,
          topic_id INTEGER, telegram_message_id INTEGER, prompt_text TEXT NOT NULL,
          payload_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          result_json TEXT, expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
          completed_at INTEGER
        );
        CREATE INDEX idx_human_assist_message
          ON human_assist_requests(chat_id, telegram_message_id, status);
        INSERT INTO human_assist_requests
        VALUES ('old', 'prompt', 1, NULL, NULL, 'Choose', '{}', 'pending', NULL, 123, 100, NULL);
    """)
    conn.commit()
    conn.close()

    store = Store(path)
    expiry = next(row for row in store.conn.execute("PRAGMA table_info(human_assist_requests)") if row["name"] == "expires_at")
    assert expiry["notnull"] == 0
    assert store.get_human_assist_request("old")["expires_at"] == 123
    store.create_human_assist_request(
        request_id="never", kind="prompt", chat_id=1, topic_id=None,
        telegram_message_id=None, prompt_text="Choose", payload={}, expires_at=None,
    )
    assert store.get_human_assist_request("never")["expires_at"] is None
    assert store.conn.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_human_assist_message'").fetchone()
    store.close()
    reopened = Store(path)
    assert reopened.get_human_assist_request("old")["expires_at"] == 123


def test_cancelled_human_assist_request_rejects_late_message_attach():
    store = Store(":memory:")
    store.create_human_assist_request(
        request_id="race", kind="prompt", chat_id=1, topic_id=None,
        telegram_message_id=None, prompt_text="Choose", payload={}, expires_at=None,
    )
    assert store.cancel_human_assist_request("race", result={"success": False, "error": "cancelled"})
    assert not store.attach_human_assist_message(
        "race", chat_id=1, topic_id=None, telegram_message_id=99,
    )
    row = store.get_human_assist_request("race")
    assert row["status"] == "cancelled"
    assert row["telegram_message_id"] is None


def test_primary_election_registered_at_then_instance_id():
    store = Store(":memory:")
    store.register_instance(instance_id="b", pid=None, cwd=None, project_root="/p", version=None)
    store.register_instance(instance_id="a", pid=None, cwd=None, project_root="/p", version=None)
    store.conn.execute("UPDATE nvim_instances SET registered_at=registered_at-10 WHERE instance_id='b'")
    store.conn.commit()
    store.heartbeat(instance_id="b", open_chats=[{"project_root": "/p", "save_id": "s", "running": False}])
    store.heartbeat(instance_id="a", open_chats=[{"project_root": "/p", "save_id": "s", "running": False}])
    primary = Registry(store, heartbeat_ttl=90).primary_for("/p", "s")
    assert primary == "b"


def test_user_event_is_inflight_until_ack():
    store = Store(":memory:")
    event_id = store.add_event(project_root="/p", save_id="s", topic_id=42, telegram_message_id=7, event_type="telegram_user_message", payload={"text": "hi"})
    assert store.has_inflight_user_message("/p", "s")
    assert store.poll_events(project_root="/p", save_id="s")[0]["id"] == event_id
    store.mark_delivered(event_id)
    assert store.poll_events(project_root="/p", save_id="s") == []
    store.ack_event(event_id)
    assert not store.has_inflight_user_message("/p", "s")


def test_binding_migration_discards_only_old_db_state(tmp_path):
    path = tmp_path / "bridge.sqlite3"
    store = Store(path)
    store.set_ask_topic("/p", "s", group_id=-100, topic_id=43, topic_title="Ask")
    store.set_notification_topic(group_id=-100, topic_id=44, title="Notify")
    store.track_topic(-100, 47)
    store.close()

    # Model an installation created before the notify-only migration.
    with sqlite3.connect(path) as conn:
        conn.execute("CREATE TABLE bindings (project_root TEXT, save_id TEXT, group_id INTEGER, topic_id INTEGER)")
        conn.execute("INSERT INTO bindings VALUES ('/old', 's', -100, 47)")
        conn.execute("DELETE FROM schema_meta WHERE key='notify_only_migration'")
        conn.execute("INSERT INTO pending_events(project_root, save_id, topic_id, event_type, payload_json, status, created_at) VALUES ('/old', 's', 47, 'telegram_bridge_attach_request', '{}', 'pending', 1)")
    store = Store(path)
    assert store.conn.execute("SELECT 1 FROM sqlite_master WHERE name='bindings'").fetchone() is None
    assert store.get_ask_topic("/p", "s")["topic_id"] == 43
    assert store.get_notification_topic(-100)["topic_id"] == 44
    assert store.get_tracked_topic(-100, 47)["topic_id"] == 47
    assert (store.get_tracked_topic(-100, 43)["project_root"], store.get_tracked_topic(-100, 43)["save_id"]) == ("/p", "s")
    assert store.conn.execute("SELECT 1 FROM pending_events WHERE event_type='telegram_bridge_attach_request'").fetchone() is None
    store.add_event(project_root="/p", save_id="s", topic_id=43, telegram_message_id=8, event_type="telegram_user_message", payload={"text": "new"})
    store.close()
    reopened = Store(path)
    assert reopened.has_inflight_user_message("/p", "s")


def test_dedupe_claim_once():
    store = Store(":memory:")
    assert store.claim_dedupe("k") is True
    assert store.claim_dedupe("k") is False


def test_primary_election_ignores_dead_pid_before_heartbeat_ttl(monkeypatch):
    store = Store(":memory:")
    store.register_instance(instance_id="dead", pid=111, cwd=None, project_root="/p", version=None)
    store.register_instance(instance_id="alive", pid=222, cwd=None, project_root="/p", version=None)
    store.conn.execute("UPDATE nvim_instances SET registered_at=registered_at-10 WHERE instance_id='dead'")
    store.conn.commit()
    store.heartbeat(instance_id="dead", open_chats=[{"project_root": "/p", "save_id": "s", "running": False}])
    store.heartbeat(instance_id="alive", open_chats=[{"project_root": "/p", "save_id": "s", "running": False}])
    monkeypatch.setattr("telegram_bridge.registry._pid_is_alive", lambda pid: pid == 222)

    primary = Registry(store, heartbeat_ttl=90).primary_for("/p", "s")

    assert primary == "alive"


def test_list_live_open_chats_filters_dead_instances_and_reports_listening():
    store = Store(":memory:")
    store.register_instance(instance_id="alive", pid=None, cwd=None, project_root="/p", version=None)
    store.register_instance(instance_id="dead", pid=None, cwd=None, project_root="/p", version=None)
    store.heartbeat(instance_id="alive", open_chats=[{"project_root": "/p", "save_id": "bound", "title": "Bound", "running": False, "notify_active": True}])
    store.heartbeat(instance_id="dead", open_chats=[{"project_root": "/p", "save_id": "stale", "title": "Stale", "running": False}])
    store.conn.execute("UPDATE nvim_instances SET last_seen_at=last_seen_at-1000 WHERE instance_id='dead'")
    alive_after = store.conn.execute("SELECT last_seen_at FROM nvim_instances WHERE instance_id='alive'").fetchone()[0] - 1

    rows = store.list_live_open_chats(alive_after)

    assert [row["save_id"] for row in rows] == ["bound"]
    assert rows[0]["notify_active"] == 1
