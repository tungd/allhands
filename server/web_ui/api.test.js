import test from "node:test";
import assert from "node:assert/strict";

import { buildPromptRequest, buildToolDecisionRequest } from "./public/api.js";

test("buildPromptRequest preserves prompt text", () => {
  assert.deepEqual(buildPromptRequest("ship it"), { text: "ship it" });
});

test("buildToolDecisionRequest trims note and omits empty note", () => {
  assert.deepEqual(
    buildToolDecisionRequest("call-1", "approved", "  looks good  "),
    { callId: "call-1", decision: "approved", note: "looks good" },
  );
  assert.deepEqual(
    buildToolDecisionRequest("call-1", "denied", "   "),
    { callId: "call-1", decision: "denied" },
  );
});
