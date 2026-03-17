import { formatTimestamp, normalizeEvent } from "./event_utils.js";

const m = window.m;

function statusClass(status) {
  switch (status) {
    case "ready":
      return "status-ready";
    case "busy":
      return "status-busy";
    case "stopped":
      return "status-stopped";
    case "error":
      return "status-error";
    default:
      return "status-neutral";
  }
}

function connectionCopy(state) {
  switch (state.connectionState) {
    case "connecting":
      return "Connecting to live session stream...";
    case "open":
      return "Live stream connected.";
    case "reconnecting":
      return state.streamError ?? "Reconnecting to live session stream...";
    case "error":
      return state.streamError ?? "Unable to connect to live session stream.";
    default:
      return "";
  }
}

function decisionLabel(decision) {
  switch (decision) {
    case "approved":
      return "Approved";
    case "denied":
      return "Denied";
    case "abort":
      return "Aborted";
    default:
      return decision;
  }
}

function formatArguments(value) {
  if (value == null) {
    return null;
  }
  if (typeof value === "string") {
    return value;
  }
  return JSON.stringify(value, null, 2);
}

function renderHomePage() {
  return m(".ui-home", [
    m(".empty-state", [
      m("p.eyebrow", "All Hands Web UI"),
      m("h1", "Open a session URL directly"),
      m("p", "Use /ui/session/<session-id> to attach to a running session."),
    ]),
  ]);
}

function renderStatePanel(title, body, action) {
  return m(".timeline-empty", [
    m("h2", title),
    m("p", body),
    action ?? null,
  ]);
}

function renderToolActions(state, actions, callInfo) {
  if (!callInfo.callId) {
    return null;
  }

  const resolution = state.resolvedCalls[callInfo.callId];
  const pending = !!state.toolPending[callInfo.callId];
  const note = state.toolNotes[callInfo.callId] ?? "";
  const error = state.toolErrors[callInfo.callId];

  if (resolution) {
    return m(".call-resolution", [
      m("span.resolution-label", decisionLabel(resolution.decision)),
      resolution.note ? m("p", resolution.note) : null,
    ]);
  }

  return m(".call-actions", [
    m("label.field-label", { for: `note-${callInfo.callId}` }, "Reviewer note"),
    m("textarea.note-input", {
      id: `note-${callInfo.callId}`,
      rows: 3,
      placeholder: "Optional note for the agent",
      value: note,
      oninput: (event) => actions.updateToolNote(callInfo.callId, event.target.value),
      disabled: pending,
    }),
    error ? m("p.inline-error", error) : null,
    m(".call-action-row", [
      m(
        "button.button.button-secondary",
        {
          type: "button",
          disabled: pending,
          onclick: () => actions.decideTool(callInfo.callId, "denied"),
        },
        pending ? "Working..." : "Deny",
      ),
      m(
        "button.button.button-primary",
        {
          type: "button",
          disabled: pending,
          onclick: () => actions.decideTool(callInfo.callId, "approved"),
        },
        pending ? "Working..." : "Approve",
      ),
    ]),
  ]);
}

function renderEventCard(state, actions, event) {
  const model = normalizeEvent(event);
  const timeLabel = formatTimestamp(event.timestamp);
  const cardClass = `event-card event-${model.kind}`;

  if (model.kind === "call") {
    const args = formatArguments(model.callInfo.arguments);
    return m("article", { class: cardClass, key: event.id }, [
      m(".event-meta", [
        m("span.event-kind", model.title),
        m("span.event-time", timeLabel),
      ]),
      model.callInfo.callId ? m("p.event-call-id", `Call ID: ${model.callInfo.callId}`) : null,
      args ? m("pre.code-block", args) : null,
      model.body ? m("p.event-body", model.body) : null,
      renderToolActions(state, actions, model.callInfo),
    ]);
  }

  if (model.kind === "patch") {
    return m("article", { class: cardClass, key: event.id }, [
      m(".event-meta", [
        m("span.event-kind", model.title),
        m("span.event-time", timeLabel),
      ]),
      m("pre.code-block", model.body),
    ]);
  }

  if (model.kind === "status") {
    return m("article", { class: cardClass, key: event.id }, [
      m(".event-meta", [
        m("span.event-kind", model.title),
        m("span.event-time", timeLabel),
      ]),
      model.body ? m("p.event-body", model.body) : null,
    ]);
  }

  return m("article", { class: cardClass, key: event.id }, [
    m(".event-meta", [
      m("span.event-kind", model.title),
      m("span.event-time", timeLabel),
    ]),
    model.body ? m("p.event-body", model.body) : null,
  ]);
}

