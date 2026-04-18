# Control Room New Session Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a routed bottom-sheet `New session` flow on `Control Room`, backed by repo discovery under the configured project root, and navigate directly into the new session after creation.

**Architecture:** Add a small backend repo catalog plus `GET /repos` while keeping session creation on the existing `POST /sessions` endpoint. In the frontend, keep `Control Room` mounted as the parent route and nest `/control-room/new` beneath it so a new bottom-sheet component can render over the live session list without remounting the page.

**Tech Stack:** Python, Tornado, Solid, Solid Router, Vitest, CSS modules

---

## File Structure

- `src/allhands_host/repo_catalog.py`
  Cached project-root repo discovery and query filtering.
- `src/allhands_host/http.py`
  New repo serialization and `GET /repos` handler.
- `src/allhands_host/app.py`
  Repo catalog wiring plus SPA fallback for `/control-room/new`.
- `tests/test_repo_catalog.py`
  Unit tests for repo discovery, filtering, and `.worktrees` exclusion.
- `tests/test_http_api.py`
  Endpoint coverage for `GET /repos` and frontend-shell fallback for the nested route.
- `frontend/src/lib/api.ts`
  `RepoSummary`, `listRepos()`, and `createSession()` client helpers.
- `frontend/src/lib/new-session-store.ts`
  Local state for launcher loading, repo search, validation, retry, and create-session submission.
- `frontend/src/lib/new-session-store.test.ts`
  Store tests for initial load, default launcher selection, query refresh, and submit/error behavior.
- `frontend/src/components/new-session-sheet.tsx`
  Routed bottom-sheet UI for fast launch.
- `frontend/src/components/new-session-sheet.module.css`
  Bottom-sheet layout, overlay, and form styling.
- `frontend/src/components/new-session-sheet.test.tsx`
  Component tests for focus, retry affordance, selection, and disabled/submit states.
- `frontend/src/routes/control-room.tsx`
  `New session` CTA, dimmed background state, and overlay slot.
- `frontend/src/routes/control-room.module.css`
  Control Room header/action layout and dimming styles.
- `frontend/src/routes/control-room.test.tsx`
  Control Room presentation test updated for the CTA and overlay behavior.
- `frontend/src/app.tsx`
  Nested `/control-room/new` route, root redirect, and route wrappers that connect the sheet to the store.
- `frontend/src/app.test.tsx`
  Route integration tests for deep-linking into the sheet and navigating into a created session.

### Task 1: Add Backend Repo Discovery

**Files:**
- Create: `src/allhands_host/repo_catalog.py`
- Test: `tests/test_repo_catalog.py`

- [ ] **Step 1: Write the failing repo catalog tests**

```python
# tests/test_repo_catalog.py
from pathlib import Path
import subprocess

from allhands_host.repo_catalog import RepoCatalog


def init_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "tests@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "All Hands Tests"], check=True)
    (path / "README.md").write_text("hello\n")
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "init"], check=True)


def test_lists_git_repos_under_project_root_alphabetically(tmp_path: Path):
    root = tmp_path / "projects"
    api = root / "api"
    docs = root / "docs"
    api.mkdir(parents=True)
    docs.mkdir(parents=True)
    init_repo(api)
    init_repo(docs)

    ignored_worktree = root / ".worktrees" / "session-1"
    ignored_worktree.mkdir(parents=True)
    (ignored_worktree / ".git").write_text("gitdir: /tmp/common\n")

    catalog = RepoCatalog(root)
    repos = catalog.list_repos()

    assert [repo.name for repo in repos] == ["api", "docs"]
    assert [repo.path for repo in repos] == [str(api.resolve()), str(docs.resolve())]


def test_filters_repo_names_and_paths(tmp_path: Path):
    root = tmp_path / "projects"
    frontend = root / "frontend-web"
    backend = root / "services" / "backend-api"
    frontend.mkdir(parents=True)
    backend.mkdir(parents=True)
    init_repo(frontend)
    init_repo(backend)

    catalog = RepoCatalog(root)

    assert [repo.name for repo in catalog.list_repos("front")] == ["frontend-web"]
    assert [repo.name for repo in catalog.list_repos("backend")] == ["backend-api"]
```

- [ ] **Step 2: Run the repo catalog tests to verify they fail**

Run: `uv run pytest tests/test_repo_catalog.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'allhands_host.repo_catalog'`

- [ ] **Step 3: Implement the repo catalog**

