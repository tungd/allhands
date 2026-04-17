from pathlib import Path
import sqlite3


SCHEMA = """
create table if not exists sessions (
  id text primary key,
  launcher text not null,
  repo_path text not null,
  worktree_path text not null,
  status text not null,
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
"""


class Database:
    def __init__(self, path: Path):
        self.path = path

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    def migrate(self) -> None:
        with self.connect() as connection:
            connection.executescript(SCHEMA)
