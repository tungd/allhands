from pathlib import Path

import pytest

from allhands_host.acp_attachment import AttentionRequiredError
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


class FakePromptResponse:
    def __init__(self, stop_reason: str):
        self.stopReason = stop_reason


class FakeAttachment:
    def __init__(
        self,
        *,
        stop_reason: str = "end_turn",
        prompt_error: Exception | None = None,
        agent_session_id: str = "agent-123",
    ):
        self.stop_reason = stop_reason
        self.prompt_error = prompt_error
        self.agent_session_id = agent_session_id
        self.cancelled = False
        self.prompts: list[str] = []

    async def prompt(self, text: str):
        self.prompts.append(text)
        if self.prompt_error is not None:
            raise self.prompt_error
        return FakePromptResponse(self.stop_reason)

    async def cancel(self) -> None:
        self.cancelled = True


class FakeWorktrees:
    def __init__(self, root: Path):
        self.root = root
        self.removed: list[Path] = []
        self.created: list[tuple[Path, str]] = []

    def create(self, repo_path: Path, session_id: str) -> Path:
        path = repo_path.parent / ".worktrees" / session_id
        self.created.append((repo_path, session_id))
        return path

    def remove(self, repo_path: Path, worktree_path: Path) -> None:
        self.removed.append(worktree_path)


class FakeNotificationService:
    def __init__(self):
        self.calls: list[dict[str, object]] = []

    def send_session(self, *, session, newest_event_seq, kind, title, body):
        self.calls.append(
            {
                "session_id": session.id,
                "newest_event_seq": newest_event_seq,
                "kind": kind,
                "title": title,
                "body": body,
            }
        )
        return True

    def send_attention_required(self, *, session, newest_event_seq, body):
        return self.send_session(
            session=session,
            newest_event_seq=newest_event_seq,
            kind="attention_required",
            title="Agent needs attention",
            body=body,
        )

    def send_completed(self, *, session, newest_event_seq, body):
        return self.send_session(
            session=session,
            newest_event_seq=newest_event_seq,
            kind="completed",
            title="Session completed",
            body=body,
        )


def make_settings(tmp_path: Path, db_path: Path) -> Settings:
    return Settings(
        project_root=tmp_path,
        database_path=db_path,
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
    )


def create_session(store: SessionStore, tmp_path: Path) -> SessionRecord:
    session = SessionRecord.new(
        launcher="codex",
        repo_path=str(tmp_path / "repo"),
        worktree_path=str(tmp_path / "repo/.worktrees/session_1"),
    )
    store.create_session(session)
    return session


@pytest.mark.asyncio
async def test_prompt_completion_marks_session_completed_and_notifies(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="running",
        last_bound_agent_session_id="agent-123",
    )

    notifications = FakeNotificationService()
    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
        notification_service=notifications,
    )
    attachment = FakeAttachment(agent_session_id="agent-123")
    service.attachments[session.id] = attachment

    accepted = await service.prompt(session.id, "Ship it")
    refreshed = store.get_session(session.id)
    events = store.list_events(session.id, after_seq=0)

    assert accepted is True
    assert attachment.cancelled is True
    assert refreshed.status == "completed"
    assert session.id not in service.attachments
    assert [event.type for event in events][-2:] == ["session.prompted", "session.completed"]
    assert notifications.calls == [
        {
            "session_id": session.id,
            "newest_event_seq": events[-1].seq,
            "kind": "completed",
            "title": "Session completed",
            "body": "Session completed and is ready to resume.",
        }
    ]


@pytest.mark.asyncio
async def test_prompt_attention_required_marks_session_and_notifies(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="running",
        last_bound_agent_session_id="agent-123",
    )

    notifications = FakeNotificationService()
    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
        notification_service=notifications,
    )
    attachment = FakeAttachment(prompt_error=AttentionRequiredError("Need approval"), agent_session_id="agent-123")
    service.attachments[session.id] = attachment

    accepted = await service.prompt(session.id, "Run the deploy")
    refreshed = store.get_session(session.id)
    events = store.list_events(session.id, after_seq=0)

    assert accepted is True
    assert attachment.cancelled is True
    assert refreshed.status == "attention_required"
    assert session.id not in service.attachments
    assert [event.type for event in events][-2:] == ["session.prompted", "session.attention_required"]
    assert notifications.calls == [
        {
            "session_id": session.id,
            "newest_event_seq": events[-1].seq,
            "kind": "attention_required",
            "title": "Agent needs attention",
            "body": "Need approval",
        }
    ]


@pytest.mark.asyncio
async def test_resume_reattaches_using_last_bound_agent_session_id(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="resume_available",
        last_bound_agent_session_id="agent-123",
    )

    launcher = FakeLauncher()
    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
        launcher_catalog=FakeLauncherCatalog(launcher),
    )

    async def fake_attach_and_resume(*, session, store, argv, cwd, session_token):
        assert argv == ["fake-agent", "--resume", "agent-123"]
        assert cwd == Path(session.worktree_path)
        assert session_token == "agent-123"
        store.append_event(session.id, "session.resumed", {"agentSessionId": session_token})
        return FakeAttachment(agent_session_id=session_token)

    monkeypatch.setattr("allhands_host.session_service.attach_and_resume", fake_attach_and_resume)

    resumed = await service.resume(session.id)

    assert resumed.status == "running"
    assert resumed.workspace_state == "ready"
    assert launcher.resume_tokens == ["agent-123"]
    assert session.id in service.attachments


@pytest.mark.asyncio
async def test_resume_recreates_missing_workspace_before_reattach(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="resume_available",
        workspace_state="missing",
        last_bound_agent_session_id="agent-123",
    )

    worktrees = FakeWorktrees(tmp_path)
    launcher = FakeLauncher()
    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
        worktree_manager=worktrees,
        launcher_catalog=FakeLauncherCatalog(launcher),
    )

    async def fake_attach_and_resume(*, session, store, argv, cwd, session_token):
        assert cwd == Path(session.worktree_path)
        return FakeAttachment(agent_session_id=session_token)

    monkeypatch.setattr("allhands_host.session_service.attach_and_resume", fake_attach_and_resume)

    resumed = await service.resume(session.id)
    events = store.list_events(session.id, after_seq=0)

    assert resumed.workspace_state == "ready"
    assert worktrees.created == [(Path(session.repo_path), session.id)]
    assert [event.type for event in events][-2:] == ["workspace.recreated", "session.bound"]


@pytest.mark.asyncio
async def test_cancel_stops_live_run_and_marks_resume_available(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="running",
        last_bound_agent_session_id="agent-123",
    )

    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
    )
    attachment = FakeAttachment(agent_session_id="agent-123")
    service.attachments[session.id] = attachment

    cancelled = await service.cancel(session.id)

    assert attachment.cancelled is True
    assert cancelled.status == "resume_available"
    assert session.id not in service.attachments


@pytest.mark.asyncio
async def test_reset_stops_live_run_and_marks_workspace_missing(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(
        session.id,
        status="running",
        last_bound_agent_session_id="agent-123",
    )

    worktrees = FakeWorktrees(tmp_path)
    service = SessionService(
        settings=make_settings(tmp_path, db.path),
        store=store,
        worktree_manager=worktrees,
    )
    attachment = FakeAttachment(agent_session_id="agent-123")
    service.attachments[session.id] = attachment

    reset = await service.reset(session.id)

    assert attachment.cancelled is True
    assert reset.workspace_state == "missing"
    assert reset.status == "resume_available"
    assert worktrees.removed == [Path(session.worktree_path)]