```python
# src/allhands_host/repo_catalog.py
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RepoRecord:
    name: str
    path: str


class RepoCatalog:
    def __init__(self, project_root: Path):
        self.project_root = project_root.resolve()
        self._cache: list[RepoRecord] | None = None

    def list_repos(self, query: str = "") -> list[RepoRecord]:
        repos = self._cache if self._cache is not None else self.refresh()
        needle = query.strip().lower()
        if not needle:
            return repos
        return [
            repo
            for repo in repos
            if needle in repo.name.lower() or needle in repo.path.lower()
        ]

    def refresh(self) -> list[RepoRecord]:
        if not self.project_root.exists():
            self._cache = []
            return self._cache

        discovered: dict[str, RepoRecord] = {}
        for marker in self.project_root.rglob(".git"):
            if ".worktrees" in marker.parts:
                continue
            repo_path = marker.parent.resolve()
            discovered[str(repo_path)] = RepoRecord(
                name=repo_path.name,
                path=str(repo_path),
            )

        self._cache = sorted(discovered.values(), key=lambda repo: repo.name.lower())
        return self._cache
```

- [ ] **Step 4: Run the repo catalog tests to verify they pass**

Run: `uv run pytest tests/test_repo_catalog.py -q`
Expected: PASS with `2 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/repo_catalog.py tests/test_repo_catalog.py
git commit -m "feat: add repo catalog for session creation"
```

### Task 2: Expose Repo Discovery Over HTTP

**Files:**
- Modify: `src/allhands_host/http.py`
- Modify: `src/allhands_host/app.py`
- Modify: `tests/test_http_api.py`

- [ ] **Step 1: Write the failing HTTP and shell-route tests**

```python
# tests/test_http_api.py
class FakeRepoCatalog:
    def __init__(self):
        self.queries = []

    def list_repos(self, query: str = ""):
        self.queries.append(query)
        return [{"name": "api", "path": "/tmp/projects/api"}]


class SessionApiTest(AsyncHTTPTestCase):
    def get_app(self):
        self.notification_service = FakeNotificationService()
        self.session_service = FakeSessionService()
        self.repo_catalog = FakeRepoCatalog()
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(
            settings=settings,
            session_service=self.session_service,
            notification_service=self.notification_service,
            repo_catalog=self.repo_catalog,
        )

    def test_repo_discovery_returns_results(self):
        response = self.fetch("/repos?query=api")
        payload = json.loads(response.body)

        assert response.code == 200
        assert payload == {"repos": [{"name": "api", "path": "/tmp/projects/api"}]}
        assert self.repo_catalog.queries == ["api"]


class FrontendShellTest(AsyncHTTPTestCase):
    def get_app(self):
        settings = Settings(
            project_root=Path("/tmp/projects"),
            database_path=Path("/tmp/allhands.sqlite3"),
            host="127.0.0.1",
            port=21991,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
        return build_app(
            settings=settings,
            session_service=FakeSessionService(),
            notification_service=FakeNotificationService(),
            repo_catalog=FakeRepoCatalog(),
            frontend_dist=Path(self.frontend_dist.name),
        )

    def test_control_room_new_route_falls_back_to_index(self):
        response = self.fetch("/control-room/new")

        assert response.code == 200
        assert "All Hands UI" in response.body.decode()
```

- [ ] **Step 2: Run the focused HTTP tests to verify they fail**

Run: `uv run pytest tests/test_http_api.py::SessionApiTest::test_repo_discovery_returns_results tests/test_http_api.py::FrontendShellTest::test_control_room_new_route_falls_back_to_index -q`
Expected: FAIL with `TypeError: build_app() got an unexpected keyword argument 'repo_catalog'` and/or `404` for `/control-room/new`

- [ ] **Step 3: Implement the handler, wiring, and SPA fallback**

```python
# src/allhands_host/http.py
def serialize_repo(repo: object) -> dict:
    if isinstance(repo, dict):
        return {"name": repo["name"], "path": repo["path"]}
    return {"name": repo.name, "path": repo.path}


class ReposHandler(tornado.web.RequestHandler):
    def initialize(self, repo_catalog) -> None:
        self.repo_catalog = repo_catalog

    def get(self) -> None:
        query = self.get_argument("query", "")
        repos = self.repo_catalog.list_repos(query)
        self.finish({"repos": [serialize_repo(repo) for repo in repos]})
```

