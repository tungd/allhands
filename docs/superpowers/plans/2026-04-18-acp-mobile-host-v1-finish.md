# ACP Mobile Host V1 Finish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the rewrite branch as a coherent v1 by adding durable lifecycle projection, background push decisions, full session-screen controls, and seen-cursor driven notification suppression.

**Architecture:** Keep Tornado, SQLite, and the existing Solid SPA, but make the backend authoritative for session lifecycle and notification decisions. Extend the current HTTP and SSE contracts just enough for the session screen and push flow to operate without reconstructing lifecycle state from raw ACP events.

**Tech Stack:** Python 3.13 via `uv`, Tornado, SQLite, `agent-client-protocol`, `pywebpush`, Solid, Solid Router, Vite, Vitest, CSS modules, SSE, PWA service worker

---

## File Structure

### Backend

- `src/allhands_host/db.py`
  Extend the SQLite schema with lifecycle projection fields and app-level seen state.
- `src/allhands_host/models.py`
  Add projected session metadata fields while keeping the existing `status` field as the run-state backing field for minimal churn.
- `src/allhands_host/store.py`
  Persist and query session projection, session seen cursors, app seen timestamp, and notification delivery state.
- `src/allhands_host/acp_attachment.py`
  Add attachment cancellation so reset/cancel can stop live runs cleanly.
- `src/allhands_host/worktrees.py`
  Support forced worktree removal and recreation for reset/resume flows.
- `src/allhands_host/notifications.py`
  Add notification decision logic using seen cursors and collapsed per-session delivery.
- `src/allhands_host/session_service.py`
  Centralize lifecycle transitions, reset/cancel/archive/resume semantics, and notification triggering.
- `src/allhands_host/http.py`
  Add timeline snapshot, cancel, reset, and seen endpoints.
- `src/allhands_host/app.py`
  Wire the new handlers and inject notification-aware services.

### Frontend

- `frontend/src/lib/api.ts`
  Expand the REST client for detail snapshots, timeline fetches, admin actions, and seen updates.
- `frontend/src/lib/events.ts`
  Track the richer session event set needed by the session screen.
- `frontend/src/lib/session-store.ts`
  Keep control-room summaries in sync and trigger notification permission after the first session appears.
- `frontend/src/lib/session-detail-store.ts`
  New file for loading one session snapshot, hydrating timeline state, subscribing to SSE, and advancing seen cursors.
- `frontend/src/lib/push.ts`
  Add permission request and idempotent subscription helpers.
- `frontend/src/routes/session.tsx`
  Replace the placeholder with the actual mobile-first operating surface.
- `frontend/src/components/timeline.tsx`
  Support curated and raw modes.
- `frontend/src/components/prompt-box.tsx`
  Add controlled submit/disabled behavior.
- `frontend/src/components/session-actions.tsx`
  New file for the action strip and destructive confirmations.
- `frontend/src/app.tsx`
  Deep-link the router to a working session screen and keep root-level behavior light.
- `frontend/src/main.tsx`
  Keep service worker registration and session-level boot behavior in one place.
- `frontend/public/sw.js`
  Deep-link notification taps to `/session/:id`.

### Tests

- `tests/test_store.py`
- `tests/test_notifications.py`
- `tests/test_session_service.py`
- `tests/test_http_api.py`
- `frontend/src/lib/session-detail-store.test.ts`
- `frontend/src/routes/session.test.tsx`
- `frontend/src/lib/push.test.ts`
- `frontend/src/app.test.tsx`

## Task 1: Persist lifecycle projection and seen cursors

**Files:**
- Modify: `src/allhands_host/db.py`
- Modify: `src/allhands_host/models.py`
- Modify: `src/allhands_host/store.py`
- Modify: `tests/test_store.py`

- [ ] **Step 1: Write the failing persistence tests**

```python
from pathlib import Path

from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


def test_store_persists_lifecycle_projection_and_seen_cursors(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)

    session = SessionRecord.new(
        launcher="codex",
        repo_path="/tmp/projects/api",
        worktree_path="/tmp/projects/.worktrees/session_1",
    )
    store.create_session(session)
    store.update_session_projection(
        session.id,
        status="attention_required",
        workspace_state="ready",
        last_bound_agent_session_id="agent-123",
        active_notification_kind="attention_required",
        last_notified_at="2026-04-18T00:00:00+00:00",
    )
    store.mark_session_seen(session.id, event_seq=7)
    store.mark_app_seen("2026-04-18T00:01:00+00:00")

    fetched = store.get_session(session.id)

    assert fetched.status == "attention_required"
    assert fetched.workspace_state == "ready"
    assert fetched.last_bound_agent_session_id == "agent-123"
    assert fetched.active_notification_kind == "attention_required"
    assert fetched.last_notified_at == "2026-04-18T00:00:00+00:00"
    assert fetched.last_seen_event_seq == 7
    assert store.get_app_last_seen_at() == "2026-04-18T00:01:00+00:00"
```

