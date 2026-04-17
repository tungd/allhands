# ACP Mobile Host Design

Date: 2026-04-18
Status: Approved for planning

## Summary

Build a single-user daemon plus browser/PWA control surface for running ACP-compatible coding agents on one host machine. The product is ACP-first, mobile-usable, and optimized for session steering over a browser instead of a desktop-only UI.

The daemon owns:

- durable logical sessions
- dedicated git worktrees per session by default
- local ACP subprocess launch and attachment over stdio
- append-only event persistence
- a small HTTP API with SSE for live updates

The daemon does not attempt to restore a raw ACP stdio connection after restart. Instead, sessions remain visible and resumable, and the selected agent adapter is responsible for starting a fresh live attachment when the user chooses to resume.

## Goals

- Single-user system only
- One host machine for v1
- Browser/PWA interface available over a public HTTPS endpoint on the user's domain
- ACP-first architecture
- Local subprocess ACP transport over stdio only in v1
- Full mobile control for session create, prompt, resume, cancel, and cleanup
- Concurrent sessions on the same host
- Durable session and event history across daemon restarts
- Root project directory boundary instead of unrestricted host command execution
- Autonomous-by-default agent operation

## Non-Goals

- Multi-user tenancy
- Remote ACP HTTP or WebSocket transports in v1
- Automatic reconstruction of in-flight ACP connections after daemon restart
- Desktop-native application packaging
- Rich diff review in v1
- Plan or markdown document viewing in v1
- Embedded terminal in v1
- Custom visualization tool rendering in v1

## Product Shape

The closest reference point is a desktop coding-agent UI, but delivered as a browser/PWA that works well from a phone. The main differentiators are:

- browser and mobile accessibility
- ACP-native orchestration instead of a single-agent bespoke protocol
- session durability independent of any single browser tab

The primary home screen is `Control Room`:

- one focused active session occupies the main view
- other concurrent sessions are available in a quick-switch tray
- a broader inbox/list view remains available for scanning all sessions

## Core Model

The system is built around three distinct concepts:

### Logical Session

A durable record representing one unit of work. A logical session survives browser disconnects and daemon restarts.

### Live Attachment

An optional running ACP subprocess currently bound to a logical session. A live attachment is disposable and may disappear when the daemon restarts or the process exits.

### Event Log

An append-only durable stream of normalized events for timeline replay and SSE fan-out. The event log is authoritative. Live streaming is only a delivery mechanism for persisted events.

## Session State Model

Each logical session contains:

- stable session id
- launcher type, such as `claude`, `codex`, or `pi`
- source repo path under the configured root
- optional subfolder path within the repo
- dedicated worktree path
- session title and derived summary text
- status
- timestamps for create, start, last activity, detach, complete
- launcher-specific resume metadata
- optional live attachment metadata
- current branch information
- waiting or unread indicator for the inbox

Session statuses are:

- `created`
- `running`
- `attention_required`
- `detached`
- `resume_available`
- `completed`
- `failed`
- `cancelled`
- `archived`

`attention_required` means the session exists and needs user attention in the inbox or control room. `detached` means the logical session exists but there is no current live ACP attachment. `resume_available` means the adapter has enough information to start a new live attachment for the same logical session.

## Lifecycle

### New Session

1. User selects a repo path under the configured project root.
2. User selects a launcher adapter and submits the initial task.
3. The daemon validates the path boundary.
4. The workspace manager creates a dedicated worktree by default.
5. The launcher adapter starts a local subprocess.
6. The ACP layer initializes the subprocess over stdio.
7. All meaningful events are normalized and persisted.
8. The UI subscribes via SSE and renders live progress from stored events.

### Browser Disconnect

- The logical session remains active.
- The live attachment continues to run.
- On reconnect, the UI fetches current session state and resumes SSE from the last event id.

### Daemon Restart