```python
# src/allhands_host/app.py
from allhands_host.repo_catalog import RepoCatalog
from allhands_host.http import (
    AppSeenHandler,
    FrontendShellHandler,
    HealthHandler,
    PushSubscriptionHandler,
    ReposHandler,
    ServerInfoHandler,
    SessionArchiveHandler,
    SessionCancelHandler,
    SessionDetailHandler,
    SessionEventsHandler,
    SessionPromptHandler,
    SessionResetHandler,
    SessionResumeHandler,
    SessionsHandler,
    SessionSeenHandler,
    SessionTimelineHandler,
)


def build_app(
    settings: Settings | None = None,
    session_service: SessionService | None = None,
    notification_service: NotificationService | None = None,
    repo_catalog: RepoCatalog | None = None,
    frontend_dist: Path | None = None,
) -> tornado.web.Application:
    define_options()
    settings = settings or load_settings()
    frontend_dist = frontend_dist or default_frontend_dist()
    repo_catalog = repo_catalog or RepoCatalog(settings.project_root)
    store: SessionStore | None = None
    if session_service is None:
        database = Database(settings.database_path)
        database.migrate()
        store = SessionStore(database)
    if notification_service is None:
        if store is None:
            database = Database(settings.database_path)
            database.migrate()
            store = SessionStore(database)
        notification_service = NotificationService(
            store=store,
            public_key=settings.vapid_public_key,
            private_key=settings.vapid_private_key,
        )
    if session_service is None:
        session_service = SessionService(
            settings=settings,
            store=store,
            notification_service=notification_service,
        )
    routes: list[tuple] = [
        (r"/healthz", HealthHandler),
        (r"/server-info", ServerInfoHandler, {"settings": settings}),
        (r"/repos", ReposHandler, {"repo_catalog": repo_catalog}),
        (r"/sessions", SessionsHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)", SessionDetailHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/timeline", SessionTimelineHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/prompt", SessionPromptHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/resume", SessionResumeHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/cancel", SessionCancelHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/reset", SessionResetHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/archive", SessionArchiveHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/seen", SessionSeenHandler, {"session_service": session_service}),
        (r"/sessions/([^/]+)/events", SessionEventsHandler, {"session_service": session_service}),
        (r"/seen/app", AppSeenHandler, {"session_service": session_service}),
        (r"/push/subscriptions", PushSubscriptionHandler, {"notification_service": notification_service}),
    ]
 
    if frontend_dist.exists():
        routes.extend(
            [
                (
                    r"/(manifest\.webmanifest)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist)},
                ),
                (
                    r"/(sw\.js)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist)},
                ),
                (
                    r"/assets/(.*)",
                    tornado.web.StaticFileHandler,
                    {"path": str(frontend_dist / "assets")},
                ),
                (r"/", FrontendShellHandler, {"frontend_dist": frontend_dist}),
                (
                    r"/(control-room(?:/new)?|inbox|session/[^/]+)",
                    FrontendShellHandler,
                    {"frontend_dist": frontend_dist},
                ),
            ]
        )

    return tornado.web.Application(routes)
```

- [ ] **Step 4: Run the focused HTTP tests to verify they pass**

Run: `uv run pytest tests/test_http_api.py::SessionApiTest::test_repo_discovery_returns_results tests/test_http_api.py::FrontendShellTest::test_control_room_new_route_falls_back_to_index -q`
Expected: PASS with `2 passed`

- [ ] **Step 5: Commit**

```bash
git add src/allhands_host/http.py src/allhands_host/app.py tests/test_http_api.py
git commit -m "feat: expose repo discovery endpoint"
```

### Task 3: Add Frontend API Helpers And New-Session Store

**Files:**
- Modify: `frontend/src/lib/api.ts`
- Create: `frontend/src/lib/new-session-store.ts`
- Test: `frontend/src/lib/new-session-store.test.ts`

- [ ] **Step 1: Write the failing new-session store tests**

```typescript
// frontend/src/lib/new-session-store.test.ts
import { renderHook, waitFor } from "@solidjs/testing-library";
import { vi } from "vitest";

vi.mock("./api", () => ({
  getServerInfo: vi.fn(),
  listRepos: vi.fn(),
  createSession: vi.fn()
}));

import { createSession, getServerInfo, listRepos } from "./api";
import { createNewSessionState } from "./new-session-store";


test("loads launchers and initial repo results on mount", async () => {
  vi.mocked(getServerInfo).mockResolvedValue({
    vapidPublicKey: "",
    availableLaunchers: ["codex", "pi"],
    projectRoot: "/tmp/projects",
    transport: "sse"
  });
  vi.mocked(listRepos).mockResolvedValue({
    repos: [{ name: "api", path: "/tmp/projects/api" }]
  });

  const { result } = renderHook(() => createNewSessionState());

  await waitFor(() => {
    expect(result.launcher()).toBe("codex");
  });

  expect(result.launchers()).toEqual(["codex", "pi"]);
  expect(result.repos()).toEqual([{ name: "api", path: "/tmp/projects/api" }]);
});


test("submits a trimmed prompt for the selected repo", async () => {
  vi.mocked(getServerInfo).mockResolvedValue({
    vapidPublicKey: "",
    availableLaunchers: ["codex"],
    projectRoot: "/tmp/projects",
    transport: "sse"
  });
  vi.mocked(listRepos).mockResolvedValue({
    repos: [{ name: "api", path: "/tmp/projects/api" }]
  });
  vi.mocked(createSession).mockResolvedValue({
    id: "session-2",
    title: "api",
    status: "running",
    runState: "running",
    workspaceState: "ready"
  });

  const { result } = renderHook(() => createNewSessionState());

  await waitFor(() => {
    expect(result.repos()[0]?.path).toBe("/tmp/projects/api");
  });

  result.selectRepo({ name: "api", path: "/tmp/projects/api" });
  result.setPrompt("  Ship the auth fix  ");

  const sessionId = await result.submit();

  expect(sessionId).toBe("session-2");
  expect(createSession).toHaveBeenCalledWith("codex", "/tmp/projects/api", "Ship the auth fix");
});
```

