from pathlib import Path
import tempfile

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class HealthHandlerTest(AsyncHTTPTestCase):
    def setUp(self):
        self.state_dir = tempfile.TemporaryDirectory()
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.state_dir.cleanup()

    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path(self.state_dir.name) / "allhands.sqlite3",
            host="127.0.0.1",
            port=21991,
            vapid_public_key="",
            vapid_private_key="",
            codex_app_server_port=21992,
            codex_binary="codex",
        )
        return build_app(settings=settings)

    def test_healthz(self):
        response = self.fetch("/healthz")
        assert response.code == 200
        assert response.headers["Content-Type"].startswith("application/json")
        assert response.body == b'{"ok":true}'
