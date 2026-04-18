from dataclasses import replace

from allhands_host.models import SessionRecord
from allhands_host.notifications import NotificationService


class FakeStore:
    def __init__(self):
        self.app_last_seen_at = "2026-04-18T00:00:05+00:00"
        self.updated: list[tuple[str, dict[str, object]]] = []

    def get_app_last_seen_at(self):
        return self.app_last_seen_at

    def list_push_subscriptions(self):
        return [{"endpoint": "https://example.invalid/1", "keys": {"p256dh": "a", "auth": "b"}}]

    def update_session_projection(self, session_id: str, **kwargs):
        self.updated.append((session_id, kwargs))


def test_notification_service_suppresses_recent_foreground_activity():
    service = NotificationService(
        store=FakeStore(),
        public_key="pub",
        private_key="priv",
        sender=lambda **kwargs: None,
    )

    assert service.should_send(
        newest_event_seq=9,
        session_last_seen_event_seq=8,
        app_last_seen_at="2026-04-18T00:00:05+00:00",
        now="2026-04-18T00:00:10+00:00",
    ) is False


def test_notification_service_sends_collapsed_session_notification():
    store = FakeStore()
    calls: list[dict[str, object]] = []
    service = NotificationService(
        store=store,
        public_key="pub",
        private_key="priv",
        sender=lambda **kwargs: calls.append(kwargs),
    )
    session = replace(
        SessionRecord.new(
            launcher="codex",
            repo_path="/tmp/projects/api",
            worktree_path="/tmp/projects/.worktrees/session_1",
        ),
        last_seen_event_seq=1,
    )

    sent = service.send_session(
        session=session,
        newest_event_seq=2,
        kind="completed",
        title="Session completed",
        body="API refactor finished",
        now="2026-04-18T00:00:30+00:00",
    )

    assert sent is True
    assert calls[0]["subscription_info"]["endpoint"] == "https://example.invalid/1"
    assert '"sessionId": "session_' in calls[0]["data"]
    assert '"tag": "session:' in calls[0]["data"]
    assert '"url": "/session/' in calls[0]["data"]
    assert store.updated == [
        (
            session.id,
            {
                "active_notification_kind": "completed",
                "last_notified_at": "2026-04-18T00:00:30+00:00",
            },
        )
    ]
