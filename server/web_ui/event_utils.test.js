import test from "node:test";
import assert from "node:assert/strict";

import { mergeEvents, normalizeEvent, readCallInfo } from "./public/event_utils.js";

test("normalizeEvent maps thought payloads into readable cards", () => {
  const event = {
    type: "acp.thought",
    payload: {
      update: {
        content: {
          type: "text",
          text: "Checking the worktree",
        },
      },
    },
  };

  assert.deepEqual(normalizeEvent(event), {
    kind: "thought",
    title: "Agent",
    body: "Checking the worktree",
  });
});

test("readCallInfo extracts tool call metadata from ACP updates", () => {
  const info = readCallInfo({
    update: {
      toolCall: {
        callId: "call-7",
        name: "run_test",
        arguments: { target: "server" },
      },
    },
  });

  assert.equal(info.callId, "call-7");
  assert.equal(info.name, "run_test");
  assert.deepEqual(info.arguments, { target: "server" });
  assert.equal(info.decision, null);
});

test("mergeEvents deduplicates by id and preserves order by sequence", () => {
  const merged = mergeEvents(
    [{ id: "session:2", seq: 2 }],
    [{ id: "session:1", seq: 1 }, { id: "session:2", seq: 2 }],
  );

  assert.deepEqual(
    merged.map((event) => event.id),
    ["session:1", "session:2"],
  );
});
