# Codex App Server Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ACP-shaped Codex launcher with a shared `codex app-server` integration that preserves All Hands-owned Codex threads across host restarts and exposes explicit Approve and Deny actions in the session UI.

**Architecture:** Add a dedicated Codex transport stack beside ACP: a machine-scoped daemon manager, a websocket JSON-RPC client, and a Codex session adapter that maps All Hands sessions to durable Codex `threadId` values. Persist Codex thread and pending approval metadata in SQLite, route `launcher="codex"` through the new adapter inside `SessionService`, and surface pending approval data through the existing HTTP and Solid session detail flow.

**Tech Stack:** Python 3.12, Tornado, SQLite, `aiohttp`, Solid, Vitest, pytest, pytest-asyncio

---

## File Structure

### Backend

- Modify: `pyproject.toml`
  Add `aiohttp` as a direct dependency for loopback health checks and websocket transport.
- Modify: `src/allhands_host/config.py`
  Add `codex_app_server_port` and `codex_binary` settings.
- Modify: `src/allhands_host/models.py`
  Add a durable `CodexSessionRecord` dataclass.
- Modify: `src/allhands_host/db.py`
  Add the `codex_sessions` table and migration path.
- Modify: `src/allhands_host/store.py`
  Add CRUD helpers for Codex session metadata and pending approval state.
- Create: `src/allhands_host/codex_daemon.py`
  Own the shared `codex app-server` lifecycle, token file, and readiness checks.
- Create: `src/allhands_host/codex_client.py`
  Handle websocket JSON-RPC initialization, requests, notifications, and server requests.
- Create: `src/allhands_host/codex_session_adapter.py`
  Translate All Hands session actions into Codex thread and turn operations.
- Modify: `src/allhands_host/session_service.py`
  Route Codex sessions through the new adapter and reconcile stale Codex state after restart.
- Modify: `src/allhands_host/http.py`
  Serialize `pendingApproval` and add approve/deny handlers.
- Modify: `src/allhands_host/app.py`
  Register the new approval routes.
- Modify: `src/allhands_host/launchers/catalog.py`
  Keep ACP launchers in the launcher catalog while still exposing `codex` in `availableLaunchers`.
- Delete: `src/allhands_host/launchers/codex.py`
  Remove the obsolete ACP-shaped Codex launcher.

### Frontend

- Modify: `frontend/src/lib/api.ts`
  Add `PendingApproval`, normalize approval data, and add approve/deny API helpers.
- Modify: `frontend/src/lib/session-detail-store.ts`
  Persist `pendingApproval`, add approve/deny actions, and honor event payload run-state overrides.
- Modify: `frontend/src/lib/session-store.ts`
  Keep list-state projections correct when Codex uses `session.completed` plus `runState: "resume_available"`.
- Create: `frontend/src/components/approval-card.tsx`
  Render the pending approval summary with Approve and Deny actions.
- Modify: `frontend/src/routes/session.tsx`
  Render the approval card and describe Codex-specific timeline events.

### Tests

- Create: `tests/test_config.py`
- Create: `tests/test_codex_daemon.py`
- Create: `tests/test_codex_client.py`
- Create: `tests/test_codex_session_adapter.py`
- Modify: `tests/test_store.py`
- Modify: `tests/test_session_service.py`
- Modify: `tests/test_http_api.py`
- Modify: `tests/test_launchers.py`
- Modify: `frontend/src/lib/session-detail-store.test.ts`
- Modify: `frontend/src/routes/session.test.tsx`

## Task 1: Persist Codex settings and session metadata

**Files:**
- Modify: `pyproject.toml`
- Modify: `src/allhands_host/config.py`
- Modify: `src/allhands_host/models.py`
- Modify: `src/allhands_host/db.py`
- Modify: `src/allhands_host/store.py`
- Create: `tests/test_config.py`
- Modify: `tests/test_store.py`

- [ ] **Step 1: Write the failing config and store tests**

```python
# tests/test_config.py
from types import SimpleNamespace
from pathlib import Path

from allhands_host.config import load_settings


def test_load_settings_exposes_codex_app_server_defaults():
    opts = SimpleNamespace(
        project_root=str(Path("/tmp/projects")),
        database_path="",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )

    settings = load_settings(opts)

    assert settings.codex_app_server_port == 21992
    assert settings.codex_binary == "codex"
```

```python
# tests/test_store.py
from allhands_host.models import CodexSessionRecord, SessionRecord


def test_store_persists_codex_session_metadata(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session_1",
    )
    store.create_session(session)
    store.upsert_codex_session(
        CodexSessionRecord(
            session_id=session.id,
            thread_id="thr_123",
            active_turn_id="turn_123",
            pending_request_id="req_123",
            pending_request_kind="command",
            pending_request_payload={"summary": "Run tests"},
            created_at=session.created_at,
            updated_at=session.updated_at,
        )
    )

    fetched = store.get_codex_session(session.id)

    assert fetched.thread_id == "thr_123"
    assert fetched.active_turn_id == "turn_123"
    assert fetched.pending_request_kind == "command"
    assert fetched.pending_request_payload == {"summary": "Run tests"}
```

