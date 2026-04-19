import base64
import json
from pathlib import Path
import tempfile

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.store import UserStore


def basic_auth_headers(**headers: str) -> dict[str, str]:
    token = base64.b64encode(b"td:8mGu57TILp27qVRDNi6O").decode("ascii")
    return {"Authorization": f"Basic {token}", **headers}


class FakeSession:
    def __init__(
        self,
        session_id: str,
        status: str,
        workspace_state: str = "ready",
        pending_approval: dict | None = None,
    ):
        self.id = session_id
        self.status = status
        self.workspace_state = workspace_state
        self.repo_path = "/tmp/projects/api"
        self.launcher = "codex"
        self.pending_approval = pending_approval


class FakeEvent:
    def __init__(self, seq: int, type_: str, payload: dict, created_at: str = "2026-04-18T00:00:00+00:00"):
        self.seq = seq
        self.type = type_
        self.payload = payload
        self.created_at = created_at


class FakeNotificationStore:
    def __init__(self):
        self.saved = []

    def save_push_subscription(self, endpoint: str, keys: dict[str, str]):
        self.saved.append({"endpoint": endpoint, "keys": keys})


class FakeNotificationService:
    def __init__(self):
        self.store = FakeNotificationStore()


class FakeRepoCatalog:
    def __init__(self):
        self.queries = []

    def list_repos(self, query: str = ""):
        self.queries.append(query)
        return [{"name": "api", "path": "/tmp/projects/api"}]


class FakeSessionService:
    def __init__(self):
        self.app_seen = []
        self.session_seen = []
        self.pending_approval = None
        self.approval_actions = []

    async def create_session(self, launcher: str, repo_path: str, prompt: str):
        return FakeSession("session_123", "created")

    async def prompt(self, session_id: str, prompt: str):
        return True

    async def resume(self, session_id: str):
        return FakeSession(session_id, "running")

    async def cancel(self, session_id: str):
        return FakeSession(session_id, "resume_available")

    async def reset(self, session_id: str):
        return FakeSession(session_id, "resume_available", workspace_state="missing")

    async def archive(self, session_id: str):
        return FakeSession(session_id, "archived")

    async def approve_pending_request(self, session_id: str):
        self.approval_actions.append({"sessionId": session_id, "decision": "approve"})
        return FakeSession(session_id, "running")

    async def deny_pending_request(self, session_id: str):
        self.approval_actions.append({"sessionId": session_id, "decision": "deny"})
        return FakeSession(session_id, "running")

    def get_session(self, session_id: str):
        payload = {
            "id": session_id,
            "status": "completed",
            "workspace_state": "ready",
            "repo_path": "/tmp/projects/api",
            "launcher": "codex",
        }
        if self.pending_approval is not None:
            payload["pending_approval"] = self.pending_approval
        return payload

    def list_sessions(self):
        return [
            {
                "id": "session_123",
                "status": "completed",
                "workspace_state": "ready",
                "repo_path": "/tmp/projects/api",
                "launcher": "codex",
            }
        ]

    def list_events(self, session_id: str, after_seq: int):
        return [FakeEvent(1, "session.created", {"status": "created"})]

    def mark_app_seen(self, timestamp: str):
        self.app_seen.append(timestamp)

    def mark_session_seen(self, session_id: str, event_seq: int):
        self.session_seen.append({"sessionId": session_id, "eventSeq": event_seq})


