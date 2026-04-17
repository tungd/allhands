import { createEffect, createSignal, onCleanup, onMount } from "solid-js";

import { listSessions, type SessionSummary } from "./api";
import { subscribeToSession } from "./events";

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
                  : session.status
        }
      : session
  );

  return {
    sessions: sortSessions(sessions)
  };
}

export function createSessionsState() {
  const [state, setState] = createSignal<SessionState>({ sessions: [] });

  onMount(async () => {
    setState(await listSessions());
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
