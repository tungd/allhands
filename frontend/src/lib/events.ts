export type SessionStreamEvent = {
  type: string;
  data: string;
  lastEventId: string;
};

import { authorizedFetch } from "./http";

function parseEventBlock(block: string): SessionStreamEvent | null {
  let type = "message";
  let lastEventId = "";
  const data: string[] = [];

  for (const line of block.split("\n")) {
    if (!line || line.startsWith(":")) {
      continue;
    }
    const separatorIndex = line.indexOf(":");
    const field = separatorIndex === -1 ? line : line.slice(0, separatorIndex);
    const value = separatorIndex === -1 ? "" : line.slice(separatorIndex + 1).replace(/^ /, "");

    if (field === "event") {
      type = value;
    } else if (field === "id") {
      lastEventId = value;
    } else if (field === "data") {
      data.push(value);
    }
  }

  if (data.length === 0 && lastEventId.length === 0) {
    return null;
  }

  return {
    type,
    data: data.join("\n"),
    lastEventId
  };
}

async function streamSessionEvents(
  sessionId: string,
  onEvent: (event: SessionStreamEvent) => void,
  signal: AbortSignal
) {
  const response = await authorizedFetch(`/sessions/${sessionId}/events`, {
    headers: { Accept: "text/event-stream" },
    signal
  });
  if (!response.ok || response.body == null) {
    return;
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (!signal.aborted) {
      const { done, value } = await reader.read();
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done }).replace(/\r\n/g, "\n");

      let boundary = buffer.indexOf("\n\n");
      while (boundary !== -1) {
        const next = parseEventBlock(buffer.slice(0, boundary));
        if (next != null) {
          onEvent(next);
        }
        buffer = buffer.slice(boundary + 2);
        boundary = buffer.indexOf("\n\n");
      }

      if (done) {
        break;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

export function subscribeToSession(sessionId: string, onEvent: (event: SessionStreamEvent) => void) {
  const controller = new AbortController();
  void streamSessionEvents(sessionId, onEvent, controller.signal).catch(() => undefined);
  return () => controller.abort();
}
