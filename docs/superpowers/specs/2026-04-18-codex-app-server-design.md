# Codex App Server Integration Design

## Summary

Replace the current ACP-shaped Codex launcher with a dedicated `codex app-server` integration. The new path keeps the existing All Hands session model and HTTP routes, but it stops pretending Codex is an ACP subprocess. Instead, `allhands_host` manages one shared machine-local Codex daemon, maps each All Hands session to a durable Codex `threadId`, and adds explicit Approve and Deny actions for Codex approval requests in the session UI.

The first cut uses the official headless Codex surface, keeps to the stable app-server API, resumes only threads that All Hands created itself, and preserves the exact Codex conversation across `allhands_host` restarts.

## Goals

- Use the official headless Codex integration surface: `codex app-server`.
- Keep one shared Codex daemon per machine, started lazily on first Codex session use.
- Persist a durable mapping from All Hands session id to Codex `threadId`.
- Resume the same Codex thread after browser disconnects and `allhands_host` restarts.
- Keep the existing All Hands session list, timeline, SSE, and session actions model.
- Add real Approve and Deny actions for Codex approval requests in the session UI.
- Keep Codex-specific protocol details behind a dedicated backend adapter rather than leaking them through the generic session API.

## Non-Goals

- Building or depending on an ACP adapter for Codex.
- Managing arbitrary external Codex threads discovered from `thread/list`.
- Implementing Codex login UX in All Hands. The target machine is pre-authenticated.
- Depending on experimental app-server APIs such as `experimentalApi`, `dynamicTools`, or extended history persistence.
- Supporting every server-initiated Codex request type in v1. The initial UI only handles binary approval flows that map cleanly to Approve and Deny.
- Migrating existing broken ACP-era Codex sessions into resumable app-server threads.

## Upstream Constraints

- `codex app-server` is the official Codex integration surface.
- The stable thread and turn APIs we need are `initialize`, `thread/start`, `thread/resume`, `thread/archive`, `thread/unsubscribe`, `turn/start`, and `turn/interrupt`.
- App-server websocket transport is documented but marked experimental and unsupported upstream. We still use loopback websocket in v1 because a reconnectable shared daemon is a better fit for All Hands than stdio per session.
- The integration stays on the stable API surface by sending `initialize` without `experimentalApi: true`.
- Approval requests that All Hands will support in v1 are:
  - `item/commandExecution/requestApproval`
  - `item/fileChange/requestApproval`
  - `item/permissions/requestApproval`

## Product Decisions

- `launcher="codex"` becomes a dedicated app-server-backed path, not an ACP launcher.
- All Hands owns one shared Codex daemon endpoint per host instance and reuses it across Codex sessions.
- The shared daemon is started on demand and then left running. `allhands_host` may adopt an already-running healthy daemon on the configured loopback port instead of spawning a second one.
- All Hands only resumes Codex threads whose `threadId` it previously created and stored locally.
- A completed Codex turn is treated as `resume_available`, not terminal `completed`, because the underlying thread remains open for future turns.
- Unsupported server-initiated Codex requests are surfaced clearly, but they are not part of the first approval UI.

## Architecture

### CodexDaemonManager

Add a machine-scoped daemon manager responsible for the shared `codex app-server` process.

Responsibilities:

- choose a single loopback websocket endpoint, for example `ws://127.0.0.1:21992`
- create and persist a high-entropy capability token file under All Hands state
- probe `GET /readyz` or `GET /healthz` before launching a new daemon
- start `codex app-server --listen ws://127.0.0.1:<port> --ws-auth capability-token --ws-token-file <token-file>` when the daemon is missing
- capture stderr for startup diagnostics and failure reporting
- expose a shared connection factory to the Codex client layer

The daemon manager does not own per-session state. It only ensures that a usable Codex app-server exists on the machine and that All Hands can authenticate to it.

### CodexAppServerClient

Add a JSON-RPC websocket client dedicated to the Codex app-server protocol.

Responsibilities:

