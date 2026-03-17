import test from "node:test";
import assert from "node:assert/strict";

import { buildPromptRequest, buildToolDecisionRequest } from "./public/api.js";

test("buildPromptRequest preserves prompt text", () => {
  assert.deepEqual(buildPromptRequest("ship it"), { text: "ship it" });
});

test("buildToolDecisionRequest trims note and omits empty note", () => {
  assert.deepEqual(
    buildToolDecisionRequest({ callId: "call-1", requestId: 7 }, "approved"),
    { callId: "call-1", requestId: 7, optionId: "approved" },
  );
});
