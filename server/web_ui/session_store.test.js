import test from "node:test";
import assert from "node:assert/strict";

import { createInitialState, reduceSessionState } from "./public/session_store.js";

test("prompt submission transitions clear the draft on success", () => {
  let state = createInitialState("session-1");
  state = reduceSessionState(state, { type: "prompt/change", text: "Review the diff" });
  state = reduceSessionState(state, { type: "prompt/submit-start" });
  state = reduceSessionState(state, { type: "prompt/submit-success" });

  assert.equal(state.promptPending, false);
  assert.equal(state.promptText, "");
});

test("stream errors move an open connection into reconnecting", () => {
  let state = createInitialState("session-1");
  state = reduceSessionState(state, { type: "stream/open" });
  state = reduceSessionState(state, {
    type: "stream/error",
    error: "Connection interrupted.",
  });

  assert.equal(state.connectionState, "reconnecting");
  assert.equal(state.streamError, "Connection interrupted.");
});

test("event ingestion records tool decisions and updates session status", () => {
  let state = createInitialState("session-1");
  state = reduceSessionState(state, {
    type: "session/load-success",
    session: { id: "session-1", status: "busy" },
  });
  state = reduceSessionState(state, {
    type: "events/add",
    events: [
      {
        id: "session-1:1",
        seq: 1,
        type: "acp.call",
        payload: { callId: "call-1", decision: "approved", note: "go ahead" },
      },
      {
        id: "session-1:2",
        seq: 2,
        type: "acp.status",
        payload: { state: "ready" },
      },
    ],
  });

  assert.equal(state.session.status, "ready");
  assert.deepEqual(state.resolvedCalls["call-1"], {
    decision: "approved",
    note: "go ahead",
    source: "event",
  });
});
