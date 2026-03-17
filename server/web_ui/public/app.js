import { createApiClient } from "./api.js";
import { createSessionStore } from "./session_store.js";
import { HomePage, renderSessionPage } from "./view.js";

const m = window.m;

if (!m) {
  throw new Error("Mithril failed to load");
}

const eventTypes = ["acp.init", "acp.status", "acp.thought", "acp.call", "acp.patch", "acp.error"];
const api = createApiClient({ baseUrl: "", fetchImpl: window.fetch.bind(window) });

function createSessionController(sessionId) {
  const store = createSessionStore({ sessionId, redraw: () => m.redraw() });
  let eventSource = null;
  let listeners = [];
  let stopped = false;

  function dispatch(action) {
    store.dispatch(action);
  }

  function closeStream() {
    if (!eventSource) {
      return;
    }
    for (const [type, handler] of listeners) {
      eventSource.removeEventListener(type, handler);
    }
    listeners = [];
    eventSource.close();
    eventSource = null;
  }

  function handleStreamEvent(event) {
    try {
      const payload = JSON.parse(event.data);
      console.log("[allhands:event]", {
        type: payload.type,
        id: payload.id,
        seq: payload.seq,
        payload: payload.payload,
      });
      dispatch({ type: "events/add", events: [payload] });
    } catch (error) {
      dispatch({
        type: "stream/error",
        error: `Failed to parse stream event: ${error.message}`,
      });
    }
  }

  function connectStream() {
    closeStream();
    dispatch({ type: "stream/connecting" });
    eventSource = new window.EventSource(`/sessions/${encodeURIComponent(sessionId)}/events`);
    listeners = eventTypes.map((type) => {
      const handler = (event) => handleStreamEvent(event);
      eventSource.addEventListener(type, handler);
      return [type, handler];
    });
    eventSource.onopen = () => {
      if (!stopped) {
        dispatch({ type: "stream/open" });
      }
    };
    eventSource.onerror = () => {
      if (!stopped) {
        dispatch({
          type: "stream/error",
          error: "Connection interrupted. The browser will retry automatically.",
        });
      }
    };
  }

  async function loadSession() {
    closeStream();
    dispatch({ type: "session/load-start" });
    try {
      const session = await api.getSession(sessionId);
      if (stopped) {
        return;
      }
      dispatch({ type: "session/load-success", session });
      connectStream();
    } catch (error) {
      if (stopped) {
        return;
      }
      if (error.status === 404) {
        dispatch({ type: "session/load-missing", error: error.message });
      } else {
        dispatch({ type: "session/load-error", error: error.message });
      }
    }
  }

  return {
    get state() {
      return store.getState();
    },

    start() {
      loadSession();
    },

    stop() {
      stopped = true;
      closeStream();
    },

    actions: {
      updatePromptText(text) {
        dispatch({ type: "prompt/change", text });
      },

      async submitPrompt() {
        const text = store.getState().promptText.trim();
        if (!text) {
          return;
        }
        dispatch({ type: "prompt/submit-start" });
        try {
          await api.sendPrompt(sessionId, text);
          if (!stopped) {
            dispatch({ type: "prompt/submit-success" });
          }
        } catch (error) {
          if (!stopped) {
            dispatch({ type: "prompt/submit-error", error: error.message });
          }
        }
      },

      async decideTool(callInfo, optionId) {
        const callId = callInfo.callId;
        if (!callId) {
          return;
        }
        dispatch({ type: "tool-decision/start", callId });
        try {
          await api.decideTool(sessionId, callInfo, optionId);
          if (!stopped) {
            dispatch({ type: "tool-decision/success", callId, decision: optionId });
          }
        } catch (error) {
          if (!stopped) {
            dispatch({ type: "tool-decision/error", callId, error: error.message });
          }
        }
      },

      async cancelSession() {
        dispatch({ type: "cancel/start" });
        try {
          await api.cancel(sessionId);
          if (!stopped) {
            dispatch({ type: "cancel/success" });
          }
        } catch (error) {
          if (!stopped) {
            dispatch({ type: "cancel/error", error: error.message });
          }
        }
      },

      retry() {
        loadSession();
      },
    },
  };
}

const SessionRoute = {
  oninit(vnode) {
    vnode.state.sessionId = vnode.attrs.id;
    vnode.state.controller = createSessionController(vnode.attrs.id);
    vnode.state.controller.start();
  },

  onbeforeupdate(vnode, old) {
    if (vnode.attrs.id !== old.attrs.id) {
      old.state.controller.stop();
      vnode.state.sessionId = vnode.attrs.id;
      vnode.state.controller = createSessionController(vnode.attrs.id);
      vnode.state.controller.start();
    }
    return true;
  },

  onremove(vnode) {
    vnode.state.controller.stop();
  },

  view(vnode) {
    return renderSessionPage(vnode.state.controller.state, vnode.state.controller.actions);
  },
};

m.route.prefix = "";
m.route(document.getElementById("app"), "/ui", {
  "/ui": HomePage,
  "/ui/session/:id": SessionRoute,
});