class SessionApiTest(AsyncHTTPTestCase):
    def setUp(self):
        self.state_dir = tempfile.TemporaryDirectory()
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.state_dir.cleanup()

    def get_app(self):
        self.notification_service = FakeNotificationService()
        self.session_service = FakeSessionService()
        self.repo_catalog = FakeRepoCatalog()
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path(self.state_dir.name) / "allhands.sqlite3",
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
            codex_app_server_port=21992,
            codex_binary="codex",
        )
        return build_app(
            settings=settings,
            session_service=self.session_service,
            notification_service=self.notification_service,
            repo_catalog=self.repo_catalog,
        )

    def test_create_session_returns_session_id(self):
        response = self.fetch(
            "/sessions",
            method="POST",
            headers=basic_auth_headers(),
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

    def test_default_user_is_created_on_startup(self):
        user = UserStore(Database(Path(self.state_dir.name) / "allhands.sqlite3")).get_user("td")

        assert user.username == "td"
        assert user.password_hash.startswith("$2")

    def test_non_health_routes_require_basic_auth(self):
        response = self.fetch("/server-info")

        assert response.code == 401
        assert response.headers["WWW-Authenticate"] == 'Basic realm="All Hands"'

    def test_session_events_stream_replays_events(self):
        response = self.fetch(
            "/sessions/session_123/events",
            headers={**basic_auth_headers(), "Last-Event-ID": "0"},
        )

        body = response.body.decode()
        assert response.code == 200
        assert response.headers["Content-Type"].startswith("text/event-stream")
        assert "id: 1" in body
        assert "event: session.created" in body

    def test_session_timeline_snapshot_returns_json(self):
        response = self.fetch("/sessions/session_123/timeline", headers=basic_auth_headers())
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload["events"][0]["type"] == "session.created"

    def test_reset_endpoint_returns_updated_projection(self):
        response = self.fetch("/sessions/session_123/reset", method="POST", headers=basic_auth_headers(), body="{}")
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload["workspaceState"] == "missing"
        assert payload["runState"] == "resume_available"

    def test_session_detail_includes_pending_approval(self):
        self.session_service.pending_approval = {
            "kind": "command",
            "summary": "Run npm test",
            "reason": "Validate the workspace",
            "command": ["npm", "test"],
            "cwd": "/tmp/projects/api/.worktrees/session_123",
        }

        response = self.fetch("/sessions/session_123", headers=basic_auth_headers())
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload["pendingApproval"]["kind"] == "command"
        assert payload["pendingApproval"]["command"] == ["npm", "test"]

    def test_approve_endpoint_resolves_pending_approval(self):
        response = self.fetch(
            "/sessions/session_123/approval/approve",
            method="POST",
            headers=basic_auth_headers(),
            body="{}",
        )
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload["runState"] == "running"
        assert self.session_service.approval_actions == [{"sessionId": "session_123", "decision": "approve"}]

    def test_seen_endpoints_accept_app_and_session_cursors(self):
        app_seen = self.fetch(
            "/seen/app",
            method="POST",
            headers=basic_auth_headers(),
            body=json.dumps({"lastSeenAt": "2026-04-18T00:01:00+00:00"}),
        )
        session_seen = self.fetch(
            "/sessions/session_123/seen",
            method="POST",
            headers=basic_auth_headers(),
            body=json.dumps({"lastSeenEventSeq": 4}),
        )

        assert app_seen.code == 204
        assert session_seen.code == 204
        assert self.session_service.app_seen == ["2026-04-18T00:01:00+00:00"]
        assert self.session_service.session_seen == [{"sessionId": "session_123", "eventSeq": 4}]

    def test_push_subscription_endpoint_persists_subscription(self):
        response = self.fetch(
            "/push/subscriptions",
            method="POST",
            headers=basic_auth_headers(),
            body=json.dumps(
                {
                    "endpoint": "https://example.invalid/subscription",
                    "keys": {"p256dh": "public", "auth": "secret"},
                }
            ),
        )

        assert response.code == 204
        assert self.notification_service.store.saved == [
            {
                "endpoint": "https://example.invalid/subscription",
                "keys": {"p256dh": "public", "auth": "secret"},
            }
        ]

    def test_repo_discovery_returns_results(self):
        response = self.fetch("/repos?query=api", headers=basic_auth_headers())
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload == {"repos": [{"name": "api", "path": "/tmp/projects/api"}]}
        assert self.repo_catalog.queries == ["api"]


class FrontendShellTest(AsyncHTTPTestCase):
    def setUp(self):
        self.state_dir = tempfile.TemporaryDirectory()
        self.frontend_dist = tempfile.TemporaryDirectory()
        dist_path = Path(self.frontend_dist.name)
        (dist_path / "assets").mkdir()
        (dist_path / "assets" / "app.js").write_text('console.log("All Hands");')
        (dist_path / "index.html").write_text("<!doctype html><html><body>All Hands UI</body></html>")
        (dist_path / "manifest.webmanifest").write_text('{"name":"All Hands"}')
        (dist_path / "sw.js").write_text('self.addEventListener("push", () => {});')
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.state_dir.cleanup()
        self.frontend_dist.cleanup()

    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path(self.state_dir.name) / "allhands.sqlite3",
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
            codex_app_server_port=21992,
            codex_binary="codex",
        )
        return build_app(
            settings=settings,
            session_service=FakeSessionService(),
            notification_service=FakeNotificationService(),
            repo_catalog=FakeRepoCatalog(),
            frontend_dist=Path(self.frontend_dist.name),
        )

    def test_root_serves_frontend_shell_without_auth(self):
        response = self.fetch("/")

        assert response.code == 200
        assert response.headers["Content-Type"].startswith("text/html")
        assert "All Hands UI" in response.body.decode()

    def test_login_route_falls_back_to_index(self):
        response = self.fetch("/login")

        assert response.code == 200
        assert "All Hands UI" in response.body.decode()

    def test_control_room_route_falls_back_to_index(self):
        response = self.fetch("/control-room")

        assert response.code == 200
        assert "All Hands UI" in response.body.decode()

    def test_control_room_new_route_falls_back_to_index(self):
        response = self.fetch("/control-room/new")

        assert response.code == 200
        assert "All Hands UI" in response.body.decode()

    def test_pwa_assets_are_served_without_auth(self):
        manifest = self.fetch("/manifest.webmanifest")
        service_worker = self.fetch("/sw.js")
        javascript = self.fetch("/assets/app.js")

        assert manifest.code == 200
        assert '"name":"All Hands"' in manifest.body.decode()
        assert service_worker.code == 200
        assert "self.addEventListener" in service_worker.body.decode()
        assert javascript.code == 200
        assert 'console.log("All Hands")' in javascript.body.decode()
