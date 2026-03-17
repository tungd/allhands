function firstString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.length > 0) {
      return value;
    }
  }
  return null;
}

function stringifyValue(value) {
  if (value == null) {
    return null;
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch (_error) {
    return String(value);
  }
}

function normalizeRequestId(value) {
  if (typeof value === "string" || typeof value === "number") {
    return value;
  }
  return null;
}

function firstNonEmptyString(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  return null;
}

function readApprovalPromptContent(content = {}) {
  if (!content || typeof content !== "object" || Array.isArray(content)) {
    return null;
  }

  const options = Array.isArray(content.options) ? content.options : null;
  if (!options || options.length === 0) {
    return null;
  }

  const optionIds = new Set(
    options
      .map((option) => option?.optionId)
      .filter((value) => typeof value === "string"),
  );
  const looksLikeApproval =
    optionIds.has("approved")
    && (optionIds.has("abort") || optionIds.has("denied"));
  if (!looksLikeApproval) {
    return null;
  }

  const callId = firstNonEmptyString([
    content.callId,
    content.toolCallId,
    content.id,
    content.requestId,
  ]);

  const name = firstNonEmptyString([
    content.toolName,
    content.name,
    content.title,
  ]) ?? "Tool request";

  const body = firstNonEmptyString([
    content.message,
    content.text,
    content.prompt,
    content.description,
    content.subtitle,
  ]) ?? "The agent is waiting for your decision before continuing.";

  return {
    callId,
    requestId: null,
    name,
    arguments: content.arguments ?? content.input ?? null,
    decision: null,
    note: null,
    sessionUpdate: "tool_approval_required",
    approvalRequired: true,
    options,
    source: "content",
    body,
  };
}

export function readCallInfo(payload = {}) {
  const update = payload.update ?? {};
  const toolCall = update.toolCall ?? payload.toolCall ?? {};
  const sessionUpdate = firstString([
    update.sessionUpdate,
    payload.sessionUpdate,
  ]);
  const requestId = normalizeRequestId(payload.requestId);
  const directOptions = Array.isArray(payload.options) ? payload.options : null;
  return {
    callId: firstString([
      toolCall.callId,
      toolCall.id,
      payload.callId,
      update.callId,
    ]) ?? (requestId == null ? null : String(requestId)),
    requestId,
    name: firstString([
      toolCall.name,
      payload.name,
      payload.decision ? "Tool decision" : "Tool call",
    ]) ?? "Tool call",
    arguments: toolCall.arguments ?? toolCall.input ?? payload.arguments ?? null,
    decision: firstString([
      payload.optionId,
      payload.decision,
      payload.outcome === "cancelled" ? "cancelled" : null,
      update.decision,
      toolCall.decision,
    ]),
    note: firstString([
      payload.note,
      update.note,
      toolCall.note,
    ]),
    sessionUpdate,
    approvalRequired:
      sessionUpdate === "tool_approval_required"
      || payload.requiresApproval === true
      || toolCall.requiresApproval === true
      || (requestId != null && Array.isArray(directOptions) && directOptions.length > 0),
    options: directOptions ?? null,
  };
}

export function normalizeEvent(event = {}) {
  const payload = event.payload ?? {};
  const update = payload.update ?? {};
  const type = event.type ?? "acp.status";

  if (type === "acp.thought") {
    const content = update.content ?? payload.content ?? null;
    const approvalPrompt = readApprovalPromptContent(content);
    if (approvalPrompt) {
      return {
        kind: "call",
        title: `Approval required: ${approvalPrompt.name}`,
        body: approvalPrompt.body,
        callInfo: approvalPrompt,
      };
    }

    return {
      kind: "thought",
      title: "Agent",
      body: firstString([
        update.content?.text,
        payload.content?.text,
        stringifyValue(update.content),
      ]) ?? "",
    };
  }

  if (type === "acp.call") {
    const callInfo = readCallInfo(payload);
    return {
      kind: "call",
      title: callInfo.decision
        ? "Tool decision"
        : callInfo.approvalRequired
          ? `Approval required: ${callInfo.name}`
          : callInfo.name,
      body: callInfo.note
        ?? (callInfo.approvalRequired ? "The agent is waiting for your decision before continuing." : ""),
      callInfo,
    };
  }

  if (type === "acp.patch") {
    return {
      kind: "patch",
      title: "Patch",
      body: firstString([
        update.patch,
        payload.patch,
        stringifyValue(payload),
      ]) ?? "",
    };
  }

  if (type === "acp.error") {
    return {
      kind: "error",
      title: "Error",
      body: firstString([
        payload.message,
        payload.error?.message,
        stringifyValue(payload.error),
      ]) ?? "Unknown error",
    };
  }

  const stream = firstString([payload.stream]);
  const state = firstString([payload.state, payload.status]);
  const line = firstString([payload.line, payload.message, payload.stopReason]);
  return {
    kind: "status",
    title: state ? `Status: ${state}` : "Status",
    body: firstString([
      stream && line ? `${stream}: ${line}` : null,
      line,
      stringifyValue(payload),
    ]) ?? "",
  };
}

export function buildTimelineItems(events = []) {
  const items = [];
  let activeThought = null;

  for (const event of events) {
    const model = normalizeEvent(event);

    if (model.kind === "thought") {
      if (!activeThought) {
        activeThought = {
          id: event.id ?? `thought-${items.length}`,
          kind: "thought",
          title: model.title,
          body: model.body,
          timestamp: event.timestamp,
          events: [event],
        };
        items.push(activeThought);
        continue;
      }

      activeThought.body += model.body;
      activeThought.timestamp = event.timestamp;
      activeThought.events.push(event);
      continue;
    }

    activeThought = null;
    items.push({
      id: event.id ?? `${model.kind}-${items.length}`,
      kind: model.kind,
      title: model.title,
      body: model.body,
      timestamp: event.timestamp,
      event,
      callInfo: model.callInfo ?? null,
    });
  }

  return items;
}

export function mergeEvents(existing, incoming) {
  const byId = new Map();
  for (const event of existing) {
    if (event?.id) {
      byId.set(event.id, event);
    }
  }
  for (const event of incoming) {
    if (event?.id) {
      byId.set(event.id, event);
    }
  }
  return Array.from(byId.values()).sort((left, right) => {
    const leftSeq = typeof left.seq === "number" ? left.seq : 0;
    const rightSeq = typeof right.seq === "number" ? right.seq : 0;
    if (leftSeq !== rightSeq) {
      return leftSeq - rightSeq;
    }
    return String(left.id).localeCompare(String(right.id));
  });
}

export function formatTimestamp(timestamp) {
  if (typeof timestamp !== "number") {
    return "";
  }
  return new Date(timestamp * 1000).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}
