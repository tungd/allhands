from pathlib import Path

import pytest

from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.launchers.base import LaunchCommand
from allhands_host.models import SessionRecord
from allhands_host.session_service import SessionService
from allhands_host.store import SessionStore


class FakeLauncher:
    def __init__(self):
        self.resume_tokens: list[str] = []

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        self.resume_tokens.append(session_token)
        return LaunchCommand(argv=["fake-agent", "--resume", session_token], cwd=Path("/tmp"))


class FakeLauncherCatalog:
    def __init__(self, launcher: FakeLauncher):
        self.launcher = launcher

    def get(self, slug: str) -> FakeLauncher:
        return self.launcher


class FakeAttachment:
    async def prompt(self, text: str) -> None:
        return None


@pytest.mark.asyncio
async def test_resume_reattaches_using_last_bound_agent_session_id(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new(
        launcher="codex",
        repo_path=str(tmp_path / "repo"),
        worktree_path=str(tmp_path / "repo/.worktrees/session_1"),
    )
    store.create_session(session)
    store.append_event(session.id, "session.bound", {"agentSessionId": "agent-123"})

    launcher = FakeLauncher()
    service = SessionService(
        settings=Settings(
            project_root=tmp_path,
            database_path=db.path,
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        ),
        store=store,
        launcher_catalog=FakeLauncherCatalog(launcher),
    )

    async def fake_attach_and_resume(*, session, store, argv, cwd, session_token):
        assert argv == ["fake-agent", "--resume", "agent-123"]
        assert cwd == Path(session.worktree_path)
        assert session_token == "agent-123"
        store.append_event(session.id, "session.resumed", {"agentSessionId": session_token})
        return FakeAttachment()

    monkeypatch.setattr("allhands_host.session_service.attach_and_resume", fake_attach_and_resume)

    resumed = await service.resume(session.id)

    assert resumed.status == "running"
    assert launcher.resume_tokens == ["agent-123"]
    assert session.id in service.attachments