- [ ] **Step 2: Run the tests to verify the new surface is missing**

Run:

```bash
uv run pytest tests/test_config.py tests/test_store.py -q
```

Expected: FAIL with missing `codex_app_server_port`, `codex_binary`, `CodexSessionRecord`, and missing Codex store helpers.

- [ ] **Step 3: Add the settings, schema, model, and store helpers**

```toml
# pyproject.toml
dependencies = [
  "agent-client-protocol>=0.1.0",
  "aiohttp>=3.13",
  "pywebpush>=2.0.3",
  "tornado>=6.4",
]
```

```python
# src/allhands_host/config.py
@dataclass(frozen=True)
class Settings:
    project_root: Path
    database_path: Path
    host: str
    port: int
    vapid_public_key: str
    vapid_private_key: str
    codex_app_server_port: int
    codex_binary: str


define("codex_app_server_port", default=21992, type=int, help="Loopback port for shared codex app-server")
define("codex_binary", default="codex", help="Codex CLI binary")


return Settings(
    project_root=project_root,
    database_path=database_path,
    host=opts.host,
    port=opts.port,
    vapid_public_key=opts.vapid_public_key,
    vapid_private_key=opts.vapid_private_key,
    codex_app_server_port=opts.codex_app_server_port,
    codex_binary=opts.codex_binary,
)
```

```python
# src/allhands_host/models.py
@dataclass(frozen=True)
class CodexSessionRecord:
    session_id: str
    thread_id: str
    active_turn_id: str | None
    pending_request_id: str | None
    pending_request_kind: str | None
    pending_request_payload: dict | None
    created_at: str
    updated_at: str
```

```python
# src/allhands_host/db.py
create table if not exists codex_sessions (
  session_id text primary key,
  thread_id text not null unique,
  active_turn_id text,
  pending_request_id text,
  pending_request_kind text,
  pending_request_payload_json text,
  created_at text not null,
  updated_at text not null
);
```

```python
# src/allhands_host/store.py
def upsert_codex_session(self, session: CodexSessionRecord) -> None:
    with self.db.connect() as connection:
        connection.execute(
            """
            insert into codex_sessions (
              session_id, thread_id, active_turn_id, pending_request_id,
              pending_request_kind, pending_request_payload_json, created_at, updated_at
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(session_id) do update set
              thread_id = excluded.thread_id,
              active_turn_id = excluded.active_turn_id,
              pending_request_id = excluded.pending_request_id,
              pending_request_kind = excluded.pending_request_kind,
              pending_request_payload_json = excluded.pending_request_payload_json,
              updated_at = excluded.updated_at
            """,
            (
                session.session_id,
                session.thread_id,
                session.active_turn_id,
                session.pending_request_id,
                session.pending_request_kind,
                json.dumps(session.pending_request_payload),
                session.created_at,
                session.updated_at,
            ),
        )


def get_codex_session(self, session_id: str) -> CodexSessionRecord:
    with self.db.connect() as connection:
        row = connection.execute(
            """
            select
              session_id,
              thread_id,
              active_turn_id,
              pending_request_id,
              pending_request_kind,
              pending_request_payload_json,
              created_at,
              updated_at
            from codex_sessions
            where session_id = ?
            """,
            (session_id,),
        ).fetchone()
    if row is None:
        raise KeyError(session_id)
    return CodexSessionRecord(
        session_id=row["session_id"],
        thread_id=row["thread_id"],
        active_turn_id=row["active_turn_id"],
        pending_request_id=row["pending_request_id"],
        pending_request_kind=row["pending_request_kind"],
        pending_request_payload=json.loads(row["pending_request_payload_json"]) if row["pending_request_payload_json"] else None,
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def clear_codex_pending_request(self, session_id: str) -> None:
    with self.db.connect() as connection:
        connection.execute(
            """
            update codex_sessions
            set pending_request_id = null,
                pending_request_kind = null,
                pending_request_payload_json = null,
                updated_at = ?
            where session_id = ?
            """,
            (utc_now(), session_id),
        )
```

- [ ] **Step 4: Run the focused backend tests**

Run:

```bash
uv run pytest tests/test_config.py tests/test_store.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit the persistence layer**

```bash
git add pyproject.toml src/allhands_host/config.py src/allhands_host/models.py src/allhands_host/db.py src/allhands_host/store.py tests/test_config.py tests/test_store.py
git commit -m "feat: persist codex session metadata"
```

## Task 2: Add the shared Codex daemon manager

**Files:**
- Create: `src/allhands_host/codex_daemon.py`
- Create: `tests/test_codex_daemon.py`

- [ ] **Step 1: Write failing daemon-manager tests**

```python
# tests/test_codex_daemon.py
import asyncio
from pathlib import Path

