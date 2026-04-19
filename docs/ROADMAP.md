# All Hands Roadmap

Last updated: 2026-04-19

## V1: Mobile ACP Session Host

**Target:** Single-user daemon + browser/PWA control surface for ACP coding agents

**Status:** ~95% complete — core architecture implemented, navigation bug fixed

---

### ✅ Completed

#### Backend
- [x] Tornado HTTP server with static asset serving
- [x] SQLite persistence for sessions and events
- [x] Session Store with durable logical sessions
- [x] Event Store with append-only log per session
- [x] ACP Attachment Layer (stdio transport, JSON-RPC framing)
- [x] Workspace Manager (worktree-per-session, cleanup)
- [x] Repo Discovery API (`GET /repos`)
- [x] Full HTTP API surface:
  - [x] `GET /server-info`
  - [x] `GET /repos`
  - [x] `GET/POST /sessions`
  - [x] `GET /sessions/:id`
  - [x] `GET /sessions/:id/timeline`
  - [x] `POST /sessions/:id/prompt`
  - [x] `POST /sessions/:id/resume`
  - [x] `POST /sessions/:id/cancel`
  - [x] `POST /sessions/:id/reset`
  - [x] `POST /sessions/:id/archive`
  - [x] `POST /sessions/:id/approval/approve`
  - [x] `POST /sessions/:id/approval/deny`
  - [x] `GET /sessions/:id/events` (SSE)
- [x] SSE live updates with Last-Event-ID reconnect
- [x] Push notification service (Web Push)
- [x] Launcher adapters: Claude, Codex, Pi
- [x] Basic authentication

#### Frontend
- [x] Solid SPA with @solidjs/router
- [x] Login screen with credential storage
- [x] Control Room (focused session + tray)
- [x] New Session bottom sheet (repo search, launcher, prompt)
- [x] Session view with timeline
- [x] Timeline component (event rendering + raw mode)
- [x] Prompt input box
- [x] Session actions (Resume, Cancel, Reset, Archive)
- [x] Approval card for attention_required
- [x] Inbox list view
- [x] CSS modules styling

---

### 🔧 In Progress / Needs Verification

- [ ] **Mobile navigation** — Fixed in code, needs deployment verification
- [ ] **PWA installability** — Manifest exists, verify install banner shows
- [ ] **Service Worker** — `sw.js` exists, verify offline/caching behavior
- [ ] **Push notifications on mobile** — Verify foreground/background logic works

---

### 🎨 Polish (V1 Completion)

These are UX polish items to make V1 feel complete:

- [ ] Timeline mobile scrolling optimization
- [ ] Timeline "jump to latest" button when many events
- [ ] Session card visual polish (status badges, last activity time)
- [ ] Tray button visual polish (active state indicator)
- [ ] Prompt box auto-focus on resume
- [ ] Error states with retry affordance
- [ ] Loading skeletons instead of blank states
- [ ] Confirmation dialogs for destructive actions (reset, archive)
- [ ] Session title editing
- [ ] Better session summary extraction from timeline
- [ ] Inbox filtering by status
- [ ] Inbox sorting by last activity

---

### 🧪 Testing Gaps

- [ ] Backend tests for approval flow
- [ ] Backend tests for notification timing logic
- [ ] Frontend tests for new session sheet error handling
- [ ] Frontend tests for timeline raw mode toggle
- [ ] E2E Playwright tests for mobile navigation
- [ ] E2E tests for push notification flow

---

## V2: Enhanced Mobile Experience

**Target:** Better usability, more agent visibility

### Features

- [ ] **Rich timeline rendering** — Tool outputs, diff previews
- [ ] **Plan/Markdown viewing** — Render agent-created plans and docs
- [ ] **Session branches** — Show git branch status, create PR button
- [ ] **Session title auto-generation** — From first prompt or summary
- [ ] **Session grouping** — By repo or project
- [ ] **Quick actions from Control Room** — Resume directly from tray
- [ ] **Session notes** — User can add notes to session
- [ ] **Export session log** — Download timeline as markdown/JSON

---

## V3: Multi-Machine Support

**Target:** SSH-backed launchers for personal multi-machine

### From Design Doc Future Extensions:

- [ ] SSH-backed launcher adapters
- [ ] Remote machine session management
- [ ] Session migration between machines
- [ ] Machine status dashboard

---

## V4: Advanced Review

**Target:** Rich diff and code review in mobile

### From Design Doc Future Extensions:

- [ ] Inline diff viewer
- [ ] PR creation flow
- [ ] Code review comments
- [ ] Light terminal exposure
- [ ] Custom visualization rendering (HTML/CSS/JS artifacts)

---

## Technical Debt

Items that should be addressed for maintainability:

- [ ] Type-safe frontend API client (currently fetch calls scattered)
- [ ] Backend error handling standardization
- [ ] Logging structured format (JSON logs)
- [ ] Configuration validation on startup
- [ ] Database migration versioning
- [ ] Graceful shutdown handling
- [ ] Health check endpoint includes database status

---

## Metrics to Track

Once V1 is deployed:

- [ ] Session creation rate
- [ ] Session completion rate
- [ ] Average session duration
- [ ] Push notification delivery success rate
- [ ] SSE reconnect frequency
- [ ] Mobile vs desktop usage split

---

## Deployment Checklist

Before announcing V1 ready:

- [ ] Server running behind Cloudflare Tunnel or nginx
- [ ] HTTPS with valid certificate
- [ ] VAPID keys generated and configured
- [ ] Default user credentials set
- [ ] Project root directory configured
- [ ] Database migrations run
- [ ] Frontend build deployed
- [ ] Push notification tested on real mobile device
- [ ] PWA install tested on iOS and Android
- [ ] All routes return SPA shell (no 404s for frontend routes)