import base64
from pathlib import Path

from allhands_host.app import build_app
from allhands_host.auth import BasicAuthenticator, hash_password, parse_basic_authorization, verify_password
from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.store import UserStore


def test_hash_password_round_trips_with_verify():
    password_hash = hash_password("8mGu57TILp27qVRDNi6O")

    assert password_hash.startswith("$2")
    assert verify_password("8mGu57TILp27qVRDNi6O", password_hash) is True
    assert verify_password("wrong-password", password_hash) is False


def test_parse_basic_authorization_rejects_invalid_headers():
    assert parse_basic_authorization(None) is None
    assert parse_basic_authorization("Bearer token") is None
    assert parse_basic_authorization("Basic not-base64") is None
    assert parse_basic_authorization(f"Basic {base64.b64encode(b'td').decode('ascii')}") is None


def test_basic_authenticator_uses_stored_users(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    user_store = UserStore(db)
    user_store.upsert_user(
        build_user("td", "8mGu57TILp27qVRDNi6O")
    )
    token = base64.b64encode(b"td:8mGu57TILp27qVRDNi6O").decode("ascii")
    authenticator = BasicAuthenticator(user_store)

    assert authenticator.authenticate(f"Basic {token}") is not None
    assert authenticator.authenticate("Basic Zm9vOmJhcg==") is None


def test_build_app_seeds_default_user_and_authenticator(tmp_path: Path):
    settings = Settings(
        project_root=tmp_path,
        database_path=tmp_path / "allhands.sqlite3",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="",
        vapid_private_key="",
        codex_app_server_port=21992,
        codex_binary="codex",
    )

    app = build_app(settings=settings)
    user = UserStore(Database(settings.database_path)).get_user("td")

    assert app.settings["authenticator"] is not None
    assert verify_password("8mGu57TILp27qVRDNi6O", user.password_hash) is True


def build_user(username: str, password: str):
    from allhands_host.models import UserRecord, utc_now

    now = utc_now()
    return UserRecord(
        username=username,
        password_hash=hash_password(password),
        created_at=now,
        updated_at=now,
    )