import pytest

from allhands_host.codex_daemon import CodexDaemonManager
from allhands_host.config import Settings


class FakeProcess:
    def __init__(self):
        self.pid = 4321


@pytest.mark.asyncio
async def test_ensure_running_reuses_healthy_daemon(tmp_path: Path):
    settings = Settings(
        project_root=tmp_path,
        database_path=tmp_path / "allhands.sqlite3",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    spawned = False

    async def probe() -> bool:
        return True

    async def spawn(_argv: list[str]) -> FakeProcess:
        nonlocal spawned
        spawned = True
        return FakeProcess()

    manager = CodexDaemonManager(settings=settings, probe_ready=probe, spawn_process=spawn)

    handle = await manager.ensure_running()

    assert handle.endpoint == "ws://127.0.0.1:21992"
    assert spawned is False


@pytest.mark.asyncio
async def test_ensure_running_spawns_when_probe_fails(tmp_path: Path):
    settings = Settings(
        project_root=tmp_path,
        database_path=tmp_path / "allhands.sqlite3",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    probes = iter([False, False, True])
    spawned: list[list[str]] = []

    async def probe() -> bool:
        return next(probes)

    async def spawn(argv: list[str]) -> FakeProcess:
        spawned.append(argv)
        return FakeProcess()

    manager = CodexDaemonManager(settings=settings, probe_ready=probe, spawn_process=spawn)

    handle = await manager.ensure_running()

    assert handle.endpoint == "ws://127.0.0.1:21992"
    assert (tmp_path / ".allhands-codex-token").exists()
    assert spawned[0][:2] == ["codex", "app-server"]
```

- [ ] **Step 2: Run the daemon-manager tests and confirm they fail**

Run:

```bash
uv run pytest tests/test_codex_daemon.py -q
```

Expected: FAIL because `CodexDaemonManager` does not exist.

- [ ] **Step 3: Implement the shared daemon manager**

```python
# src/allhands_host/codex_daemon.py
from dataclasses import dataclass
from pathlib import Path
import secrets


@dataclass(frozen=True)
class CodexDaemonHandle:
    endpoint: str
    token: str


class CodexDaemonManager:
    def __init__(
        self,
        settings: Settings,
        probe_ready=None,
        spawn_process=None,
    ):
        self.settings = settings
        self.endpoint = f"ws://127.0.0.1:{settings.codex_app_server_port}"
        self.token_path = settings.database_path.parent / ".allhands-codex-token"
        self._probe_ready = probe_ready or self._default_probe_ready
        self._spawn_process = spawn_process or self._default_spawn_process
        self._lock = asyncio.Lock()

    async def ensure_running(self) -> CodexDaemonHandle:
        async with self._lock:
            token = self._read_or_create_token()
            if await self._probe_ready():
                return CodexDaemonHandle(endpoint=self.endpoint, token=token)
            argv = [
                self.settings.codex_binary,
                "app-server",
                "--listen",
                self.endpoint,
                "--ws-auth",
                "capability-token",
                "--ws-token-file",
                str(self.token_path),
            ]
            await self._spawn_process(argv)
            for _ in range(20):
                if await self._probe_ready():
                    return CodexDaemonHandle(endpoint=self.endpoint, token=token)
                await asyncio.sleep(0.25)
            raise RuntimeError("codex app-server did not become ready")
```

- [ ] **Step 4: Run the daemon-manager tests**

Run:

```bash
uv run pytest tests/test_codex_daemon.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit the daemon manager**

```bash
git add src/allhands_host/codex_daemon.py tests/test_codex_daemon.py
git commit -m "feat: add shared codex daemon manager"
```

## Task 3: Add the Codex app-server websocket client

**Files:**
- Create: `src/allhands_host/codex_client.py`
- Create: `tests/test_codex_client.py`

- [ ] **Step 1: Write the failing websocket client tests**

```python
# tests/test_codex_client.py
import asyncio
import json

from aiohttp import web
import pytest

from allhands_host.codex_client import CodexAppServerClient


@pytest.mark.asyncio
async def test_client_initializes_before_thread_start(aiohttp_unused_port):
    seen_methods: list[str] = []

    async def websocket_handler(request: web.Request) -> web.WebSocketResponse:
        assert request.headers["Authorization"].startswith("Bearer ")
        ws = web.WebSocketResponse()
        await ws.prepare(request)

        initialize = json.loads((await ws.receive()).data)
        seen_methods.append(initialize["method"])
        await ws.send_json(
            {"id": initialize["id"], "result": {"userAgent": "codex", "codexHome": "/tmp/.codex", "platformFamily": "unix", "platformOs": "darwin"}}
        )

        initialized = json.loads((await ws.receive()).data)
        seen_methods.append(initialized["method"])

        request_message = json.loads((await ws.receive()).data)
        seen_methods.append(request_message["method"])
        await ws.send_json({"id": request_message["id"], "result": {"thread": {"id": "thr_123"}}})
        await ws.close()
        return ws

    app = web.Application()
    app.router.add_get("/", websocket_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    port = aiohttp_unused_port()
    site = web.TCPSite(runner, "127.0.0.1", port)
    await site.start()

    client = CodexAppServerClient(endpoint=f"ws://127.0.0.1:{port}/", token="secret")
    await client.connect()
    thread = await client.thread_start(cwd="/tmp/projects/api")
    await client.close()
    await runner.cleanup()

    assert thread["id"] == "thr_123"
    assert seen_methods == ["initialize", "initialized", "thread/start"]
```

- [ ] **Step 2: Run the websocket client test and confirm the missing client**

Run:

```bash
uv run pytest tests/test_codex_client.py -q
```

Expected: FAIL because `CodexAppServerClient` does not exist.

- [ ] **Step 3: Implement the JSON-RPC websocket client**

```python
# src/allhands_host/codex_client.py
import asyncio
from collections.abc import Awaitable, Callable

import aiohttp


class CodexRpcError(RuntimeError):
    pass


class CodexAppServerClient:
    def __init__(self, endpoint: str, token: str, on_server_request: Callable[[dict], Awaitable[None]] | None = None):
        self.endpoint = endpoint
        self.token = token
        self.on_server_request = on_server_request
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task[None] | None = None

    async def connect(self) -> None:
        self._session = aiohttp.ClientSession(headers={"Authorization": f"Bearer {self.token}"})
        self._ws = await self._session.ws_connect(self.endpoint)
        await self.request(
            "initialize",
            {"clientInfo": {"name": "allhands_host", "title": "All Hands Host", "version": "0.1.0"}},
        )
        await self.notify("initialized", {})
        self._reader_task = asyncio.create_task(self._read_messages())

    async def request(self, method: str, params: dict | None = None) -> dict:
        self._next_id += 1
        request_id = self._next_id
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        await self._ws.send_json({"id": request_id, "method": method, "params": params or {}})
        return await future

    async def notify(self, method: str, params: dict | None = None) -> None:
        await self._ws.send_json({"method": method, "params": params or {}})

    async def thread_start(self, cwd: str) -> dict:
        payload = await self.request("thread/start", {"cwd": cwd})
        return payload["thread"]
```

```python
# src/allhands_host/codex_client.py
    async def thread_resume(self, thread_id: str) -> dict:
        payload = await self.request("thread/resume", {"threadId": thread_id})
        return payload["thread"]

    async def turn_start(self, thread_id: str, input_items: list[dict], cwd: str) -> dict:
        payload = await self.request(
            "turn/start",
            {
                "threadId": thread_id,
                "input": input_items,
                "cwd": cwd,
                "approvalPolicy": "unlessTrusted",
                "approvalsReviewer": "user",
                "sandboxPolicy": {
                    "type": "workspaceWrite",
                    "writableRoots": [cwd],
                    "networkAccess": False,
                },
            },
        )
        return payload["turn"]

    async def turn_interrupt(self, thread_id: str, turn_id: str) -> None:
        await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

    async def thread_archive(self, thread_id: str) -> None:
        await self.request("thread/archive", {"threadId": thread_id})
```

- [ ] **Step 4: Run the websocket client test**

Run:

```bash
uv run pytest tests/test_codex_client.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit the client**

```bash
git add src/allhands_host/codex_client.py tests/test_codex_client.py
git commit -m "feat: add codex app-server client"
```

## Task 4: Build the Codex session adapter and integrate it into session service

**Files:**
- Create: `src/allhands_host/codex_session_adapter.py`
- Modify: `src/allhands_host/session_service.py`
- Modify: `src/allhands_host/launchers/catalog.py`
- Delete: `src/allhands_host/launchers/codex.py`
- Modify: `tests/test_launchers.py`
- Create: `tests/test_codex_session_adapter.py`
- Modify: `tests/test_session_service.py`

- [ ] **Step 1: Write the failing adapter and service tests**

```python
# tests/test_codex_session_adapter.py
from pathlib import Path

import pytest

from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


class FakeWorktreeManager:
    def create(self, repo_path: Path, session_id: str) -> None:
        worktree = repo_path.parent / ".worktrees" / session_id
        worktree.mkdir(parents=True, exist_ok=True)


class FakeDaemonManager:
    async def ensure_running(self):
        return type("Handle", (), {"endpoint": "ws://127.0.0.1:21992", "token": "secret"})()


class FakeClient:
    async def thread_start(self, cwd: str):
        assert cwd.endswith("session_1")
        return {"id": "thr_123"}

    async def turn_start(self, thread_id: str, input_items: list[dict], cwd: str):
        assert thread_id == "thr_123"
        assert input_items == [{"type": "text", "text": "Fix the API"}]
        return {"id": "turn_123", "status": "inProgress"}


@pytest.mark.asyncio
async def test_bootstrap_persists_thread_and_turn_ids(tmp_path: Path):
    repo_path = tmp_path / "repo"
    repo_path.mkdir()
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new(
        launcher="codex",
        repo_path=str(repo_path),
        worktree_path=str(tmp_path / ".worktrees" / "session_1"),
    )
    store.create_session(session)

    async def client_factory(_handle):
        return FakeClient()

    adapter = CodexSessionAdapter(
        store=store,
        worktree_manager=FakeWorktreeManager(),
        daemon_manager=FakeDaemonManager(),
        client_factory=client_factory,
    )

    await adapter.bootstrap(session, "Fix the API")

    codex = store.get_codex_session(session.id)
    refreshed = store.get_session(session.id)

    assert codex.thread_id == "thr_123"
    assert codex.active_turn_id == "turn_123"
    assert refreshed.status == "running"
```

```python
# tests/test_session_service.py
from dataclasses import replace

from allhands_host.db import Database
from allhands_host.store import SessionStore


class FakeCodexAdapter:
    def __init__(self):
        self.resumed: list[str] = []

    async def resume(self, session):
        self.resumed.append(session.id)
        return replace(session, status="running")


@pytest.mark.asyncio
async def test_codex_session_service_resumes_using_stored_thread_id(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new(
        launcher="codex",
        repo_path=str(tmp_path / "repo"),
        worktree_path=str(tmp_path / "repo/.worktrees/session_1"),
    )
    store.create_session(session)
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
    fake_codex = FakeCodexAdapter()
    service = SessionService(
        settings=Settings(
            project_root=tmp_path,
            database_path=tmp_path / "allhands.sqlite3",
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
            codex_app_server_port=21992,
            codex_binary="codex",
        ),
        store=store,
        launcher_catalog=FakeLauncherCatalog(FakeLauncher()),
        codex_adapter=fake_codex,
    )

    resumed = await service.resume(session.id)

    assert resumed.status == "running"
    assert fake_codex.resumed == [session.id]
```

```python
# tests/test_launchers.py
from allhands_host.launchers.catalog import LauncherCatalog, available_launchers


def test_catalog_keeps_acp_launchers_while_exposing_codex():
    catalog = LauncherCatalog(project_root=Path("/tmp/projects"))

    assert catalog.slugs() == ["claude", "pi"]
    assert available_launchers() == ["claude", "codex", "pi"]
```

- [ ] **Step 2: Run the backend integration tests and confirm failure**

Run:

```bash
uv run pytest tests/test_codex_session_adapter.py tests/test_session_service.py tests/test_launchers.py -q
```

Expected: FAIL because the adapter, launcher cleanup, and Codex delegation do not exist yet.

- [ ] **Step 3: Implement the adapter and session-service delegation**

```python
# src/allhands_host/codex_session_adapter.py
from dataclasses import dataclass
import asyncio
import contextlib


@dataclass
class LiveCodexSession:
    client: CodexAppServerClient
    thread_id: str
    active_turn_id: str | None
    pump_task: asyncio.Task[None]


class NoPendingApprovalError(RuntimeError):
    pass


class CodexSessionAdapter:
    def __init__(self, store: SessionStore, worktree_manager: WorktreeManager, daemon_manager: CodexDaemonManager, client_factory=None):
        self.store = store
        self.worktree_manager = worktree_manager
        self.daemon_manager = daemon_manager
        self.client_factory = client_factory or self._default_client_factory
        self.live_sessions: dict[str, LiveCodexSession] = {}

    async def bootstrap(self, session: SessionRecord, prompt: str) -> None:
        repo_path = Path(session.repo_path)
        await asyncio.to_thread(self.worktree_manager.create, repo_path, session.id)
        handle = await self.daemon_manager.ensure_running()
        client = await self.client_factory(handle)
        thread = await client.thread_start(cwd=session.worktree_path)
        turn = await client.turn_start(
            thread_id=thread["id"],
            input_items=[{"type": "text", "text": prompt}],
            cwd=session.worktree_path,
        )
        self.store.upsert_codex_session(
            CodexSessionRecord(
                session_id=session.id,
                thread_id=thread["id"],
                active_turn_id=turn["id"],
                pending_request_id=None,
                pending_request_kind=None,
                pending_request_payload=None,
                created_at=session.created_at,
                updated_at=utc_now(),
            )
        )
        self.store.append_event(session.id, "session.bound", {"threadId": thread["id"]})
        self.store.update_session_projection(session.id, status="running", workspace_state="ready")
```

```python
# src/allhands_host/codex_session_adapter.py
    async def reconcile_startup_state(self) -> None:
        for session in self.store.list_sessions():
            if session.launcher != "codex":
                continue
            if session.status in {"running", "attention_required"}:
                self.store.update_session_projection(
                    session.id,
                    status="resume_available",
                    active_notification_kind="none",
                )
                self.store.clear_codex_pending_request(session.id)
                self.store.upsert_codex_session(
                    replace(self.store.get_codex_session(session.id), active_turn_id=None)
                )
```

```python
# src/allhands_host/session_service.py
if launcher == "codex":
    self._track_bootstrap(self.codex_adapter.bootstrap(session, prompt))
    return self.store.get_session(session.id)


if session.launcher == "codex":
    return await self.codex_adapter.resume(session)
```

```python
# src/allhands_host/launchers/catalog.py
from allhands_host.launchers.claude import ClaudeLauncher
from allhands_host.launchers.pi import PiLauncher

AVAILABLE_LAUNCHERS = ["claude", "codex", "pi"]


class LauncherCatalog:
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self._launchers = {
            "claude": ClaudeLauncher(),
            "pi": PiLauncher(),
        }


def available_launchers() -> list[str]:
    return AVAILABLE_LAUNCHERS.copy()
```

- [ ] **Step 4: Run the adapter and service tests**

Run:

```bash
uv run pytest tests/test_codex_session_adapter.py tests/test_session_service.py tests/test_launchers.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit the Codex adapter integration**

```bash
git add src/allhands_host/codex_session_adapter.py src/allhands_host/session_service.py src/allhands_host/launchers/catalog.py tests/test_codex_session_adapter.py tests/test_session_service.py tests/test_launchers.py
git rm src/allhands_host/launchers/codex.py
git commit -m "feat: integrate codex app-server sessions"
```

## Task 5: Expose pending approval data and approve/deny HTTP endpoints

**Files:**
- Modify: `src/allhands_host/http.py`
- Modify: `src/allhands_host/app.py`
- Modify: `src/allhands_host/session_service.py`
- Modify: `tests/test_http_api.py`

- [ ] **Step 1: Write failing HTTP API tests**

```python
# tests/test_http_api.py
def test_session_detail_includes_pending_approval(self):
    self.session_service.pending_approval = {
        "kind": "command",
        "summary": "Run npm test",
        "reason": "Validate the workspace",
        "command": ["npm", "test"],
        "cwd": "/tmp/projects/api/.worktrees/session_123",
    }

    response = self.fetch("/sessions/session_123")
    payload = json.loads(response.body)

    assert response.code == 200
    assert payload["pendingApproval"]["kind"] == "command"
    assert payload["pendingApproval"]["command"] == ["npm", "test"]


def test_approve_endpoint_resolves_pending_approval(self):
    response = self.fetch("/sessions/session_123/approval/approve", method="POST", body="{}")
    payload = json.loads(response.body)

    assert response.code == 200
    assert payload["runState"] == "running"
    assert self.session_service.approval_actions == [{"sessionId": "session_123", "decision": "approve"}]
```

- [ ] **Step 2: Run the HTTP API tests and confirm failure**

Run:

```bash
uv run pytest tests/test_http_api.py -q
```

Expected: FAIL because session detail does not include `pendingApproval` and the approval endpoints do not exist.

- [ ] **Step 3: Implement the handlers and serialization**

```python
# src/allhands_host/http.py
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
```

```python
# src/allhands_host/http.py
class SessionApprovalApproveHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.approve_pending_request(session_id)
        self.finish(serialize_session(session))


class SessionApprovalDenyHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.deny_pending_request(session_id)
        self.finish(serialize_session(session))
```

```python
# src/allhands_host/app.py
(r"/sessions/([^/]+)/approval/approve", SessionApprovalApproveHandler, {"session_service": session_service}),
(r"/sessions/([^/]+)/approval/deny", SessionApprovalDenyHandler, {"session_service": session_service}),
```

- [ ] **Step 4: Run the HTTP API tests**

Run:

```bash
uv run pytest tests/test_http_api.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit the HTTP API changes**

```bash
git add src/allhands_host/http.py src/allhands_host/app.py src/allhands_host/session_service.py tests/test_http_api.py
git commit -m "feat: expose codex approval endpoints"
```

## Task 6: Add the frontend approval UI and Codex-aware state transitions

**Files:**
- Create: `frontend/src/components/approval-card.tsx`
- Modify: `frontend/src/lib/api.ts`
- Modify: `frontend/src/lib/session-detail-store.ts`
- Modify: `frontend/src/lib/session-store.ts`
- Modify: `frontend/src/routes/session.tsx`
- Modify: `frontend/src/lib/session-detail-store.test.ts`
- Modify: `frontend/src/routes/session.test.tsx`

- [ ] **Step 1: Write the failing frontend tests**

```tsx
// frontend/src/lib/session-detail-store.test.ts
test("approvePending posts to the codex approval endpoint", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/sessions/session-1")) {
      return {
        ok: true,
        json: async () => ({
          id: "session-1",
          runState: "attention_required",
          workspaceState: "ready",
          pendingApproval: {
            kind: "command",
            summary: "Run npm test",
            command: ["npm", "test"],
            cwd: "/tmp/projects/api/.worktrees/session-1"
          }
        })
      };
    }
    if (url.endsWith("/sessions/session-1/timeline")) {
      return { ok: true, json: async () => ({ events: [] }) };
    }
    if (url.endsWith("/sessions/session-1/approval/approve")) {
      return {
        ok: true,
        json: async () => ({
          id: "session-1",
          runState: "running",
          workspaceState: "ready"
        })
      };
    }
    if (url.endsWith("/sessions/session-1/seen")) {
      return { ok: true, json: async () => ({}) };
    }
    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("EventSource", FakeEventSource);

  const { result } = renderHook(() => createSessionDetailState("session-1"));

  await waitFor(() => expect(result.detail()?.pendingApproval?.kind).toBe("command"));
  await result.approvePending();

  expect(fetchMock).toHaveBeenCalledWith(
    "/sessions/session-1/approval/approve",
    expect.objectContaining({ method: "POST" })
  );
});
```

```tsx
// frontend/src/routes/session.test.tsx
import { fireEvent, render, screen } from "@solidjs/testing-library";

test("renders codex approval card and action buttons", async () => {
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true, json: async () => ({}) }));
  vi.stubGlobal("EventSource", FakeEventSource);

  render(() => (
    <SessionRoute
      sessionId="session-1"
      initialDetail={{
        id: "session-1",
        title: "API Refactor",
        runState: "attention_required",
        workspaceState: "ready",
        pendingApproval: {
          kind: "command",
          summary: "Run npm test",
          command: ["npm", "test"],
          cwd: "/tmp/projects/api/.worktrees/session-1"
        }
      }}
      initialTimeline={[]}
    />
  ));

  expect(screen.getByText("Run npm test")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Approve" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Deny" })).toBeTruthy();
});
```

- [ ] **Step 2: Run the frontend tests and confirm failure**

Run:

```bash
pnpm --dir frontend test -- --run frontend/src/lib/session-detail-store.test.ts frontend/src/routes/session.test.tsx
```

Expected: FAIL because `pendingApproval`, `approvePending`, `denyPending`, and the approval card do not exist.

- [ ] **Step 3: Implement the frontend API helpers, state, and UI**

```ts
// frontend/src/lib/api.ts
export type PendingApproval = {
  kind: "command" | "file_change" | "permissions";
  summary: string;
  reason?: string;
  command?: string[];
  cwd?: string;
};

