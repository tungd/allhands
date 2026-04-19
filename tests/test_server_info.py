import base64
import json
from pathlib import Path
import tempfile

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class ServerInfoHandlerTest(AsyncHTTPTestCase):
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
            vapid_public_key="pub",
            vapid_private_key="priv",
            codex_app_server_port=21992,
            codex_binary="codex",
        )
        return build_app(settings=settings)

    def test_server_info(self):
        token = base64.b64encode(b"td:8mGu57TILp27qVRDNi6O").decode("ascii")
        response = self.fetch("/server-info", headers={"Authorization": f"Basic {token}"})
        payload = json.loads(response.body)
        assert response.code == 200
        assert payload["projectRoot"] == "/tmp/projects"
        assert payload["availableLaunchers"] == ["claude", "codex", "pi"]
        assert payload["transport"] == "sse"
