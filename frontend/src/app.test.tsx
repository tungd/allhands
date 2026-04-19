import { fireEvent, render, screen, within } from "@solidjs/testing-library";

import { App } from "./app";
import { getStoredCredentials, storeCredentials } from "./lib/auth";

const AUTHORIZATION = `Basic ${btoa("td:secret")}`;

function setCredentials() {
  storeCredentials({ username: "td", password: "secret" });
}

function buildJsonResponse(payload: unknown) {
  return {
    ok: true,
    status: 200,
    body: null,
    json: async () => payload
  };
}

beforeEach(() => {
  window.history.pushState({}, "", "/");
  localStorage.clear();
  Object.defineProperty(window, "scrollTo", {
    value: vi.fn(),
    writable: true
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

test("redirects to the login page when no credentials are stored", async () => {
  render(() => <App />);

  expect(await screen.findByRole("heading", { name: "Sign in to All Hands", level: 2 })).toBeTruthy();
});

test("renders the control room shell with stored credentials", async () => {
  setCredentials();
  window.history.pushState({}, "", "/control-room");
  const fetchMock = vi.fn().mockResolvedValue(buildJsonResponse({ sessions: [] }));
  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByRole("heading", { name: "Control Room", level: 1 })).toBeTruthy();
  const sessionsCall = fetchMock.mock.calls.find(([url]) => url === "/sessions");
  expect(sessionsCall).toBeTruthy();
  expect(new Headers(sessionsCall?.[1]?.headers).get("Authorization")).toBe(AUTHORIZATION);
});

test("loads sessions into the control room from the API", async () => {
  setCredentials();
  window.history.pushState({}, "", "/control-room");
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url === "/sessions") {
      return buildJsonResponse({
        sessions: [{ id: "session-1", title: "API Refactor", status: "running" }]
      });
    }
    if (url === "/seen/app" || url === "/sessions/session-1/events") {
      return buildJsonResponse({});
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  const focused = await screen.findByLabelText("Focused session");
  expect(within(focused).getByText("API Refactor")).toBeTruthy();
});

test("stores credentials after login and navigates to the control room", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url === "/server-info") {
      return buildJsonResponse({
        vapidPublicKey: "",
        availableLaunchers: ["codex"],
        projectRoot: "/tmp/projects",
        transport: "sse"
      });
    }
    if (url === "/sessions") {
      return buildJsonResponse({ sessions: [] });
    }
    if (url === "/seen/app") {
      return buildJsonResponse({});
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  fireEvent.input(await screen.findByLabelText("Username"), {
    target: { value: "td" }
  });
  fireEvent.input(screen.getByLabelText("Password"), {
    target: { value: "secret" }
  });
  fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

  expect(await screen.findByRole("heading", { name: "Control Room", level: 1 })).toBeTruthy();
  expect(getStoredCredentials()).toEqual({ username: "td", password: "secret" });
  const loginCall = fetchMock.mock.calls.find(([url]) => url === "/server-info");
  expect(new Headers(loginCall?.[1]?.headers).get("Authorization")).toBe(AUTHORIZATION);
});

test("redirects back to login when the API returns 401", async () => {
  setCredentials();
  window.history.pushState({}, "", "/control-room");
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: false,
      status: 401,
      body: null,
      json: async () => ({ error: "authentication required" })
    })
  );

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByRole("heading", { name: "Sign in to All Hands", level: 2 })).toBeTruthy();
  expect(getStoredCredentials()).toBeNull();
});

test("deep-links a notification tap into the session route", async () => {
  setCredentials();
  window.history.pushState({}, "", "/session/session-1");

  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url === "/sessions/session-1") {
      return buildJsonResponse({
        id: "session-1",
        title: "API Refactor",
        runState: "running",
        workspaceState: "ready"
      });
    }
    if (url === "/sessions/session-1/timeline") {
      return buildJsonResponse({ events: [] });
    }
    if (url === "/sessions/session-1/events" || url === "/sessions/session-1/seen") {
      return buildJsonResponse({});
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByText("API Refactor")).toBeTruthy();
});

test("deep-links into the control room new-session sheet", async () => {
  setCredentials();
  window.history.pushState({}, "", "/control-room/new");

  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url === "/sessions" && init?.method == null) {
      return buildJsonResponse({ sessions: [] });
    }
    if (url === "/seen/app") {
      return buildJsonResponse({});
    }
    if (url === "/server-info") {
      return buildJsonResponse({
        vapidPublicKey: "",
        availableLaunchers: ["codex", "pi"],
        projectRoot: "/tmp/projects",
        transport: "sse"
      });
    }
    if (url === "/repos?query=") {
      return buildJsonResponse({ repos: [{ name: "api", path: "/tmp/projects/api" }] });
    }

    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByRole("dialog", { name: "New session" })).toBeTruthy();
  expect(await screen.findByRole("button", { name: /^api/ })).toBeTruthy();
});

test("creates a session from the sheet and navigates to the session route", async () => {
  setCredentials();
  window.history.pushState({}, "", "/control-room/new");

  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url === "/sessions" && init?.method == null) {
      return buildJsonResponse({ sessions: [] });
    }
    if (url === "/seen/app") {
      return buildJsonResponse({});
    }
    if (url === "/server-info") {
      return buildJsonResponse({
        vapidPublicKey: "",
        availableLaunchers: ["codex"],
        projectRoot: "/tmp/projects",
        transport: "sse"
      });
    }
    if (url === "/repos?query=") {
      return buildJsonResponse({ repos: [{ name: "api", path: "/tmp/projects/api" }] });
    }
    if (url === "/sessions" && init?.method === "POST") {
      return buildJsonResponse({
        id: "session-2",
        repoPath: "/tmp/projects/api",
        runState: "running",
        workspaceState: "ready"
      });
    }
    if (url === "/sessions/session-2") {
      return buildJsonResponse({
        id: "session-2",
        title: "API Refactor",
        repoPath: "/tmp/projects/api",
        runState: "running",
        workspaceState: "ready"
      });
    }
    if (url === "/sessions/session-2/timeline") {
      return buildJsonResponse({ events: [] });
    }
    if (url === "/sessions/session-2/events" || url === "/sessions/session-2/seen") {
      return buildJsonResponse({});
    }

    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);

  render(() => <App vapidPublicKey="BElidedValue" />);

  fireEvent.click(await screen.findByRole("button", { name: /^api/ }));
  fireEvent.input(screen.getByLabelText("Prompt"), {
    target: { value: "Ship the auth fix" }
  });
  fireEvent.click(screen.getByRole("button", { name: "Create session" }));

  expect(await screen.findByText("API Refactor")).toBeTruthy();
});
