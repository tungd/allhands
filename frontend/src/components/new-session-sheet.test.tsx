import { fireEvent, render, screen } from "@solidjs/testing-library";

import { NewSessionSheet } from "./new-session-sheet";


test("focuses the repo search field and disables submit until the form is valid", async () => {
  render(() => (
    <NewSessionSheet
      query=""
      repos={[{ name: "api", path: "/tmp/projects/api" }]}
      selectedRepoPath=""
      launchers={["codex"]}
      launcher="codex"
      prompt=""
      repoLoading={false}
      repoError={null}
      launcherError={null}
      submitError={null}
      submitting={false}
      canSubmit={false}
      onClose={() => undefined}
      onQueryInput={() => undefined}
      onRetryRepos={() => undefined}
      onSelectRepo={() => undefined}
      onLauncherChange={() => undefined}
      onPromptInput={() => undefined}
      onSubmit={() => undefined}
    />
  ));

  const search = screen.getByLabelText("Repository");
  expect(document.activeElement).toBe(search);
  expect((screen.getByRole("button", { name: "Create session" }) as HTMLButtonElement).disabled).toBe(true);
});


test("renders retry and selection affordances", async () => {
  const onRetryRepos = vi.fn();
  const onSelectRepo = vi.fn();

  render(() => (
    <NewSessionSheet
      query="api"
      repos={[{ name: "api", path: "/tmp/projects/api" }]}
      selectedRepoPath="/tmp/projects/api"
      launchers={["codex"]}
      launcher="codex"
      prompt="Ship it"
      repoLoading={false}
      repoError="Failed to load repositories."
      launcherError={null}
      submitError={null}
      submitting={false}
      canSubmit={true}
      onClose={() => undefined}
      onQueryInput={() => undefined}
      onRetryRepos={onRetryRepos}
      onSelectRepo={onSelectRepo}
      onLauncherChange={() => undefined}
      onPromptInput={() => undefined}
      onSubmit={() => undefined}
    />
  ));

  fireEvent.click(screen.getByRole("button", { name: "Retry repository search" }));
  fireEvent.click(screen.getByRole("button", { name: /^api/ }));

  expect(onRetryRepos).toHaveBeenCalledTimes(1);
  expect(onSelectRepo).toHaveBeenCalledWith({ name: "api", path: "/tmp/projects/api" });
  expect(screen.getByText("Selected")).toBeTruthy();
});
