import json
from pathlib import Path

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class FakeSession:
    def __init__(self, session_id: str, status: str):
        self.id = session_id
        self.status = status


class FakeEvent:
    def __init__(self, seq: int, type_: str, payload: dict):
        self.seq = seq
        self.type = type_
        self.payload = payload


class FakeSessionService:
    async def create_session(self, launcher: str, repo_path: str, prompt: str):
        return FakeSession("session_123", "created")

    async def prompt(self, session_id: str, prompt: str):
        return True

    async def resume(self, session_id: str):
        return FakeSession(session_id, "running")

    def archive(self, session_id: str):
        return FakeSession(session_id, "archived")

    def list_events(self, session_id: str, after_seq: int):
        return [FakeEvent(1, "session.created", {"status": "created"})]


class SessionApiTest(AsyncHTTPTestCase):
    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(settings=settings, session_service=FakeSessionService())

    def test_create_session_returns_session_id(self):
        response = self.fetch(
            "/sessions",
            method="POST",
            body=json.dumps(
                {
                    "launcher": "codex",
                    "repoPath": "/tmp/projects/api",
                    "prompt": "Fix the API",
                }
            ),
        )
        payload = json.loads(response.body)
        assert response.code == 201
        assert payload["status"] == "created"
        assert payload["id"].startswith("session_")

    def test_session_events_stream_replays_events(self):
        response = self.fetch("/sessions/session_123/events", headers={"Last-Event-ID": "0"})

        body = response.body.decode()
        assert response.code == 200
        assert response.headers["Content-Type"].startswith("text/event-stream")
        assert "id: 1" in body
        assert "event: session.created" in body
