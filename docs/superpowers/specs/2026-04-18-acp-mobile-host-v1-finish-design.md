# ACP Mobile Host V1 Finish Design

Date: 2026-04-18
Status: Ready for review

## Summary

This document scopes the remaining work needed to call the current rewrite branch a complete v1 for personal mobile session control.

The existing branch already provides:

- Tornado runtime bootstrap with options-driven config
- SQLite-backed sessions and event storage
- local ACP subprocess attach and resume plumbing
- worktree creation and repo-root enforcement
- a Solid PWA shell served from Tornado
- session list loading with SSE updates
- Web Push subscription storage and service worker installation

What is still missing is coherent product behavior around lifecycle, notifications, and the session detail experience. This finish pass tightens those boundaries without widening scope into diff review, markdown rendering, terminal emulation, or multi-machine orchestration.

## Goals

- Make the server authoritative for session lifecycle and workspace state
- Complete the mobile-first `Session` screen as the primary operating surface
- Add background push behavior for `attention_required` and `completed`
- Suppress push when the user has already seen the relevant session state
- Support destructive admin controls directly from the session screen
- Preserve current rewrite architecture instead of introducing a second control plane

## Non-Goals

- Diff or review UI
- Markdown or plan document rendering
- Embedded terminal
- Custom visualization tooling
- Multi-machine execution
- Desktop packaging or single-binary distribution work
- Replacing SSE with WebSocket or another live transport

## Current Problem

The current branch has enough infrastructure to create and monitor sessions, but the remaining product gaps all center on lifecycle semantics:

- `resume` exists, but session state is still too thin for the UI to drive confidently
- push subscriptions exist, but the daemon does not yet decide when to notify
- the session screen is still mostly a shell
- destructive controls like cancel and reset do not yet have complete end-to-end semantics
- the app does not yet track what the user has already seen, so background push would be noisy or wrong

These are not separate subsystems. They are one unfinished lifecycle problem and should be solved together.

## Lifecycle Model

The backend should remain the single source of truth for session state. The frontend should render the durable snapshot the daemon exposes instead of inferring session state from raw ACP traffic.

Each durable session should expose these lifecycle fields:

- `run_state`: `created`, `running`, `attention_required`, `completed`, `failed`, `detached`, `resume_available`, `archived`
- `workspace_state`: `ready`, `missing`
- `last_bound_agent_session_id`: the last launcher/ACP session token used for resume
- `last_activity_at`
- `last_notified_at`
- `active_notification_kind`: `none`, `attention_required`, `completed`
- `last_seen_event_seq`

The raw event log remains authoritative, but the daemon should project these fields so the client can render a stable operating model.

### Transition Rules

#### Create

- Validate the repo path against the configured root
- Create a dedicated worktree
- Start the adapter and attach ACP
- Mark `run_state=running`
- Mark `workspace_state=ready`
- Persist `last_bound_agent_session_id` from the attachment

#### Attention Required

- Mark `run_state=attention_required`
- Drop the live attachment
- Keep session history and worktree intact
- Mark `active_notification_kind=attention_required`

`attention_required` is terminal for the live run. The agent has stopped and cannot later complete without an explicit user resume flow.

#### Completed

- Mark `run_state=completed`
- Drop the live attachment
- Keep history and worktree intact
- Mark `active_notification_kind=completed`

#### Daemon Restart

- Reload sessions and events from SQLite
- Do not attempt to restore raw ACP stdio state
- Any session that had been live and was not already terminal should become `detached` or `resume_available`
- Preserve `workspace_state`

#### Cancel Run

- Stop the live attachment if present
- Keep history and worktree intact
- Mark `run_state=detached` or `resume_available` depending on whether a resume token is available

#### Reset Workspace

Reset is always available, including during an active run.

Reset means:

- stop the live run if one exists
- preserve session history
- delete the current worktree
- mark `workspace_state=missing`
- leave the session resumable if a resume token exists

After reset:

- `run_state=resume_available` when `last_bound_agent_session_id` exists
- otherwise `run_state=detached`

#### Resume

Resume is the recovery path for both detached sessions and sessions whose worktree has been reset.

Resume must:

- recreate a fresh worktree first if `workspace_state=missing`
- run the adapter resume path using `last_bound_agent_session_id`
- bind the new attachment back to the same logical session
- mark `run_state=running`
- mark `workspace_state=ready`

#### Archive

- Keep the durable history
- Mark `run_state=archived`
- Clear `active_notification_kind`

## Notification Model

Push remains complementary to SSE. The app should feel live when open and interrupt only when closed or backgrounded.

### Push Triggers

The daemon may send push only for:

- `attention_required`
- `completed`

No other event type should generate a background push in v1.

### Foreground Versus Background

When the app is open and actively rendering live state, SSE should be the only delivery channel. Background push should be suppressed.

The design should not use a dedicated presence system. Instead it should use a durable seen model:

- app-level `last_seen_at`
- per-session `last_seen_event_seq`

The client updates seen state when:

- the app is visible
- the session detail screen renders events
- the user opens a notification deep link
- the control room or inbox is actively open

Push suppression rules:

- do not push if the newest push-worthy session event is already at or below `last_seen_event_seq`
- do not push if `last_seen_at` is recent enough to treat the app as foreground
- otherwise send or replace the session’s current active notification

