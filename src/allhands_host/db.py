from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
import sqlite3


SCHEMA = """
create table if not exists sessions (
  id text primary key,
  launcher text not null,
  repo_path text not null,
  worktree_path text not null,
  status text not null,
  workspace_state text not null default 'ready',
  last_bound_agent_session_id text,
  last_activity_at text not null,
  last_notified_at text,
  active_notification_kind text not null default 'none',
  last_seen_event_seq integer not null default 0,
  created_at text not null,
  updated_at text not null
);

create table if not exists events (
  session_id text not null,
  seq integer not null,
  type text not null,
  payload_json text not null,
  created_at text not null,
  primary key (session_id, seq)
);

create table if not exists push_subscriptions (
  endpoint text primary key,
  keys_json text not null,
  created_at text not null
);

create table if not exists app_state (
  singleton integer primary key check (singleton = 1),
  last_seen_at text
);

create table if not exists codex_sessions (
  session_id text primary key,
  thread_id text not null unique,
  active_turn_id text,
  pending_request_id text,
  pending_request_kind text,
  pending_request_payload_json text,
  created_at text not null,
  updated_at text not null
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def migrate(self) -> None:
        with self.connect() as connection:
            connection.executescript(SCHEMA)
            self._migrate_sessions_table(connection)

    def _migrate_sessions_table(self, connection: sqlite3.Connection) -> None:
        columns = {
            row["name"]
            for row in connection.execute("pragma table_info(sessions)").fetchall()
        }
        migrations = {
            "workspace_state": "alter table sessions add column workspace_state text not null default 'ready'",
            "last_bound_agent_session_id": "alter table sessions add column last_bound_agent_session_id text",
            "last_activity_at": "alter table sessions add column last_activity_at text",
            "last_notified_at": "alter table sessions add column last_notified_at text",
            "active_notification_kind": "alter table sessions add column active_notification_kind text not null default 'none'",
            "last_seen_event_seq": "alter table sessions add column last_seen_event_seq integer not null default 0",
        }
        for column_name, statement in migrations.items():
            if column_name not in columns:
                connection.execute(statement)

        connection.execute(
            """
            update sessions
            set workspace_state = coalesce(workspace_state, 'ready'),
                last_activity_at = coalesce(last_activity_at, updated_at),
                active_notification_kind = coalesce(active_notification_kind, 'none'),
                last_seen_event_seq = coalesce(last_seen_event_seq, 0)
            """
        )