- [ ] **Step 2: Run the store tests to verify they fail**

Run: `uv run pytest tests/test_store.py -q`

Expected: fail with `AttributeError` for missing projection methods and/or `TypeError` because `SessionRecord` does not have the new fields yet.

- [ ] **Step 3: Add projected fields, app-state storage, and store helpers**

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
    workspace_state: str
    last_bound_agent_session_id: str | None
    last_activity_at: str
    last_notified_at: str | None
    active_notification_kind: str
    last_seen_event_seq: int
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
            workspace_state="ready",
            last_bound_agent_session_id=None,
            last_activity_at=now,
            last_notified_at=None,
            active_notification_kind="none",
            last_seen_event_seq=0,
            created_at=now,
            updated_at=now,
        )
```

```python
# src/allhands_host/db.py
SCHEMA = """
create table if not exists sessions (
  id text primary key,
  launcher text not null,
  repo_path text not null,
  worktree_path text not null,
  status text not null,
  workspace_state text not null default 'ready',
  last_bound_agent_session_id text,
  last_activity_at text not null,
  last_notified_at text,
  active_notification_kind text not null default 'none',
  last_seen_event_seq integer not null default 0,
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

create table if not exists push_subscriptions (
  endpoint text primary key,
  keys_json text not null,
  created_at text not null
);

create table if not exists app_state (
  singleton integer primary key check (singleton = 1),
  last_seen_at text
);
"""
```

```python
# src/allhands_host/store.py
def update_session_projection(
    self,
    session_id: str,
    *,
    status: str | None = None,
    workspace_state: str | None = None,
    last_bound_agent_session_id: str | None = None,
    last_activity_at: str | None = None,
    last_notified_at: str | None = None,
    active_notification_kind: str | None = None,
) -> SessionRecord:
    current = self.get_session(session_id)
    updated_at = utc_now()
    next_status = current.status if status is None else status
    next_workspace_state = current.workspace_state if workspace_state is None else workspace_state
    next_agent_session_id = (
        current.last_bound_agent_session_id
        if last_bound_agent_session_id is None
        else last_bound_agent_session_id
    )
    next_last_activity_at = current.last_activity_at if last_activity_at is None else last_activity_at
    next_last_notified_at = current.last_notified_at if last_notified_at is None else last_notified_at
    next_notification_kind = (
        current.active_notification_kind
        if active_notification_kind is None
        else active_notification_kind
    )
    with self.db.connect() as connection:
        connection.execute(
            '''
            update sessions
            set status = ?, workspace_state = ?, last_bound_agent_session_id = ?,
                last_activity_at = ?, last_notified_at = ?, active_notification_kind = ?,
                updated_at = ?
            where id = ?
            ''',
            (
                next_status,
                next_workspace_state,
                next_agent_session_id,
                next_last_activity_at,
                next_last_notified_at,
                next_notification_kind,
                updated_at,
                session_id,
            ),
        )
    return self.get_session(session_id)


def mark_session_seen(self, session_id: str, event_seq: int) -> SessionRecord:
    with self.db.connect() as connection:
        connection.execute(
            "update sessions set last_seen_event_seq = max(last_seen_event_seq, ?) where id = ?",
            (event_seq, session_id),
        )
    return self.get_session(session_id)


def mark_app_seen(self, timestamp: str) -> None:
    with self.db.connect() as connection:
        connection.execute(
            """
            insert into app_state (singleton, last_seen_at)
            values (1, ?)
            on conflict(singleton) do update set last_seen_at = excluded.last_seen_at
            """,
            (timestamp,),
        )


def get_app_last_seen_at(self) -> str | None:
    with self.db.connect() as connection:
        row = connection.execute(
            "select last_seen_at from app_state where singleton = 1"
        ).fetchone()
    return None if row is None else row["last_seen_at"]
```

- [ ] **Step 4: Run the store tests to verify they pass**

Run: `uv run pytest tests/test_store.py -q`

Expected: `3 passed` or more, including the new lifecycle projection test.

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/db.py src/allhands_host/models.py src/allhands_host/store.py tests/test_store.py
git commit -m "feat: persist session lifecycle projection"
```

## Task 2: Implement lifecycle transitions, notifications, and admin controls

**Files:**
- Modify: `src/allhands_host/acp_attachment.py`
- Modify: `src/allhands_host/worktrees.py`
- Modify: `src/allhands_host/notifications.py`
- Modify: `src/allhands_host/session_service.py`
- Create: `tests/test_notifications.py`
- Modify: `tests/test_session_service.py`

- [ ] **Step 1: Write the failing lifecycle and notification tests**

