import asyncio
import contextlib
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
    pending_request_rpc_id: object | None = None


class NoPendingApprovalError(RuntimeError):
    pass


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

    async def archive(self, session: SessionRecord) -> SessionRecord:
        try:
            codex = self.store.get_codex_session(session.id)
        except KeyError:
            self.store.append_event(session.id, "session.archived", {})
            return self.store.update_session_projection(
                session.id,
                status="archived",
                active_notification_kind="none",
            )

        live = self.live_sessions.pop(session.id, None)
        client = live.client if live is not None else await self._open_client(session.id)
        try:
            active_turn_id = live.active_turn_id if live is not None else codex.active_turn_id
            if active_turn_id is not None:
                await client.turn_interrupt(codex.thread_id, active_turn_id)
            await client.thread_archive(codex.thread_id)
        finally:
            with contextlib.suppress(Exception):
                await client.close()

        self._update_codex_session(
            session.id,
            active_turn_id=None,
            pending_request_id=None,
            pending_request_kind=None,
            pending_request_payload=None,
        )
        self.store.append_event(session.id, "session.archived", {})
        return self.store.update_session_projection(
            session.id,
            status="archived",
            active_notification_kind="none",
        )

    async def approve_pending_request(self, session: SessionRecord) -> SessionRecord:
        codex = self.store.get_codex_session(session.id)
        pending = codex.pending_request_payload or {}
        if codex.pending_request_kind == "permissions":
            permissions = pending.get("permissions")
            if not isinstance(permissions, dict):
                permissions = {}
            return await self._resolve_pending_request(session, {"permissions": permissions}, "approve")
        return await self._resolve_pending_request(session, {"decision": "accept"}, "approve")

    async def deny_pending_request(self, session: SessionRecord) -> SessionRecord:
        codex = self.store.get_codex_session(session.id)
        if codex.pending_request_kind == "permissions":
            return await self._resolve_pending_request(session, {"permissions": {}}, "deny")
        return await self._resolve_pending_request(session, {"decision": "decline"}, "deny")

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

        if "id" in payload:
            request_id = payload["id"]
            normalized = self._normalize_pending_request(method, params)
            if normalized is not None:
                live = self.live_sessions.get(session_id)
                if live is not None:
                    live.pending_request_rpc_id = request_id
                request_id_text = self._request_id_text(request_id)
                self._update_codex_session(
                    session_id,
                    pending_request_id=request_id_text,
                    pending_request_kind=normalized["kind"],
                    pending_request_payload=normalized,
                )
                self.store.append_event(
                    session_id,
                    "codex.approval.requested",
                    {
                        "requestId": request_id_text,
                        "method": method,
                        "pendingApproval": normalized,
                    },
                )
                self.store.append_event(
                    session_id,
                    "session.attention_required",
                    {
                        "message": str(normalized.get("summary") or "Codex requires approval"),
                        "pendingApproval": normalized,
                    },
                )
                self.store.update_session_projection(
                    session_id,
                    status="attention_required",
                    active_notification_kind="attention_required",
                )
                return

            self.store.append_event(
                session_id,
                "codex.request.unsupported",
                {"requestId": self._request_id_text(request_id), "method": method},
            )
            self.store.append_event(
                session_id,
                "session.attention_required",
                {"message": f"Unsupported Codex request: {method}"},
            )
            self.store.update_session_projection(
                session_id,
                status="attention_required",
                active_notification_kind="attention_required",
            )
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

        if method == "serverRequest/resolved":
            request_id = self._request_id_text(params.get("requestId"))
            try:
                codex = self.store.get_codex_session(session_id)
            except KeyError:
                return
            if request_id is None or codex.pending_request_id != request_id:
                return
            live = self.live_sessions.get(session_id)
            if live is not None:
                live.pending_request_rpc_id = None
            self._update_codex_session(
                session_id,
                pending_request_id=None,
                pending_request_kind=None,
                pending_request_payload=None,
            )
            session = self.store.get_session(session_id)
            if session.status == "attention_required":
                self.store.update_session_projection(
                    session_id,
                    status="running",
                    active_notification_kind="none",
                )
            return

        self.store.append_event(
            session_id,
            f"codex.{method.replace('/', '.')}",
            params if isinstance(params, dict) else {"data": params},
        )

    async def _resolve_pending_request(
        self,
        session: SessionRecord,
        result: dict,
        decision: str,
    ) -> SessionRecord:
        live = self.live_sessions.get(session.id)
        if live is None or live.pending_request_rpc_id is None:
            raise NoPendingApprovalError("No live pending Codex approval")

        codex = self.store.get_codex_session(session.id)
        if codex.pending_request_id is None:
            raise NoPendingApprovalError("No live pending Codex approval")

        await live.client.respond(live.pending_request_rpc_id, result)
        live.pending_request_rpc_id = None
        self._update_codex_session(
            session.id,
            pending_request_id=None,
            pending_request_kind=None,
            pending_request_payload=None,
        )
        self.store.append_event(
            session.id,
            "codex.approval.resolved",
            {"requestId": codex.pending_request_id, "decision": decision},
        )
        return self.store.update_session_projection(
            session.id,
            status="running",
            active_notification_kind="none",
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

    def _normalize_pending_request(self, method: str, params: object) -> dict | None:
        if not isinstance(params, dict):
            return None

        reason = params.get("reason")
        reason_text = reason if isinstance(reason, str) else None
        if method == "item/commandExecution/requestApproval":
            command = params.get("command")
            cwd = params.get("cwd")
            if isinstance(command, list) and all(isinstance(part, str) for part in command):
                return {
                    "kind": "command",
                    "summary": f"Run {' '.join(command)}",
                    "reason": reason_text,
                    "command": command,
                    "cwd": cwd,
                }
            network_context = params.get("networkApprovalContext")
            return {
                "kind": "command",
                "summary": "Allow network access",
                "reason": reason_text,
                "networkApprovalContext": network_context,
                "cwd": cwd,
            }

        if method == "item/fileChange/requestApproval":
            payload = {
                "kind": "file_change",
                "summary": "Approve file changes",
                "reason": reason_text,
            }
            grant_root = params.get("grantRoot")
            if grant_root is not None:
                payload["grantRoot"] = grant_root
            return payload

        if method == "item/permissions/requestApproval":
            permissions = params.get("permissions")
            return {
                "kind": "permissions",
                "summary": "Grant additional permissions",
                "reason": reason_text,
                "permissions": permissions if isinstance(permissions, dict) else {},
            }

        return None

    def _request_id_text(self, request_id: object) -> str | None:
        if request_id is None:
            return None
        return str(request_id)
