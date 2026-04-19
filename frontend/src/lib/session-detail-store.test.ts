import { renderHook, waitFor } from "@solidjs/testing-library";

import { createSessionDetailState } from "./session-detail-store";


function createSseStream() {
  const encoder = new TextEncoder();
  let controller: ReadableStreamDefaultController<Uint8Array> | null = null;
  const stream = new ReadableStream<Uint8Array>({
    start(nextController) {
      controller = nextController;
    }
  });

  return {
    stream,
    emit(event: { seq: number; type: string; payload?: Record<string, unknown> }) {
      controller?.enqueue(
        encoder.encode(
          `id: ${event.seq}\nevent: ${event.type}\ndata: ${JSON.stringify(event.payload ?? {})}\n\n`
        )
      );
    },
    close() {
      controller?.close();
    }
  };
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


test("batches seen updates until the session event burst settles", async () => {
  vi.useFakeTimers();
  const events = createSseStream();
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/sessions/session-1/events")) {
      return {
        ok: true,
        body: events.stream
      };
    }
    if (url.endsWith("/sessions/session-1/seen")) {
      return {
        ok: true,
        json: async () => ({})
      };
    }
    throw new Error(`unexpected fetch: ${url} ${JSON.stringify(init)}`);
  });

  vi.stubGlobal("fetch", fetchMock);

  const { cleanup } = renderHook(() =>
    createSessionDetailState("session-1", {
      detail: {
        id: "session-1",
        repoPath: "/tmp/projects/api",
        runState: "running",
        workspaceState: "ready"
      },
      timeline: [
        {
          seq: 1,
          type: "session.bound",
          payload: {},
          createdAt: "2026-04-18T00:00:00+00:00"
        }
      ]
    })
  );

  await Promise.resolve();

  events.emit({ seq: 2, type: "session.bound" });
  await Promise.resolve();
  await vi.advanceTimersByTimeAsync(200);
  events.emit({ seq: 3, type: "session.bound" });
  await Promise.resolve();
  await vi.advanceTimersByTimeAsync(200);
  events.emit({ seq: 4, type: "session.bound" });
  await Promise.resolve();
  await vi.advanceTimersByTimeAsync(200);
  events.emit({ seq: 5, type: "session.bound" });
  await Promise.resolve();
  await vi.advanceTimersByTimeAsync(200);
  events.emit({ seq: 6, type: "session.bound" });
  await Promise.resolve();
  await vi.advanceTimersByTimeAsync(499);

  expect(
    fetchMock.mock.calls.filter(([input]) => {
      const url = typeof input === "string" ? input : input.toString();
      return url.endsWith("/sessions/session-1/seen");
    })
  ).toHaveLength(0);

  await vi.advanceTimersByTimeAsync(1);

  const seenCalls = fetchMock.mock.calls.filter(([input]) => {
    const url = typeof input === "string" ? input : input.toString();
    return url.endsWith("/sessions/session-1/seen");
  });

  expect(seenCalls).toHaveLength(1);
  expect(seenCalls[0]?.[1]).toMatchObject({
    method: "POST",
    body: JSON.stringify({ lastSeenEventSeq: 6 })
  });

  events.close();
  cleanup();
  vi.useRealTimers();
});