function renderSessionTimeline(state, actions) {
  if (state.sessionState === "loading") {
    return renderStatePanel("Loading session", "Fetching session metadata and attaching to the event stream.");
  }

  if (state.sessionState === "missing") {
    return renderStatePanel("Session not found", state.sessionError ?? "The requested session does not exist.");
  }

  if (state.sessionState === "error") {
    return renderStatePanel(
      "Failed to load session",
      state.sessionError ?? "The host returned an unexpected error.",
      m(
        "button.button.button-primary",
        { type: "button", onclick: actions.retry },
        "Retry",
      ),
    );
  }

  if (!state.events.length) {
    return renderStatePanel("Session is connected", "Events will appear here as the agent produces updates.");
  }

  return m(
    ".timeline",
    state.events.map((event) => renderEventCard(state, actions, event)),
  );
}

export function renderSessionPage(state, actions) {
  const session = state.session;
  const canSend = session && session.status === "ready" && !state.promptPending;
  const connectionMessage = connectionCopy(state);

  return m(".session-screen", [
    m(".page-background"),
    m("header.session-header", [
      m(".header-main", [
        m("p.eyebrow", "All Hands Session"),
        m("h1", session?.id ?? state.sessionId),
        m(".header-paths", [
          session?.repoPath ? m("p.path-line", `Repo: ${session.repoPath}`) : null,
          session?.worktreePath ? m("p.path-line", `Worktree: ${session.worktreePath}`) : null,
        ]),
      ]),
      m(".header-status", [
        m("span", { class: `status-pill ${statusClass(session?.status)}` }, session?.status ?? "loading"),
        m(
          "button.button.button-secondary",
          {
            type: "button",
            onclick: actions.cancelSession,
            disabled: !session || state.cancelPending,
          },
          state.cancelPending ? "Cancelling..." : "Cancel",
        ),
      ]),
    ]),
    connectionMessage
      ? m("div", {
          class: `stream-banner ${state.connectionState === "open" ? "banner-open" : "banner-warning"}`,
        }, connectionMessage)
      : null,
    state.promptError ? m("p.global-error", state.promptError) : null,
    state.cancelError ? m("p.global-error", state.cancelError) : null,
    m("main.session-content", renderSessionTimeline(state, actions)),
    session
      ? m(
          "form.composer",
          {
            onsubmit: (event) => {
              event.preventDefault();
              actions.submitPrompt();
            },
          },
          [
            m("label.field-label", { for: "prompt" }, "Prompt"),
            m("textarea#prompt.prompt-input", {
              rows: 4,
              placeholder: canSend ? "Ask the agent what to do next..." : "Wait for the session to become ready before sending a prompt.",
              value: state.promptText,
              disabled: !canSend,
              oninput: (event) => actions.updatePromptText(event.target.value),
            }),
            m(".composer-row", [
              m("span.composer-hint", canSend ? "Prompt the live session directly from the browser." : "Session must be ready to accept prompts."),
              m(
                "button.button.button-primary",
                {
                  type: "submit",
                  disabled: !canSend || !state.promptText.trim(),
                },
                state.promptPending ? "Sending..." : "Send Prompt",
              ),
            ]),
          ],
        )
      : null,
  ]);
}

export const HomePage = {
  view: renderHomePage,
};
