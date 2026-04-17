import json

from allhands_host.db import Database
from allhands_host.models import EventRecord, SessionRecord, utc_now


class SessionStore:
    def __init__(self, db: Database):
        self.db = db

    def create_session(self, session: SessionRecord) -> None:
        with self.db.connect() as connection:
            connection.execute(
                """
                insert into sessions (id, launcher, repo_path, worktree_path, status, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session.id,
                    session.launcher,
                    session.repo_path,
                    session.worktree_path,
                    session.status,
                    session.created_at,
                    session.updated_at,
                ),
            )

    def get_session(self, session_id: str) -> SessionRecord:
        with self.db.connect() as connection:
            row = connection.execute(
                "select * from sessions where id = ?",
                (session_id,),
            ).fetchone()
        if row is None:
            raise KeyError(session_id)
        return SessionRecord(**dict(row))

    def list_sessions(self) -> list[SessionRecord]:
        with self.db.connect() as connection:
            rows = connection.execute(
                "select * from sessions order by updated_at desc, created_at desc"
            ).fetchall()
        return [SessionRecord(**dict(row)) for row in rows]

    def update_status(self, session_id: str, status: str) -> SessionRecord:
        updated_at = utc_now()
        with self.db.connect() as connection:
            connection.execute(
                "update sessions set status = ?, updated_at = ? where id = ?",
                (status, updated_at, session_id),
            )
        session = self.get_session(session_id)
        return SessionRecord(
            id=session.id,
            launcher=session.launcher,
            repo_path=session.repo_path,
            worktree_path=session.worktree_path,
            status=status,
            created_at=session.created_at,
            updated_at=updated_at,
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