- [ ] **Step 2: Run the store tests to verify they fail**

Run: `pnpm --dir frontend test -- --run src/lib/new-session-store.test.ts`
Expected: FAIL with `Failed to resolve import "./new-session-store"` and missing `createSession`/`listRepos` exports

- [ ] **Step 3: Implement the API helpers and store**

```typescript
// frontend/src/lib/api.ts
export type RepoSummary = {
  name: string;
  path: string;
};


export async function listRepos(query = ""): Promise<{ repos: RepoSummary[] }> {
  const response = await fetch(`/repos?query=${encodeURIComponent(query)}`);
  if (!response.ok) {
    throw new Error("failed to load repos");
  }
  return (await response.json()) as { repos: RepoSummary[] };
}


export async function createSession(
  launcher: string,
  repoPath: string,
  prompt: string
): Promise<SessionDetail> {
  return normalizeSession(
    await postJson<SessionApiRecord>("/sessions", {
      launcher,
      repoPath,
      prompt
    })
  );
}
```

```typescript
// frontend/src/lib/new-session-store.ts
import { createMemo, createSignal, onMount } from "solid-js";

import { createSession, getServerInfo, listRepos, type RepoSummary } from "./api";


export function createNewSessionState() {
  const [query, setQuery] = createSignal("");
  const [repos, setRepos] = createSignal<RepoSummary[]>([]);
  const [selectedRepo, setSelectedRepo] = createSignal<RepoSummary | null>(null);
  const [launchers, setLaunchers] = createSignal<string[]>([]);
  const [launcher, setLauncher] = createSignal("");
  const [prompt, setPrompt] = createSignal("");
  const [repoLoading, setRepoLoading] = createSignal(false);
  const [repoError, setRepoError] = createSignal<string | null>(null);
  const [launcherError, setLauncherError] = createSignal<string | null>(null);
  const [submitting, setSubmitting] = createSignal(false);
  const [submitError, setSubmitError] = createSignal<string | null>(null);

  async function loadLaunchers() {
    try {
      const info = await getServerInfo();
      setLaunchers(info.availableLaunchers);
      if (!launcher() && info.availableLaunchers.length > 0) {
        setLauncher(info.availableLaunchers[0]!);
      }
      setLauncherError(null);
    } catch {
      setLaunchers([]);
      setLauncher("");
      setLauncherError("Failed to load launchers.");
    }
  }

  async function refreshRepos(nextQuery = query()) {
    setRepoLoading(true);
    try {
      const response = await listRepos(nextQuery);
      setRepos(response.repos);
      setRepoError(null);
    } catch {
      setRepos([]);
      setRepoError("Failed to load repositories.");
    } finally {
      setRepoLoading(false);
    }
  }

  async function updateQuery(nextQuery: string) {
    setQuery(nextQuery);
    await refreshRepos(nextQuery);
  }

  function selectRepo(repo: RepoSummary) {
    setSelectedRepo(repo);
    setQuery(repo.name);
    setRepoError(null);
  }

  const canSubmit = createMemo(
    () => selectedRepo() != null && launcher() !== "" && prompt().trim() !== "" && !submitting()
  );

  async function submit() {
    if (!canSubmit()) {
      return null;
    }

    setSubmitting(true);
    setSubmitError(null);
    try {
      const session = await createSession(launcher(), selectedRepo()!.path, prompt().trim());
      return session.id;
    } catch {
      setSubmitError("Failed to create session.");
      return null;
    } finally {
      setSubmitting(false);
    }
  }

  onMount(() => {
    void loadLaunchers();
    void refreshRepos("");
  });

  return {
    query,
    repos,
    selectedRepo,
    launchers,
    launcher,
    prompt,
    repoLoading,
    repoError,
    launcherError,
    submitting,
    submitError,
    canSubmit,
    updateQuery,
    selectRepo,
    setLauncher,
    setPrompt,
    refreshRepos,
    submit
  };
}
```

- [ ] **Step 4: Run the store tests to verify they pass**

