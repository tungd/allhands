# All Hands

All Hands is a monorepo for a mobile-first ACP host and iOS client. The server
owns session orchestration, git worktree management, and SSE event streaming for
remote ACP agents. The iOS app connects over the user's tailnet and renders the
live agent session.

## Layout

- `server/`: OCaml ACP host and HTTP/SSE server
- `ios/`: SwiftUI app and local Swift package
- `docs/`: PRD and architecture notes
- `scripts/`: bootstrap helpers

## Prerequisites

- macOS with Xcode 26+
- OCaml 5.4 with `opam`
- `xcodegen`
- Python 3 for the fake ACP test agent

## Quick Start

```bash
make setup
make tailscalekit
make build
make test
make run-server
make open-ios
```

The iOS app compiles without `TailscaleKit`, but Tailscale sign-in and
tailnet networking stay in stub mode until the XCFramework is built from
[`libtailscale/swift`](https://github.com/tailscale/libtailscale/tree/main/swift).
See [`docs/architecture.md`](/Users/tung/Projects/std23/allhands/docs/architecture.md)
for the integration boundary.

## Server

The server exposes:

- `GET /healthz`
- `POST /sessions`
- `GET /sessions/:id`
- `POST /sessions/:id/prompts`
- `POST /sessions/:id/tool-decisions`
- `POST /sessions/:id/cancel`
- `GET /sessions/:id/events`
- `DELETE /sessions/:id`

`POST /sessions` accepts:

```json
{
  "repoPath": "/absolute/path/to/repo",
  "agentCommand": "/usr/bin/env",
  "agentArgs": ["python3", "/abs/path/to/agent.py"]
}
```

The server spawns the agent, initializes ACP over stdio, creates a dedicated git
worktree, and emits semantic SSE events for the mobile client.

## iOS

The app project is generated from `ios/project.yml`:

```bash
cd ios
xcodegen generate
open AllHands.xcodeproj
```

To build and install the upstream Tailscale binary dependency into
`ios/Vendor/TailscaleKit/TailscaleKit.xcframework`, run:

```bash
make tailscalekit
```

The non-UI code lives in `ios/AllHandsKit`, which also has the package tests.
The app now defaults to Tailscale onboarding, then discovers servers via
Bonjour on the local network.