```python
# tests/test_notifications.py
from allhands_host.notifications import NotificationService


class FakeStore:
    def __init__(self):
        self.app_last_seen_at = "2026-04-18T00:00:05+00:00"
        self.sent = []

    def get_app_last_seen_at(self):
        return self.app_last_seen_at

    def list_push_subscriptions(self):
        return [{"endpoint": "https://example.invalid/1", "keys": {"p256dh": "a", "auth": "b"}}]


def test_notification_service_suppresses_recent_foreground_activity():
    service = NotificationService(
        store=FakeStore(),
        public_key="pub",
        private_key="priv",
        sender=lambda **kwargs: None,
    )

    assert service.should_send(
        newest_event_seq=9,
        session_last_seen_event_seq=8,
        app_last_seen_at="2026-04-18T00:00:05+00:00",
        now="2026-04-18T00:00:10+00:00",
    ) is False
```

```python
# tests/test_session_service.py
from pathlib import Path

import pytest

from allhands_host.config import Settings
from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.session_service import SessionService
from allhands_host.store import SessionStore


class FakeAttachment:
    def __init__(self):
        self.cancelled = False

    async def prompt(self, text: str) -> None:
        return None

    async def cancel(self) -> None:
        self.cancelled = True


class FakeWorktrees:
    def __init__(self, root: Path):
        self.root = root
        self.removed = []
        self.created = []

    def create(self, repo_path: Path, session_id: str) -> Path:
        path = self.root / ".worktrees" / session_id
        self.created.append(path)
        return path

    def remove(self, repo_path: Path, worktree_path: Path) -> None:
        self.removed.append(worktree_path)


@pytest.mark.asyncio
async def test_reset_stops_live_run_and_marks_workspace_missing(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new("codex", str(tmp_path / "repo"), str(tmp_path / "repo/.worktrees/session_1"))
    store.create_session(session)
    store.update_session_projection(
        session.id,
        status="running",
        last_bound_agent_session_id="agent-123",
    )

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
        worktree_manager=FakeWorktrees(tmp_path),
    )
    attachment = FakeAttachment()
    service.attachments[session.id] = attachment

    reset = await service.reset(session.id)

    assert attachment.cancelled is True
    assert reset.workspace_state == "missing"
    assert reset.status == "resume_available"
```

- [ ] **Step 2: Run the targeted backend tests to verify they fail**

Run: `uv run pytest tests/test_notifications.py tests/test_session_service.py -q`

Expected: fail because `NotificationService.should_send`, `Attachment.cancel`, `WorktreeManager.remove`, and `SessionService.reset` do not exist yet.

- [ ] **Step 3: Add cancellation, reset/resume semantics, and push decision logic**

```python
# src/allhands_host/acp_attachment.py
@dataclass
class Attachment:
    session: SessionRecord
    store: SessionStore
    connection: Any
    process: asyncio.subprocess.Process
    agent_session_id: str

    async def prompt(self, text: str) -> None:
        await self.connection.prompt(
            prompt=[acp.text_block(text)],
            session_id=self.agent_session_id,
        )

    async def cancel(self) -> None:
        with contextlib.suppress(Exception):
            await self.connection.cancel(session_id=self.agent_session_id)
        if self.process.returncode is None:
            self.process.terminate()
            await self.process.wait()
```

```python
# src/allhands_host/worktrees.py
def create(self, repo_path: Path, session_id: str) -> Path:
    repo_path = self.validate_repo_path(repo_path)
    worktrees_root = repo_path.parent / ".worktrees"
    worktrees_root.mkdir(exist_ok=True)
    worktree_path = worktrees_root / session_id
    branch_name = f"allhands/{session_id}"
    subprocess.run(
        ["git", "-C", str(repo_path), "worktree", "add", "-B", branch_name, str(worktree_path)],
        check=True,
    )
    return worktree_path


def remove(self, repo_path: Path, worktree_path: Path) -> None:
    repo_path = self.validate_repo_path(repo_path)
    subprocess.run(
        ["git", "-C", str(repo_path), "worktree", "remove", "--force", str(worktree_path)],
        check=True,
    )
```

```python
# src/allhands_host/notifications.py
from datetime import datetime, timedelta


class NotificationService:
    def __init__(self, store: SessionStore, public_key: str, private_key: str, sender=webpush):
        self.store = store
        self.public_key = public_key
        self.private_key = private_key
        self.sender = sender

    def should_send(
        self,
        *,
        newest_event_seq: int,
        session_last_seen_event_seq: int,
        app_last_seen_at: str | None,
        now: str,
    ) -> bool:
        if newest_event_seq <= session_last_seen_event_seq:
            return False
        if app_last_seen_at is None:
            return True
        seen_at = datetime.fromisoformat(app_last_seen_at)
        current = datetime.fromisoformat(now)
        return current - seen_at > timedelta(seconds=15)
```