Run: `pnpm --dir frontend test -- --run src/lib/new-session-store.test.ts`
Expected: PASS with `2 passed`

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/api.ts frontend/src/lib/new-session-store.ts frontend/src/lib/new-session-store.test.ts
git commit -m "feat: add new session store and api helpers"
```

### Task 4: Build The Bottom-Sheet Component

**Files:**
- Create: `frontend/src/components/new-session-sheet.tsx`
- Create: `frontend/src/components/new-session-sheet.module.css`
- Test: `frontend/src/components/new-session-sheet.test.tsx`

- [ ] **Step 1: Write the failing sheet component tests**

```typescript
// frontend/src/components/new-session-sheet.test.tsx
import { fireEvent, render, screen } from "@solidjs/testing-library";

import { NewSessionSheet } from "./new-session-sheet";


test("focuses the repo search field and disables submit until the form is valid", async () => {
  render(() => (
    <NewSessionSheet
      query=""
      repos={[{ name: "api", path: "/tmp/projects/api" }]}
      selectedRepoPath=""
      launchers={["codex"]}
      launcher="codex"
      prompt=""
      repoLoading={false}
      repoError={null}
      launcherError={null}
      submitError={null}
      submitting={false}
      canSubmit={false}
      onClose={() => undefined}
      onQueryInput={() => undefined}
      onRetryRepos={() => undefined}
      onSelectRepo={() => undefined}
      onLauncherChange={() => undefined}
      onPromptInput={() => undefined}
      onSubmit={() => undefined}
    />
  ));

  const search = screen.getByLabelText("Repository");
  expect(document.activeElement).toBe(search);
  expect((screen.getByRole("button", { name: "Create session" }) as HTMLButtonElement).disabled).toBe(true);
});


test("renders retry and selection affordances", async () => {
  const onRetryRepos = vi.fn();
  const onSelectRepo = vi.fn();

  render(() => (
    <NewSessionSheet
      query="api"
      repos={[{ name: "api", path: "/tmp/projects/api" }]}
      selectedRepoPath="/tmp/projects/api"
      launchers={["codex"]}
      launcher="codex"
      prompt="Ship it"
      repoLoading={false}
      repoError="Failed to load repositories."
      launcherError={null}
      submitError={null}
      submitting={false}
      canSubmit={true}
      onClose={() => undefined}
      onQueryInput={() => undefined}
      onRetryRepos={onRetryRepos}
      onSelectRepo={onSelectRepo}
      onLauncherChange={() => undefined}
      onPromptInput={() => undefined}
      onSubmit={() => undefined}
    />
  ));

  fireEvent.click(screen.getByRole("button", { name: "Retry repository search" }));
  fireEvent.click(screen.getByRole("button", { name: /^api/ }));

  expect(onRetryRepos).toHaveBeenCalledTimes(1);
  expect(onSelectRepo).toHaveBeenCalledWith({ name: "api", path: "/tmp/projects/api" });
  expect(screen.getByText("Selected")).toBeTruthy();
});
```

- [ ] **Step 2: Run the component tests to verify they fail**

Run: `pnpm --dir frontend test -- --run src/components/new-session-sheet.test.tsx`
Expected: FAIL with `Failed to resolve import "./new-session-sheet"`

- [ ] **Step 3: Implement the sheet component and styles**

```typescript
// frontend/src/components/new-session-sheet.tsx
import { For, Show, onMount } from "solid-js";

import type { RepoSummary } from "../lib/api";
import styles from "./new-session-sheet.module.css";


export type NewSessionSheetProps = {
  query: string;
  repos: RepoSummary[];
  selectedRepoPath: string;
  launchers: string[];
  launcher: string;
  prompt: string;
  repoLoading: boolean;
  repoError: string | null;
  launcherError: string | null;
  submitError: string | null;
  submitting: boolean;
  canSubmit: boolean;
  onClose: () => void;
  onQueryInput: (value: string) => void;
  onRetryRepos: () => void;
  onSelectRepo: (repo: RepoSummary) => void;
  onLauncherChange: (value: string) => void;
  onPromptInput: (value: string) => void;
  onSubmit: () => void | Promise<void>;
};


