import { render, screen } from "@solidjs/testing-library";

import { SessionRoute } from "./session";


class FakeEventSource {
  addEventListener() {
    return undefined;
  }

  close() {
    return undefined;
  }
}


test("renders timeline first, action strip, and disabled prompt hint", () => {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({})
    })
  );
  vi.stubGlobal("EventSource", FakeEventSource);

  render(() => (
    <SessionRoute
      sessionId="session-1"
      initialDetail={{
        id: "session-1",
        title: "API Refactor",
        runState: "resume_available",
        workspaceState: "missing"
      }}
      initialTimeline={[
        { seq: 1, type: "workspace.reset", payload: {}, createdAt: "2026-04-18T00:00:00+00:00" }
      ]}
    />
  ));

  expect(screen.getByRole("heading", { name: "API Refactor" })).toBeTruthy();
  expect(screen.getByText("Workspace reset")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Resume" })).toBeTruthy();
  expect(screen.getByText("Resume session to send a prompt")).toBeTruthy();
});
