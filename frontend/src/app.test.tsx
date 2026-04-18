import { fireEvent, render, screen, within } from "@solidjs/testing-library";

import { App } from "./app";


class FakeEventSource {
  addEventListener() {
    return undefined;
  }

  close() {
    return undefined;
  }
}

function stubApi(sessions: Array<{ id: string; title: string; status: string }>) {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ sessions })
    })
  );
  vi.stubGlobal("EventSource", FakeEventSource);
}

beforeEach(() => {
  window.history.pushState({}, "", "/");
  Object.defineProperty(window, "scrollTo", {
    value: vi.fn(),
    writable: true
  });
});


test("renders the control room shell", () => {
  stubApi([]);
  render(() => <App vapidPublicKey="" />);
  expect(screen.getByRole("heading", { name: "Control Room", level: 1 })).toBeTruthy();
});


test("loads sessions into the control room from the API", async () => {
  stubApi([
    {
      id: "session-1",
      title: "API Refactor",
      status: "running"
    }
  ]);

  render(() => <App vapidPublicKey="" />);

  const focused = await screen.findByLabelText("Focused session");

  expect(within(focused).getByText("API Refactor")).toBeTruthy();
});


test("deep-links a notification tap into the session route", async () => {
  window.history.pushState({}, "", "/session/session-1");
  vi.stubGlobal(
    "fetch",
    vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          id: "session-1",
          title: "API Refactor",
          runState: "running",
          workspaceState: "ready"
        })
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ events: [] })
      })
  );
  vi.stubGlobal("EventSource", FakeEventSource);

  render(() => <App vapidPublicKey="BElidedValue" />);

  expect(await screen.findByText("API Refactor")).toBeTruthy();
});


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
