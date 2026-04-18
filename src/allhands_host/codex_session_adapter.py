import asyncio
from dataclasses import dataclass, replace
import inspect
from pathlib import Path

from allhands_host.codex_client import CodexAppServerClient
from allhands_host.codex_daemon import CodexDaemonManager
from allhands_host.models import CodexSessionRecord, SessionRecord, utc_now
from allhands_host.store import SessionStore
from allhands_host.worktrees import WorktreeManager


@dataclass
class LiveCodexSession:
    client: object
    thread_id: str
    active_turn_id: str | None


class CodexSessionAdapter:
    def __init__(
        self,
        store: SessionStore,
        worktree_manager: WorktreeManager,
        daemon_manager: CodexDaemonManager,
        client_factory=None,
    ):
        self.store = store
        self.worktree_manager = worktree_manager
        self.daemon_manager = daemon_manager
        self.client_factory = client_factory or self._default_client_factory
        self.live_sessions: dict[str, LiveCodexSession] = {}

    def reconcile_startup_state(self) -> None:
        for session in self.store.list_sessions():
            if session.launcher != "codex" or session.status not in {"running", "attention_required"}:
                continue
            try:
                codex = self.store.get_codex_session(session.id)
            except KeyError:
                continue
            self.store.upsert_codex_session(
                replace(
                    codex,
                    active_turn_id=None,
                    pending_request_id=None,
                    pending_request_kind=None,
                    pending_request_payload=None,
                    updated_at=utc_now(),
                )
            )
            self.store.update_session_projection(
                session.id,
                status="resume_available",
                active_notification_kind="none",
            )

    async def bootstrap(self, session: SessionRecord, prompt: str) -> None:
        repo_path = Path(session.repo_path)
        await asyncio.to_thread(self.worktree_manager.create, repo_path, session.id)
        client = await self._open_client(session.id)
        thread = await client.thread_start(cwd=session.worktree_path)
        self.store.append_event(session.id, "session.bound", {"threadId": thread["id"]})
        self.store.update_session_projection(
            session.id,
            status="running",
            workspace_state="ready",
            active_notification_kind="none",
        )
        self.live_sessions[session.id] = LiveCodexSession(client=client, thread_id=thread["id"], active_turn_id=None)
        await self._start_turn(session, prompt)

    async def resume(self, session: SessionRecord) -> SessionRecord:
        session = self.store.get_session(session.id)
        repo_path = Path(session.repo_path)
        if session.workspace_state == "missing":
            await asyncio.to_thread(self.worktree_manager.create, repo_path, session.id)
            self.store.append_event(session.id, "workspace.recreated", {})

        codex = self.store.get_codex_session(session.id)
        client = await self._open_client(session.id)
        thread = await client.thread_resume(codex.thread_id)
        self.live_sessions[session.id] = LiveCodexSession(
            client=client,
            thread_id=thread["id"],
            active_turn_id=codex.active_turn_id,
        )
        self.store.append_event(session.id, "session.bound", {"threadId": thread["id"]})
        return self.store.update_session_projection(
            session.id,
            status="running",
            workspace_state="ready",
            active_notification_kind="none",
        )

    async def prompt(self, session: SessionRecord, prompt: str) -> bool:
        live = self.live_sessions.get(session.id)
        if live is None:
            return False
        await self._start_turn(session, prompt)
        return True

    async def cancel(self, session: SessionRecord) -> SessionRecord:
        live = self.live_sessions.pop(session.id, None)
        if live is None:
            return self.store.get_session(session.id)

        if live.active_turn_id is not None:
            await live.client.turn_interrupt(live.thread_id, live.active_turn_id)
        await live.client.close()
        self._update_codex_session(
            session.id,
            active_turn_id=None,
            pending_request_id=None,
            pending_request_kind=None,
            pending_request_payload=None,
        )
        self.store.append_event(session.id, "session.cancelled", {})
        return self.store.update_session_projection(
            session.id,
            status="resume_available",
            active_notification_kind="none",
        )

    async def reset(self, session: SessionRecord) -> SessionRecord:
        live = self.live_sessions.pop(session.id, None)
        if live is not None:
            if live.active_turn_id is not None:
                await live.client.turn_interrupt(live.thread_id, live.active_turn_id)
            await live.client.close()
        await asyncio.to_thread(self.worktree_manager.remove, Path(session.repo_path), Path(session.worktree_path))
        self._update_codex_session(
            session.id,
            active_turn_id=None,
            pending_request_id=None,
            pending_request_kind=None,
            pending_request_payload=None,
        )
        self.store.append_event(session.id, "workspace.reset", {})
        return self.store.update_session_projection(
            session.id,
            status="resume_available",
            workspace_state="missing",
            active_notification_kind="none",
        )

    async def _start_turn(self, session: SessionRecord, prompt: str) -> None:
        live = self.live_sessions[session.id]
        turn = await live.client.turn_start(
            thread_id=live.thread_id,
            input_items=[{"type": "text", "text": prompt}],
            cwd=session.worktree_path,
        )
        live.active_turn_id = turn["id"]
        self._update_codex_session(session.id, thread_id=live.thread_id, active_turn_id=turn["id"])
        self.store.append_event(session.id, "session.prompted", {"prompt": prompt})

    async def _open_client(self, session_id: str):
        handle = await self.daemon_manager.ensure_running()
        candidate = self.client_factory(handle)
        client = await candidate if inspect.isawaitable(candidate) else candidate
        if hasattr(client, "on_server_request"):
            client.on_server_request = lambda payload: self._handle_message(session_id, payload)
        if hasattr(client, "connect"):
            await client.connect()
        return client

    async def _default_client_factory(self, handle):
        return CodexAppServerClient(endpoint=handle.endpoint, token=handle.token)

    async def _handle_message(self, session_id: str, payload: dict) -> None:
        method = payload.get("method")
        params = payload.get("params", {})
        if not isinstance(method, str):
            return

        if method == "turn/completed":
            live = self.live_sessions.pop(session_id, None)
            if live is not None:
                asyncio.create_task(live.client.close())
            self._update_codex_session(
                session_id,
                active_turn_id=None,
                pending_request_id=None,
                pending_request_kind=None,
                pending_request_payload=None,
            )
            self.store.append_event(session_id, "session.completed", {"runState": "resume_available"})
            self.store.update_session_projection(
                session_id,
                status="resume_available",
                active_notification_kind="none",
            )
            return

        self.store.append_event(
            session_id,
            f"codex.{method.replace('/', '.')}",
            params if isinstance(params, dict) else {"data": params},
        )

    def _update_codex_session(
        self,
        session_id: str,
        *,
        thread_id: str | None = None,
        active_turn_id: str | None = None,
        pending_request_id: str | None = None,
        pending_request_kind: str | None = None,
        pending_request_payload: dict | None = None,
    ) -> None:
        try:
            current = self.store.get_codex_session(session_id)
            self.store.upsert_codex_session(
                replace(
                    current,
                    thread_id=current.thread_id if thread_id is None else thread_id,
                    active_turn_id=active_turn_id,
                    pending_request_id=pending_request_id,
                    pending_request_kind=pending_request_kind,
                    pending_request_payload=pending_request_payload,
                    updated_at=utc_now(),
                )
            )
        except KeyError:
            session = self.store.get_session(session_id)
            if thread_id is None:
                raise
            self.store.upsert_codex_session(
                CodexSessionRecord(
                    session_id=session_id,
                    thread_id=thread_id,
                    active_turn_id=active_turn_id,
                    pending_request_id=pending_request_id,
                    pending_request_kind=pending_request_kind,
                    pending_request_payload=pending_request_payload,
                    created_at=session.created_at,
                    updated_at=utc_now(),
                )
            )