This avoids a separate presence subsystem while keeping suppression restart-safe.

### Collapsing Notifications

There should be at most one active notification per session.

Requirements:

- notifications collapse by session id
- a new push for the same session replaces the old one
- tapping the notification deep-links to `/session/:id`

Because `attention_required` halts the run, `completed` does not need to replace `attention_required` for the same live attempt. They are mutually exclusive outcomes for one run.

### Permission UX

The app should not request notification permission on first load.

Instead:

- prompt for notification permission after the first session is created
- keep the app fully usable if permission is denied
- provide a non-blocking way to re-enable notifications later

## Session Screen

The `Session` route should become the main mobile operating surface.

### Layout

The layout should prioritize timeline context over controls above the fold:

- compact session header with title, launcher, run state, workspace state, and last activity
- timeline first
- actions below the timeline
- prompt composer pinned at the bottom of the viewport

The prompt composer should remain visually subordinate to the timeline.

### Timeline Modes

The timeline should support two modes:

- curated human-readable mode by default
- raw event inspector as a toggle

Curated mode should cover daemon-normalized lifecycle events and important ACP activity, including:

- session creation
- attach and resume
- prompt sent
- grouped thought and progress updates
- attention required
- completion
- cancellation
- archive
- reset and workspace recreation

Raw mode should show:

- event sequence
- event type
- timestamp
- raw payload

The raw event log remains durable. Curated mode is only a presentation layer over known event categories.

### Action Model

The session screen must expose these controls directly:

- `Prompt`
- `Resume`
- `Archive`
- `Cancel run`
- `Reset workspace`

Behavior:

- `Prompt` is available only while the session is live
- if the session is not live, the prompt box is disabled until the user explicitly taps `Resume`
- there is no auto-resume-on-send path
- destructive actions require confirmation on mobile

### Reset and Resume UX

`Reset workspace` should present the user with a destructive confirmation and then:

- stop the run if active
- preserve history
- remove the worktree
- leave the session in a resumable or detached state

`Resume` should automatically recreate a fresh worktree first when the workspace is missing. There is no separate `Recreate workspace` action in v1.

## API Contract Changes

The finish pass should extend the current HTTP surface so the SPA can operate without guessing.

Required additions or upgrades:

- enrich `GET /sessions` with lifecycle and workspace summary fields needed for control-room sorting and badges
- enrich `GET /sessions/:id` with the projected lifecycle snapshot used by the session screen
- add a JSON event snapshot route for initial timeline rendering, rather than relying on SSE framing for first load
- keep `GET /sessions/:id/events` as the live SSE stream
- add `POST /sessions/:id/cancel`
- add `POST /sessions/:id/reset`
- add seen-cursor update endpoints so the client can advance app-level `last_seen_at` and per-session `last_seen_event_seq`

Exact route names may change during implementation, but the contract must preserve these capabilities.

## Frontend State Contract

The SPA should continue using:

- REST for initial snapshot
- SSE for live updates while the app is open
- push only when backgrounded or closed

The client may still render curated timeline entries locally, but it should not derive lifecycle rules, notification semantics, or workspace semantics from raw events alone.

The frontend should treat the server’s projected session snapshot as authoritative for:

- run state
- workspace state
- control enablement
- resume availability
- notification clearing

## Data and Storage

The finish pass requires a small amount of additional durable state beyond the current session and event tables.

Durable additions:

- projected lifecycle fields for sessions
- app-level seen timestamp
- per-session seen cursor
- per-session active notification kind and notification timestamp

This state should remain simple and single-user oriented. There is no need to introduce a user table, client identities, or multi-device ownership semantics in v1.

## Error Handling

The lifecycle rules above need explicit failure behavior:

- failed cancel/reset should keep the prior session state and surface an error event
- failed worktree recreation during resume should leave the session non-live and mark the workspace as missing
- failed push delivery should not break the session lifecycle transition itself
- missing resume metadata should disable resume and keep the session detached

Administrative actions should prefer preserving session history over forcing cleanup to succeed.

## Testing

This finish pass should be verified with both backend and frontend coverage.

### Backend

- lifecycle transition tests for create, cancel, reset, resume, archive
- tests that reset on an active session stops the run and marks the workspace missing
- tests that resume recreates a missing worktree automatically
- tests for notification suppression based on seen state
- tests for per-session notification collapse and replacement behavior
- tests for new session detail and timeline snapshot endpoints

### Frontend

- session detail screen tests for timeline-first layout and mode toggle
- control enablement tests for live versus non-live sessions
- disabled prompt box tests when resume is required
- notification opt-in flow after first session creation
- deep-link handling into `/session/:id`
- seen-cursor update tests during active viewing

### Verification Target

The implementation should end with:

- full `pytest` pass
- full frontend `vitest` pass
- successful frontend production build
- manual smoke verification that the session detail route, cancel, reset, resume, and notification subscription flow behave coherently

## Scope Boundary

This document intentionally keeps the completion pass narrow.

It does not expand the product beyond the original rewrite vision. It only finishes the missing v1 semantics so the browser/PWA control surface works coherently on mobile with lifecycle-aware notifications and durable session control.
