from importlib import import_module
from pathlib import Path

import pytest

from allhands_host.db import Database
from allhands_host.models import CodexSessionRecord, SessionRecord
from allhands_host.store import SessionStore


def load_codex_session_adapter_module():
    try:
        return import_module("allhands_host.codex_session_adapter")
    except ModuleNotFoundError as exc:
        pytest.fail(f"expected allhands_host.codex_session_adapter module: {exc}")


class FakeWorktreeManager:
    def __init__(self):
        self.created: list[tuple[Path, str]] = []
        self.removed: list[tuple[Path, Path]] = []

    def create(self, repo_path: Path, session_id: str) -> Path:
        self.created.append((repo_path, session_id))
        return repo_path.parent / ".worktrees" / session_id

    def remove(self, repo_path: Path, worktree_path: Path) -> None:
        self.removed.append((repo_path, worktree_path))


class FakeDaemonManager:
    async def ensure_running(self):
        return type("Handle", (), {"endpoint": "ws://127.0.0.1:21992", "token": "secret"})()


class FakeClient:
    def __init__(self):
        self.connected = False
        self.closed = False
        self.thread_start_calls: list[str] = []
        self.thread_resume_calls: list[str] = []
        self.turn_start_calls: list[dict[str, object]] = []
        self.turn_interrupt_calls: list[tuple[str, str]] = []
        self.thread_archive_calls: list[str] = []

    async def connect(self) -> None:
        self.connected = True

    async def close(self) -> None:
        self.closed = True

    async def thread_start(self, cwd: str) -> dict:
        self.thread_start_calls.append(cwd)
        return {"id": "thr_123"}

    async def thread_resume(self, thread_id: str) -> dict:
        self.thread_resume_calls.append(thread_id)
        return {"id": thread_id}

    async def turn_start(self, thread_id: str, input_items: list[dict], cwd: str) -> dict:
        self.turn_start_calls.append({"thread_id": thread_id, "input_items": input_items, "cwd": cwd})
        return {"id": "turn_123", "status": "inProgress"}

    async def turn_interrupt(self, thread_id: str, turn_id: str) -> None:
        self.turn_interrupt_calls.append((thread_id, turn_id))

    async def thread_archive(self, thread_id: str) -> None:
        self.thread_archive_calls.append(thread_id)


def create_session(store: SessionStore, tmp_path: Path, *, launcher: str = "codex") -> SessionRecord:
    session = SessionRecord.new(
        launcher=launcher,
        repo_path=str(tmp_path / "repo"),
        worktree_path=str(tmp_path / "repo/.worktrees/session_1"),
    )
    store.create_session(session)
    return session


@pytest.mark.asyncio
async def test_bootstrap_persists_thread_and_turn_ids(tmp_path: Path):
    module = load_codex_session_adapter_module()
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    client = FakeClient()

    async def client_factory(_handle):
        return client

    adapter = module.CodexSessionAdapter(
        store=store,
        worktree_manager=FakeWorktreeManager(),
        daemon_manager=FakeDaemonManager(),
        client_factory=client_factory,
    )

    await adapter.bootstrap(session, "Fix the API")

    codex = store.get_codex_session(session.id)
    refreshed = store.get_session(session.id)

    assert client.connected is True
    assert codex.thread_id == "thr_123"
    assert codex.active_turn_id == "turn_123"
    assert refreshed.status == "running"
    assert refreshed.workspace_state == "ready"


@pytest.mark.asyncio
async def test_resume_uses_stored_thread_id(tmp_path: Path):
    module = load_codex_session_adapter_module()
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = create_session(store, tmp_path)
    store.update_session_projection(session.id, status="resume_available", workspace_state="missing")
    store.upsert_codex_session(
        CodexSessionRecord(
            session_id=session.id,
            thread_id="thr_123",
            active_turn_id=None,
            pending_request_id=None,
            pending_request_kind=None,
            pending_request_payload=None,
            created_at=session.created_at,
            updated_at=session.updated_at,
        )
    )
    worktrees = FakeWorktreeManager()
    client = FakeClient()

    async def client_factory(_handle):
        return client

    adapter = module.CodexSessionAdapter(
        store=store,
        worktree_manager=worktrees,
        daemon_manager=FakeDaemonManager(),
        client_factory=client_factory,
    )

    resumed = await adapter.resume(session)

    assert resumed.status == "running"
    assert resumed.workspace_state == "ready"
    assert client.thread_resume_calls == ["thr_123"]
    assert worktrees.created == [(Path(session.repo_path), session.id)]