export function NewSessionSheet(props: NewSessionSheetProps) {
  let repoInput!: HTMLInputElement;

  onMount(() => {
    repoInput.focus();
  });

  return (
    <div class={styles.backdrop}>
      <section aria-label="New session" aria-modal="true" class={styles.sheet} role="dialog">
        <div class={styles.header}>
          <h3>New session</h3>
          <button class={styles.close} type="button" onClick={props.onClose}>
            Close
          </button>
        </div>

        <label class={styles.field}>
          <span>Repository</span>
          <input
            ref={repoInput}
            aria-label="Repository"
            class={styles.input}
            value={props.query}
            onInput={(event) => void props.onQueryInput(event.currentTarget.value)}
            placeholder="Search repositories"
          />
        </label>

        <Show when={props.repoLoading}>
          <p class={styles.hint}>Loading repositories…</p>
        </Show>

        <Show when={props.repoError}>
          <div class={styles.errorRow}>
            <p class={styles.error}>{props.repoError}</p>
            <button type="button" onClick={props.onRetryRepos}>
              Retry repository search
            </button>
          </div>
        </Show>

        <div class={styles.repoList}>
          <For each={props.repos}>
            {(repo) => (
              <button
                class={styles.repoButton}
                classList={{ [styles.repoSelected]: props.selectedRepoPath === repo.path }}
                type="button"
                onClick={() => props.onSelectRepo(repo)}
              >
                <span>{repo.name}</span>
                <Show when={props.selectedRepoPath === repo.path}>
                  <span class={styles.selectedBadge}>Selected</span>
                </Show>
              </button>
            )}
          </For>
        </div>

        <label class={styles.field}>
          <span>Launcher</span>
          <select
            class={styles.select}
            value={props.launcher}
            onChange={(event) => props.onLauncherChange(event.currentTarget.value)}
          >
            <For each={props.launchers}>{(launcher) => <option value={launcher}>{launcher}</option>}</For>
          </select>
        </label>

        <Show when={props.launcherError}>
          <p class={styles.error}>{props.launcherError}</p>
        </Show>

        <label class={styles.field}>
          <span>Prompt</span>
          <textarea
            aria-label="Prompt"
            class={styles.textarea}
            rows={5}
            value={props.prompt}
            onInput={(event) => props.onPromptInput(event.currentTarget.value)}
            placeholder="Describe what the session should do"
          />
        </label>

        <Show when={props.submitError}>
          <p class={styles.error}>{props.submitError}</p>
        </Show>

        <div class={styles.footer}>
          <button
            class={styles.primary}
            type="button"
            disabled={!props.canSubmit || props.submitting}
            onClick={() => void props.onSubmit()}
          >
            {props.submitting ? "Creating…" : "Create session"}
          </button>
        </div>
      </section>
    </div>
  );
}
```

```css
/* frontend/src/components/new-session-sheet.module.css */
.backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding: 16px;
  background: rgba(15, 23, 42, 0.28);
}

.sheet {
  width: min(100%, 720px);
  max-height: min(88vh, 820px);
  display: grid;
  gap: 14px;
  padding: 20px;
  border: 1px solid var(--border);
  border-radius: 28px 28px 20px 20px;
  background: var(--panel);
  box-shadow: var(--shadow-soft);
  overflow: auto;
}

.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.close {
  border: 0;
  background: transparent;
  color: var(--muted);
}

.field {
  display: grid;
  gap: 8px;
}

.input,
.select,
.textarea {
  border: 1px solid var(--border);
  border-radius: 16px;
  padding: 12px;
  background: var(--panel);
  color: var(--text);
}

.textarea {
  min-height: 120px;
}

.repoList {
  display: grid;
  gap: 8px;
}

.repoButton {
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: 1px solid var(--border);
  border-radius: 16px;
  background: var(--panel);
  padding: 12px 14px;
  text-align: left;
}

.repoSelected {
  border-color: var(--accent);
}

.selectedBadge {
  color: var(--accent);
  font-size: 0.875rem;
}

.hint {
  margin: 0;
  color: var(--muted);
}

