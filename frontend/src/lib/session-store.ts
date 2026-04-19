import { createEffect, createSignal, onCleanup, onMount } from "solid-js";

import { getServerInfo, listSessions, markAppSeen, type SessionSummary } from "./api";
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
  const payloadRunState =
    typeof event.payload.runState === "string"
      ? event.payload.runState
      : typeof event.payload.status === "string"
        ? event.payload.status
        : null;

  const sessions = state.sessions.map((session) =>
    session.id === event.sessionId
      ? {
          ...session,
          status:
            event.type === "session.bound"
              ? "running"
              : event.type === "session.cancelled"
                ? "resume_available"
                : event.type === "session.failed"
                  ? "failed"
                  : event.type === "session.attention_required"
              ? "attention_required"
              : event.type === "session.completed"
                ? payloadRunState ?? "completed"
              : event.type === "session.archived"
                  ? "archived"
                  : session.status,
          runState:
            event.type === "session.bound"
              ? "running"
              : event.type === "session.cancelled"
                ? "resume_available"
                : event.type === "session.failed"
                  ? "failed"
                  : event.type === "session.attention_required"
              ? "attention_required"
              : event.type === "session.completed"
                ? payloadRunState ?? "completed"
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
    try {
      const [next, info] = await Promise.all([
        listSessions(),
        vapidPublicKey
          ? Promise.resolve({ vapidPublicKey })
          : getServerInfo().catch(() => ({ vapidPublicKey: "" }))
      ]);
      await maybeEnableNotifications({
        previousCount: state().sessions.length,
        nextCount: next.sessions.length,
        vapidPublicKey: info.vapidPublicKey
      });
      setState(next);
    } catch {
      setState({ sessions: [] });
    }
  });

  onMount(() => {
    function markVisibleSeen() {
      if (document.visibilityState === "visible") {
        void markAppSeen(new Date().toISOString()).catch(() => undefined);
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
