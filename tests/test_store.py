from pathlib import Path

from allhands_host.db import Database
from allhands_host import models
from allhands_host.models import SessionRecord, UserRecord, utc_now
from allhands_host.store import SessionStore, UserStore


def test_store_persists_sessions_and_events(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session-1",
    )
    store.create_session(session)
    store.append_event(session.id, "session.created", {"status": "created"})

    fetched = store.get_session(session.id)
    events = store.list_events(session.id, after_seq=0)

    assert fetched.id == session.id
    assert fetched.status == "created"
    assert events[0].type == "session.created"


def test_store_persists_push_subscriptions(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    store.save_push_subscription(
        endpoint="https://example.invalid/subscription",
        keys={"p256dh": "public", "auth": "secret"},
    )

    subscriptions = store.list_push_subscriptions()

    assert subscriptions == [
        {
            "endpoint": "https://example.invalid/subscription",
            "keys": {"p256dh": "public", "auth": "secret"},
        }
    ]


def test_store_persists_lifecycle_projection_and_seen_cursors(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session_1",
    )
    store.create_session(session)
    store.update_session_projection(
        session.id,
        status="attention_required",
        workspace_state="ready",
        last_bound_agent_session_id="agent-123",
        active_notification_kind="attention_required",
        last_notified_at="2026-04-18T00:00:00+00:00",
    )
    store.mark_session_seen(session.id, event_seq=7)
    store.mark_app_seen("2026-04-18T00:01:00+00:00")

    fetched = store.get_session(session.id)

    assert fetched.status == "attention_required"
    assert fetched.workspace_state == "ready"
    assert fetched.last_bound_agent_session_id == "agent-123"
    assert fetched.active_notification_kind == "attention_required"
    assert fetched.last_notified_at == "2026-04-18T00:00:00+00:00"
    assert fetched.last_seen_event_seq == 7
    assert store.get_app_last_seen_at() == "2026-04-18T00:01:00+00:00"


def test_store_persists_codex_session_metadata(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session_1",
    )
    store.create_session(session)
    assert hasattr(models, "CodexSessionRecord")

    store.upsert_codex_session(
        models.CodexSessionRecord(
            session_id=session.id,
            thread_id="thr_123",
            active_turn_id="turn_123",
            pending_request_id="req_123",
            pending_request_kind="command",
            pending_request_payload={"summary": "Run tests"},
            created_at=session.created_at,
            updated_at=session.updated_at,
        )
    )

    fetched = store.get_codex_session(session.id)

    assert fetched.thread_id == "thr_123"
    assert fetched.active_turn_id == "turn_123"
    assert fetched.pending_request_kind == "command"
    assert fetched.pending_request_payload == {"summary": "Run tests"}


def test_user_store_persists_users(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = UserStore(db)
    now = utc_now()

    store.upsert_user(
        UserRecord(
            username="td",
            password_hash="$2y$12$uFiH7if9Kfu6//E0Svozd.Ws3B5C9r93y7/MUjoRRB93kN5hbyMkq",
            created_at=now,
            updated_at=now,
        )
    )

    fetched = store.get_user("td")

    assert fetched.username == "td"
    assert fetched.password_hash.startswith("$2")
    assert [user.username for user in store.list_users()] == ["td"]
