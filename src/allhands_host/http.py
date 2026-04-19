import asyncio
from pathlib import Path

import tornado.escape
import tornado.iostream
import tornado.web

from allhands_host.auth import REALM
from allhands_host.config import Settings
from allhands_host.codex_session_adapter import NoPendingApprovalError
from allhands_host.launchers.catalog import available_launchers


def serialize_session(session: object) -> dict:
    if isinstance(session, dict):
        raw = dict(session)
    else:
        raw = dict(vars(session))

    status = raw.get("status")
    workspace_state = raw.get("workspace_state", raw.get("workspaceState"))
    payload = dict(raw)
    if status is not None:
        payload["runState"] = status
    if workspace_state is not None:
        payload["workspaceState"] = workspace_state
        payload.setdefault("workspace_state", workspace_state)
    for key, alias in (
        ("repo_path", "repoPath"),
        ("worktree_path", "worktreePath"),
        ("pending_approval", "pendingApproval"),
        ("last_bound_agent_session_id", "lastBoundAgentSessionId"),
        ("last_activity_at", "lastActivityAt"),
        ("last_notified_at", "lastNotifiedAt"),
        ("active_notification_kind", "activeNotificationKind"),
        ("last_seen_event_seq", "lastSeenEventSeq"),
        ("created_at", "createdAt"),
        ("updated_at", "updatedAt"),
    ):
        value = raw.get(key)
        if value is not None:
            payload[alias] = value
    return payload


def serialize_event(event: object) -> dict:
    return {
        "seq": event.seq,
        "type": event.type,
        "payload": event.payload,
        "createdAt": event.created_at,
    }


def serialize_repo(repo: object) -> dict:
    if isinstance(repo, dict):
        return {"name": repo["name"], "path": repo["path"]}
    return {"name": repo.name, "path": repo.path}


class HealthHandler(tornado.web.RequestHandler):
    def get(self) -> None:
        self.set_header("Content-Type", "application/json")
        self.finish(b'{"ok":true}')


class BasicAuthMixin:
    def prepare(self):
        authenticator = self.application.settings.get("authenticator")
        if authenticator is None:
            return super().prepare()
        user = authenticator.authenticate(self.request.headers.get("Authorization"))
        if user is None:
            self.set_status(401)
            self.set_header("WWW-Authenticate", f'Basic realm="{REALM}"')
            self.finish({"error": "authentication required"})
            raise tornado.web.Finish()
        self._current_user = user
        return super().prepare()


class AuthenticatedHandler(BasicAuthMixin, tornado.web.RequestHandler):
    pass


class AuthenticatedStaticFileHandler(BasicAuthMixin, tornado.web.StaticFileHandler):
    pass


class ServerInfoHandler(AuthenticatedHandler):
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


class ReposHandler(AuthenticatedHandler):
    def initialize(self, repo_catalog) -> None:
        self.repo_catalog = repo_catalog

    def get(self) -> None:
        query = self.get_argument("query", "")
        repos = self.repo_catalog.list_repos(query)
        self.finish({"repos": [serialize_repo(repo) for repo in repos]})


class SessionsHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def get(self) -> None:
        self.finish({"sessions": [serialize_session(session) for session in self.session_service.list_sessions()]})

    async def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        session = await self.session_service.create_session(
            launcher=payload["launcher"],
            repo_path=payload["repoPath"],
            prompt=payload["prompt"],
        )
        self.set_status(201)
        self.finish(serialize_session(session))


class SessionDetailHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def get(self, session_id: str) -> None:
        self.finish(serialize_session(self.session_service.get_session(session_id)))


class SessionTimelineHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def get(self, session_id: str) -> None:
        events = self.session_service.list_events(session_id, after_seq=0)
        self.finish({"events": [serialize_event(event) for event in events]})


class SessionPromptHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        accepted = await self.session_service.prompt(session_id, payload["prompt"])
        self.finish({"accepted": accepted})


class SessionResumeHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.resume(session_id)
        self.finish(serialize_session(session))


class SessionCancelHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.cancel(session_id)
        self.finish(serialize_session(session))


class SessionResetHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.reset(session_id)
        self.finish(serialize_session(session))


class SessionArchiveHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.archive(session_id)
        self.finish(serialize_session(session))


class SessionApprovalApproveHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        try:
            session = await self.session_service.approve_pending_request(session_id)
        except NoPendingApprovalError as exc:
            raise tornado.web.HTTPError(409, reason=str(exc)) from exc
        self.finish(serialize_session(session))


class SessionApprovalDenyHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        try:
            session = await self.session_service.deny_pending_request(session_id)
        except NoPendingApprovalError as exc:
            raise tornado.web.HTTPError(409, reason=str(exc)) from exc
        self.finish(serialize_session(session))


class SessionEventsHandler(AuthenticatedHandler):
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


class PushSubscriptionHandler(AuthenticatedHandler):
    def initialize(self, notification_service) -> None:
        self.notification_service = notification_service

    def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.notification_service.store.save_push_subscription(
            endpoint=payload["endpoint"],
            keys=payload["keys"],
        )
        self.set_status(204)


class AppSeenHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.session_service.mark_app_seen(payload["lastSeenAt"])
        self.set_status(204)


class SessionSeenHandler(AuthenticatedHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def post(self, session_id: str) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.session_service.mark_session_seen(session_id, payload["lastSeenEventSeq"])
        self.set_status(204)


class FrontendShellHandler(AuthenticatedHandler):
    def initialize(self, frontend_dist: Path) -> None:
        self.index_path = Path(frontend_dist) / "index.html"

    def get(self, path: str = "") -> None:
        if not self.index_path.exists():
            raise tornado.web.HTTPError(404)
        self.set_header("Content-Type", "text/html; charset=UTF-8")
        self.finish(self.index_path.read_bytes())
