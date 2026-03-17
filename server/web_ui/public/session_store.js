import { buildTimelineItems, mergeEvents, readCallInfo } from "./event_utils.js";

export function createInitialState(sessionId) {
  return {
    sessionId,
    session: null,
    events: [],
    timelineItems: [],
    sessionState: "loading",
    connectionState: "idle",
    promptText: "",
    promptPending: false,
    promptError: null,
    cancelPending: false,
    cancelError: null,
    toolPending: {},
    toolErrors: {},
    resolvedCalls: {},
    sessionError: null,
    streamError: null,
  };
}

function applyEventSideEffects(state, events) {
  let nextSession = state.session;
  const resolvedCalls = { ...state.resolvedCalls };

  for (const event of events) {
    if (event.type === "acp.status") {
      const status = event.payload?.state;
      if (status && nextSession) {
        nextSession = { ...nextSession, status };
      }
    }

    if (event.type === "acp.call") {
      const info = readCallInfo(event.payload);
      if (info.callId && info.decision) {
        resolvedCalls[info.callId] = {
          decision: info.decision,
          note: info.note ?? null,
          source: "event",
        };
      }
    }
  }

  return {
    ...state,
    session: nextSession,
    resolvedCalls,
  };
}

export function reduceSessionState(state, action) {
  switch (action.type) {
    case "session/load-start":
      return {
        ...state,
        sessionState: "loading",
        sessionError: null,
      };
    case "session/load-success":
      return {
        ...state,
        session: action.session,
        sessionState: "ready",
        sessionError: null,
      };
    case "session/load-missing":
      return {
        ...state,
        sessionState: "missing",
        sessionError: action.error,
      };
    case "session/load-error":
      return {
        ...state,
        sessionState: "error",
        sessionError: action.error,
      };
    case "stream/connecting":
      return {
        ...state,
        connectionState: state.connectionState === "open" ? "reconnecting" : "connecting",
        streamError: null,
      };
    case "stream/open":
      return {
        ...state,
        connectionState: "open",
        streamError: null,
      };
    case "stream/error":
      return {
        ...state,
        connectionState:
          state.connectionState === "open" || state.connectionState === "reconnecting"
            ? "reconnecting"
            : "error",
        streamError: action.error ?? "Stream connection interrupted.",
      };
    case "prompt/change":
      return {
        ...state,
        promptText: action.text,
      };
    case "prompt/submit-start":
      return {
        ...state,
        promptPending: true,
        promptError: null,
      };
    case "prompt/submit-success":
      return {
        ...state,
        promptPending: false,
        promptText: "",
      };
    case "prompt/submit-error":
      return {
        ...state,
        promptPending: false,
        promptError: action.error,
      };
    case "cancel/start":
      return {
        ...state,
        cancelPending: true,
        cancelError: null,
      };
    case "cancel/success":
      return {
        ...state,
        cancelPending: false,
      };
    case "cancel/error":
      return {
        ...state,
        cancelPending: false,
        cancelError: action.error,
      };
    case "tool-decision/start":
      return {
        ...state,
        toolPending: {
          ...state.toolPending,
          [action.callId]: true,
        },
        toolErrors: {
          ...state.toolErrors,
          [action.callId]: null,
        },
      };
    case "tool-decision/success":
      return {
        ...state,
        toolPending: {
          ...state.toolPending,
          [action.callId]: false,
        },
        resolvedCalls: {
          ...state.resolvedCalls,
          [action.callId]: {
            decision: action.decision,
            note: null,
            source: "local",
          },
        },
      };
    case "tool-decision/error":
      return {
        ...state,
        toolPending: {
          ...state.toolPending,
          [action.callId]: false,
        },
        toolErrors: {
          ...state.toolErrors,
          [action.callId]: action.error,
        },
      };
    case "events/add": {
      const mergedEvents = mergeEvents(state.events, action.events);
      return applyEventSideEffects(
        {
          ...state,
          events: mergedEvents,
          timelineItems: buildTimelineItems(mergedEvents),
        },
        action.events,
      );
    }
    default:
      return state;
  }
}

export function createSessionStore({ sessionId, redraw = () => {} }) {
  let state = createInitialState(sessionId);

  return {
    getState() {
      return state;
    },

    dispatch(action) {
      state = reduceSessionState(state, action);
      redraw();
      return state;
    },
  };
}
