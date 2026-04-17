import tornado.web

from allhands_host.config import Settings, define_options, load_settings
from allhands_host.db import Database
from allhands_host.http import (
    HealthHandler,
    ServerInfoHandler,
    SessionArchiveHandler,
    SessionDetailHandler,
    SessionEventsHandler,
    SessionPromptHandler,
    SessionResumeHandler,
    SessionsHandler,
)
from allhands_host.session_service import SessionService
from allhands_host.store import SessionStore


def build_app(
    settings: Settings | None = None,
    session_service: SessionService | None = None,
) -> tornado.web.Application:
    define_options()
    settings = settings or load_settings()
    if session_service is None:
        database = Database(settings.database_path)
        database.migrate()
        session_service = SessionService(settings=settings, store=SessionStore(database))
    return tornado.web.Application(
        [
            (r"/healthz", HealthHandler),
            (r"/server-info", ServerInfoHandler, {"settings": settings}),
            (r"/sessions", SessionsHandler, {"session_service": session_service}),
            (r"/sessions/([^/]+)", SessionDetailHandler, {"session_service": session_service}),
            (r"/sessions/([^/]+)/prompt", SessionPromptHandler, {"session_service": session_service}),
            (r"/sessions/([^/]+)/resume", SessionResumeHandler, {"session_service": session_service}),
            (r"/sessions/([^/]+)/archive", SessionArchiveHandler, {"session_service": session_service}),
            (r"/sessions/([^/]+)/events", SessionEventsHandler, {"session_service": session_service}),
        ]
    )
