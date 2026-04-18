import { renderHook, waitFor } from "@solidjs/testing-library";

vi.mock("./api", () => ({
  getServerInfo: vi.fn(),
  listRepos: vi.fn(),
  createSession: vi.fn()
}));

import { createSession, getServerInfo, listRepos } from "./api";
import { createNewSessionState } from "./new-session-store";


test("loads launchers and initial repo results on mount", async () => {
  vi.mocked(getServerInfo).mockResolvedValue({
    vapidPublicKey: "",
    availableLaunchers: ["codex", "pi"],
    projectRoot: "/tmp/projects",
    transport: "sse"
  });
  vi.mocked(listRepos).mockResolvedValue({
    repos: [{ name: "api", path: "/tmp/projects/api" }]
  });

  const { result } = renderHook(() => createNewSessionState());

  await waitFor(() => {
    expect(result.launcher()).toBe("codex");
  });

  expect(result.launchers()).toEqual(["codex", "pi"]);
  expect(result.repos()).toEqual([{ name: "api", path: "/tmp/projects/api" }]);
});


test("submits a trimmed prompt for the selected repo", async () => {
  vi.mocked(getServerInfo).mockResolvedValue({
    vapidPublicKey: "",
    availableLaunchers: ["codex"],
    projectRoot: "/tmp/projects",
    transport: "sse"
  });
  vi.mocked(listRepos).mockResolvedValue({
    repos: [{ name: "api", path: "/tmp/projects/api" }]
  });
  vi.mocked(createSession).mockResolvedValue({
    id: "session-2",
    title: "api",
    status: "running",
    runState: "running",
    workspaceState: "ready"
  });

  const { result } = renderHook(() => createNewSessionState());

  await waitFor(() => {
    expect(result.repos()[0]?.path).toBe("/tmp/projects/api");
  });

  result.selectRepo({ name: "api", path: "/tmp/projects/api" });
  result.setPrompt("  Ship the auth fix  ");

  const sessionId = await result.submit();

  expect(sessionId).toBe("session-2");
  expect(createSession).toHaveBeenCalledWith("codex", "/tmp/projects/api", "Ship the auth fix");
});