- open websocket connections with the capability token
- send `initialize` followed by `initialized` on each new connection
- issue stable protocol requests such as `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, `thread/archive`, and `thread/unsubscribe`
- route notifications and server-initiated requests back into the session adapter
- translate connection failures, JSON-RPC errors, and health-check failures into explicit backend errors

This client should stay transport-focused. Session status rules, event normalization, and persistence belong in the session adapter.

### CodexSessionAdapter

Add a Codex-specific adapter that translates All Hands session behavior into Codex thread and turn behavior.

Responsibilities:

- create a Codex thread for a new All Hands session
- resume an existing Codex thread for a stored session
- start turns from prompts
- interrupt active turns for Cancel and Reset
- archive the remote thread for Archive
- persist and expose pending approval state
- normalize Codex notifications into durable All Hands events

`SessionService` remains the entry point used by the HTTP layer, but it routes `launcher="codex"` to this adapter instead of the ACP attachment path.

## Persistence Model

Do not overload `last_bound_agent_session_id` with Codex thread ids. That field is ACP-shaped and will stay ACP-shaped.

Add dedicated Codex metadata tables:

### `codex_sessions`

- `session_id` primary key, foreign key to `sessions.id`
- `thread_id` text not null unique
- `active_turn_id` text null
- `pending_request_id` text null
- `pending_request_kind` text null
- `pending_request_payload_json` text null
- `created_at` text not null
- `updated_at` text not null

This table is the durable proof that All Hands created the Codex thread and is allowed to manage it later.

### `daemon_state` does not need a dedicated table in v1

The daemon endpoint is deterministic from config, and the websocket token lives in a stable token file under the All Hands state directory. On restart, `allhands_host` simply probes the known endpoint and either reuses the running daemon or starts a new one.

## Session Lifecycle

### Create Session

1. Create the All Hands `sessions` row immediately with `status="created"`.
2. Ensure the repo worktree exists.
3. Ensure the shared Codex daemon is healthy.
4. Open a Codex app-server connection and initialize it.
5. Call `thread/start`.
6. Persist the returned `threadId` in `codex_sessions`.
7. Append `session.bound` with `threadId`.
8. Call `turn/start` with:
   - the stored `threadId`
   - the initial prompt
   - `cwd` set to the session worktree path
   - a workspace-write sandbox rooted at the worktree
   - approval review by the user
9. Persist `active_turn_id`.
10. Stream turn and item events into the existing durable timeline.

As with the current async bootstrap path, the HTTP create call should return before the turn finishes.

### Resume Session

1. Read the stored `threadId` from `codex_sessions`.
2. Ensure the worktree exists, recreating it if needed.
3. Ensure the shared Codex daemon is healthy.
4. Open a fresh Codex client connection and initialize it.
5. Call `thread/resume` for the stored `threadId`.
6. Append `session.bound` with `threadId`.
7. Mark the session `running` and ready for prompts.

Resume never creates a new Codex thread. If the stored `threadId` cannot be resumed, the session becomes `failed` with the app-server error surfaced into the timeline.

### Prompt a Running Session

Sending a prompt starts a new Codex turn on the existing thread:

- require a resumed live Codex connection
- call `turn/start` with the current `threadId`
- set `cwd` to the current worktree path
- persist the new `active_turn_id`
- append `session.prompted`

### Turn Completion

When Codex emits `turn/completed`:

- clear `active_turn_id`
- unsubscribe the connection from that thread
- drop the live in-memory session attachment
- append `session.completed` with payload that projects the session to `resume_available`
- project the All Hands session to `resume_available`

The thread remains durable on the Codex side, but All Hands returns to its normal detached-and-resumable model between turns.

### Cancel Run

Cancel maps to `turn/interrupt` using the persisted `active_turn_id`. After the interrupted turn reaches `turn/completed`, All Hands clears live state and projects the session to `resume_available`.

### Reset Workspace

Reset preserves the remote Codex thread and only resets local workspace state:

1. interrupt any active turn
2. remove the current worktree
3. mark workspace state as missing
4. keep the stored `threadId`

The next Resume recreates the worktree and the next `turn/start` sends the new `cwd`.

### Archive

Archive maps to the remote thread archive behavior:

1. interrupt any active turn if necessary
2. call `thread/archive` for the stored `threadId`
3. clear any live Codex connection for that session
4. mark the All Hands session `archived`

Archive does not delete the local timeline. It only closes the session operationally in both systems.

## Restart and Reconnect Semantics

### Browser Disconnect

- The backend connection to Codex remains live independently of the browser until the turn completes or is interrupted, including while the turn is blocked on approval.
- The browser simply reconnects to All Hands SSE and continues from stored events.

### `allhands_host` Restart

On host restart, any live in-memory Codex connection is gone. The durable session and thread mapping remain.

Startup reconciliation rules:

- Codex sessions with a stored `threadId` and a stale `running` or `attention_required` state are normalized to `resume_available`.
- stale `active_turn_id` and `pending_request_*` state is cleared because those ids are tied to the lost live connection
- The prior timeline stays visible immediately from SQLite.
- When the user chooses Resume, All Hands reconnects to the same `threadId` through the shared daemon.

This is a session-level continuation model, not a guarantee of mid-turn transport resurrection. Exact thread history is preserved. In-flight turn and pending approval recovery after a host restart is best-effort.

## Approval UX

### Supported Request Types

The first cut adds explicit Approve and Deny actions for these Codex requests:

- command execution approvals
- file change approvals
- permission requests

All three are binary enough to map cleanly into the requested UI.

### Session State

When one of the supported approval requests arrives:

- persist `pending_request_id`, `pending_request_kind`, and normalized request payload in `codex_sessions`
- append a timeline event describing the request
- project the session to `attention_required`
- keep the live Codex connection open so the response can be sent on the same connection

When the request is resolved:

- clear pending request state
- append a resolution event
- if the turn is still active, project the session back to `running`
- when the turn later completes, project the session to `resume_available`

### HTTP API

Extend the existing session detail API with:

- `pendingApproval`: optional object when a Codex approval is waiting

Suggested shape:

```json
{
  "pendingApproval": {
    "kind": "command" | "file_change" | "permissions",
    "summary": "Run npm test in the worktree",
    "reason": "Needs to run project tests",
    "command": ["npm", "test"],
    "cwd": "/path/to/worktree"
  }
}
```

Add endpoints:

- `POST /sessions/:id/approval/approve`
- `POST /sessions/:id/approval/deny`

Each endpoint resolves the current pending Codex request for that session and returns the refreshed session detail. If no matching live pending request exists, return `409 Conflict`.

### UI

On the session page, render a dedicated approval card when `pendingApproval` is present:

- concise summary of the requested action
- command preview or file-change summary when available
- explicit `Approve` and `Deny` buttons
- session action buttons remain visible, with `Cancel run` still available

The session list and control room already prioritize `attention_required`, so no new list behavior is needed beyond surfacing the detail card.

### Unsupported Request Types

If Codex sends a server-initiated request that is not one of the supported approval flows, All Hands should:

- append a clear timeline event naming the unsupported request method
- mark the session `attention_required`
- surface that the request cannot be answered from the current UI
- leave `Cancel run` available so the user can recover

This avoids pretending that all Codex server requests are binary approvals when some require structured user input.

## Event Model

Keep the existing generic session events for cross-launcher behavior:

- `session.created`
- `session.bound`
- `session.prompted`
- `session.attention_required`
- `session.completed`
- `session.failed`
- `session.archived`

Add Codex-specific timeline events for raw inspection and debugging, for example:

- `codex.thread.started`
- `codex.thread.resumed`
- `codex.turn.started`
- `codex.turn.completed`
- `codex.item.started`
- `codex.item.delta`
- `codex.item.completed`
- `codex.approval.requested`
- `codex.approval.resolved`
- `codex.request.unsupported`

Use the generic session events to drive summary state and notifications. Use the Codex-prefixed events to preserve protocol detail without polluting the shared session projection model.

## Error Handling

- If the shared daemon cannot be reached and cannot be started, fail the session with the captured stderr or readiness timeout reason.
- If websocket initialization fails, fail the session with a clear app-server connection error.
- If `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, or `thread/archive` returns a JSON-RPC error, append a durable `session.failed` event with the surfaced message.
- If the configured loopback port is occupied by a non-Codex process, fail fast and do not attempt to kill it automatically.
- If a live Codex connection drops during a turn, mark the session `resume_available` and require an explicit Resume rather than guessing transport state.