```python
# src/allhands_host/session_service.py
async def cancel(self, session_id: str) -> SessionRecord:
    attachment = self.attachments.pop(session_id, None)
    if attachment is not None:
        await attachment.cancel()
    next_status = "resume_available" if self.store.last_bound_agent_session_id(session_id) else "detached"
    self.store.append_event(session_id, "session.cancelled", {})
    return self.store.update_session_projection(session_id, status=next_status)


async def reset(self, session_id: str) -> SessionRecord:
    session = self.store.get_session(session_id)
    attachment = self.attachments.pop(session_id, None)
    if attachment is not None:
        await attachment.cancel()
    self.worktree_manager.remove(Path(session.repo_path), Path(session.worktree_path))
    next_status = "resume_available" if session.last_bound_agent_session_id else "detached"
    self.store.append_event(session_id, "workspace.reset", {})
    return self.store.update_session_projection(
        session_id,
        status=next_status,
        workspace_state="missing",
    )


async def resume(self, session_id: str) -> SessionRecord:
    session = self.store.get_session(session_id)
    repo_path = Path(session.repo_path)
    if session.workspace_state == "missing":
        self.worktree_manager.create(repo_path, session.id)
        self.store.append_event(session.id, "workspace.recreated", {})
    command = self.launcher_catalog.get(session.launcher).build_resume_command(
        session_token=session.last_bound_agent_session_id or self.store.last_bound_agent_session_id(session_id)
    )
    attachment = await attach_and_resume(
        session=session,
        store=self.store,
        argv=command.argv,
        cwd=Path(session.worktree_path),
        session_token=session.last_bound_agent_session_id or self.store.last_bound_agent_session_id(session_id),
    )
    self.attachments[session.id] = attachment
    self.store.append_event(session.id, "session.bound", {"agentSessionId": attachment.agent_session_id})
    return self.store.update_session_projection(
        session.id,
        status="running",
        workspace_state="ready",
        last_bound_agent_session_id=attachment.agent_session_id,
    )
```

- [ ] **Step 4: Run the targeted backend tests to verify they pass**

Run: `uv run pytest tests/test_notifications.py tests/test_session_service.py -q`

Expected: all tests in both files pass.

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/acp_attachment.py src/allhands_host/worktrees.py src/allhands_host/notifications.py src/allhands_host/session_service.py tests/test_notifications.py tests/test_session_service.py
git commit -m "feat: add lifecycle transitions and notification rules"
```

## Task 3: Extend the HTTP API for detail snapshots, timeline fetches, admin actions, and seen updates

**Files:**
- Modify: `src/allhands_host/http.py`
- Modify: `src/allhands_host/app.py`
- Modify: `tests/test_http_api.py`

- [ ] **Step 1: Write the failing HTTP API tests**

```python
def test_session_timeline_snapshot_returns_json(self):
    response = self.fetch("/sessions/session_123/timeline")
    payload = json.loads(response.body)

    assert response.code == 200
    assert payload["events"][0]["type"] == "session.created"


def test_reset_endpoint_returns_updated_projection(self):
    response = self.fetch("/sessions/session_123/reset", method="POST", body="{}")
    payload = json.loads(response.body)

    assert response.code == 200
    assert payload["workspaceState"] == "missing"
    assert payload["runState"] == "resume_available"


def test_seen_endpoints_accept_app_and_session_cursors(self):
    app_seen = self.fetch("/seen/app", method="POST", body=json.dumps({"lastSeenAt": "2026-04-18T00:01:00+00:00"}))
    session_seen = self.fetch(
        "/sessions/session_123/seen",
        method="POST",
        body=json.dumps({"lastSeenEventSeq": 4}),
    )

    assert app_seen.code == 204
    assert session_seen.code == 204
```

- [ ] **Step 2: Run the HTTP API tests to verify they fail**

Run: `uv run pytest tests/test_http_api.py -q`

Expected: fail because the new routes and fake service methods do not exist yet.

- [ ] **Step 3: Add the new handlers and route wiring**

```python
# src/allhands_host/http.py
class SessionTimelineHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def get(self, session_id: str) -> None:
        events = self.session_service.list_events(session_id, after_seq=0)
        self.finish(
            {
                "events": [
                    {
                        "seq": event.seq,
                        "type": event.type,
                        "payload": event.payload,
                        "createdAt": event.created_at,
                    }
                    for event in events
                ]
            }
        )


class SessionCancelHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.cancel(session_id)
        self.finish({"id": session.id, "runState": session.status, "workspaceState": session.workspace_state})


class SessionResetHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    async def post(self, session_id: str) -> None:
        session = await self.session_service.reset(session_id)
        self.finish({"id": session.id, "runState": session.status, "workspaceState": session.workspace_state})


class AppSeenHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def post(self) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.session_service.mark_app_seen(payload["lastSeenAt"])
        self.set_status(204)


