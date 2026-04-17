import tornado.web

from allhands_host.config import Settings, define_options, load_settings
from allhands_host.http import HealthHandler, ServerInfoHandler


def build_app(settings: Settings | None = None) -> tornado.web.Application:
    define_options()
    settings = settings or load_settings()
    return tornado.web.Application(
        [
            (r"/healthz", HealthHandler),
            (r"/server-info", ServerInfoHandler, {"settings": settings}),
        ]
    )