export type SessionDetail = SessionSummary & {
  launcher?: string;
  repoPath?: string;
  worktreePath?: string;
  activeNotificationKind?: string;
  lastActivityAt?: string;
  lastSeenEventSeq?: number;
  pendingApproval?: PendingApproval;
};

type SessionApiRecord = {
  id: string;
  title?: string;
  status?: string;
  runState?: string;
  workspaceState?: string;
  launcher?: string;
  repoPath?: string;
  repo_path?: string;
  worktreePath?: string;
  worktree_path?: string;
  activeNotificationKind?: string;
  active_notification_kind?: string;
  lastActivityAt?: string;
  last_activity_at?: string;
  lastSeenEventSeq?: number;
  last_seen_event_seq?: number;
  pendingApproval?: PendingApproval;
  pending_approval?: PendingApproval;
};

function normalizeSession(session: SessionApiRecord): SessionDetail {
  const runState = session.runState ?? session.status ?? "created";
  const workspaceState = session.workspaceState ?? "ready";

  return {
    id: session.id,
    title: deriveTitle(session),
    status: runState,
    runState,
    workspaceState,
    launcher: session.launcher,
    repoPath: session.repoPath ?? session.repo_path,
    worktreePath: session.worktreePath ?? session.worktree_path,
    activeNotificationKind: session.activeNotificationKind ?? session.active_notification_kind,
    lastActivityAt: session.lastActivityAt ?? session.last_activity_at,
    lastSeenEventSeq: session.lastSeenEventSeq ?? session.last_seen_event_seq,
    pendingApproval: session.pendingApproval ?? session.pending_approval,
  };
}