class SessionSeenHandler(tornado.web.RequestHandler):
    def initialize(self, session_service) -> None:
        self.session_service = session_service

    def post(self, session_id: str) -> None:
        payload = tornado.escape.json_decode(self.request.body or b"{}")
        self.session_service.mark_session_seen(session_id, payload["lastSeenEventSeq"])
        self.set_status(204)
```

```python
# src/allhands_host/app.py
routes.extend(
    [
        (r"/sessions/([^/]+)/timeline", SessionTimelineHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/cancel", SessionCancelHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/reset", SessionResetHandler, {"session_service": session_service}),
        (r"/seen/app", AppSeenHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/seen", SessionSeenHandler, {"session_service": session_service}),
    ]
)
```

- [ ] **Step 4: Run the HTTP API tests to verify they pass**

Run: `uv run pytest tests/test_http_api.py -q`

Expected: all HTTP API tests pass, including the new timeline, reset, and seen endpoints.

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/http.py src/allhands_host/app.py tests/test_http_api.py
git commit -m "feat: expose session detail lifecycle endpoints"
```

## Task 4: Build the session detail store and timeline-first session screen

**Files:**
- Modify: `frontend/src/lib/api.ts`
- Modify: `frontend/src/lib/events.ts`
- Create: `frontend/src/lib/session-detail-store.ts`
- Modify: `frontend/src/components/timeline.tsx`
- Modify: `frontend/src/components/prompt-box.tsx`
- Create: `frontend/src/components/session-actions.tsx`
- Create: `frontend/src/components/session-actions.module.css`
- Modify: `frontend/src/routes/session.tsx`
- Create: `frontend/src/lib/session-detail-store.test.ts`
- Modify: `frontend/src/routes/session.test.tsx`

- [ ] **Step 1: Write the failing frontend detail tests**

```tsx
// frontend/src/lib/session-detail-store.test.ts
import { renderHook } from "@solidjs/testing-library";
import { vi } from "vitest";

import { createSessionDetailState } from "./session-detail-store";


test("loads timeline and disables prompt until resume is available", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          id: "session-1",
          title: "API Refactor",
          runState: "resume_available",
          workspaceState: "missing"
        })
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          events: [{ seq: 1, type: "workspace.reset", payload: {}, createdAt: "2026-04-18T00:00:00+00:00" }]
        })
      })
  );
  vi.stubGlobal("EventSource", class {
    addEventListener() {}
    close() {}
  });

  const { result } = renderHook(() => createSessionDetailState("session-1"));

  await Promise.resolve()
  await Promise.resolve()

  expect(result.detail()?.runState).toBe("resume_available");
  expect(result.timeline()[0].type).toBe("workspace.reset");
  expect(result.promptDisabled()).toBe(true);
});
```

```tsx
// frontend/src/routes/session.test.tsx
import { render, screen } from "@solidjs/testing-library";

import { SessionRoute } from "./session";


test("renders timeline first, action strip, and disabled prompt hint", () => {
  render(() => (
    <SessionRoute
      sessionId="session-1"
      initialDetail={{
        id: "session-1",
        title: "API Refactor",
        runState: "resume_available",
        workspaceState: "missing"
      }}
      initialTimeline={[
        { seq: 1, type: "workspace.reset", body: "Workspace reset", createdAt: "2026-04-18T00:00:00+00:00" }
      ]}
    />
  ));

  expect(screen.getByText("Workspace reset")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Resume" })).toBeTruthy();
  expect(screen.getByText("Resume session to send a prompt")).toBeTruthy();
});
```

- [ ] **Step 2: Run the targeted frontend tests to verify they fail**

Run: `pnpm --dir frontend test -- src/lib/session-detail-store.test.ts src/routes/session.test.tsx`

Expected: fail because the detail store, session actions component, and richer session route do not exist yet.

- [ ] **Step 3: Implement the detail store, timeline toggle, and action strip**

```ts
// frontend/src/lib/api.ts
export type SessionDetail = {
  id: string;
  title: string;
  runState: string;
  workspaceState: string;
};

export type TimelineEvent = {
  seq: number;
  type: string;
  payload: Record<string, unknown>;
  createdAt: string;
};

export async function getSession(sessionId: string): Promise<SessionDetail> {
  const response = await fetch(`/sessions/${sessionId}`);
  if (!response.ok) throw new Error("failed to load session");
  return response.json();
}

export async function listTimeline(sessionId: string): Promise<{ events: TimelineEvent[] }> {
  const response = await fetch(`/sessions/${sessionId}/timeline`);
  if (!response.ok) throw new Error("failed to load timeline");
  return response.json();
}

export async function resumeSession(sessionId: string): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/resume`, { method: "POST", body: "{}" });
  if (!response.ok) throw new Error("failed to resume session");
}

