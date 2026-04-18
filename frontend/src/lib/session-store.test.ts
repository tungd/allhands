import { applyEvent } from "./session-store";


test("promotes attention-required sessions to the top of the tray", () => {
  const state = {
    sessions: [
      { id: "a", title: "API", status: "running" },
      { id: "b", title: "Docs", status: "running" }
    ]
  };

  const next = applyEvent(state, {
    sessionId: "b",
    type: "session.attention_required",
    payload: {}
  });

  expect(next.sessions[0].id).toBe("b");
  expect(next.sessions[0].status).toBe("attention_required");
});


test("uses payload runState when codex completes into a resumable state", () => {
  const state = {
    sessions: [
      { id: "a", title: "API", status: "running", runState: "running" },
      { id: "b", title: "Docs", status: "running", runState: "running" }
    ]
  };

  const next = applyEvent(state, {
    sessionId: "a",
    type: "session.completed",
    payload: { runState: "resume_available" }
  });

  expect(next.sessions[0].id).toBe("a");
  expect(next.sessions[0].status).toBe("resume_available");
  expect(next.sessions[0].runState).toBe("resume_available");
});
