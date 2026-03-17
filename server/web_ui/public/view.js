import { formatTimestamp } from "./event_utils.js";

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

function requestOptionLabel(option) {
  if (typeof option?.name === "string" && option.name.trim()) {
    return option.name.trim();
  }
  return typeof option?.optionId === "string" ? option.optionId : "Choose";
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

function optionLabel(callInfo, optionId, fallback) {
  const options = Array.isArray(callInfo.options) ? callInfo.options : [];
  const match = options.find((option) => option?.optionId === optionId);
  return typeof match?.name === "string" && match.name.trim() ? match.name.trim() : fallback;
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
  if (!callInfo.callId || !callInfo.approvalRequired) {
    return null;
  }

  const resolution = state.resolvedCalls[callInfo.callId];
  const pending = !!state.toolPending[callInfo.callId];
  const error = state.toolErrors[callInfo.callId];
  const options = Array.isArray(callInfo.options) ? callInfo.options : [];

  if (resolution) {
    const resolvedLabel = optionLabel(callInfo, resolution.decision, decisionLabel(resolution.decision));
    return m(".call-resolution", [
      m("span.resolution-label", resolvedLabel),
      resolution.note ? m("p", resolution.note) : null,
    ]);
  }

  return m(".call-actions", [
    error ? m("p.inline-error", error) : null,
    m(".call-action-row", [
      ...(options.length
        ? options.map((option, index) =>
            m(
              `button.button.${index === 0 ? "button-primary" : "button-secondary"}`,
              {
                type: "button",
                disabled: pending,
                onclick: () => actions.decideTool(callInfo, option.optionId),
              },
              pending ? "Working..." : requestOptionLabel(option),
            ))
        : [
            m(
              "button.button.button-secondary",
              {
                type: "button",
                disabled: pending,
                onclick: () => actions.decideTool(callInfo, "denied"),
              },
              pending ? "Working..." : optionLabel(callInfo, "abort", optionLabel(callInfo, "denied", "Deny")),
            ),
            m(
              "button.button.button-primary",
              {
                type: "button",
                disabled: pending,
                onclick: () => actions.decideTool(callInfo, "approved"),
              },
              pending ? "Working..." : optionLabel(callInfo, "approved", "Approve"),
            ),
          ]),
    ]),
  ]);
}

function renderThoughtItem(item) {
  return m("article", { class: "event-card event-thought", key: item.id }, [
    m(".event-meta", [
      m("span.event-kind", item.title),
      m("span.event-time", formatTimestamp(item.timestamp)),
    ]),
    item.body ? m("p.event-body event-body-thought", item.body) : null,
  ]);
}

function shouldExpandByDefault(item) {
  if (item.kind === "thought") {
    return true;
  }
  if (item.kind === "call" && item.callInfo?.approvalRequired) {
    return true;
  }
  return false;
}

function renderCardMeta(title, timeLabel) {
  return m(".event-meta", [
    m("span.event-kind", title),
    m("span.event-time", timeLabel),
  ]);
}

function renderEventCard(state, actions, item) {
  const timeLabel = formatTimestamp(item.timestamp);
  const cardClass = `event-card event-${item.kind}`;

  if (item.kind === "thought") {
    return renderThoughtItem(item);
  }

  if (item.kind === "call") {
    const args = formatArguments(item.callInfo.arguments);
    return m("article", { class: `${cardClass} event-system`, key: item.id }, [
      m(
        "details.event-details",
        { open: shouldExpandByDefault(item) },
        [
          m("summary.event-summary", renderCardMeta(item.title, timeLabel)),
          m(".event-details-body", [
            item.callInfo.callId ? m("p.event-call-id", `Call ID: ${item.callInfo.callId}`) : null,
            args ? m("pre.code-block", args) : null,
            item.body ? m("p.event-body", item.body) : null,
            renderToolActions(state, actions, item.callInfo),
          ]),
        ],
      ),
    ]);
  }

  if (item.kind === "patch") {
    return m("article", { class: `${cardClass} event-system`, key: item.id }, [
      m(
        "details.event-details",
        { open: shouldExpandByDefault(item) },
        [
          m("summary.event-summary", renderCardMeta(item.title, timeLabel)),
          m(".event-details-body", [
            m("pre.code-block", item.body),
          ]),
        ],
      ),
    ]);
  }

  if (item.kind === "status") {
    return m("article", { class: `${cardClass} event-system`, key: item.id }, [
      m(
        "details.event-details",
        { open: shouldExpandByDefault(item) },
        [
          m("summary.event-summary", renderCardMeta(item.title, timeLabel)),
          m(".event-details-body", [
            item.body ? m("p.event-body", item.body) : null,
          ]),
        ],
      ),
    ]);
  }

  return m("article", { class: `${cardClass} event-system`, key: item.id }, [
    m(
      "details.event-details",
      { open: shouldExpandByDefault(item) },
      [
        m("summary.event-summary", renderCardMeta(item.title, timeLabel)),
        m(".event-details-body", [
          item.body ? m("p.event-body", item.body) : null,
        ]),
      ],
    ),
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

  if (!state.timelineItems.length) {
    return renderStatePanel("Session is connected", "Events will appear here as the agent produces updates.");
  }

  return m(
    ".timeline",
    state.timelineItems.map((item) => renderEventCard(state, actions, item)),
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
