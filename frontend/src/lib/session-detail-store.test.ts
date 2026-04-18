import { renderHook, waitFor } from "@solidjs/testing-library";

import { createSessionDetailState } from "./session-detail-store";


class FakeEventSource {
  addEventListener() {
    return undefined;
  }

  close() {
    return undefined;
  }
}


test("loads timeline and disables prompt until resume is available", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/sessions/session-1")) {
      return {
        ok: true,
        json: async () => ({
          id: "session-1",
          repoPath: "/tmp/projects/api",
          runState: "resume_available",
          workspaceState: "missing"
        })
      };
    }
    if (url.endsWith("/sessions/session-1/timeline")) {
      return {
        ok: true,
        json: async () => ({
          events: [
            {
              seq: 1,
              type: "workspace.reset",
              payload: {},
              createdAt: "2026-04-18T00:00:00+00:00"
            }
          ]
        })
      };
    }
    if (url.endsWith("/sessions/session-1/seen")) {
      return {
        ok: true,
        json: async () => ({})
      };
    }
    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("EventSource", FakeEventSource);

  const { result } = renderHook(() => createSessionDetailState("session-1"));

  await waitFor(() => {
    expect(result.detail()?.runState).toBe("resume_available");
  });

  expect(result.timeline()[0]?.type).toBe("workspace.reset");
  expect(result.promptDisabled()).toBe(true);
});


test("approvePending posts to the codex approval endpoint", async () => {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/sessions/session-1")) {
      return {
        ok: true,
        json: async () => ({
          id: "session-1",
          repoPath: "/tmp/projects/api",
          runState: "attention_required",
          workspaceState: "ready",
          pendingApproval: {
            kind: "command",
            summary: "Run npm test",
            command: ["npm", "test"],
            cwd: "/tmp/projects/api/.worktrees/session-1"
          }
        })
      };
    }
    if (url.endsWith("/sessions/session-1/timeline")) {
      return { ok: true, json: async () => ({ events: [] }) };
    }
    if (url.endsWith("/sessions/session-1/approval/approve")) {
      return {
        ok: true,
        json: async () => ({
          id: "session-1",
          repoPath: "/tmp/projects/api",
          runState: "running",
          workspaceState: "ready"
        })
      };
    }
    if (url.endsWith("/sessions/session-1/seen")) {
      return {
        ok: true,
        json: async () => ({})
      };
    }
    throw new Error(`unexpected fetch: ${url}`);
  });

  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("EventSource", FakeEventSource);

  const { result } = renderHook(() => createSessionDetailState("session-1"));

  await waitFor(() => {
    expect(result.detail()?.pendingApproval?.kind).toBe("command");
  });
  await result.approvePending();

  expect(fetchMock).toHaveBeenCalledWith(
    "/sessions/session-1/approval/approve",
    expect.objectContaining({ method: "POST" })
  );
});
