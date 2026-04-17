# ACP Mobile Host V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-user ACP-first daemon and installable PWA that can create, run, resume, and monitor concurrent coding-agent sessions on one host through REST, SSE, and background push notifications.

**Architecture:** Use a Python/Tornado backend with SQLite-backed logical sessions, append-only event storage, worktree management, and local stdio ACP attachments through launcher adapters. Serve a Solid SPA and PWA assets from the same backend; the SPA uses REST for snapshots, SSE for live updates, and push only when the app is backgrounded or closed.

**Tech Stack:** Python 3.12, `uv`, Tornado, `agent-client-protocol`, SQLite, `pnpm`, Vite, Solid, Ark UI, CSS modules, CSS variables, Vitest, pytest

---

## File Structure

### Backend

- `pyproject.toml`
  Python package metadata, runtime dependencies, dev dependencies, and pytest configuration.
- `src/allhands_host/config.py`
  Environment-backed runtime settings for project root, database path, host, port, launchers, and Web Push keys.
- `src/allhands_host/logging.py`
  Tornado-compatible logging setup with structured, readable defaults.
- `src/allhands_host/db.py`
  SQLite connection helpers, schema bootstrap, and transaction wrapper.
- `src/allhands_host/models.py`
  Typed dataclasses for sessions, events, launcher metadata, and push subscriptions.
- `src/allhands_host/store.py`
  CRUD and query layer for sessions, events, and subscriptions.
- `src/allhands_host/launchers/base.py`
  Launcher adapter protocol and shared helpers.
- `src/allhands_host/launchers/catalog.py`
  Enabled launcher registry and config-based allowlist assembly.
- `src/allhands_host/launchers/claude.py`
  Claude Code launcher and resume adapter.
- `src/allhands_host/launchers/codex.py`
  Codex launcher and resume adapter.
- `src/allhands_host/launchers/pi.py`
  Pi launcher and resume adapter.
- `src/allhands_host/worktrees.py`
  Repo-root validation, worktree branch naming, creation, cleanup, and archive helpers.
- `src/allhands_host/processes.py`
  Async subprocess runner with stdin/stdout/stderr pipes and lifecycle hooks.
- `src/allhands_host/acp_attachment.py`
  ACP stdio attachment, initialize/session flow, prompt/cancel handling, and event normalization.
- `src/allhands_host/notifications.py`
  Web Push subscription persistence and background notification sender.
- `src/allhands_host/http.py`
  Tornado handlers for REST endpoints, SPA asset serving, manifest, service worker, and SSE.
- `src/allhands_host/app.py`
  `build_app()` wiring for routes and shared services.
- `src/allhands_host/main.py`
  Process entry point.

### Frontend

- `frontend/package.json`
  Frontend scripts and dependencies.
- `frontend/tsconfig.json`
  TypeScript compiler settings.
- `frontend/vite.config.ts`
  Solid/Vite build config.
- `frontend/index.html`
  SPA entry document.
- `frontend/public/manifest.webmanifest`
  PWA manifest.
- `frontend/public/sw.js`
  Service worker for installability, notification click handling, and push event routing.
- `frontend/src/main.tsx`
  Solid application bootstrap.
- `frontend/src/app.tsx`
  Router and top-level providers.
- `frontend/src/lib/api.ts`
  REST client.
- `frontend/src/lib/events.ts`
  SSE client and replay cursor handling.
- `frontend/src/lib/push.ts`
  Notification permission and subscription registration helpers.
- `frontend/src/lib/session-store.ts`
  Session list/detail state and event application.
- `frontend/src/routes/control-room.tsx`
  Focused home view with quick-switch tray.
- `frontend/src/routes/inbox.tsx`
  Full session list view.
- `frontend/src/routes/session.tsx`
  Detailed timeline and action view.
- `frontend/src/components/session-tray.tsx`
  Quick-switch control room tray.
- `frontend/src/components/session-card.tsx`
  Session summary card used in control room and inbox.
- `frontend/src/components/timeline.tsx`
  Timeline renderer for normalized events.
- `frontend/src/components/prompt-box.tsx`
  Prompt input and submit state.
- `frontend/src/components/install-banner.tsx`
  Contextual PWA install affordance.
- `frontend/src/styles/tokens.css`
  Global CSS variables.
- `frontend/src/styles/app.css`
  Global layout and Ark-inspired base styling.
- `frontend/src/components/*.module.css`
  Component-local CSS modules.

### Tests

- `tests/test_health.py`
- `tests/test_server_info.py`
- `tests/test_store.py`
- `tests/test_worktrees.py`
- `tests/test_launchers.py`
- `tests/test_acp_attachment.py`
- `tests/test_http_api.py`
- `tests/fixtures/fake_acp_agent.py`
- `frontend/src/lib/session-store.test.ts`
- `frontend/src/routes/control-room.test.tsx`
- `frontend/src/routes/session.test.tsx`
- `frontend/src/lib/push.test.ts`

