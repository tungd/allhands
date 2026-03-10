# PRD: All Hands (Project "Untether")

## 1. Executive Summary

**All Hands** is a high-performance, open-source orchestration suite for running
AI coding agents (e.g., Claude Code, Aider, OpenDevin) as persistent server-side
processes. Unlike traditional remote-desktop or terminal-streaming solutions,
All Hands utilizes the **Agent Client Protocol (ACP)** to provide a semantic,
data-driven mobile experience. It allows developers to steer complex coding
tasks from a native iOS app with the responsiveness of a local IDE and the power
of remote infrastructure.

---

## 2. System Architecture

The system follows a distributed "Agent-Host-Client" topology:

1. **Agent (The Engine):** An ACP-compliant CLI tool (e.g., `claude-code
   --experimental-acp`) running on a VPS or MacBook.
2. **Server (The Orchestrator):** An OCaml 5 binary using `Domainslib` for
   parallel task management and `h1` for SSE-based streaming.
3. **Client (The Interface):** A native Swift iOS app using the **Tailscale
   Swift SDK** for userspace networking.

---

## 3. Tech Stack

| Component | Technology |
| --- | --- |
| **Server Language** | OCaml 5.x (Multicore) |
| **Server Concurrency** | `Domainslib` (Task-stealing scheduler) |
| **Server Web Stack** | `h1` (High-performance HTTP/1.1) |
| **Client Language** | Swift 6 (SwiftUI) |
| **Networking** | Tailscale Swift SDK (Embedded `tsnet`) |
| **Communication** | Server-Sent Events (SSE) with Custom Semantic Framing |

---

## 4. Functional Requirements

### **A. OCaml ACP Host (Server)**

* **JSON-RPC Management:** The server must spawn agents as child processes and
  communicate via JSON-RPC 2.0 over standard I/O pipes.
* **Multicore Scaling:** Use `Domainslib` to isolate agent process I/O from the
  HTTP server loop, ensuring high-frequency agent output doesn't block the UI.
* **Worktree Orchestration:** Automatically provision and cleanup `git worktree`
  environments for each session.
* **Session Persistence:** Cache the ACP message log in memory. When a client
  reconnects, the server re-broadcasts the session state to the mobile app.

### **B. Semantic Mobile Client (iOS)**

* **Tailscale Integration:** Embed Tailscale directly into the app. Use
  `tsnet.Dial` to connect to the OCaml server's private Tailnet IP.
* **Native ACP Rendering:**
  * **Thought Stream:** Render agent "reasoning" in a
    chat-like interface.
  * **Tool UI:** Display tool calls (e.g., `list_files`, `run_test`) as
    interactive status cards.
  * **Native Diff:** A specialized Swift component to review code changes with
    syntax highlighting and "Approve/Reject" toggles.
* **Background Steering:** Support for iOS Live Activities or Push Notifications
  (via Tailscale relay) when the agent requires human intervention.

### **C. Protocol: Custom SSE over ACP**

* **Event Types:**
  * `acp.init`: Session handshake and agent capabilities.
  * `acp.thought`: Incremental reasoning tokens.
  * `acp.call`: Tool execution requests (requiring user approval).
  * `acp.patch`: Unified diff format for code modifications.
  * `acp.error`: Diagnostic and crash reporting.

---

## 5. Non-Functional Requirements

* **Latency:** End-to-end event propagation (Agent -> OCaml -> Swift) must be
  `< 100ms` on standard 5G/Fiber.
* **Privacy:** No third-party servers. All data stays within the user's Tailnet.
* **Efficiency:** The OCaml server should utilize `< 100MB` of RAM per idle
  agent session.
* **Resilience:** The system must handle IP roaming seamlessly via Tailscale's
  persistent connection logic.

---

## 6. Implementation Roadmap

### **Phase 1: The OCaml Core**

* Implement `Domainslib` task pool for process spawning.
* Build `h1` SSE endpoint.
* Develop JSON-RPC parser for ACP input from agents.

### **Phase 2: The Swift Foundation**

* Integrate Tailscale Swift SDK.
* Build manual SSE parser for raw TCP streams.
* Implement basic "Thought" and "Output" UI.

### **Phase 3: Semantic Richness**

* Add native Diff-viewing component.
* Implement Worktree management scripts in OCaml.
* Add Apple Watch/Notification support for "Human-in-the-Loop" approvals.