## Configuration

Add minimal Codex daemon settings to `Settings`:

- `codex_app_server_port` with a fixed default distinct from the main All Hands HTTP port
- optional `codex_binary` override if `codex` on `PATH` is not desired

Derive the websocket token file from the existing All Hands state root rather than adding a separate state location concept in v1.

## Migration

- Existing non-Codex launchers are unchanged.
- Existing ACP-era Codex sessions do not gain resumability automatically because they have no stored Codex `threadId`.
- Those legacy sessions remain readable from their local timeline and can be archived or discarded, but new Codex sessions use the app-server-backed path.

## Testing

### Backend

Add tests for:

- shared daemon lazy start
- reusing an already-running daemon on the configured loopback port
- failure when the port is occupied by a non-Codex process
- create session persists `threadId`
- resume uses stored `threadId` instead of creating a new thread
- cancel interrupts the stored `active_turn_id`
- reset preserves `threadId` while removing the worktree
- archive calls `thread/archive`
- approval request persistence and projection to `attention_required`
- Approve and Deny endpoints resolving the live pending request
- restart reconciliation from stale `running` or `attention_required` to `resume_available`

Use a fake app-server in tests rather than shelling out to the real Codex CLI.

### Frontend

Add tests for:

- session detail approval card rendering
- Approve and Deny button behavior
- session detail status transitions through `running`, `attention_required`, and `resume_available`
- unsupported-request fallback messaging

### Manual Verification

On the target Intel Mac, verify:

- `codex app-server` launches headlessly from the installed CLI
- the shared daemon is started only on first Codex session use
- a Codex session creates a durable thread and can be resumed later
- the same session remains resumable after restarting `allhands_host`
- command, file-change, and permission approvals show real Approve and Deny actions

## Risks

- Loopback websocket transport is still upstream experimental, so the transport layer should stay isolated behind `CodexAppServerClient` to make a future transport swap possible.
- Mid-turn recovery after an `allhands_host` restart is not guaranteed in v1 because server-initiated requests are tied to a live connection.
- Codex approval flows expose more than simple Approve and Deny in some cases. V1 intentionally keeps the UI narrow and may need expansion later.
