import { createMemo, createSignal, onCleanup, onMount } from "solid-js";

import {
  approveSessionApproval,
  archiveSession,
  cancelSession,
  denySessionApproval,
  getSession,
  listTimeline,
  markSessionSeen,
  resetSession,
  resumeSession,
  sendPrompt,
  type SessionDetail,
  type TimelineEvent
} from "./api";
import { subscribeToSession } from "./events";


function applyEventToDetail(
  detail: SessionDetail | null,
  event: { type: string; payload: Record<string, unknown> }
): SessionDetail | null {
  if (detail == null) {
    return detail;
  }

  const payloadRunState =
    typeof event.payload.runState === "string"
      ? event.payload.runState
      : typeof event.payload.status === "string"
        ? event.payload.status
        : null;
  const pendingApproval = event.payload.pendingApproval as SessionDetail["pendingApproval"] | undefined;

  switch (event.type) {
    case "session.bound":
      return {
        ...detail,
        status: "running",
        runState: "running",
        workspaceState: "ready",
        pendingApproval: undefined
      };
    case "session.cancelled":
      return {
        ...detail,
        status: "resume_available",
        runState: "resume_available",
        pendingApproval: undefined
      };
    case "session.attention_required":
      return {
        ...detail,
        status: "attention_required",
        runState: "attention_required",
        pendingApproval: pendingApproval ?? detail.pendingApproval
      };
    case "session.completed":
      return {
        ...detail,
        status: payloadRunState ?? "completed",
        runState: payloadRunState ?? "completed",
        pendingApproval: undefined
      };
    case "session.archived":
      return { ...detail, status: "archived", runState: "archived", pendingApproval: undefined };
    case "session.failed":
      return { ...detail, status: "failed", runState: "failed", pendingApproval: undefined };
    case "workspace.reset":
      return {
        ...detail,
        status: "resume_available",
        runState: "resume_available",
        workspaceState: "missing",
        pendingApproval: undefined
      };
    case "workspace.recreated":
      return { ...detail, workspaceState: "ready" };
    default:
      return detail;
  }
}

async function markLatestSeen(sessionId: string, events: TimelineEvent[]) {
  const newest = events.at(-1);
  if (newest == null) {
    return;
  }
  await markSessionSeen(sessionId, newest.seq);
}

export function createSessionDetailState(
  sessionId: string,
  initial: { detail?: SessionDetail | null; timeline?: TimelineEvent[] | null } = {}
) {
  const [detail, setDetail] = createSignal<SessionDetail | null>(initial.detail ?? null);
  const [timeline, setTimeline] = createSignal<TimelineEvent[]>(initial.timeline ?? []);
  const [rawMode, setRawMode] = createSignal(false);

  async function refreshDetail() {
    const next = await getSession(sessionId);
    setDetail(next);
    return next;
  }

  async function refreshTimeline() {
    const snapshot = await listTimeline(sessionId);
    setTimeline(snapshot.events);
    await markLatestSeen(sessionId, snapshot.events);
    return snapshot.events;
  }

  onMount(() => {
    void (async () => {
      if (initial.detail == null) {
        await refreshDetail();
      }
      if (initial.timeline == null) {
        await refreshTimeline();
      } else {
        await markLatestSeen(sessionId, initial.timeline);
      }
    })();

    const unsubscribe = subscribeToSession(sessionId, (event) => {
      const payload = event.data ? (JSON.parse(event.data) as Record<string, unknown>) : {};
      const nextSeq = Number(event.lastEventId || timeline().length + 1);
      setTimeline((current) => [
        ...current,
        {
          seq: nextSeq,
          type: event.type,
          payload,
          createdAt: new Date().toISOString()
        }
      ]);
      setDetail((current) => applyEventToDetail(current, { type: event.type, payload }));
      void markSessionSeen(sessionId, nextSeq);
    });

    onCleanup(() => {
      unsubscribe();
    });
  });

  const promptDisabled = createMemo(() => detail()?.runState !== "running");
  const actionsDisabled = createMemo(() => detail()?.runState === "created");

  return {
    detail,
    timeline,
    rawMode,
    setRawMode,
    actionsDisabled,
    promptDisabled,
    sendPrompt: (prompt: string) => sendPrompt(sessionId, prompt),
    resume: async () => {
      setDetail(await resumeSession(sessionId));
    },
    cancel: async () => {
      setDetail(await cancelSession(sessionId));
    },
    reset: async () => {
      setDetail(await resetSession(sessionId));
    },
    archive: async () => {
      setDetail(await archiveSession(sessionId));
    },
    approvePending: async () => {
      setDetail(await approveSessionApproval(sessionId));
    },
    denyPending: async () => {
      setDetail(await denySessionApproval(sessionId));
    }
  };
}
