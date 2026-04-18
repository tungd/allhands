import { createEffect, createSignal, onCleanup, onMount } from "solid-js";

import { listSessions, markAppSeen, type SessionSummary } from "./api";
import { subscribeToSession } from "./events";
import { maybeEnableNotifications } from "./push";

export type SessionState = {
  sessions: SessionSummary[];
};

export type SessionEvent = {
  sessionId: string;
  type: string;
  payload: Record<string, unknown>;
};

function sortSessions(sessions: SessionSummary[]) {
  return [...sessions].sort((left, right) => {
    if (left.status === "attention_required" && right.status !== "attention_required") return -1;
    if (left.status !== "attention_required" && right.status === "attention_required") return 1;
    return 0;
  });
}

export function applyEvent(state: SessionState, event: SessionEvent): SessionState {
  const sessions = state.sessions.map((session) =>
    session.id === event.sessionId
      ? {
          ...session,
          status:
            event.type === "session.attention_required"
              ? "attention_required"
              : event.type === "session.completed"
                ? "completed"
              : event.type === "session.archived"
                  ? "archived"
                  : session.status,
          runState:
            event.type === "session.attention_required"
              ? "attention_required"
              : event.type === "session.completed"
                ? "completed"
                : event.type === "session.archived"
                  ? "archived"
                  : session.runState
        }
      : session
  );

  return {
    sessions: sortSessions(sessions)
  };
}

export function createSessionsState(vapidPublicKey = "") {
  const [state, setState] = createSignal<SessionState>({ sessions: [] });

  onMount(async () => {
    const next = await listSessions();
    await maybeEnableNotifications({
      previousCount: state().sessions.length,
      nextCount: next.sessions.length,
      vapidPublicKey
    });
    setState(next);
  });

  onMount(() => {
    function markVisibleSeen() {
      if (document.visibilityState === "visible") {
        void markAppSeen(new Date().toISOString());
      }
    }

    markVisibleSeen();
    document.addEventListener("visibilitychange", markVisibleSeen);
    onCleanup(() => {
      document.removeEventListener("visibilitychange", markVisibleSeen);
    });
  });

  createEffect(() => {
    const sessions = state().sessions;
    const unsubscribe = sessions.map((session) =>
      subscribeToSession(session.id, (event) => {
        const payload = event.data ? (JSON.parse(event.data) as Record<string, unknown>) : {};
        setState((current) =>
          applyEvent(current, {
            sessionId: session.id,
            type: event.type,
            payload
          })
        );
      })
    );

    onCleanup(() => {
      unsubscribe.forEach((dispose) => dispose());
    });
  });

  return state;
}