.errorRow {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.error {
  margin: 0;
  color: #b42318;
}

.footer {
  position: sticky;
  bottom: -20px;
  padding-top: 8px;
  background: linear-gradient(180deg, rgba(255, 255, 255, 0), var(--panel) 32%);
}

.primary {
  width: 100%;
  border: 1px solid var(--accent);
  background: var(--accent);
  color: var(--panel);
  border-radius: 999px;
  padding: 12px 18px;
}
```

- [ ] **Step 4: Run the component tests to verify they pass**

Run: `pnpm --dir frontend test -- --run src/components/new-session-sheet.test.tsx`
Expected: PASS with `2 passed`

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/new-session-sheet.tsx frontend/src/components/new-session-sheet.module.css frontend/src/components/new-session-sheet.test.tsx
git commit -m "feat: add new session bottom sheet"
```

### Task 5: Wire The Nested Control Room Route

**Files:**
- Modify: `frontend/src/routes/control-room.tsx`
- Create: `frontend/src/routes/control-room.module.css`
- Modify: `frontend/src/routes/control-room.test.tsx`
- Modify: `frontend/src/app.tsx`
- Modify: `frontend/src/app.test.tsx`

- [ ] **Step 1: Write the failing route and integration tests**

```typescript
// frontend/src/routes/control-room.test.tsx
import { render, screen, within } from "@solidjs/testing-library";

import { ControlRoom } from "./control-room";


test("renders the focused session, quick switch tray, and new session CTA", () => {
  render(() => (
    <ControlRoom
      sessions={[
        { id: "a", title: "API Refactor", status: "attention_required" },
        { id: "b", title: "Docs Cleanup", status: "running" }
      ]}
      sheetOpen={false}
    />
  ));

  const focused = screen.getByLabelText("Focused session");

  expect(within(focused).getByText("API Refactor")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Docs Cleanup" })).toBeTruthy();
  expect((screen.getByRole("link", { name: "New session" }) as HTMLAnchorElement).getAttribute("href")).toBe("/control-room/new");
});
```

```typescript
// frontend/src/app.test.tsx
import { fireEvent, render, screen, within } from "@solidjs/testing-library";


test("deep-links into the control room new-session sheet", async () => {
  window.history.pushState({}, "", "/control-room/new");

  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url === "/sessions" && init?.method == null) {
      return { ok: true, json: async () => ({ sessions: [] }) };
    }
    if (url === "/seen/app") {
      return { ok: true, json: async () => ({}) };
    }
    if (url === "/server-info") {
      return {
        ok: true,
        json: async () => ({
          vapidPublicKey: "",
          availableLaunchers: ["codex", "pi"],
          projectRoot: "/tmp/projects",
          transport: "sse"
        })
      };
    }
    if (url === "/repos?query=") {
      return {
        ok: true,
        json: async () => ({ repos: [{ name: "api", path: "/tmp/projects/api" }] })
      };
    }

    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("EventSource", FakeEventSource);

  render(() => <App vapidPublicKey="" />);

  expect(await screen.findByRole("dialog", { name: "New session" })).toBeTruthy();
  expect(await screen.findByRole("button", { name: /^api/ })).toBeTruthy();
});


test("creates a session from the sheet and navigates to the session route", async () => {
  window.history.pushState({}, "", "/control-room/new");

  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url === "/sessions" && init?.method == null) {
      return { ok: true, json: async () => ({ sessions: [] }) };
    }
    if (url === "/seen/app") {
      return { ok: true, json: async () => ({}) };
    }
    if (url === "/server-info") {
      return {
        ok: true,
        json: async () => ({
          vapidPublicKey: "",
          availableLaunchers: ["codex"],
          projectRoot: "/tmp/projects",
          transport: "sse"
        })
      };
    }
    if (url === "/repos?query=") {
      return {
        ok: true,
        json: async () => ({ repos: [{ name: "api", path: "/tmp/projects/api" }] })
      };
    }
    if (url === "/sessions" && init?.method === "POST") {
      return {
        ok: true,
        json: async () => ({
          id: "session-2",
          repoPath: "/tmp/projects/api",
          runState: "running",
          workspaceState: "ready"
        })
      };
    }
    if (url === "/sessions/session-2") {
      return {
        ok: true,
        json: async () => ({
          id: "session-2",
          title: "API Refactor",
          repoPath: "/tmp/projects/api",
          runState: "running",
          workspaceState: "ready"
        })
      };
    }
    if (url === "/sessions/session-2/timeline") {
      return { ok: true, json: async () => ({ events: [] }) };
    }

    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("EventSource", FakeEventSource);

  render(() => <App vapidPublicKey="" />);

  fireEvent.click(await screen.findByRole("button", { name: /^api/ }));
  fireEvent.input(screen.getByLabelText("Prompt"), {
    target: { value: "Ship the auth fix" }
  });
  fireEvent.click(screen.getByRole("button", { name: "Create session" }));

  expect(await screen.findByText("API Refactor")).toBeTruthy();
});
```

- [ ] **Step 2: Run the focused frontend tests to verify they fail**

Run: `pnpm --dir frontend test -- --run src/routes/control-room.test.tsx src/app.test.tsx`
Expected: FAIL because the CTA, nested route, and new-session sheet do not exist yet

- [ ] **Step 3: Implement the routed sheet integration**

```typescript
// frontend/src/routes/control-room.tsx
import type { JSX } from "solid-js";
import { Show } from "solid-js";

import { SessionCard } from "../components/session-card";
import { SessionTray } from "../components/session-tray";
import styles from "./control-room.module.css";


export type ControlRoomProps = {
  sessions: Array<{ id: string; title: string; status: string }>;
  children?: JSX.Element;
  sheetOpen?: boolean;
};


export function ControlRoom(props: ControlRoomProps) {
  const focused = () => props.sessions[0];

  return (
    <section class={styles.room}>
      <div class={styles.header}>
        <h2>Control Room</h2>
        <a class={styles.newSession} href="/control-room/new">
          New session
        </a>
      </div>

      <div classList={{ [styles.content]: true, [styles.dimmed]: props.sheetOpen ?? false }}>
        {focused() ? (
          <SessionCard title={focused()!.title} status={focused()!.status} />
        ) : (
          <article class={styles.empty}>No sessions yet</article>
        )}
        <SessionTray
          sessions={props.sessions.map((session) => ({
            id: session.id,
            title: session.title
          }))}
        />
      </div>

      <Show when={props.children}>{props.children}</Show>
    </section>
  );
}
```

```css
/* frontend/src/routes/control-room.module.css */
.room {
  position: relative;
  display: grid;
  gap: 16px;
}

.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.newSession {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--accent);
  background: var(--accent);
  color: var(--panel);
  border-radius: 999px;
  padding: 10px 16px;
  text-decoration: none;
}

.content {
  display: grid;
  gap: 16px;
  transition: opacity 140ms ease;
}

.dimmed {
  opacity: 0.4;
  pointer-events: none;
}

.empty {
  border: 1px dashed var(--border);
  border-radius: var(--radius-lg);
  padding: 20px;
  color: var(--muted);
}
```

```typescript
// frontend/src/app.tsx
import type { JSX } from "solid-js";

import { A, Navigate, Route, Router, useLocation, useNavigate } from "@solidjs/router";

import "./styles/tokens.css";
import "./styles/app.css";

import { NewSessionSheet } from "./components/new-session-sheet";
import { createNewSessionState } from "./lib/new-session-store";
import { createSessionsState } from "./lib/session-store";
import { ControlRoom } from "./routes/control-room";
import { Inbox } from "./routes/inbox";
import { SessionRoute } from "./routes/session";


function SessionPage() {
  return <SessionRoute />;
}


function AppShell(props: { children: JSX.Element }) {
  return (
    <main class="app-shell">
      <header class="topbar">
        <h1>Control Room</h1>
        <nav>
          <A href="/control-room">Control Room</A>
          <A href="/inbox">Inbox</A>
        </nav>
      </header>
      {props.children}
    </main>
  );
}


export function App(props: { vapidPublicKey?: string }) {
  function ControlRoomPage(routeProps: { children?: JSX.Element }) {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    const location = useLocation();

    return (
      <ControlRoom
        sessions={state().sessions}
        sheetOpen={location.pathname === "/control-room/new"}
      >
        {routeProps.children}
      </ControlRoom>
    );
  }

  function NewSessionPage() {
    const state = createNewSessionState();
    const navigate = useNavigate();

    return (
      <NewSessionSheet
        query={state.query()}
        repos={state.repos()}
        selectedRepoPath={state.selectedRepo()?.path ?? ""}
        launchers={state.launchers()}
        launcher={state.launcher()}
        prompt={state.prompt()}
        repoLoading={state.repoLoading()}
        repoError={state.repoError()}
        launcherError={state.launcherError()}
        submitError={state.submitError()}
        submitting={state.submitting()}
        canSubmit={state.canSubmit()}
        onClose={() => navigate("/control-room", { replace: true })}
        onQueryInput={(value) => void state.updateQuery(value)}
        onRetryRepos={() => void state.refreshRepos()}
        onSelectRepo={state.selectRepo}
        onLauncherChange={state.setLauncher}
        onPromptInput={state.setPrompt}
        onSubmit={async () => {
          const sessionId = await state.submit();
          if (sessionId) {
            navigate(`/session/${sessionId}`, { replace: true });
          }
        }}
      />
    );
  }

  function InboxPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    return <Inbox sessions={state().sessions} />;
  }

  return (
    <Router root={AppShell}>
      <Route path="/" component={() => <Navigate href="/control-room" />} />
      <Route path="/control-room" component={ControlRoomPage}>
        <Route path="/new" component={NewSessionPage} />
      </Route>
      <Route path="/inbox" component={InboxPage} />
      <Route path="/session/:sessionId" component={SessionPage} />
    </Router>
  );
}
```

- [ ] **Step 4: Run the focused frontend tests to verify they pass**

Run: `pnpm --dir frontend test -- --run src/routes/control-room.test.tsx src/app.test.tsx`
Expected: PASS with the updated Control Room and nested-route coverage

- [ ] **Step 5: Commit**

```bash
git add frontend/src/routes/control-room.tsx frontend/src/routes/control-room.module.css frontend/src/routes/control-room.test.tsx frontend/src/app.tsx frontend/src/app.test.tsx
git commit -m "feat: add control room session creation flow"
```

## Final Verification

- Run: `uv run pytest -q`
  Expected: all backend tests pass, including `tests/test_repo_catalog.py` and the updated HTTP tests.
- Run: `pnpm --dir frontend test -- --run`
  Expected: all Vitest tests pass, including the new session store, bottom-sheet, control-room, and app-route coverage.
- Run: `pnpm --dir frontend build`
  Expected: Vite builds `frontend/dist/` without routing or component errors.
