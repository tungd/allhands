from pathlib import Path

from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


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
