function joinUrl(baseUrl, path) {
  if (!baseUrl) {
    return path;
  }
  return `${baseUrl.replace(/\/$/, "")}${path}`;
}

function extractErrorMessage(payload, fallback) {
  if (!payload || typeof payload !== "object") {
    return fallback;
  }
  if (typeof payload.error === "string" && payload.error) {
    return payload.error;
  }
  if (typeof payload.message === "string" && payload.message) {
    return payload.message;
  }
  return fallback;
}

async function readJsonResponse(response) {
  const raw = await response.text();
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch (_error) {
    return null;
  }
}

async function requestJson(fetchImpl, url, options = {}) {
  const response = await fetchImpl(url, options);
  const payload = await readJsonResponse(response);
  if (!response.ok) {
    const fallback = `Request failed with status ${response.status}`;
    const error = new Error(extractErrorMessage(payload, fallback));
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

export function buildPromptRequest(text) {
  return { text };
}

export function buildToolDecisionRequest(callInfo, optionId) {
  const payload = { optionId };
  if (callInfo?.callId) {
    payload.callId = callInfo.callId;
  }
  if (callInfo && callInfo.requestId != null) {
    payload.requestId = callInfo.requestId;
  }
  return payload;
}

export function createApiClient({ baseUrl = "", fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("fetch is required");
  }

  return {
    async getSession(sessionId) {
      const payload = await requestJson(
        fetchImpl,
        joinUrl(baseUrl, `/sessions/${encodeURIComponent(sessionId)}`),
        { method: "GET" },
      );
      return payload?.session ?? null;
    },

    async sendPrompt(sessionId, text) {
      return requestJson(
        fetchImpl,
        joinUrl(baseUrl, `/sessions/${encodeURIComponent(sessionId)}/prompts`),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(buildPromptRequest(text)),
        },
      );
    },

    async decideTool(sessionId, callInfo, optionId) {
      return requestJson(
        fetchImpl,
        joinUrl(baseUrl, `/sessions/${encodeURIComponent(sessionId)}/tool-decisions`),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(buildToolDecisionRequest(callInfo, optionId)),
        },
      );
    },

    async cancel(sessionId) {
      return requestJson(
        fetchImpl,
        joinUrl(baseUrl, `/sessions/${encodeURIComponent(sessionId)}/cancel`),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
        },
      );
    },
  };
}
