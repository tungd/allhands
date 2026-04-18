import json
from datetime import datetime, timedelta

from pywebpush import webpush

from allhands_host.models import SessionRecord, utc_now
from allhands_host.store import SessionStore


class NotificationService:
    def __init__(
        self,
        store: SessionStore,
        public_key: str,
        private_key: str,
        sender=webpush,
        foreground_window_seconds: int = 15,
    ):
        self.store = store
        self.public_key = public_key
        self.private_key = private_key
        self.sender = sender
        self.foreground_window = timedelta(seconds=foreground_window_seconds)

    def should_send(
        self,
        *,
        newest_event_seq: int,
        session_last_seen_event_seq: int,
        app_last_seen_at: str | None,
        now: str,
    ) -> bool:
        if newest_event_seq <= session_last_seen_event_seq:
            return False
        if app_last_seen_at is None:
            return True
        seen_at = datetime.fromisoformat(app_last_seen_at)
        current = datetime.fromisoformat(now)
        return current - seen_at > self.foreground_window

    def send(self, *, title: str, body: str, session_id: str, kind: str) -> bool:
        if not self.private_key:
            return False

        subscriptions = self.store.list_push_subscriptions()
        if not subscriptions:
            return False

        payload = json.dumps(
            {
                "title": title,
                "body": body,
                "sessionId": session_id,
                "kind": kind,
                "tag": f"session:{session_id}",
                "url": f"/session/{session_id}",
            }
        )
        for subscription in subscriptions:
            self.sender(
                subscription_info=subscription,
                data=payload,
                vapid_private_key=self.private_key,
                vapid_claims={"sub": "mailto:none@example.com"},
            )
        return True

    def send_session(
        self,
        *,
        session: SessionRecord,
        newest_event_seq: int,
        kind: str,
        title: str,
        body: str,
        now: str | None = None,
    ) -> bool:
        current = now or utc_now()
        if not self.should_send(
            newest_event_seq=newest_event_seq,
            session_last_seen_event_seq=session.last_seen_event_seq,
            app_last_seen_at=self.store.get_app_last_seen_at(),
            now=current,
        ):
            return False

        sent = self.send(
            title=title,
            body=body,
            session_id=session.id,
            kind=kind,
        )
        if not sent:
            return False

        self.store.update_session_projection(
            session.id,
            active_notification_kind=kind,
            last_notified_at=current,
        )
        return True

    def send_attention_required(self, session: SessionRecord, newest_event_seq: int, body: str) -> bool:
        return self.send_session(
            session=session,
            newest_event_seq=newest_event_seq,
            kind="attention_required",
            title="Agent needs attention",
            body=body,
        )

    def send_completed(self, session: SessionRecord, newest_event_seq: int, body: str) -> bool:
        return self.send_session(
            session=session,
            newest_event_seq=newest_event_seq,
            kind="completed",
            title="Session completed",
            body=body,
        )