export async function approveSessionApproval(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/approval/approve`));
}

export async function denySessionApproval(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/approval/deny`));
}
```

```ts
// frontend/src/lib/session-detail-store.ts
function applyEventToDetail(
  detail: SessionDetail | null,
  event: { type: string; payload: Record<string, unknown> }
): SessionDetail | null {
  if (detail == null) {
    return detail;
  }

  const payloadRunState =
    typeof event.payload.runState === "string"
      ? event.payload.runState
      : typeof event.payload.status === "string"
        ? event.payload.status
        : null;

  switch (event.type) {
    case "session.attention_required":
      return Object.assign({}, detail, {
        status: "attention_required",
        runState: "attention_required",
        pendingApproval: (event.payload.pendingApproval as SessionDetail["pendingApproval"]) ?? detail.pendingApproval
      });
    case "session.completed":
      return Object.assign({}, detail, {
        status: payloadRunState ?? "completed",
        runState: payloadRunState ?? "completed",
        pendingApproval: undefined
      });
    default:
      return detail;
  }
}
```

```tsx
// frontend/src/components/approval-card.tsx
import type { PendingApproval } from "../lib/api";

export function ApprovalCard(props: {
  approval: PendingApproval;
  onApprove: () => void;
  onDeny: () => void;
}) {
  return (
    <section aria-label="Pending approval">
      <h3>Approval required</h3>
      <p>{props.approval.summary}</p>
      {props.approval.command ? <pre>{props.approval.command.join(" ")}</pre> : null}
      <button type="button" onClick={props.onApprove}>Approve</button>
      <button type="button" onClick={props.onDeny}>Deny</button>
    </section>
  );
}
```

```tsx
// frontend/src/routes/session.tsx
{state.detail()?.pendingApproval ? (
  <ApprovalCard
    approval={state.detail()!.pendingApproval!}
    onApprove={() => void state.approvePending()}
    onDeny={() => void state.denyPending()}
  />
) : null}
```

- [ ] **Step 4: Run the frontend tests and build**

Run:

```bash
pnpm --dir frontend test -- --run
pnpm --dir frontend build
```

Expected: PASS.

- [ ] **Step 5: Commit the frontend Codex UI**

```bash
git add frontend/src/components/approval-card.tsx frontend/src/lib/api.ts frontend/src/lib/session-detail-store.ts frontend/src/lib/session-store.ts frontend/src/routes/session.tsx frontend/src/lib/session-detail-store.test.ts frontend/src/routes/session.test.tsx
git commit -m "feat: add codex approval ui"
```

## Task 7: Run full verification and manual smoke checks

**Files:**
- No planned source edits. If verification exposes bugs, fix them in the touched files above and commit the fixups with a focused commit message.

- [ ] **Step 1: Run the full backend and frontend automated suites**

Run:

```bash
uv run pytest -q
pnpm --dir frontend test -- --run
pnpm --dir frontend build
```

Expected: all commands PASS.

- [ ] **Step 2: Verify lazy daemon start and resume manually**

Run:

```bash
PYTHONPATH=src uv run python -m allhands_host.main --codex_app_server_port=21992 --vapid_public_key="$VAPID_PUBLIC_KEY" --vapid_private_key="$VAPID_PRIVATE_KEY"
```

Then verify in the browser:

- create a new Codex session and confirm the session leaves `created` quickly
- confirm the first Codex request starts the shared daemon
- complete a turn and confirm the session returns to `resume_available`
- restart `allhands_host`, reload the UI, and confirm the same session can resume the same Codex thread

- [ ] **Step 3: Verify approval handling manually**

Use a Codex prompt that triggers a shell command, file change, or permission request. Confirm:

- the session moves to `attention_required`
- the session detail page shows a summary plus Approve and Deny buttons
- approving returns the session to `running`
- denying leaves the turn recoverable and eventually returns the session to `resume_available`

- [ ] **Step 4: Commit only if verification exposed fixups**

If you made verification fixes:

```bash
git add <exact-files-you-fixed>
git commit -m "fix: tighten codex app-server integration"
```

If verification required no code changes, do not create an empty commit.

## Self-Review

### Spec coverage

- Shared daemon lifecycle: Task 2
- Stable websocket client and JSON-RPC handshake: Task 3
- Durable `threadId`, `active_turn_id`, and pending approval persistence: Task 1
- Session create, resume, cancel, reset, archive, and restart reconciliation: Task 4
- HTTP `pendingApproval` detail and approve/deny endpoints: Task 5
- Real Approve and Deny UI actions plus Codex-aware run-state handling: Task 6
- Full automated and manual verification on the target machine: Task 7

No spec gaps remain.

### Placeholder scan

- No `TODO`, `TBD`, or “implement later” markers remain.
- Every task contains concrete files, commands, and code snippets.
- Verification commands are explicit.

### Type consistency

- Backend durable record name: `CodexSessionRecord`
- Daemon manager name: `CodexDaemonManager`
- Websocket client name: `CodexAppServerClient`
- Adapter name: `CodexSessionAdapter`
- Frontend detail property: `pendingApproval`

These names are used consistently across tasks.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-codex-app-server.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