- The daemon reloads logical sessions and event history from SQLite.
- Any former live attachment is treated as gone.
- Sessions return as `detached` or `resume_available`.
- The UI shows the prior timeline immediately.
- The user may explicitly choose `resume`.

### Resume

- The user triggers resume from the UI.
- The launcher adapter starts a fresh subprocess using the agent's native resume behavior.
- The ACP layer binds the new subprocess to the existing logical session.
- New events continue in the same durable session timeline.

This is a product-level continuation model, not a transport-level process resurrection model.

## Architecture

The daemon is a Python application built around these subsystems:

### Session Store

Persists logical sessions, derived summaries, live attachment metadata, and event records in SQLite.

### Event Store

Maintains an append-only sequence per session. Every event is written before it is emitted over SSE.

### Launcher Adapters

One adapter per agent family. Each adapter is responsible for:

- capability detection
- command construction for new sessions
- command construction for resume flows
- extracting and persisting resume metadata
- translating launcher-specific details into daemon-level metadata

ACP remains the common transport once the process is live, but start and resume behavior is adapter-specific.

### ACP Attachment Layer

Owns stdio transport, JSON-RPC framing, ACP request and notification handling, and normalization of raw protocol traffic into durable daemon events.

### Workspace Manager

Validates project-root boundaries, creates worktrees, tracks cleanup state, and handles archive or removal actions.

### Web Layer

Exposes the HTTP API, serves the SPA and PWA assets, and provides SSE endpoints.

## Stack

The intended v1 stack is:

- Python
- `uv` for dependency management and local execution
- Tornado for HTTP server, static assets, SSE, subprocess-friendly asyncio integration, and logging
- official `agent-client-protocol` Python SDK for ACP models and plumbing
- Solid for the frontend SPA
- Ark UI for headless accessible UI primitives
- CSS modules plus global CSS variables for styling
- SSE for live event delivery
- SQLite for persistence

This choice is driven primarily by the availability of an official ACP Python SDK and secondarily by Tornado's fit for an async daemon with static asset serving and strong default logging. On the frontend, Solid is chosen for a fast, highly interactive SPA, while Ark UI provides accessible headless primitives without forcing Tailwind or a heavyweight visual kit.

Packaging into a single distributable artifact is deferred until after a working v1 exists.

## HTTP API

The daemon exposes a small HTTP surface:

- `GET /`
  Serve the SPA entry point.
- `GET /manifest.webmanifest`
  Serve the PWA manifest.
- `GET /sw.js`
  Serve the service worker.
- `GET /server-info`
  Return version, configured project root, available launchers, and daemon health.
- `GET /sessions`
  Return control-room and inbox summaries.
- `POST /sessions`
  Create a logical session, create a worktree, launch the adapter, and attach ACP.
- `GET /sessions/:id`
  Return the full durable session model plus derived UI fields.
- `POST /sessions/:id/prompt`
  Send a user prompt into the current live attachment.
- `POST /sessions/:id/resume`
  Start a fresh live attachment through the selected adapter and bind it to the existing logical session.
- `POST /sessions/:id/cancel`
  Cancel the current live attachment.
- `POST /sessions/:id/archive`
  Archive the logical session without deleting its history.
- `DELETE /sessions/:id`
  Hard delete for sessions that are already inactive.
- `GET /sessions/:id/events`
  SSE stream for session updates.

The naming may change in implementation, but the product contract is fixed: session state is fetched with normal HTTP and updated incrementally over SSE.

## SSE Contract

SSE is the only live transport in v1.

Requirements:

- every meaningful event is persisted before it is emitted
- SSE event ids are monotonic per session
- reconnecting clients use `Last-Event-ID`
- event replay comes from SQLite, not in-memory buffers
- heartbeats keep long-lived mobile connections alive

Event categories include:

- session lifecycle events
- normalized ACP content updates
- launcher lifecycle events
- status changes such as running, attention-required, detached, resumed, completed
- daemon-originated diagnostics

