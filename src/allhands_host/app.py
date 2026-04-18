from pathlib import Path

import tornado.web

from allhands_host.config import Settings, define_options, load_settings
from allhands_host.db import Database
from allhands_host.http import (
    AppSeenHandler,
    HealthHandler,
    FrontendShellHandler,
    SessionCancelHandler,
    ServerInfoHandler,
    SessionArchiveHandler,
    SessionDetailHandler,
    SessionEventsHandler,
    SessionPromptHandler,
    SessionResetHandler,
    SessionResumeHandler,
    SessionSeenHandler,
    SessionTimelineHandler,
    SessionsHandler,
    PushSubscriptionHandler,
)
from allhands_host.notifications import NotificationService
from allhands_host.session_service import SessionService
from allhands_host.store import SessionStore


def default_frontend_dist() -> Path:
    return Path(__file__).resolve().parents[2] / "frontend" / "dist"


def build_app(
    settings: Settings | None = None,
    session_service: SessionService | None = None,
    notification_service: NotificationService | None = None,
    frontend_dist: Path | None = None,
) -> tornado.web.Application:
    define_options()
    settings = settings or load_settings()
    frontend_dist = frontend_dist or default_frontend_dist()
    store: SessionStore | None = None
    if session_service is None:
        database = Database(settings.database_path)
        database.migrate()
        store = SessionStore(database)
    if notification_service is None:
        if store is None:
            database = Database(settings.database_path)
            database.migrate()
            store = SessionStore(database)
        notification_service = NotificationService(
            store=store,
            public_key=settings.vapid_public_key,
            private_key=settings.vapid_private_key,
        )
    if session_service is None:
        session_service = SessionService(
            settings=settings,
            store=store,
            notification_service=notification_service,
        )
    routes: list[tuple] = [
        (r"/healthz", HealthHandler),
        (r"/server-info", ServerInfoHandler, {"settings": settings}),
        (r"/sessions", SessionsHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)", SessionDetailHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/timeline", SessionTimelineHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/prompt", SessionPromptHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/resume", SessionResumeHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/cancel", SessionCancelHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/reset", SessionResetHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/archive", SessionArchiveHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/seen", SessionSeenHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/events", SessionEventsHandler, {"session_service": session_service}),
        (r"/seen/app", AppSeenHandler, {"session_service": session_service}),
        (r"/push/subscriptions", PushSubscriptionHandler, {"notification_service": notification_service}),
    ]

    if frontend_dist.exists():
        routes.extend(
            [
                (
                    r"/(manifest\.webmanifest)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist)},
                ),
                (
                    r"/(sw\.js)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist)},
                ),
                (
                    r"/assets/(.*)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist / "assets")},
                ),
                (r"/", FrontendShellHandler, {"frontend_dist": frontend_dist}),
                (r"/(control-room|inbox|session/[^/]+)", FrontendShellHandler, {"frontend_dist": frontend_dist}),
            ]
        )

    return tornado.web.Application(routes)
