import asyncio
import contextlib
from dataclasses import asdict, replace
from pathlib import Path

from allhands_host.acp_attachment import AttentionRequiredError, Attachment, attach_and_initialize, attach_and_resume
from allhands_host.codex_daemon import CodexDaemonManager
from allhands_host.codex_session_adapter import CodexSessionAdapter, NoPendingApprovalError
from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.launchers.catalog import LauncherCatalog
from allhands_host.models import SessionRecord
from allhands_host.notifications import NotificationService
from allhands_host.store import SessionStore
from allhands_host.worktrees import WorktreeManager


class SessionService:
    def __init__(
        self,
        settings: Settings,
        store: SessionStore | None = None,
        worktree_manager: WorktreeManager | None = None,
        launcher_catalog: LauncherCatalog | None = None,
        notification_service: NotificationService | None = None,
        codex_adapter: CodexSessionAdapter | None = None,
    ):
        self.settings = settings
        self.store = store or SessionStore(Database(settings.database_path))
        self.worktree_manager = worktree_manager or WorktreeManager(settings.project_root)
        self.launcher_catalog = launcher_catalog or LauncherCatalog(settings.project_root)
        self.notification_service = notification_service
        self.codex_adapter = codex_adapter or CodexSessionAdapter(
            store=self.store,
            worktree_manager=self.worktree_manager,
            daemon_manager=CodexDaemonManager(settings),
        )
        self.attachments: dict[str, Attachment] = {}
        self._bootstrap_tasks: set[asyncio.Task[None]] = set()
        reconcile = getattr(self.codex_adapter, "reconcile_startup_state", None)
        if callable(reconcile):
            reconcile()

    async def create_session(self, launcher: str, repo_path: str, prompt: str) -> SessionRecord:
        repo = Path(repo_path).resolve()
        seed = SessionRecord.new(
            launcher=launcher,
            repo_path=str(repo),
            worktree_path=str(repo),
        )
        session = replace(seed, worktree_path=str(repo.parent / ".worktrees" / seed.id))
        self.store.create_session(session)
        self.store.append_event(session.id, "session.created", {"status": session.status})
        if launcher == "codex":
            self._track_bootstrap(self._bootstrap_codex_session(session, prompt))
        else:
            self._track_bootstrap(self._bootstrap_session(session, prompt))
        return self.store.get_session(session.id)

    def list_sessions(self) -> list[dict]:
        return [asdict(session) for session in self.store.list_sessions()]

    def get_session(self, session_id: str) -> dict:
        session = self.store.get_session(session_id)
        payload = asdict(session)
        if session.launcher != "codex":
            return payload
        try:
            codex = self.store.get_codex_session(session_id)
        except KeyError:
            return payload
        if codex.pending_request_payload is not None:
            payload["pending_approval"] = codex.pending_request_payload
        return payload

    def list_events(self, session_id: str, after_seq: int):
        return self.store.list_events(session_id, after_seq)

    def mark_app_seen(self, timestamp: str) -> None:
        self.store.mark_app_seen(timestamp)

    def mark_session_seen(self, session_id: str, event_seq: int) -> None:
        self.store.mark_session_seen(session_id, event_seq)

    async def prompt(self, session_id: str, prompt: str) -> bool:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            try:
                return await self.codex_adapter.prompt(session, prompt)
            except Exception as exc:
                self.store.append_event(session_id, "session.failed", {"error": str(exc)})
                self.store.update_session_projection(
                    session_id,
                    status="failed",
                    active_notification_kind="none",
                )
                return False

        attachment = self.attachments.get(session_id)
        if attachment is None:
            return False

        self.store.append_event(session_id, "session.prompted", {"prompt": prompt})

        try:
            response = await attachment.prompt(prompt)
        except AttentionRequiredError as exc:
            await attachment.cancel()
            self.attachments.pop(session_id, None)
            event = self.store.append_event(
                session_id,
                "session.attention_required",
                {"message": str(exc)},
            )
            session = self.store.update_session_projection(
                session_id,
                status="attention_required",
                active_notification_kind="attention_required",
            )
            self._notify_attention_required(session, event.seq, str(exc))
            return True
        except Exception as exc:
            await attachment.cancel()
            self.attachments.pop(session_id, None)
            self.store.append_event(session_id, "session.failed", {"error": str(exc)})
            self.store.update_session_projection(
                session_id,
                status="failed",
                active_notification_kind="none",
            )
            return False

        await attachment.cancel()
        self.attachments.pop(session_id, None)
        stop_reason = getattr(response, "stopReason", "end_turn")
        event = self.store.append_event(
            session_id,
            "session.completed",
            {"stopReason": stop_reason},
        )
        session = self.store.update_session_projection(
            session_id,
            status="completed",
            active_notification_kind="completed",
        )
        self._notify_completed(session, event.seq)
        return True

    async def resume(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            return await self.codex_adapter.resume(session)
        repo_path = Path(session.repo_path)
        if session.workspace_state == "missing":
            await asyncio.to_thread(self.worktree_manager.create, repo_path, session.id)
            self.store.append_event(session.id, "workspace.recreated", {})
        session_token = session.last_bound_agent_session_id or self.store.last_bound_agent_session_id(session_id)
        command = self.launcher_catalog.get(session.launcher).build_resume_command(session_token=session_token)
        attachment = await attach_and_resume(
            session=session,
            store=self.store,
            argv=command.argv,
            cwd=Path(session.worktree_path),
            session_token=session_token,
        )
        self.attachments[session.id] = attachment
        self.store.append_event(session.id, "session.bound", {"agentSessionId": attachment.agent_session_id})
        return self.store.update_session_projection(
            session.id,
            status="running",
            workspace_state="ready",
            last_bound_agent_session_id=attachment.agent_session_id,
            active_notification_kind="none",
        )

    async def cancel(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            return await self.codex_adapter.cancel(session)
        attachment = self.attachments.pop(session_id, None)
        if attachment is None:
            return self.store.get_session(session_id)
        await attachment.cancel()
        self.store.append_event(session_id, "session.cancelled", {})
        return self.store.update_session_projection(
            session_id,
            status=self._resumable_status(session_id),
            active_notification_kind="none",
        )

    async def reset(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            return await self.codex_adapter.reset(session)
        attachment = self.attachments.pop(session_id, None)
        if attachment is not None:
            await attachment.cancel()
        await asyncio.to_thread(self.worktree_manager.remove, Path(session.repo_path), Path(session.worktree_path))
        self.store.append_event(session_id, "workspace.reset", {})
        return self.store.update_session_projection(
            session_id,
            status=self._resumable_status(session_id),
            workspace_state="missing",
            active_notification_kind="none",
        )

    async def approve_pending_request(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher != "codex":
            raise NoPendingApprovalError("No live pending Codex approval")
        return await self.codex_adapter.approve_pending_request(session)

    async def deny_pending_request(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher != "codex":
            raise NoPendingApprovalError("No live pending Codex approval")
        return await self.codex_adapter.deny_pending_request(session)

    async def archive(self, session_id: str) -> SessionRecord:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            return await self.codex_adapter.archive(session)
        self.attachments.pop(session_id, None)
        self.store.append_event(session_id, "session.archived", {})
        return self.store.update_session_projection(
            session_id,
            status="archived",
            active_notification_kind="none",
        )

    def _resumable_status(self, session_id: str) -> str:
        session = self.store.get_session(session_id)
        if session.launcher == "codex":
            try:
                self.store.get_codex_session(session_id)
            except KeyError:
                return "detached"
            return "resume_available"
        try:
            token = self.store.last_bound_agent_session_id(session_id)
        except KeyError:
            token = None
        return "resume_available" if token else "detached"

    def _track_bootstrap(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._bootstrap_tasks.add(task)
        task.add_done_callback(self._bootstrap_tasks.discard)

    async def _bootstrap_codex_session(self, session: SessionRecord, prompt: str) -> None:
        try:
            await self.codex_adapter.bootstrap(session, prompt)
        except Exception as exc:
            self.store.append_event(session.id, "session.failed", {"error": str(exc)})
            self.store.update_session_projection(
                session.id,
                status="failed",
                active_notification_kind="none",
            )

    async def _bootstrap_session(self, session: SessionRecord, prompt: str) -> None:
        repo_path = Path(session.repo_path)
        worktree_path = Path(session.worktree_path)
        attachment: Attachment | None = None

        try:
            await asyncio.to_thread(self.worktree_manager.create, repo_path, session.id)
            command = self.launcher_catalog.get(session.launcher).build_start_command(
                repo_path=repo_path,
                worktree_path=worktree_path,
                prompt=prompt,
            )
            attachment = await attach_and_initialize(
                session=session,
                store=self.store,
                argv=command.argv,
                cwd=command.cwd,
            )
            self.attachments[session.id] = attachment
            self.store.append_event(session.id, "session.bound", {"agentSessionId": attachment.agent_session_id})
            self.store.update_session_projection(
                session.id,
                status="running",
                workspace_state="ready",
                last_bound_agent_session_id=attachment.agent_session_id,
                active_notification_kind="none",
            )
            await self.prompt(session.id, prompt)
        except Exception as exc:
            if attachment is not None:
                with contextlib.suppress(Exception):
                    await attachment.cancel()
            self.attachments.pop(session.id, None)
            self.store.append_event(session.id, "session.failed", {"error": str(exc)})
            self.store.update_session_projection(
                session.id,
                status="failed",
                active_notification_kind="none",
            )

    def _notify_attention_required(self, session: SessionRecord, newest_event_seq: int, message: str) -> None:
        if self.notification_service is None:
            return
        self.notification_service.send_attention_required(
            session=session,
            newest_event_seq=newest_event_seq,
            body=message,
        )

    def _notify_completed(self, session: SessionRecord, newest_event_seq: int) -> None:
        if self.notification_service is None:
            return
        self.notification_service.send_completed(
            session=session,
            newest_event_seq=newest_event_seq,
            body="Session completed and is ready to resume.",
        )
