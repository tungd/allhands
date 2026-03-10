# Architecture

All Hands splits into two runtime surfaces:

## Server

The OCaml host accepts mobile HTTP requests, spawns ACP child processes over
stdio, and emits semantic SSE events.

Request flow:

1. `POST /sessions` creates a git worktree and launches an ACP child process.
2. The host sends `initialize` and `session/new` to the child.
3. `POST /sessions/:id/prompts` forwards `session/prompt`.
4. Child JSON-RPC notifications are translated into `acp.*` SSE events.
5. `GET /sessions/:id/events` replays missed events using `Last-Event-ID`.

## iOS

The app uses a Tailscale-backed `URLSession` when `TailscaleKit.framework` is
available. The current scaffold keeps a direct-base-URL debug mode so the rest
of the app can build and run without the framework being embedded yet.

Client flow:

1. Start or attach to a Tailscale node.
2. Build a `URLSession` for REST and SSE traffic.
3. Create a session, post prompts, and subscribe to the stream.
4. Render thoughts, tool calls, diffs, and errors as typed timeline entries.

## Event Model

The mobile-facing SSE contract is:

```json
{
  "id": "session_123:7",
  "sessionId": "session_123",
  "seq": 7,
  "type": "acp.thought",
  "timestamp": 1741550400.0,
  "payload": {}
}
```

The payload stays permissive so the host can preserve raw ACP notifications
while the semantic mapping evolves.