export async function cancelSession(sessionId: string): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/cancel`, { method: "POST", body: "{}" });
  if (!response.ok) throw new Error("failed to cancel session");
}

export async function resetSession(sessionId: string): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/reset`, { method: "POST", body: "{}" });
  if (!response.ok) throw new Error("failed to reset session");
}

export async function archiveSession(sessionId: string): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/archive`, { method: "POST", body: "{}" });
  if (!response.ok) throw new Error("failed to archive session");
}
```

```ts
// frontend/src/lib/session-detail-store.ts
import { createMemo, createSignal, onMount } from "solid-js";

import {
  archiveSession,
  cancelSession,
  getSession,
  listTimeline,
  markSessionSeen,
  resetSession,
  resumeSession,
  type SessionDetail,
  type TimelineEvent,
} from "./api";
import { subscribeToSession } from "./events";

export function createSessionDetailState(
  sessionId: string,
  initial: { detail?: SessionDetail | null; timeline?: TimelineEvent[] } = {},
) {
  const [detail, setDetail] = createSignal<SessionDetail | null>(initial.detail ?? null);
  const [timeline, setTimeline] = createSignal<TimelineEvent[]>(initial.timeline ?? []);
  const [rawMode, setRawMode] = createSignal(false);

  onMount(async () => {
    if (initial.detail == null) {
      setDetail(await getSession(sessionId));
    }
    if (initial.timeline == null) {
      const snapshot = await listTimeline(sessionId);
      setTimeline(snapshot.events);
      if (snapshot.events.length > 0) {
        void markSessionSeen(sessionId, snapshot.events.at(-1)!.seq);
      }
    }
    subscribeToSession(sessionId, (event) => {
      const nextSeq = Number(event.lastEventId || timeline().length + 1);
      setTimeline((current) => [
        ...current,
        {
          seq: nextSeq,
          type: event.type,
          payload: JSON.parse(event.data || "{}"),
          createdAt: new Date().toISOString(),
        },
      ]);
      void markSessionSeen(sessionId, nextSeq);
    });
  });

  const promptDisabled = createMemo(() => detail()?.runState !== "running");

  return {
    detail,
    timeline,
    rawMode,
    setRawMode,
    promptDisabled,
    resume: () => resumeSession(sessionId),
    cancel: () => cancelSession(sessionId),
    reset: () => resetSession(sessionId),
    archive: () => archiveSession(sessionId),
  };
}
```

```tsx
// frontend/src/components/timeline.tsx
export type TimelineProps = {
  items: Array<{ seq: number; type: string; body: string; raw?: string }>;
  rawMode: boolean;
  onToggleMode: () => void;
};

export function Timeline(props: TimelineProps) {
  return (
    <section class={styles.timeline}>
      <button type="button" onClick={props.onToggleMode}>
        {props.rawMode ? "Show curated timeline" : "Show raw events"}
      </button>
      <For each={props.items}>
        {(item) => <div>{props.rawMode ? item.raw ?? item.type : item.body}</div>}
      </For>
    </section>
  );
}
```

```tsx
// frontend/src/components/prompt-box.tsx
export function PromptBox(props: { disabled?: boolean; hint?: string; onSubmit?: (prompt: string) => Promise<void> | void }) {
  let input!: HTMLTextAreaElement;

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    if (props.disabled || !props.onSubmit) return;
    await props.onSubmit(input.value);
    input.value = "";
  }

  return (
    <form class={styles.box} onSubmit={handleSubmit}>
      <textarea ref={input} class={styles.input} name="prompt" rows={4} disabled={props.disabled} />
      <button type="submit" disabled={props.disabled}>Send</button>
      <Show when={props.hint}>
        <p>{props.hint}</p>
      </Show>
    </form>
  );
}
```

```tsx
// frontend/src/components/session-actions.tsx
export function SessionActions(props: {
  onResume: () => void;
  onCancel: () => void;
  onReset: () => void;
  onArchive: () => void;
}) {
  return (
    <div class={styles.actions}>
      <button type="button" onClick={props.onResume}>Resume</button>
      <button type="button" onClick={props.onCancel}>Cancel run</button>
      <button type="button" onClick={props.onReset}>Reset workspace</button>
      <button type="button" onClick={props.onArchive}>Archive</button>
    </div>
  );
}
```