Push notifications are complementary, not a second live session protocol. When the app is open, session updates arrive through SSE. Push exists only to notify the user when the app is backgrounded or closed.

## UI Contract

The frontend is a full SPA, not a server-rendered app with islands. This is required by the product goals:

- install to home screen
- service worker support
- background push notifications
- a dense interactive control-room experience

### PWA

The web app includes:

- web app manifest
- service worker
- installability for home-screen use
- push subscription flow
- notification handling for `attention_required` and `completed` events

Notification permission should be requested contextually, not on first load.

### Home

`Control Room` is the default home screen.

- one focused session is primary
- other sessions appear in a quick-switch tray
- the tray supports concurrent running, waiting, and completed sessions

### Inbox

A session inbox/list exists for broader scanning and re-entry. It supports:

- attention-required sessions
- detached sessions
- resume-available sessions
- completed sessions
- archived sessions

### Session View

The session view supports:

- event timeline
- prompt input
- cancel action
- resume action when available
- archive and cleanup actions
- lightweight session metadata display, including repo, worktree, branch, launcher, and status

The UI is mobile-first. Desktop support is acceptable but not the optimization target.

## Frontend Design System

The UI should stay visually close to Ark UI's site rather than the generic style of many starter kits.

Visual direction:

- light neutral surfaces
- soft borders
- restrained accents
- clean typography
- dense but calm information layout

Styling approach:

- CSS modules for component-local styles
- global CSS variables for tokens such as color, spacing, radius, shadow, and motion
- Ark UI parts styled through classes and `data-*` selectors
- no Tailwind dependency in v1
- no Panda CSS requirement in v1

The intent is to keep the interface fast and lightweight while still feeling deliberate and polished.

## Security and Trust Boundary

This is a single-user daemon, not a general remote execution platform.

Boundaries:

- the daemon is exposed over public HTTPS behind an external auth gate such as Cloudflare Access
- the daemon itself stays simple and does not attempt full multi-user auth design
- sessions may only be launched from repositories under one configured root project directory
- worktrees are created within allowed locations only
- launchers are configured adapters, not arbitrary commands entered from the browser

The user chose autonomous-by-default behavior. Therefore, policy and visibility matter more than interactive approval gates in v1.

## Persistence

SQLite stores:

- sessions
- event records
- launcher metadata
- resume metadata
- worktree bookkeeping
- daemon version and migration metadata

The persisted event log is the basis for:

- inbox summaries
- session replay
- reconnect after browser loss
- durable audit trail for what happened in a session

## Operational Model

The daemon runs as a long-lived personal service on one machine.

Recommended deployment assumptions:

- one process is sufficient for v1
- nginx or Cloudflare Tunnel can front the daemon if needed
- public HTTPS and authentication are handled outside the daemon
- the daemon itself listens on a local or private interface

## Future Extensions

Not part of v1, but intentionally left room for later:

- SSH-backed launchers for personal multi-machine support while preserving the same logical-session model
- richer diff and review flows
- plan and markdown artifact viewing
- light terminal exposure
- custom visualization tooling that renders user-facing HTML, CSS, and JavaScript artifacts in the UI

SSH-based multi-machine support should be implemented by adding a different launcher or transport runner, not by changing the session model.

## Rationale

The main design decision is to persist durable logical sessions instead of trying to persist raw ACP process state. This keeps restart behavior simple, matches the resume capabilities of the target agents, and avoids building fragile transport rehydration logic into the daemon.

The second main decision is to use SSE instead of WebSockets. The product's live-update needs are one-way from daemon to browser, and SSE aligns naturally with append-only event replay, mobile reconnect behavior, and a simple HTTP-first architecture.

The third main decision is to make the frontend a proper SPA/PWA. Home-screen install, service workers, and background push notifications are product requirements, so the UI architecture should support them directly instead of layering them awkwardly onto server-rendered pages.
