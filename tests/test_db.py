from pathlib import Path

from allhands_host.db import Database


class FakeConnection:
    def __init__(self):
        self.row_factory = None
        self.close_called = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def close(self) -> None:
        self.close_called = True


def test_database_connect_closes_connection_after_context(monkeypatch):
    fake = FakeConnection()

    monkeypatch.setattr("allhands_host.db.sqlite3.connect", lambda path: fake)

    db = Database(Path("/tmp/allhands.sqlite3"))
    with db.connect() as connection:
        assert connection is fake

    assert fake.close_called is True


def test_database_migrate_creates_users_table(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")

    db.migrate()

    with db.connect() as connection:
        tables = {
            row["name"]
            for row in connection.execute(
                "select name from sqlite_master where type = 'table'"
            ).fetchall()
        }

    assert "users" in tables