```tsx
// frontend/src/routes/session.tsx
import { useParams } from "@solidjs/router";

import { PromptBox } from "../components/prompt-box";
import { SessionActions } from "../components/session-actions";
import { Timeline } from "../components/timeline";
import { createSessionDetailState } from "../lib/session-detail-store";

export function SessionRoute(props: { sessionId?: string; initialDetail?: any; initialTimeline?: any[] }) {
  const sessionId = () => props.sessionId ?? useParams().sessionId;
  const state = createSessionDetailState(sessionId(), {
    detail: props.initialDetail,
    timeline: props.initialTimeline,
  });

  return (
    <section>
      <h2>{state.detail()?.title ?? "Session"}</h2>
      <Timeline
        items={state.timeline().map((item) => ({
          seq: item.seq,
          type: item.type,
          body: item.type === "workspace.reset" ? "Workspace reset" : item.type,
          raw: JSON.stringify(item.payload),
        }))}
        rawMode={state.rawMode()}
        onToggleMode={() => state.setRawMode((current) => !current)}
      />
      <SessionActions
        onResume={() => void state.resume()}
        onCancel={() => void state.cancel()}
        onReset={() => void state.reset()}
        onArchive={() => void state.archive()}
      />
      <PromptBox
        disabled={state.promptDisabled()}
        hint={state.promptDisabled() ? "Resume session to send a prompt" : undefined}
      />
    </section>
  );
}
```

- [ ] **Step 4: Run the targeted frontend tests to verify they pass**

Run: `pnpm --dir frontend test -- src/lib/session-detail-store.test.ts src/routes/session.test.tsx`

Expected: both the new detail store test and the updated session route test pass.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/api.ts frontend/src/lib/events.ts frontend/src/lib/session-detail-store.ts frontend/src/components/timeline.tsx frontend/src/components/prompt-box.tsx frontend/src/components/session-actions.tsx frontend/src/components/session-actions.module.css frontend/src/routes/session.tsx frontend/src/lib/session-detail-store.test.ts frontend/src/routes/session.test.tsx
git commit -m "feat: build session detail screen and admin controls"
```

## Task 5: Add notification permission gating, seen updates, and deep-link handoff

**Files:**
- Modify: `frontend/src/lib/api.ts`
- Modify: `frontend/src/lib/session-store.ts`
- Modify: `frontend/src/lib/push.ts`
- Modify: `frontend/src/app.tsx`
- Modify: `frontend/src/main.tsx`
- Modify: `frontend/public/sw.js`
- Modify: `frontend/src/lib/push.test.ts`
- Modify: `frontend/src/app.test.tsx`

- [ ] **Step 1: Write the failing push and app-flow tests**

```tsx
// frontend/src/lib/push.test.ts
import { maybeEnableNotifications } from "./push";


test("requests permission after the first session appears", async () => {
  const requestPermission = vi.fn().mockResolvedValue("granted");
  vi.stubGlobal("Notification", { permission: "default", requestPermission });
  vi.stubGlobal("navigator", {
    serviceWorker: {
      ready: Promise.resolve({
        pushManager: {
          getSubscription: vi.fn().mockResolvedValue(null),
          subscribe: vi.fn().mockResolvedValue({ toJSON: () => ({ endpoint: "https://example.invalid/1", keys: {} }) }),
        },
      },
    },
  });
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ sessions: [{ id: "session-1", title: "API Refactor", status: "running" }] }),
    }),
  );

  await maybeEnableNotifications({ previousCount: 0, nextCount: 1, vapidPublicKey: "BElidedValue" });

  expect(requestPermission).toHaveBeenCalledOnce();
});
```

```tsx
// frontend/src/app.test.tsx
test("deep-links a notification tap into the session route", async () => {
  window.history.pushState({}, "", "/session/session-1");
  vi.stubGlobal(
    "fetch",
    vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          id: "session-1",
          title: "API Refactor",
          runState: "running",
          workspaceState: "ready"
        })
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ events: [] })
      })
  );
  vi.stubGlobal("EventSource", class {
    addEventListener() {}
    close() {}
  });

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByText("API Refactor")).toBeTruthy();
});
```

- [ ] **Step 2: Run the targeted frontend tests to verify they fail**

Run: `pnpm --dir frontend test -- src/lib/push.test.ts src/app.test.tsx`

Expected: fail because the permission gate helper, deep-link-specific behavior, and seen update hooks do not exist yet.

- [ ] **Step 3: Add the permission gate, seen updates, and service-worker deep links**

```ts
// frontend/src/lib/api.ts
export async function getServerInfo(): Promise<{ vapidPublicKey: string }> {
  const response = await fetch("/server-info");
  if (!response.ok) throw new Error("failed to load server info");
  return response.json();
}

export async function markAppSeen(lastSeenAt: string): Promise<void> {
  const response = await fetch("/seen/app", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lastSeenAt }),
  });
  if (!response.ok) throw new Error("failed to mark app seen");
}

export async function markSessionSeen(sessionId: string, lastSeenEventSeq: number): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/seen`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lastSeenEventSeq }),
  });
  if (!response.ok) throw new Error("failed to mark session seen");
}
```

```ts
// frontend/src/lib/push.ts
export async function maybeEnableNotifications(props: {
  previousCount: number;
  nextCount: number;
  vapidPublicKey: string;
}) {
  if (props.previousCount !== 0 || props.nextCount === 0) return;
  if (Notification.permission !== "default") return;

  const permission = await Notification.requestPermission();
  if (permission !== "granted") return;

  const registration = await navigator.serviceWorker.ready;
  const existing = await registration.pushManager.getSubscription();
  const subscription = existing ?? (await subscribeToPush(registration, props.vapidPublicKey));
  await registerPushSubscription(subscription);
}
```

