from dataclasses import asdict
from pathlib import Path

from allhands_host.acp_attachment import Attachment, attach_and_initialize
from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.launchers.catalog import LauncherCatalog
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore
from allhands_host.worktrees import WorktreeManager


class SessionService:
    def __init__(
        self,
        settings: Settings,
        store: SessionStore | None = None,
        worktree_manager: WorktreeManager | None = None,
        launcher_catalog: LauncherCatalog | None = None,
    ):
        self.settings = settings
        self.store = store or SessionStore(Database(settings.database_path))
        self.worktree_manager = worktree_manager or WorktreeManager(settings.project_root)
        self.launcher_catalog = launcher_catalog or LauncherCatalog(settings.project_root)
        self.attachments: dict[str, Attachment] = {}

    async def create_session(self, launcher: str, repo_path: str, prompt: str) -> SessionRecord:
        repo = Path(repo_path).resolve()
        seed = SessionRecord.new(
            launcher=launcher,
            repo_path=str(repo),
            worktree_path=str(repo),
        )
        worktree_path = self.worktree_manager.create(repo, session_id=seed.id)
        session = SessionRecord(
            id=seed.id,
            launcher=seed.launcher,
            repo_path=seed.repo_path,
            worktree_path=str(worktree_path),
            status=seed.status,
            created_at=seed.created_at,
            updated_at=seed.updated_at,
        )
        self.store.create_session(session)
        self.store.append_event(session.id, "session.created", {"status": session.status})
        command = self.launcher_catalog.get(launcher).build_start_command(
            repo_path=repo,
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
        await attachment.prompt(prompt)
        self.store.update_status(session.id, "running")
        return self.store.get_session(session.id)

    def list_sessions(self) -> list[dict]:
        return [asdict(session) for session in self.store.list_sessions()]

    def get_session(self, session_id: str) -> dict:
        return asdict(self.store.get_session(session_id))

    def list_events(self, session_id: str, after_seq: int):
        return self.store.list_events(session_id, after_seq)

    async def prompt(self, session_id: str, prompt: str) -> bool:
        attachment = self.attachments.get(session_id)
        if attachment is None:
            return False
        await attachment.prompt(prompt)
        return True

    async def resume(self, session_id: str) -> SessionRecord:
        return self.store.get_session(session_id)

    def archive(self, session_id: str) -> SessionRecord:
        return self.store.update_status(session_id, "archived")
