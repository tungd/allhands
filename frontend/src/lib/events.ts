export type SessionStreamEvent = {
  type: string;
  data: string;
  lastEventId: string;
};

const SESSION_EVENT_TYPES = [
  "session.created",
  "session.prompted",
  "session.bound",
  "session.cancelled",
  "session.attention_required",
  "session.completed",
  "session.archived",
  "session.failed",
  "workspace.reset",
  "workspace.recreated",
  "acp.initialized",
  "acp.thought",
  "acp.permission_requested"
] as const;

export function subscribeToSession(sessionId: string, onEvent: (event: SessionStreamEvent) => void) {
  const source = new EventSource(`/sessions/${sessionId}/events`);

  for (const type of SESSION_EVENT_TYPES) {
    source.addEventListener(type, (event) => {
      const message = event as MessageEvent<string>;
      onEvent({
        type,
        data: message.data,
        lastEventId: message.lastEventId
      });
    });
  }

  return () => source.close();
}
