import type { TimelineEvent } from "./api";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAgentRole(value: unknown): boolean {
  return value === "assistant" || value === "agent";
}

function collectTextParts(value: unknown): string[] {
  if (typeof value === "string") {
    return value.length > 0 ? [value] : [];
  }

  if (Array.isArray(value)) {
    return value.flatMap((entry) => collectTextParts(entry));
  }

  if (!isRecord(value)) {
    return [];
  }

  const directText = value.text;
  if (typeof directText === "string" && directText.length > 0) {
    return [directText];
  }

  const content = value.content;
  if (Array.isArray(content)) {
    return content.flatMap((entry) => collectTextParts(entry));
  }

  return [];
}

export function extractAgentMessageMarkdown(event: TimelineEvent): string | null {
  const payload = event.payload;
  const candidates: Record<string, unknown>[] = [];

  if (isRecord(payload.item)) {
    candidates.push(payload.item);
  }
  if (isRecord(payload.message)) {
    candidates.push(payload.message);
  }
  if (isRecord(payload.delta)) {
    candidates.push(payload.delta);
  }
  if (isAgentRole(payload.role)) {
    candidates.push(payload);
  }

  for (const candidate of candidates) {
    if (!isAgentRole(candidate.role)) {
      continue;
    }
    const text = collectTextParts(candidate).join("\n\n").trim();
    if (text.length > 0) {
      return text;
    }
  }

  return null;
}

export function describeTimelineEvent(event: TimelineEvent): string {
  switch (event.type) {
    case "session.created":
      return "Session created";
    case "workspace.reset":
      return "Workspace reset";
    case "workspace.recreated":
      return "Workspace recreated";
    case "session.completed":
      return "Session completed";
    case "session.failed":
      return String(event.payload.error ?? "Session failed");
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
    case "codex.approval.requested":
      return String(
        (event.payload.pendingApproval as { summary?: string } | undefined)?.summary ?? "Codex requested approval"
      );
    case "codex.approval.resolved":
      return "Approval resolved";
    case "codex.request.unsupported":
      return `Unsupported Codex request: ${String(event.payload.method ?? "unknown")}`;
    case "acp.thought":
      return String(event.payload.text ?? "Agent thought");
    default:
      return event.type;
  }
}
