import json
from pathlib import Path

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class ServerInfoHandlerTest(AsyncHTTPTestCase):
    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(settings=settings)

    def test_server_info(self):
        response = self.fetch("/server-info")
        payload = json.loads(response.body)
        assert response.code == 200
        assert payload["projectRoot"] == "/tmp/projects"
        assert payload["availableLaunchers"] == ["claude", "codex", "pi"]
        assert payload["transport"] == "sse"
