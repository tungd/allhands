export type SessionSummary = {
  id: string;
  title: string;
  status: string;
};

type SessionApiRecord = {
  id: string;
  status: string;
  title?: string;
  repoPath?: string;
  repo_path?: string;
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

export async function listSessions(): Promise<{ sessions: SessionSummary[] }> {
  const response = await fetch("/sessions");
  if (!response.ok) throw new Error("failed to load sessions");
  const payload = (await response.json()) as { sessions: SessionApiRecord[] };
  return {
    sessions: payload.sessions.map((session) => ({
      id: session.id,
      title: deriveTitle(session),
      status: session.status
    }))
  };
}

export async function sendPrompt(sessionId: string, prompt: string): Promise<void> {
  const response = await fetch(`/sessions/${sessionId}/prompt`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt })
  });
  if (!response.ok) throw new Error("failed to send prompt");
}