```ts
// frontend/src/lib/session-store.ts
import { listSessions, markAppSeen, type SessionSummary } from "./api";
import { maybeEnableNotifications } from "./push";

export function createSessionsState(vapidPublicKey = "") {
  const [state, setState] = createSignal<SessionState>({ sessions: [] });

  onMount(async () => {
    const next = await listSessions();
    await maybeEnableNotifications({
      previousCount: state().sessions.length,
      nextCount: next.sessions.length,
      vapidPublicKey,
    });
    setState(next);
  });

  onMount(() => {
    function markVisibleSeen() {
      if (document.visibilityState === "visible") {
        void markAppSeen(new Date().toISOString());
      }
    }
    markVisibleSeen();
    document.addEventListener("visibilitychange", markVisibleSeen);
    onCleanup(() => document.removeEventListener("visibilitychange", markVisibleSeen));
  });

  return state;
}
```

```tsx
// frontend/src/app.tsx
export function App(props: { vapidPublicKey?: string }) {
  function ControlRoomPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    return <ControlRoom sessions={state().sessions} />;
  }

  function InboxPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    return <Inbox sessions={state().sessions} />;
  }

  return (
    <Router root={AppShell}>
      <Route path="/" component={ControlRoomPage} />
      <Route path="/control-room" component={ControlRoomPage} />
      <Route path="/inbox" component={InboxPage} />
      <Route path="/session/:sessionId" component={SessionPage} />
    </Router>
  );
}
```

```ts
// frontend/src/main.tsx
import { render } from "solid-js/web";

import { App } from "./app";
import { getServerInfo } from "./lib/api";

if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register("/sw.js");
}

async function bootstrap() {
  const info = await getServerInfo().catch(() => ({ vapidPublicKey: "" }));
  render(() => <App vapidPublicKey={info.vapidPublicKey} />, document.getElementById("root")!);
}

void bootstrap();
```

```js
// frontend/public/sw.js
self.addEventListener("push", (event) => {
  const payload = event.data ? event.data.json() : { title: "All Hands", body: "Session update", url: "/" };
  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      tag: payload.tag ?? payload.url,
      data: { url: payload.url ?? "/" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(self.clients.openWindow(event.notification.data?.url ?? "/"));
});
```

- [ ] **Step 4: Run the targeted frontend tests to verify they pass**

Run: `pnpm --dir frontend test -- src/lib/push.test.ts src/app.test.tsx`

Expected: the notification gate test and the deep-link test pass.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/api.ts frontend/src/lib/session-store.ts frontend/src/lib/push.ts frontend/src/app.tsx frontend/src/main.tsx frontend/public/sw.js frontend/src/lib/push.test.ts frontend/src/app.test.tsx
git commit -m "feat: add notification opt-in and deep links"
```

## Task 6: Refresh docs and run full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README for the finished v1 control loop**

~~~markdown
# All Hands Rewrite

Single-user ACP session host with a Tornado backend and a Solid PWA frontend.

## Run

```bash
uv sync
pnpm --dir frontend install
pnpm --dir frontend build
uv run python -m allhands_host.main --vapid_public_key=<public> --vapid_private_key=<private>
```

## Test

```bash
uv run pytest -q
pnpm --dir frontend test -- --run
pnpm --dir frontend build
```

## V1 Capabilities

- concurrent local ACP sessions
- worktree-per-session by default
- reset, cancel, resume, and archive from the mobile session screen
- SSE while the app is open
- push notifications for `attention_required` and `completed` while backgrounded
~~~

- [ ] **Step 2: Run the full verification suite**

Run: `uv run pytest -q && pnpm --dir frontend test -- --run && pnpm --dir frontend build`

Expected:
- all backend tests pass
- all frontend tests pass
- the production bundle builds successfully

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: finalize v1 finish documentation"
```

## Self-Review

- Spec coverage:
  - lifecycle projection and seen cursors: Tasks 1-3
  - cancel/reset/resume/archive semantics: Tasks 2-4
  - push suppression and collapsed delivery: Tasks 1-3 and 5
  - notification prompt after first session creation: Task 5
  - timeline-first session screen with curated/raw modes: Task 4
- deep-link handoff into `/session/:id`: Task 5
- Placeholder scan:
  - no placeholder markers remain
  - every task includes exact files, tests, commands, and commit points
- Type consistency:
  - backend keeps `status` as the stored run-state field to minimize churn, while HTTP payloads expose `runState`
  - `workspaceState`, `lastSeenEventSeq`, and `lastSeenAt` are used consistently across API, store, and SPA code

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-acp-mobile-host-v1-finish.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
