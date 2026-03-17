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

export function readCallInfo(payload = {}) {
  const update = payload.update ?? {};
  const toolCall = update.toolCall ?? payload.toolCall ?? {};
  return {
    callId: firstString([
      toolCall.callId,
      toolCall.id,
      payload.callId,
      update.callId,
    ]),
    name: firstString([
      toolCall.name,
      payload.name,
      payload.decision ? "Tool decision" : "Tool call",
    ]) ?? "Tool call",
    arguments: toolCall.arguments ?? toolCall.input ?? payload.arguments ?? null,
    decision: firstString([
      payload.decision,
      update.decision,
      toolCall.decision,
    ]),
    note: firstString([
      payload.note,
      update.note,
      toolCall.note,
    ]),
  };
}

export function normalizeEvent(event = {}) {
  const payload = event.payload ?? {};
  const update = payload.update ?? {};
  const type = event.type ?? "acp.status";

  if (type === "acp.thought") {
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
      title: callInfo.decision ? "Tool decision" : callInfo.name,
      body: callInfo.note ?? "",
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