## Task 1: Bootstrap the Python daemon and health endpoint

**Files:**
- Create: `pyproject.toml`
- Create: `src/allhands_host/__init__.py`
- Create: `src/allhands_host/config.py`
- Create: `src/allhands_host/app.py`
- Create: `src/allhands_host/http.py`
- Create: `src/allhands_host/main.py`
- Test: `tests/test_health.py`

- [ ] **Step 1: Write the failing health test**

```python
from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app


class HealthHandlerTest(AsyncHTTPTestCase):
    def get_app(self):
        return build_app()

    def test_healthz(self):
        response = self.fetch("/healthz")
        assert response.code == 200
        assert response.headers["Content-Type"].startswith("application/json")
        assert response.body == b'{"ok":true}'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_health.py -q`

Expected: fail with `ModuleNotFoundError: No module named 'allhands_host'`

- [ ] **Step 3: Add the minimal backend skeleton**

```toml
[project]
name = "allhands-host"
version = "0.1.0"
description = "Single-user ACP mobile host"
requires-python = ">=3.12"
dependencies = [
  "agent-client-protocol>=0.1.0",
  "tornado>=6.4",
]

[dependency-groups]
dev = [
  "pytest>=8.3",
  "pytest-asyncio>=0.23",
]

[tool.pytest.ini_options]
pythonpath = ["src"]
```

```python
# src/allhands_host/config.py
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    project_root: Path = Path.cwd()


def load_settings() -> Settings:
    return Settings()
```

```python
# src/allhands_host/http.py
import tornado.web


class HealthHandler(tornado.web.RequestHandler):
    def get(self) -> None:
        self.set_header("Content-Type", "application/json")
        self.finish(b'{"ok":true}')
```

```python
# src/allhands_host/app.py
import tornado.web

from allhands_host.http import HealthHandler


def build_app() -> tornado.web.Application:
    return tornado.web.Application(
        [
            (r"/healthz", HealthHandler),
        ]
    )
```

```python
# src/allhands_host/main.py
from allhands_host.app import build_app


def main() -> None:
    app = build_app()
    app.listen(21991)
    import tornado.ioloop

    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `uv run pytest tests/test_health.py -q`

Expected: `1 passed`

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml src/allhands_host tests/test_health.py
git commit -m "feat: bootstrap tornado daemon health endpoint"
```

## Task 2: Add config, logging, and `GET /server-info`

**Files:**
- Modify: `src/allhands_host/config.py`
- Create: `src/allhands_host/logging.py`
- Create: `src/allhands_host/launchers/base.py`
- Create: `src/allhands_host/launchers/catalog.py`
- Modify: `src/allhands_host/http.py`
- Modify: `src/allhands_host/app.py`
- Test: `tests/test_server_info.py`

- [ ] **Step 1: Write the failing server-info test**

```python
import json
from pathlib import Path

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class ServerInfoHandlerTest(AsyncHTTPTestCase):
    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(settings=settings)

    def test_server_info(self):
        response = self.fetch("/server-info")
        payload = json.loads(response.body)
        assert response.code == 200
        assert payload["projectRoot"] == "/tmp/projects"
        assert payload["availableLaunchers"] == ["claude", "codex", "pi"]
        assert payload["transport"] == "sse"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_server_info.py -q`

Expected: fail because `Settings` and `/server-info` do not exist yet

- [ ] **Step 3: Implement settings, launcher catalog, and handler**

```python
# src/allhands_host/config.py
from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True)
class Settings:
    project_root: Path
    database_path: Path
    host: str
    port: int
    vapid_public_key: str
    vapid_private_key: str


def load_settings() -> Settings:
    project_root = Path(os.environ["ALLHANDS_PROJECT_ROOT"]).resolve()
    database_path = Path(os.environ.get("ALLHANDS_DB_PATH", ".allhands.sqlite3")).resolve()
    return Settings(
        project_root=project_root,
        database_path=database_path,
        host=os.environ.get("ALLHANDS_HOST", "127.0.0.1"),
        port=int(os.environ.get("ALLHANDS_PORT", "21991")),
        vapid_public_key=os.environ.get("ALLHANDS_VAPID_PUBLIC_KEY", ""),
        vapid_private_key=os.environ.get("ALLHANDS_VAPID_PRIVATE_KEY", ""),
    )
```

```python
# src/allhands_host/launchers/catalog.py
def available_launchers() -> list[str]:
    return ["claude", "codex", "pi"]
```

```python
# src/allhands_host/logging.py
import logging


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
```

```python
# src/allhands_host/http.py
import tornado.web

from allhands_host.config import Settings
from allhands_host.launchers.catalog import available_launchers


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
```

