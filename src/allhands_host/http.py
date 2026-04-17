import tornado.escape
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
        for event in self.session_service.list_events(session_id, last_event_id):
            self.write(
                f"id: {event.seq}\n"
                f"event: {event.type}\n"
                f"data: {tornado.escape.json_encode(event.payload)}\n\n"
            )
        await self.flush()
