import tornado.web

from allhands_host.config import Settings
from allhands_host.launchers.catalog import available_launchers


class HealthHandler(tornado.web.RequestHandler):
    def get(self) -> None:
        self.set_header("Content-Type", "application/json")
        self.finish(b'{"ok":true}')


class ServerInfoHandler(tornado.web.RequestHandler):
    def initialize(self, settings: Settings) -> None:
        self.settings_obj = settings

    def get(self) -> None:
        self.finish(
            {
                "projectRoot": str(self.settings_obj.project_root),
                "availableLaunchers": available_launchers(),
                "transport": "sse",
            }
        )
