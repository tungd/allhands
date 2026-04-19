import { useParams } from "@solidjs/router";

import { ApprovalCard } from "../components/approval-card";
import { PromptBox } from "../components/prompt-box";
import { SessionActions } from "../components/session-actions";
import { Timeline } from "../components/timeline";
import { createSessionDetailState } from "../lib/session-detail-store";
import { describeTimelineEvent, extractAgentMessageMarkdown } from "../lib/timeline";
import type { SessionDetail, TimelineEvent } from "../lib/api";

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
          markdown: extractAgentMessageMarkdown(item) ?? undefined,
          raw: JSON.stringify(item.payload),
          createdAt: item.createdAt
        }))}
        rawMode={state.rawMode()}
        onToggleMode={() => state.setRawMode((current) => !current)}
      />
      {state.detail()?.pendingApproval ? (
        <ApprovalCard
          approval={state.detail()!.pendingApproval!}
          onApprove={() => void state.approvePending()}
          onDeny={() => void state.denyPending()}
        />
      ) : null}
      <SessionActions
        disabled={state.actionsDisabled()}
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
