import asyncio
from pathlib import Path

import tornado.escape
import tornado.iostream
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
                "vapidPublicKey": self.settings_obj.vapid_public_key,
            }
        )


class SessionsHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def get(self) -> None:
        self.finish({"sessions": self.session_service.list_sessions()})

    async def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        session = await self.session_service.create_session(
            launcher=payload["launcher"],
            repo_path=payload["repoPath"],
            prompt=payload["prompt"],
        )
        self.set_status(201)
        self.finish({"id": session.id, "status": session.status})


class SessionDetailHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def get(self, session_id: str) -> None:
        self.finish(self.session_service.get_session(session_id))


class SessionPromptHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        accepted = await self.session_service.prompt(session_id, payload["prompt"])
        self.finish({"accepted": accepted})


class SessionResumeHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.resume(session_id)
        self.finish({"id": session.id, "status": session.status})


class SessionArchiveHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def post(self, session_id: str) -> None:
        session = self.session_service.archive(session_id)
        self.finish({"id": session.id, "status": session.status})


class SessionEventsHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def get(self, session_id: str) -> None:
        self.set_header("Content-Type", "text/event-stream")
        self.set_header("Cache-Control", "no-cache")
        last_event_id = int(self.request.headers.get("Last-Event-ID", "0"))
        live_stream = "text/event-stream" in self.request.headers.get("Accept", "")

        try:
            while True:
                events = self.session_service.list_events(session_id, last_event_id)
                for event in events:
                    self.write(
                        f"id: {event.seq}\n"
                        f"event: {event.type}\n"
                        f"data: {tornado.escape.json_encode(event.payload)}\n\n"
                    )
                    last_event_id = event.seq
                await self.flush()
                if not live_stream:
                    break
                await asyncio.sleep(0.25)
        except tornado.iostream.StreamClosedError:
            return


class PushSubscriptionHandler(tornado.web.RequestHandler):
    def initialize(self, notification_service) -> None:
        self.notification_service = notification_service

    def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.notification_service.store.save_push_subscription(
            endpoint=payload["endpoint"],
            keys=payload["keys"],
        )
        self.set_status(204)


class FrontendShellHandler(tornado.web.RequestHandler):
    def initialize(self, frontend_dist: Path) -> None:
        self.index_path = Path(frontend_dist) / "index.html"

    def get(self, path: str = "") -> None:
        if not self.index_path.exists():
            raise tornado.web.HTTPError(404)
        self.set_header("Content-Type", "text/html; charset=UTF-8")
        self.finish(self.index_path.read_bytes())
