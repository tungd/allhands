export type SessionSummary = {
  id: string;
  title: string;
  status: string;
  runState: string;
  workspaceState: string;
};

export type PendingApproval = {
  kind: "command" | "file_change" | "permissions";
  summary: string;
  reason?: string;
  command?: string[];
  cwd?: string;
  grantRoot?: string;
  permissions?: Record<string, unknown>;
  networkApprovalContext?: Record<string, unknown>;
};

export type SessionDetail = SessionSummary & {
  launcher?: string;
  repoPath?: string;
  worktreePath?: string;
  activeNotificationKind?: string;
  lastActivityAt?: string;
  lastSeenEventSeq?: number;
  pendingApproval?: PendingApproval;
};

export type TimelineEvent = {
  seq: number;
  type: string;
  payload: Record<string, unknown>;
  createdAt: string;
};

export type RepoSummary = {
  name: string;
  path: string;
};

import { authorizedFetch } from "./http";

type SessionApiRecord = {
  id: string;
  title?: string;
  status?: string;
  runState?: string;
  workspaceState?: string;
  launcher?: string;
  repoPath?: string;
  repo_path?: string;
  worktreePath?: string;
  worktree_path?: string;
  activeNotificationKind?: string;
  active_notification_kind?: string;
  lastActivityAt?: string;
  last_activity_at?: string;
  lastSeenEventSeq?: number;
  last_seen_event_seq?: number;
  pendingApproval?: PendingApproval;
  pending_approval?: PendingApproval;
};

function deriveTitle(session: SessionApiRecord): string {
  if (session.title) {
    return session.title;
  }

  const repoPath = session.repoPath ?? session.repo_path;
  if (!repoPath) {
    return session.id;
  }

  const parts = repoPath.split("/").filter(Boolean);
  return parts.at(-1) ?? session.id;
}

function normalizeSession(session: SessionApiRecord): SessionDetail {
  const runState = session.runState ?? session.status ?? "created";
  const workspaceState = session.workspaceState ?? "ready";

  return {
    id: session.id,
    title: deriveTitle(session),
    status: runState,
    runState,
    workspaceState,
    launcher: session.launcher,
    repoPath: session.repoPath ?? session.repo_path,
    worktreePath: session.worktreePath ?? session.worktree_path,
    activeNotificationKind: session.activeNotificationKind ?? session.active_notification_kind,
    lastActivityAt: session.lastActivityAt ?? session.last_activity_at,
    lastSeenEventSeq: session.lastSeenEventSeq ?? session.last_seen_event_seq,
    pendingApproval: session.pendingApproval ?? session.pending_approval
  };
}

async function postJson<T>(path: string, body: Record<string, unknown> = {}): Promise<T> {
  const response = await authorizedFetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!response.ok) {
    throw new Error(`request failed: ${path}`);
  }
  return (await response.json()) as T;
}

export async function listSessions(): Promise<{ sessions: SessionSummary[] }> {
  const response = await authorizedFetch("/sessions");
  if (!response.ok) {
    throw new Error("failed to load sessions");
  }
  const payload = (await response.json()) as { sessions: SessionApiRecord[] };
  return {
    sessions: payload.sessions.map((session) => normalizeSession(session))
  };
}

export async function listRepos(query = ""): Promise<{ repos: RepoSummary[] }> {
  const response = await authorizedFetch(`/repos?query=${encodeURIComponent(query)}`);
  if (!response.ok) {
    throw new Error("failed to load repos");
  }
  return (await response.json()) as { repos: RepoSummary[] };
}

export async function getSession(sessionId: string): Promise<SessionDetail> {
  const response = await authorizedFetch(`/sessions/${sessionId}`);
  if (!response.ok) {
    throw new Error("failed to load session");
  }
  return normalizeSession((await response.json()) as SessionApiRecord);
}

export async function listTimeline(sessionId: string): Promise<{ events: TimelineEvent[] }> {
  const response = await authorizedFetch(`/sessions/${sessionId}/timeline`);
  if (!response.ok) {
    throw new Error("failed to load timeline");
  }
  return (await response.json()) as { events: TimelineEvent[] };
}

export async function sendPrompt(sessionId: string, prompt: string): Promise<void> {
  const response = await authorizedFetch(`/sessions/${sessionId}/prompt`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt })
  });
  if (!response.ok) {
    throw new Error("failed to send prompt");
  }
}

export async function createSession(
  launcher: string,
  repoPath: string,
  prompt: string
): Promise<SessionDetail> {
  return normalizeSession(
    await postJson<SessionApiRecord>("/sessions", {
      launcher,
      repoPath,
      prompt
    })
  );
}

export async function resumeSession(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/resume`));
}

export async function cancelSession(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/cancel`));
}

export async function resetSession(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/reset`));
}

export async function archiveSession(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/archive`));
}

export async function approveSessionApproval(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/approval/approve`));
}

export async function denySessionApproval(sessionId: string): Promise<SessionDetail> {
  return normalizeSession(await postJson<SessionApiRecord>(`/sessions/${sessionId}/approval/deny`));
}

export async function markSessionSeen(sessionId: string, lastSeenEventSeq: number): Promise<void> {
  const response = await authorizedFetch(`/sessions/${sessionId}/seen`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lastSeenEventSeq })
  });
  if (!response.ok) {
    throw new Error("failed to update seen cursor");
  }
}

export async function markAppSeen(lastSeenAt: string): Promise<void> {
  const response = await authorizedFetch("/seen/app", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lastSeenAt })
  });
  if (!response.ok) {
    throw new Error("failed to mark app seen");
  }
}

export async function getServerInfo(): Promise<{
  vapidPublicKey: string;
  availableLaunchers: string[];
  projectRoot: string;
  transport: string;
}> {
  const response = await authorizedFetch("/server-info");
  if (!response.ok) {
    throw new Error("failed to load server info");
  }
  return (await response.json()) as {
    vapidPublicKey: string;
    availableLaunchers: string[];
    projectRoot: string;
    transport: string;
  };
}
