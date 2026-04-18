import { useParams } from "@solidjs/router";

import { PromptBox } from "../components/prompt-box";
import { SessionActions } from "../components/session-actions";
import { Timeline } from "../components/timeline";
import { createSessionDetailState } from "../lib/session-detail-store";
import type { SessionDetail, TimelineEvent } from "../lib/api";


function describeTimelineEvent(event: TimelineEvent): string {
  switch (event.type) {
    case "workspace.reset":
      return "Workspace reset";
    case "workspace.recreated":
      return "Workspace recreated";
    case "session.completed":
      return "Session completed";
    case "session.attention_required":
      return String(event.payload.message ?? "Agent needs attention");
    case "session.cancelled":
      return "Run cancelled";
    case "session.archived":
      return "Session archived";
    case "session.prompted":
      return "Prompt sent";
    case "session.bound":
      return "Session attached";
    case "acp.thought":
      return String(event.payload.text ?? "Agent thought");
    default:
      return event.type;
  }
}

export function SessionRoute(props: {
  sessionId?: string;
  initialDetail?: SessionDetail | null;
  initialTimeline?: TimelineEvent[] | null;
}) {
  const resolvedSessionId = props.sessionId ?? useParams().sessionId ?? "";
  const state = createSessionDetailState(resolvedSessionId, {
    detail: props.initialDetail,
    timeline: props.initialTimeline
  });

  return (
    <section>
      <h2>{state.detail()?.title ?? "Session"}</h2>
      <Timeline
        items={state.timeline().map((item) => ({
          seq: item.seq,
          type: item.type,
          body: describeTimelineEvent(item),
          raw: JSON.stringify(item.payload),
          createdAt: item.createdAt
        }))}
        rawMode={state.rawMode()}
        onToggleMode={() => state.setRawMode((current) => !current)}
      />
      <SessionActions
        onResume={() => void state.resume()}
        onCancel={() => void state.cancel()}
        onReset={() => void state.reset()}
        onArchive={() => void state.archive()}
      />
      <PromptBox
        disabled={state.promptDisabled()}
        hint={state.promptDisabled() ? "Resume session to send a prompt" : undefined}
        onSubmit={(prompt) => state.sendPrompt(prompt)}
      />
    </section>
  );
}