```python
# src/allhands_host/app.py
import tornado.web

from allhands_host.config import Settings, load_settings
from allhands_host.http import HealthHandler, ServerInfoHandler


def build_app(settings: Settings | None = None) -> tornado.web.Application:
    settings = settings or load_settings()
    return tornado.web.Application(
        [
            (r"/healthz", HealthHandler),
            (r"/server-info", ServerInfoHandler, {"settings": settings}),
        ]
    )
```

```python
# src/allhands_host/main.py
from allhands_host.app import build_app
from allhands_host.logging import configure_logging


def main() -> None:
    configure_logging()
    app = build_app()
    app.listen(21991)
    import tornado.ioloop

    tornado.ioloop.IOLoop.current().start()
```

- [ ] **Step 4: Run the new tests**

Run: `uv run pytest tests/test_health.py tests/test_server_info.py -q`

Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host tests/test_server_info.py
git commit -m "feat: expose server info and launcher catalog"
```

## Task 3: Build the SQLite-backed logical session and event store

**Files:**
- Create: `src/allhands_host/db.py`
- Create: `src/allhands_host/models.py`
- Create: `src/allhands_host/store.py`
- Modify: `src/allhands_host/app.py`
- Test: `tests/test_store.py`

- [ ] **Step 1: Write the failing store tests**

```python
from pathlib import Path

from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


def test_store_persists_sessions_and_events(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session-1",
    )
    store.create_session(session)
    store.append_event(session.id, "session.created", {"status": "created"})

    fetched = store.get_session(session.id)
    events = store.list_events(session.id, after_seq=0)

    assert fetched.id == session.id
    assert fetched.status == "created"
    assert events[0].type == "session.created"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_store.py -q`

Expected: fail because `Database`, `SessionRecord`, and `SessionStore` do not exist yet

- [ ] **Step 3: Implement schema and store primitives**

```python
# src/allhands_host/models.py
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import uuid4


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


@dataclass(frozen=True)
class SessionRecord:
    id: str
    launcher: str
    repo_path: str
    worktree_path: str
    status: str
    created_at: str
    updated_at: str

    @classmethod
    def new(cls, launcher: str, repo_path: str, worktree_path: str) -> "SessionRecord":
        now = utc_now()
        return cls(
            id=f"session_{uuid4().hex[:12]}",
            launcher=launcher,
            repo_path=repo_path,
            worktree_path=worktree_path,
            status="created",
            created_at=now,
            updated_at=now,
        )
```

```python
# src/allhands_host/db.py
import sqlite3
from pathlib import Path


