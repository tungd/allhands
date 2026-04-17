import tornado.web

from allhands_host.http import HealthHandler


def build_app() -> tornado.web.Application:
    return tornado.web.Application(
        [
            (r"/healthz", HealthHandler),
        ]
    )
