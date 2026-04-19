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

/** Trailing seen marker - batches bursts and only posts the newest cursor. */
function createSeenMarker(sessionId: string, delayMs = 500) {
  let pendingSeq: number | null = null;
  let timeoutId: ReturnType<typeof setTimeout> | null = null;
  let inFlightSeq: number | null = null;
  let lastSentSeq = 0;

  const flush = async () => {
    timeoutId = null;
    if (inFlightSeq != null) {
      return;
    }
    const seq = pendingSeq;
    if (seq == null || seq <= lastSentSeq) {
      pendingSeq = null;
      return;
    }
    pendingSeq = null;
    inFlightSeq = seq;
    try {
      await markSessionSeen(sessionId, seq);
      lastSentSeq = seq;
    } catch {
      pendingSeq = pendingSeq == null ? seq : Math.max(pendingSeq, seq);
    } finally {
      inFlightSeq = null;
      if (pendingSeq != null && pendingSeq > lastSentSeq && timeoutId == null) {
        timeoutId = setTimeout(() => void flush().catch(() => undefined), delayMs);
      }
    }
  };

  const markSeen = (seq: number) => {
    if (!Number.isFinite(seq) || seq <= 0 || seq <= lastSentSeq) {
      return;
    }
    pendingSeq = pendingSeq == null ? seq : Math.max(pendingSeq, seq);
    if (timeoutId != null) {
      clearTimeout(timeoutId);
    }
    timeoutId = setTimeout(() => void flush().catch(() => undefined), delayMs);
  };

  const cancel = () => {
    if (timeoutId != null) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
    pendingSeq = null;
  };

  return { markSeen, cancel };
}

export function createSessionDetailState(
  sessionId: string,
  initial: { detail?: SessionDetail | null; timeline?: TimelineEvent[] | null } = {}
) {
  const [detail, setDetail] = createSignal<SessionDetail | null>(initial.detail ?? null);
  const [timeline, setTimeline] = createSignal<TimelineEvent[]>(initial.timeline ?? []);
  const [rawMode, setRawMode] = createSignal(false);
  const seenMarker = createSeenMarker(sessionId, 500);

  async function refreshDetail() {
    const next = await getSession(sessionId);
    setDetail(next);
    return next;
  }

  async function refreshTimeline() {
    const snapshot = await listTimeline(sessionId);
    setTimeline(snapshot.events);
    seenMarker.markSeen(snapshot.events.at(-1)?.seq ?? 0);
    return snapshot.events;
  }

  onMount(() => {
    void (async () => {
      try {
        if (initial.detail == null) {
          await refreshDetail();
        }
        if (initial.timeline == null) {
          await refreshTimeline();
        } else {
          seenMarker.markSeen(initial.timeline.at(-1)?.seq ?? 0);
        }
      } catch {
        return;
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
      seenMarker.markSeen(nextSeq);
    });

    onCleanup(() => {
      seenMarker.cancel();
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