SCHEMA = """
create table if not exists sessions (
  id text primary key,
  launcher text not null,
  repo_path text not null,
  worktree_path text not null,
  status text not null,
  created_at text not null,
  updated_at text not null
);
create table if not exists events (
  session_id text not null,
  seq integer not null,
  type text not null,
  payload_json text not null,
  created_at text not null,
  primary key (session_id, seq)
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    def migrate(self) -> None:
        with self.connect() as connection:
            connection.executescript(SCHEMA)
```

```python
# src/allhands_host/store.py
import json
from allhands_host.db import Database
from allhands_host.models import SessionRecord, utc_now


class SessionStore:
    def __init__(self, db: Database):
        self.db = db

    def create_session(self, session: SessionRecord) -> None:
        with self.db.connect() as connection:
            connection.execute(
                "insert into sessions values (?, ?, ?, ?, ?, ?, ?)",
                (
                    session.id,
                    session.launcher,
                    session.repo_path,
                    session.worktree_path,
                    session.status,
                    session.created_at,
                    session.updated_at,
                ),
            )

    def get_session(self, session_id: str) -> SessionRecord:
        with self.db.connect() as connection:
            row = connection.execute("select * from sessions where id = ?", (session_id,)).fetchone()
        return SessionRecord(**dict(row))

    def append_event(self, session_id: str, type_: str, payload: dict) -> None:
        with self.db.connect() as connection:
            current = connection.execute(
                "select coalesce(max(seq), 0) from events where session_id = ?",
                (session_id,),
            ).fetchone()[0]
            connection.execute(
                "insert into events values (?, ?, ?, ?, ?)",
                (session_id, current + 1, type_, json.dumps(payload), utc_now()),
            )

    def list_events(self, session_id: str, after_seq: int) -> list:
        with self.db.connect() as connection:
            rows = connection.execute(
                "select seq, type, payload_json from events where session_id = ? and seq > ? order by seq asc",
                (session_id, after_seq),
            ).fetchall()
        return [type("Event", (), {"seq": row["seq"], "type": row["type"], "payload": json.loads(row["payload_json"])}) for row in rows]
```

- [ ] **Step 4: Run the store test**

Run: `uv run pytest tests/test_store.py -q`

Expected: `1 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/db.py src/allhands_host/models.py src/allhands_host/store.py tests/test_store.py
git commit -m "feat: add sqlite session and event store"
```

## Task 4: Enforce the project-root boundary and default worktree creation

**Files:**
- Create: `src/allhands_host/worktrees.py`
- Test: `tests/test_worktrees.py`

- [ ] **Step 1: Write the failing worktree tests**

```python
from pathlib import Path
import subprocess

import pytest

from allhands_host.worktrees import ProjectBoundaryError, WorktreeManager


def init_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q", path], check=True)
    (path / "README.md").write_text("hello\n")
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "init"], check=True)


def test_rejects_paths_outside_root(tmp_path: Path):
    manager = WorktreeManager(project_root=tmp_path / "allowed")
    with pytest.raises(ProjectBoundaryError):
        manager.validate_repo_path(tmp_path / "outside")


def test_creates_worktree_under_hidden_dir(tmp_path: Path):
    root = tmp_path / "allowed"
    repo = root / "api"
    repo.mkdir(parents=True)
    init_repo(repo)

    manager = WorktreeManager(project_root=root)
    worktree = manager.create(repo_path=repo, session_id="session_123")

    assert worktree.parent.parent == root
    assert worktree.exists()
```

- [ ] **Step 2: Run the worktree tests to verify they fail**

Run: `uv run pytest tests/test_worktrees.py -q`

Expected: fail because `WorktreeManager` does not exist yet

- [ ] **Step 3: Implement the boundary and worktree manager**

```python
# src/allhands_host/worktrees.py
from dataclasses import dataclass
from pathlib import Path
import subprocess


class ProjectBoundaryError(ValueError):
    pass


@dataclass
class WorktreeManager:
    project_root: Path

    def validate_repo_path(self, repo_path: Path) -> Path:
        repo_path = repo_path.resolve()
        root = self.project_root.resolve()
        if root not in repo_path.parents and repo_path != root:
            raise ProjectBoundaryError(f"{repo_path} is outside {root}")
        return repo_path

    def create(self, repo_path: Path, session_id: str) -> Path:
        repo_path = self.validate_repo_path(repo_path)
        worktrees_root = repo_path.parent / ".worktrees"
        worktrees_root.mkdir(exist_ok=True)
        worktree_path = worktrees_root / session_id
        branch_name = f"allhands/{session_id}"
        subprocess.run(
            ["git", "-C", str(repo_path), "worktree", "add", "-b", branch_name, str(worktree_path)],
            check=True,
        )
        return worktree_path
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_worktrees.py -q`

Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/worktrees.py tests/test_worktrees.py
git commit -m "feat: enforce project root and worktree creation"
```

## Task 5: Add launcher adapters and subprocess supervision

**Files:**
- Modify: `src/allhands_host/launchers/base.py`
- Modify: `src/allhands_host/launchers/catalog.py`
- Create: `src/allhands_host/launchers/claude.py`
- Create: `src/allhands_host/launchers/codex.py`
- Create: `src/allhands_host/launchers/pi.py`
- Create: `src/allhands_host/processes.py`
- Test: `tests/test_launchers.py`

- [ ] **Step 1: Write the failing launcher tests**

```python
from pathlib import Path

from allhands_host.launchers.catalog import LauncherCatalog


def test_catalog_returns_resume_capable_launcher(tmp_path: Path):
    catalog = LauncherCatalog(project_root=tmp_path)
    launcher = catalog.get("codex")

    command = launcher.build_start_command(
        repo_path=tmp_path / "repo",
        worktree_path=tmp_path / "repo/.worktrees/session_1",
        prompt="Fix the API",
    )
    resume = launcher.build_resume_command(session_token="abc123")

    assert command.argv[0]
    assert resume.argv[0]
    assert launcher.slug == "codex"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_launchers.py -q`

Expected: fail because `LauncherCatalog` and concrete launchers do not exist yet

- [ ] **Step 3: Implement the adapter contract and runner**

```python
# src/allhands_host/launchers/base.py
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class LaunchCommand:
    argv: list[str]
    cwd: Path


class Launcher:
    slug: str

    def build_start_command(self, repo_path: Path, worktree_path: Path, prompt: str) -> LaunchCommand:
        raise NotImplementedError

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        raise NotImplementedError
```

```python
# src/allhands_host/launchers/codex.py
from pathlib import Path

from allhands_host.launchers.base import LaunchCommand, Launcher


class CodexLauncher(Launcher):
    slug = "codex"

    def build_start_command(self, repo_path: Path, worktree_path: Path, prompt: str) -> LaunchCommand:
        return LaunchCommand(
            argv=["codex", "--experimental-acp", "--prompt", prompt],
            cwd=worktree_path,
        )

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        return LaunchCommand(
            argv=["codex", "--experimental-acp", "--resume", session_token],
            cwd=Path("."),
        )
```

```python
# src/allhands_host/launchers/catalog.py
from pathlib import Path

from allhands_host.launchers.claude import ClaudeLauncher
from allhands_host.launchers.codex import CodexLauncher
from allhands_host.launchers.pi import PiLauncher


class LauncherCatalog:
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self._launchers = {
            "claude": ClaudeLauncher(),
            "codex": CodexLauncher(),
            "pi": PiLauncher(),
        }

    def get(self, slug: str):
        return self._launchers[slug]
```

```python
# src/allhands_host/processes.py
import asyncio
from dataclasses import dataclass

from allhands_host.launchers.base import LaunchCommand


@dataclass
class RunningProcess:
    process: asyncio.subprocess.Process


async def spawn(command: LaunchCommand) -> RunningProcess:
    process = await asyncio.create_subprocess_exec(
        *command.argv,
        cwd=str(command.cwd),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    return RunningProcess(process=process)
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_launchers.py -q`

Expected: `1 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/launchers src/allhands_host/processes.py tests/test_launchers.py
git commit -m "feat: add launcher adapters and subprocess runner"
```

## Task 6: Attach ACP over stdio and normalize events into the store

**Files:**
- Create: `src/allhands_host/acp_attachment.py`
- Create: `tests/fixtures/fake_acp_agent.py`
- Test: `tests/test_acp_attachment.py`

- [ ] **Step 1: Write the failing ACP attachment test**

```python
from pathlib import Path

import pytest

from allhands_host.acp_attachment import attach_and_initialize
from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


@pytest.mark.asyncio
async def test_attachment_records_initialize_and_prompt_events(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new("codex", "/tmp/repo", "/tmp/repo/.worktrees/session_1")
    store.create_session(session)

    fixture = Path("tests/fixtures/fake_acp_agent.py").resolve()
    attachment = await attach_and_initialize(
        session=session,
        store=store,
        argv=["python3", str(fixture)],
        cwd=tmp_path,
    )
    await attachment.prompt("hello")

    events = store.list_events(session.id, after_seq=0)
    assert [event.type for event in events] == [
        "session.attached",
        "acp.initialized",
        "acp.thought",
    ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/test_acp_attachment.py -q`

Expected: fail because the attachment layer and fixture agent do not exist yet

- [ ] **Step 3: Implement the fake agent and attachment flow**

```python
# tests/fixtures/fake_acp_agent.py
import json
import sys


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    if message["method"] == "initialize":
        send({"id": message["id"], "result": {"capabilities": {}}})
    elif message["method"] == "session/new":
        send({"id": message["id"], "result": {"sessionId": "fake"}})
    elif message["method"] == "session/prompt":
        send({"method": "session/update", "params": {"kind": "thought", "text": "thinking"}})
        send({"id": message["id"], "result": {"ok": True}})
```

```python
# src/allhands_host/acp_attachment.py
import asyncio
import json
from dataclasses import dataclass
from pathlib import Path

from allhands_host.models import SessionRecord
from allhands_host.processes import spawn
from allhands_host.store import SessionStore
from allhands_host.launchers.base import LaunchCommand


@dataclass
class Attachment:
    session: SessionRecord
    store: SessionStore
    stdin: asyncio.StreamWriter
    stdout: asyncio.StreamReader
    next_id: int = 1

    async def rpc(self, method: str, params: dict) -> None:
        payload = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.next_id += 1
        self.stdin.write((json.dumps(payload) + "\n").encode())
        await self.stdin.drain()

    async def prompt(self, text: str) -> None:
        await self.rpc("session/prompt", {"prompt": [{"type": "text", "text": text}]})
        line = await self.stdout.readline()
        update = json.loads(line)
        if update.get("method") == "session/update":
            self.store.append_event(self.session.id, "acp.thought", {"text": update["params"]["text"]})


async def attach_and_initialize(session: SessionRecord, store: SessionStore, argv: list[str], cwd: Path) -> Attachment:
    process = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(cwd),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    attachment = Attachment(session=session, store=store, stdin=process.stdin, stdout=process.stdout)
    store.append_event(session.id, "session.attached", {})
    await attachment.rpc("initialize", {})
    await attachment.stdout.readline()
    store.append_event(session.id, "acp.initialized", {})
    await attachment.rpc("session/new", {})
    await attachment.stdout.readline()
    return attachment
```

- [ ] **Step 4: Run the ACP attachment test**

Run: `uv run pytest tests/test_acp_attachment.py -q`

Expected: `1 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/acp_attachment.py tests/fixtures/fake_acp_agent.py tests/test_acp_attachment.py
git commit -m "feat: attach local ACP subprocesses and persist events"
```

## Task 7: Expose session create/detail/prompt/resume/cancel/archive APIs and SSE

**Files:**
- Modify: `src/allhands_host/http.py`
- Modify: `src/allhands_host/app.py`
- Modify: `src/allhands_host/store.py`
- Test: `tests/test_http_api.py`

- [ ] **Step 1: Write the failing HTTP API integration tests**

```python
import json
from pathlib import Path

from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app
from allhands_host.config import Settings


class SessionApiTest(AsyncHTTPTestCase):
    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(settings=settings)

    def test_create_session_returns_session_id(self):
        response = self.fetch(
            "/sessions",
            method="POST",
            body=json.dumps(
                {
                    "launcher": "codex",
                    "repoPath": "/tmp/projects/api",
                    "prompt": "Fix the API",
                }
            ),
        )
        payload = json.loads(response.body)
        assert response.code == 201
        assert payload["status"] == "created"
        assert payload["id"].startswith("session_")
```

- [ ] **Step 2: Run the integration tests to verify they fail**

Run: `uv run pytest tests/test_http_api.py -q`

Expected: fail because `/sessions` and SSE routes do not exist yet

- [ ] **Step 3: Implement the REST handlers and SSE stream**

```python
# src/allhands_host/http.py
import json
import tornado.web


class SessionsHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self) -> None:
        payload = json.loads(self.request.body)
        session = await self.session_service.create_session(
            launcher=payload["launcher"],
            repo_path=payload["repoPath"],
            prompt=payload["prompt"],
        )
        self.set_status(201)
        self.finish({"id": session.id, "status": session.status})


class SessionPromptHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        payload = json.loads(self.request.body)
        accepted = await self.session_service.prompt(session_id=session_id, prompt=payload["prompt"])
        self.finish({"accepted": accepted})


class SessionResumeHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.resume(session_id=session_id)
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
        last_event_id = self.request.headers.get("Last-Event-ID", "0")
        events = self.session_service.list_events(session_id=session_id, after_seq=int(last_event_id))
        for event in events:
            self.write(f"id: {event.seq}\nevent: {event.type}\ndata: {json.dumps(event.payload)}\n\n")
        await self.flush()
```

```python
# src/allhands_host/app.py
routes = [
    (r"/healthz", HealthHandler),
    (r"/server-info", ServerInfoHandler, {"settings": settings}),
    (r"/sessions", SessionsHandler, {"session_service": session_service}),
    (r"/sessions/([^/]+)/prompt", SessionPromptHandler, {"session_service": session_service}),
    (r"/sessions/([^/]+)/resume", SessionResumeHandler, {"session_service": session_service}),
    (r"/sessions/([^/]+)/archive", SessionArchiveHandler, {"session_service": session_service}),
    (r"/sessions/([^/]+)/events", SessionEventsHandler, {"session_service": session_service}),
]
```

- [ ] **Step 4: Run the API tests**

Run: `uv run pytest tests/test_http_api.py -q`

Expected: `1 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/app.py src/allhands_host/http.py src/allhands_host/store.py tests/test_http_api.py
git commit -m "feat: add session REST API and SSE replay"
```

## Task 8: Scaffold the Solid SPA, PWA shell, and design tokens

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/tsconfig.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/index.html`
- Create: `frontend/public/manifest.webmanifest`
- Create: `frontend/public/sw.js`
- Create: `frontend/src/main.tsx`
- Create: `frontend/src/app.tsx`
- Create: `frontend/src/styles/tokens.css`
- Create: `frontend/src/styles/app.css`
- Test: `frontend/src/app.test.tsx`

- [ ] **Step 1: Write the failing frontend shell test**

```tsx
import { render, screen } from "@solidjs/testing-library";

import { App } from "./app";


test("renders the control room shell", () => {
  render(() => <App />);
  expect(screen.getByText("Control Room")).toBeTruthy();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --dir frontend test -- --run src/app.test.tsx`

Expected: fail because the frontend project does not exist yet

- [ ] **Step 3: Add the Solid/Vite/PWA scaffold**

```json
{
  "name": "allhands-frontend",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "vitest"
  },
  "dependencies": {
    "@ark-ui/solid": "^4.0.0",
    "@solidjs/router": "^0.14.0",
    "solid-js": "^2.0.0"
  },
  "devDependencies": {
    "@solidjs/testing-library": "^0.8.0",
    "jsdom": "^24.0.0",
    "vite": "^6.0.0",
    "vite-plugin-solid": "^2.10.0",
    "vitest": "^2.0.0"
  }
}
```

```tsx
// frontend/src/app.tsx
import "./styles/tokens.css";
import "./styles/app.css";

export function App() {
  return (
    <main class="app-shell">
      <header class="topbar">
        <h1>Control Room</h1>
      </header>
    </main>
  );
}
```

```css
/* frontend/src/styles/tokens.css */
:root {
  --bg: #f6f5f1;
  --panel: #ffffff;
  --border: #e4e1d8;
  --text: #1d1b17;
  --muted: #6f6a60;
  --accent: #111111;
  --radius-lg: 20px;
  --shadow-soft: 0 10px 30px rgba(17, 17, 17, 0.06);
}
```

```css
/* frontend/src/styles/app.css */
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: ui-sans-serif, system-ui, sans-serif;
}

.app-shell {
  min-height: 100vh;
  padding: 20px;
}

.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
```

- [ ] **Step 4: Run the frontend test and build**

Run: `pnpm --dir frontend test -- --run src/app.test.tsx && pnpm --dir frontend build`

Expected: `1 passed` and a successful Vite build

- [ ] **Step 5: Commit**

```bash
git add frontend
git commit -m "feat: scaffold solid pwa shell"
```

## Task 9: Implement REST/SSE clients, session state, and the Control Room UI

**Files:**
- Create: `frontend/src/lib/api.ts`
- Create: `frontend/src/lib/events.ts`
- Create: `frontend/src/lib/session-store.ts`
- Create: `frontend/src/routes/control-room.tsx`
- Create: `frontend/src/routes/inbox.tsx`
- Create: `frontend/src/routes/session.tsx`
- Create: `frontend/src/components/session-card.tsx`
- Create: `frontend/src/components/session-tray.tsx`
- Create: `frontend/src/components/install-banner.tsx`
- Create: `frontend/src/components/timeline.tsx`
- Create: `frontend/src/components/prompt-box.tsx`
- Create: `frontend/src/components/*.module.css`
- Test: `frontend/src/lib/session-store.test.ts`
- Test: `frontend/src/routes/control-room.test.tsx`

- [ ] **Step 1: Write the failing session-store tests**

```tsx
import { applyEvent } from "./session-store";


test("promotes attention-required sessions to the top of the tray", () => {
  const state = {
    sessions: [{ id: "a", status: "running" }, { id: "b", status: "running" }],
  };

  const next = applyEvent(state, {
    sessionId: "b",
    type: "session.attention_required",
    payload: {},
  });

  expect(next.sessions[0].id).toBe("b");
  expect(next.sessions[0].status).toBe("attention_required");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --dir frontend test -- --run src/lib/session-store.test.ts src/routes/control-room.test.tsx`

Expected: fail because the state and route files do not exist yet

- [ ] **Step 3: Implement API, EventSource, and the Control Room pages**

```ts
// frontend/src/lib/api.ts
export async function listSessions() {
  const response = await fetch("/sessions");
  if (!response.ok) throw new Error("failed to load sessions");
  return response.json();
}

export async function sendPrompt(sessionId: string, prompt: string) {
  const response = await fetch(`/sessions/${sessionId}/prompt`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt }),
  });
  if (!response.ok) throw new Error("failed to send prompt");
}
```

```ts
// frontend/src/lib/events.ts
export function subscribeToSession(sessionId: string, lastEventId: number, onEvent: (event: MessageEvent) => void) {
  const source = new EventSource(`/sessions/${sessionId}/events`, {
    withCredentials: true,
  });
  source.onmessage = onEvent;
  return () => source.close();
}
```

```tsx
// frontend/src/routes/control-room.tsx
import { For } from "solid-js";

export function ControlRoom(props: { sessions: Array<{ id: string; title: string; status: string }> }) {
  const focused = () => props.sessions[0];

  return (
    <section>
      <h2>Control Room</h2>
      <article>{focused()?.title ?? "No sessions yet"}</article>
      <div class="session-tray">
        <For each={props.sessions}>{(session) => <button>{session.title}</button>}</For>
      </div>
    </section>
  );
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm --dir frontend test -- --run src/lib/session-store.test.ts src/routes/control-room.test.tsx`

Expected: the new state and route tests pass

- [ ] **Step 5: Commit**

```bash
git add frontend/src
git commit -m "feat: build control room session state and live views"
```

## Task 10: Add Web Push subscriptions and background notifications

**Files:**
- Modify: `pyproject.toml`
- Create: `src/allhands_host/notifications.py`
- Modify: `src/allhands_host/db.py`
- Modify: `src/allhands_host/store.py`
- Modify: `src/allhands_host/http.py`
- Create: `frontend/src/lib/push.ts`
- Modify: `frontend/public/sw.js`
- Test: `tests/test_http_api.py`
- Test: `frontend/src/lib/push.test.ts`

- [ ] **Step 1: Write failing push subscription tests**

```python
def test_store_persists_push_subscription(tmp_path):
    from allhands_host.db import Database
    from allhands_host.store import SessionStore

    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    store.save_push_subscription(
        endpoint="https://example.invalid/1",
        keys={"p256dh": "a", "auth": "b"},
    )
    subscriptions = store.list_push_subscriptions()
    assert subscriptions[0]["endpoint"] == "https://example.invalid/1"
```

```ts
import { normalizePermission } from "./push";

test("maps denied permissions to an unsubscribed state", () => {
  expect(normalizePermission("denied")).toBe("unsubscribed");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_http_api.py -q && pnpm --dir frontend test -- --run src/lib/push.test.ts`

Expected: fail because subscription storage and push helpers do not exist yet

- [ ] **Step 3: Implement subscription storage and client registration**

```toml
[project]
dependencies = [
  "agent-client-protocol>=0.1.0",
  "pywebpush>=2.0.3",
  "tornado>=6.4",
]
```

```python
# src/allhands_host/notifications.py
from pywebpush import webpush


class NotificationService:
    def __init__(self, store, public_key: str, private_key: str):
        self.store = store
        self.public_key = public_key
        self.private_key = private_key

    def send_attention_required(self, title: str, body: str) -> None:
        for subscription in self.store.list_push_subscriptions():
            webpush(
                subscription_info=subscription,
                data=f'{{"title":"{title}","body":"{body}"}}',
                vapid_private_key=self.private_key,
                vapid_claims={"sub": "mailto:none@example.com"},
            )
```

```ts
// frontend/src/lib/push.ts
export function normalizePermission(permission: NotificationPermission) {
  return permission === "granted" ? "subscribed" : "unsubscribed";
}

export async function subscribeToPush(registration: ServiceWorkerRegistration, publicKey: string) {
  return registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: publicKey,
  });
}
```

```js
// frontend/public/sw.js
self.addEventListener("push", (event) => {
  const payload = event.data ? event.data.json() : { title: "All Hands", body: "Session update" };
  event.waitUntil(self.registration.showNotification(payload.title, { body: payload.body }));
});
```

```python
# src/allhands_host/http.py
class PushSubscriptionHandler(tornado.web.RequestHandler):
    def initialize(self, notification_service) -> None:
        self.notification_service = notification_service

    def post(self) -> None:
        payload = json.loads(self.request.body)
        self.notification_service.store.save_push_subscription(
            endpoint=payload["endpoint"],
            keys=payload["keys"],
        )
        self.set_status(204)
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_store.py tests/test_http_api.py -q && pnpm --dir frontend test -- --run src/lib/push.test.ts`

Expected: the storage and push helper tests pass

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host frontend/public/sw.js frontend/src/lib/push.ts tests frontend/src/lib/push.test.ts
git commit -m "feat: add background push notifications"
```

## Task 11: Add end-to-end smoke coverage and repo docs

**Files:**
- Create: `README.md`
- Modify: `tests/test_http_api.py`
- Modify: `frontend/src/routes/session.test.tsx`

- [ ] **Step 1: Extend the integration tests to cover resume and archive**

```python
def test_resume_and_archive_flow(client):
    created = client.create_session("codex", "/tmp/projects/api", "fix it")
    resumed = client.resume_session(created["id"])
    archived = client.archive_session(created["id"])

    assert resumed["status"] in {"running", "resume_available"}
    assert archived["status"] == "archived"
```

- [ ] **Step 2: Run the smoke suite to verify the new assertions fail**

Run: `uv run pytest tests/test_http_api.py -q && pnpm --dir frontend test -- --run src/routes/session.test.tsx`

Expected: fail because resume and archive wiring is incomplete

- [ ] **Step 3: Complete the missing resume/archive wiring and write a minimal README**

~~~markdown
# All Hands Rewrite

Single-user ACP session host with a Tornado backend and Solid PWA frontend.

## Run

```bash
uv sync
pnpm --dir frontend install
uv run python -m allhands_host.main
```

## Test

```bash
uv run pytest -q
pnpm --dir frontend test -- --run
```
~~~

- [ ] **Step 4: Run the full verification suite**

Run: `uv run pytest -q && pnpm --dir frontend test -- --run && pnpm --dir frontend build`

Expected: all backend tests pass, all frontend tests pass, and the production build succeeds

- [ ] **Step 5: Commit**

```bash
git add README.md tests frontend/src/routes/session.test.tsx
git commit -m "feat: finish v1 rewrite smoke coverage"
```

## Self-Review

- Spec coverage:
  - Python/Tornado/ACP SDK/SQLite stack: Tasks 1-7
  - Project-root boundary and worktrees: Task 4
  - Local subprocess launchers and resume metadata: Tasks 5-7
  - Durable logical sessions and event log: Tasks 3, 6, and 7
  - SSE as the primary live transport: Task 7
  - Solid SPA and PWA shell: Tasks 8 and 9
  - Ark-inspired design system without Tailwind: Tasks 8 and 9
  - Background push notifications: Task 10
  - Resume/archive flows and end-to-end verification: Task 11
- Placeholder scan:
  - No placeholder markers remain.
  - Every task includes explicit files, commands, and code snippets.
- Type consistency:
  - Session statuses use `attention_required`, `detached`, `resume_available`, `completed`, `failed`, `cancelled`, and `archived`.
  - Frontend route names use `control-room`, `inbox`, and `session`.
  - Backend package name stays `allhands_host`.

## Notes Before Execution

- Keep the first implementation pass narrow. Do not add diff review, markdown viewing, embedded terminal, or multi-machine launchers before the core session loop works.
- Use fake ACP agents in tests before wiring real launcher commands into manual smoke runs.
- Treat push as complementary. Do not let push-specific work complicate the SSE path.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-acp-mobile-host-v1.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
