# Control Room New Session Flow Design

## Goal

Add a visible `New session` entry point to the home screen without turning `Control Room` into a setup surface. The home screen should remain focused on active sessions, while a fast-launch flow opens as a bottom sheet over `Control Room`, lets the user discover a repo under the configured project root, choose a launcher, enter the initial prompt, and then navigates directly into the new session after creation.

## Problem

The backend already supports session creation through `POST /sessions`, but the shipped frontend does not expose that capability from the home screen. `Control Room` currently renders the focused session card and the session tray only, so users have no direct path to start a new session from the primary entry screen.

## Product Decisions

- `Control Room` remains the default home screen.
- `New session` is a prominent call to action on `Control Room`, not an inline composer.
- The setup flow is optimized for fast launch rather than full preflight configuration.
- Successful creation should navigate directly to `/session/:id`.
- Repo selection should support browsing and searching all repos under the configured project root, not just manual path entry or previously used repos.
- The setup flow should use a bottom sheet over `Control Room`.
- The sheet should be controlled by routing, not local toggle state.

## UX Model

### Entry Point

`Control Room` gains a `New session` action in the top-level header area. This action is visible whether or not any sessions exist.

### Route Model

The session setup surface is represented by a nested route under `Control Room`, for example:

- `/control-room`
- `/control-room/new`

`/control-room` renders the base home screen. `/control-room/new` keeps the same parent screen mounted and renders a bottom-sheet composer over it. This gives the flow proper back-button behavior, a stable refresh model, and a clear URL for deep-linking without duplicating sheet state in component logic.

### Sheet Layout

The bottom sheet contains a single fast-launch form:

1. Header with `New session` title and dismiss action.
2. Repo search field with live results below it.
3. Compact launcher selector, preselected to the first launcher returned by server info.
4. Prompt textarea.
5. Sticky primary action for `Create session`.

The background `Control Room` remains visible and dimmed while the sheet is open.

### Interaction Details

- Opening `/control-room/new` should focus the repo search input.
- Repo search should support both blank-state browsing and query-driven filtering.
- Selecting a repo should update the form in place; the flow stays on one sheet.
- `Create session` remains disabled until repo, launcher, and prompt are valid.
- On submit, the sheet enters a loading state and stays open until the create request resolves.
- On success, route directly to `/session/:id`.
- On dismiss, route back to `/control-room`.

## Repo Discovery Design

### Why It Is Needed

The current backend accepts a `repoPath` during session creation but does not provide a way for the frontend to discover valid repositories under `projectRoot`. Because the chosen UX requires browse/search across all repos, repo discovery must become a first-class backend capability.

### API Shape

Add a discovery endpoint:

- `GET /repos?query=<text>`

Response shape:

```json
{
  "repos": [
    {
      "path": "/tmp/projects/api",
      "name": "api"
    }
  ]
}
```

Behavior:

- A blank query returns an initial browse list ordered alphabetically by repo name.
- A non-blank query filters the discovered repo set.
- Results only include repositories under the configured `projectRoot`.
- Results exclude generated `.worktrees` directories.

### Backend Service

Add a backend repo-discovery service responsible for:

- scanning the configured project root for Git repositories
- excluding nested `.worktrees` paths
- returning normalized repo records for the UI
- caching the discovered set in memory so every keystroke does not trigger a full filesystem walk

The filtering step should happen against the cached set, while refresh or invalidation can remain simple in v1.

## Frontend Architecture

### Control Room Page

`ControlRoomPage` should own the session summary state and render the base route content plus a child outlet for the new-session sheet. This avoids remounting the background screen when the nested route opens.

### New Session Sheet

The sheet should manage only form-local state:

- repo query
- selected repo
- selected launcher
- prompt text
- loading and inline error states

It should fetch:

- launcher options from existing server info
- repo results from the new repo-discovery endpoint

It should submit via the existing `POST /sessions` endpoint.

### Session Creation Flow

1. User opens `/control-room/new`.
2. Sheet requests launcher metadata and repo results.
3. User selects a repo, confirms launcher, and enters the prompt.
4. Sheet posts to `/sessions`.
5. On success, the router navigates to `/session/:id`.

## Error Handling

The flow should recover in place without forcing the user out of `Control Room`.

### Repo Discovery

Repo search supports four states:

- idle
- loading
- empty
- error

If repo discovery fails, the sheet stays open and shows an inline retry affordance below the search field.

### Session Creation

If session creation fails:

- keep the sheet open
- preserve the selected repo, launcher, and prompt
- show an inline error near the primary action
- allow retry without re-entering the form

### Validation

Validation stays minimal:

- selected repo is required
- launcher is required
- prompt must be non-empty after trimming

## Testing

### Frontend

Add tests for:

- rendering the `New session` action on `Control Room`
- opening and dismissing the nested route sheet
- repo search request and result rendering
- blank-state browse results
- launcher selection and prompt entry
- form validation and disabled submit state
- loading state during creation
- successful navigation to `/session/:id`
- inline repo-discovery error handling
- inline session-creation error handling

### Backend

Add tests for:

- repo discovery under `projectRoot`
- exclusion of `.worktrees` content
- query filtering behavior
- HTTP response shape for `GET /repos`
- failure behavior when repo discovery cannot complete

## Out Of Scope

This design does not include:

- a multi-step setup wizard
- advanced session metadata fields beyond repo, launcher, and prompt
- draft persistence after dismissing the sheet
- repo favorites, recents, or ranking logic
- changes to the session detail view beyond navigating to it after creation

## Implementation Notes

- Prefer a nested route over ad hoc sheet state because the route is the source of truth for whether the sheet is open.
- Keep repo discovery and session creation as separate API calls. This avoids overloading `POST /sessions` with discovery concerns and keeps error handling simpler.
- Preserve the existing `Control Room` role as the operational home screen rather than turning it into a creation dashboard.
