import json

from allhands_host.db import Database
from allhands_host.models import EventRecord, SessionRecord, utc_now

_UNSET = object()


class SessionStore:
    def __init__(self, db: Database):
        self.db = db

    def create_session(self, session: SessionRecord) -> None:
        with self.db.connect() as connection:
            connection.execute(
                """
                insert into sessions (
                  id, launcher, repo_path, worktree_path, status, workspace_state,
                  last_bound_agent_session_id, last_activity_at, last_notified_at,
                  active_notification_kind, last_seen_event_seq, created_at, updated_at
                )
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session.id,
                    session.launcher,
                    session.repo_path,
                    session.worktree_path,
                    session.status,
                    session.workspace_state,
                    session.last_bound_agent_session_id,
                    session.last_activity_at,
                    session.last_notified_at,
                    session.active_notification_kind,
                    session.last_seen_event_seq,
                    session.created_at,
                    session.updated_at,
                ),
            )

    def get_session(self, session_id: str) -> SessionRecord:
        with self.db.connect() as connection:
            row = connection.execute(
                """
                select
                  id,
                  launcher,
                  repo_path,
                  worktree_path,
                  status,
                  coalesce(workspace_state, 'ready') as workspace_state,
                  last_bound_agent_session_id,
                  coalesce(last_activity_at, updated_at) as last_activity_at,
                  last_notified_at,
                  coalesce(active_notification_kind, 'none') as active_notification_kind,
                  coalesce(last_seen_event_seq, 0) as last_seen_event_seq,
                  created_at,
                  updated_at
                from sessions
                where id = ?
                """,
                (session_id,),
            ).fetchone()
        if row is None:
            raise KeyError(session_id)
        return SessionRecord(**dict(row))

    def list_sessions(self) -> list[SessionRecord]:
        with self.db.connect() as connection:
            rows = connection.execute(
                """
                select
                  id,
                  launcher,
                  repo_path,
                  worktree_path,
                  status,
                  coalesce(workspace_state, 'ready') as workspace_state,
                  last_bound_agent_session_id,
                  coalesce(last_activity_at, updated_at) as last_activity_at,
                  last_notified_at,
                  coalesce(active_notification_kind, 'none') as active_notification_kind,
                  coalesce(last_seen_event_seq, 0) as last_seen_event_seq,
                  created_at,
                  updated_at
                from sessions
                order by updated_at desc, created_at desc
                """
            ).fetchall()
        return [SessionRecord(**dict(row)) for row in rows]

    def update_status(self, session_id: str, status: str) -> SessionRecord:
        return self.update_session_projection(session_id, status=status)

    def update_session_projection(
        self,
        session_id: str,
        *,
        status: str | object = _UNSET,
        workspace_state: str | object = _UNSET,
        last_bound_agent_session_id: str | None | object = _UNSET,
        last_activity_at: str | object = _UNSET,
        last_notified_at: str | None | object = _UNSET,
        active_notification_kind: str | object = _UNSET,
    ) -> SessionRecord:
        current = self.get_session(session_id)
        updated_at = utc_now()
        with self.db.connect() as connection:
            connection.execute(
                """
                update sessions
                set status = ?,
                    workspace_state = ?,
                    last_bound_agent_session_id = ?,
                    last_activity_at = ?,
                    last_notified_at = ?,
                    active_notification_kind = ?,
                    updated_at = ?
                where id = ?
                """,
                (
                    current.status if status is _UNSET else status,
                    current.workspace_state if workspace_state is _UNSET else workspace_state,
                    (
                        current.last_bound_agent_session_id
                        if last_bound_agent_session_id is _UNSET
                        else last_bound_agent_session_id
                    ),
                    current.last_activity_at if last_activity_at is _UNSET else last_activity_at,
                    current.last_notified_at if last_notified_at is _UNSET else last_notified_at,
                    (
                        current.active_notification_kind
                        if active_notification_kind is _UNSET
                        else active_notification_kind
                    ),
                    updated_at,
                    session_id,
                ),
            )
        return self.get_session(session_id)

    def mark_session_seen(self, session_id: str, event_seq: int) -> None:
        with self.db.connect() as connection:
            connection.execute(
                """
                update sessions
                set last_seen_event_seq = max(last_seen_event_seq, ?)
                where id = ?
                """,
                (event_seq, session_id),
            )

    def mark_app_seen(self, seen_at: str) -> None:
        with self.db.connect() as connection:
            connection.execute(
                """
                insert into app_state (singleton, last_seen_at)
                values (1, ?)
                on conflict(singleton) do update set
                  last_seen_at = excluded.last_seen_at
                """,
                (seen_at,),
            )

    def get_app_last_seen_at(self) -> str | None:
        with self.db.connect() as connection:
            row = connection.execute(
                "select last_seen_at from app_state where singleton = 1"
            ).fetchone()
        if row is None:
            return None
        return row["last_seen_at"]

    def _update_session_activity(self, connection, session_id: str, created_at: str, payload: dict) -> None:
        agent_session_id = payload.get("agentSessionId") if isinstance(payload, dict) else None
        connection.execute(
            """
            update sessions
            set last_activity_at = ?,
                updated_at = ?,
                last_bound_agent_session_id = coalesce(?, last_bound_agent_session_id)
            where id = ?
            """,
            (created_at, created_at, agent_session_id, session_id),
        )

    def append_event(self, session_id: str, type_: str, payload: dict) -> EventRecord:
        with self.db.connect() as connection:
            current = connection.execute(
                "select coalesce(max(seq), 0) as seq from events where session_id = ?",
                (session_id,),
            ).fetchone()["seq"]
            event = EventRecord(
                session_id=session_id,
                seq=current + 1,
                type=type_,
                payload=payload,
                created_at=utc_now(),
            )
            connection.execute(
                """
                insert into events (session_id, seq, type, payload_json, created_at)
                values (?, ?, ?, ?, ?)
                """,
                (
                    event.session_id,
                    event.seq,
                    event.type,
                    json.dumps(event.payload),
                    event.created_at,
                ),
            )
            self._update_session_activity(connection, session_id, event.created_at, payload)
        return event

    def list_events(self, session_id: str, after_seq: int) -> list[EventRecord]:
        with self.db.connect() as connection:
            rows = connection.execute(
                """
                select session_id, seq, type, payload_json, created_at
                from events
                where session_id = ? and seq > ?
                order by seq asc
                """,
                (session_id, after_seq),
            ).fetchall()
        return [
            EventRecord(
                session_id=row["session_id"],
                seq=row["seq"],
                type=row["type"],
                payload=json.loads(row["payload_json"]),
                created_at=row["created_at"],
            )
            for row in rows
        ]

    def save_push_subscription(self, endpoint: str, keys: dict[str, str]) -> None:
        with self.db.connect() as connection:
            connection.execute(
                """
                insert into push_subscriptions (endpoint, keys_json, created_at)
                values (?, ?, ?)
                on conflict(endpoint) do update set
                  keys_json = excluded.keys_json
                """,
                (endpoint, json.dumps(keys), utc_now()),
            )

    def list_push_subscriptions(self) -> list[dict[str, object]]:
        with self.db.connect() as connection:
            rows = connection.execute(
                """
                select endpoint, keys_json, created_at
                from push_subscriptions
                order by created_at desc
                """
            ).fetchall()
        return [
            {
                "endpoint": row["endpoint"],
                "keys": json.loads(row["keys_json"]),
            }
            for row in rows
        ]

    def last_bound_agent_session_id(self, session_id: str) -> str:
        session = self.get_session(session_id)
        if session.last_bound_agent_session_id is not None:
            return session.last_bound_agent_session_id

        with self.db.connect() as connection:
            row = connection.execute(
                """
                select payload_json
                from events
                where session_id = ? and type = 'session.bound'
                order by seq desc
                limit 1
                """,
                (session_id,),
            ).fetchone()
        if row is None:
            raise KeyError(session_id)
        payload = json.loads(row["payload_json"])
        return payload["agentSessionId"]
