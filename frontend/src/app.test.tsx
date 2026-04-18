import { render, screen, within } from "@solidjs/testing-library";

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
