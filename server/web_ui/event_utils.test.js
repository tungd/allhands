import test from "node:test";
import assert from "node:assert/strict";

import {
  buildTimelineItems,
  mergeEvents,
  normalizeEvent,
  readCallInfo,
} from "./public/event_utils.js";

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
  assert.equal(info.approvalRequired, false);
});

test("readCallInfo marks approval-required tool calls", () => {
  const info = readCallInfo({
    update: {
      sessionUpdate: "tool_approval_required",
      toolCall: {
        callId: "call-9",
        name: "run_test",
      },
    },
  });

  assert.equal(info.callId, "call-9");
  assert.equal(info.approvalRequired, true);
  assert.equal(info.sessionUpdate, "tool_approval_required");
});

test("readCallInfo understands request-permission payloads", () => {
  const info = readCallInfo({
    requestId: 77,
    toolCall: {
      callId: "call-9",
      name: "run_test",
    },
    options: [
      { optionId: "approved", name: "Approve", kind: "allow_once" },
      { optionId: "abort", name: "Abort", kind: "reject_once" },
    ],
  });

  assert.equal(info.callId, "call-9");
  assert.equal(info.requestId, 77);
  assert.equal(info.approvalRequired, true);
  assert.deepEqual(info.options, [
    { optionId: "approved", name: "Approve", kind: "allow_once" },
    { optionId: "abort", name: "Abort", kind: "reject_once" },
  ]);
});

test("normalizeEvent labels approval-required calls distinctly", () => {
  const event = {
    type: "acp.call",
    payload: {
      update: {
        sessionUpdate: "tool_approval_required",
        toolCall: {
          callId: "call-2",
          name: "run_test",
        },
      },
    },
  };

  assert.deepEqual(normalizeEvent(event), {
    kind: "call",
    title: "Approval required: run_test",
    body: "The agent is waiting for your decision before continuing.",
    callInfo: {
      callId: "call-2",
      requestId: null,
      name: "run_test",
      arguments: null,
      decision: null,
      note: null,
      sessionUpdate: "tool_approval_required",
      approvalRequired: true,
      options: null,
    },
  });
});

test("normalizeEvent labels request-permission calls distinctly", () => {
  const event = {
    type: "acp.call",
    payload: {
      requestId: 77,
      toolCall: {
        callId: "call-2",
        name: "run_test",
      },
      options: [
        { optionId: "approved", name: "Approve", kind: "allow_once" },
        { optionId: "abort", name: "Abort", kind: "reject_once" },
      ],
    },
  };

  assert.deepEqual(normalizeEvent(event), {
    kind: "call",
    title: "Approval required: run_test",
    body: "The agent is waiting for your decision before continuing.",
    callInfo: {
      callId: "call-2",
      requestId: 77,
      name: "run_test",
      arguments: null,
      decision: null,
      note: null,
      sessionUpdate: null,
      approvalRequired: true,
      options: [
        { optionId: "approved", name: "Approve", kind: "allow_once" },
        { optionId: "abort", name: "Abort", kind: "reject_once" },
      ],
    },
  });
});

test("normalizeEvent converts approval-shaped thought content into a call card", () => {
  const event = {
    type: "acp.thought",
    payload: {
      update: {
        content: {
          callId: "call-44",
          toolName: "run_test",
          message: "Run the test suite?",
          options: [
            { optionId: "approved", name: "Yes", kind: "allow_once" },
            { optionId: "abort", name: "No, provide feedback", kind: "reject_once" },
          ],
        },
      },
    },
  };

  assert.deepEqual(normalizeEvent(event), {
    kind: "call",
    title: "Approval required: run_test",
    body: "Run the test suite?",
    callInfo: {
      callId: "call-44",
      name: "run_test",
      arguments: null,
      decision: null,
      note: null,
      sessionUpdate: "tool_approval_required",
      approvalRequired: true,
      options: [
        { optionId: "approved", name: "Yes", kind: "allow_once" },
        { optionId: "abort", name: "No, provide feedback", kind: "reject_once" },
      ],
      requestId: null,
      source: "content",
      body: "Run the test suite?",
    },
  });
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

test("buildTimelineItems merges consecutive thought chunks into one item", () => {
  const items = buildTimelineItems([
    {
      id: "session:1",
      seq: 1,
      type: "acp.thought",
      timestamp: 10,
      payload: { update: { content: { type: "text", text: "Doing" } } },
    },
    {
      id: "session:2",
      seq: 2,
      type: "acp.thought",
      timestamp: 11,
      payload: { update: { content: { type: "text", text: " fine" } } },
    },
  ]);

  assert.equal(items.length, 1);
  assert.equal(items[0].kind, "thought");
  assert.equal(items[0].body, "Doing fine");
  assert.equal(items[0].timestamp, 11);
});

test("buildTimelineItems breaks thought groups on non-thought events", () => {
  const items = buildTimelineItems([
    {
      id: "session:1",
      seq: 1,
      type: "acp.thought",
      timestamp: 10,
      payload: { update: { content: { type: "text", text: "First" } } },
    },
    {
      id: "session:2",
      seq: 2,
      type: "acp.status",
      timestamp: 11,
      payload: { state: "busy" },
    },
    {
      id: "session:3",
      seq: 3,
      type: "acp.thought",
      timestamp: 12,
      payload: { update: { content: { type: "text", text: "Second" } } },
    },
  ]);

  assert.deepEqual(
    items.map((item) => item.kind),
    ["thought", "status", "thought"],
  );
  assert.equal(items[0].body, "First");
  assert.equal(items[2].body, "Second");
});

test("buildTimelineItems leaves non-thought events standalone", () => {
  const items = buildTimelineItems([
    {
      id: "session:1",
      seq: 1,
      type: "acp.call",
      timestamp: 10,
      payload: {
        update: {
          toolCall: {
            callId: "call-1",
            name: "run_test",
          },
        },
      },
    },
    {
      id: "session:2",
      seq: 2,
      type: "acp.patch",
      timestamp: 11,
      payload: {
        update: { patch: "diff --git a/file b/file" },
      },
    },
  ]);

  assert.equal(items.length, 2);
  assert.deepEqual(
    items.map((item) => item.kind),
    ["call", "patch"],
  );
  assert.equal(items[0].callInfo.callId, "call-1");
});
