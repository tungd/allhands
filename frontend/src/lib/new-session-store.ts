import { createMemo, createSignal, onMount } from "solid-js";

import { createSession, getServerInfo, listRepos, type RepoSummary } from "./api";


export function createNewSessionState() {
  const [query, setQuery] = createSignal("");
  const [repos, setRepos] = createSignal<RepoSummary[]>([]);
  const [selectedRepo, setSelectedRepo] = createSignal<RepoSummary | null>(null);
  const [launchers, setLaunchers] = createSignal<string[]>([]);
  const [launcher, setLauncher] = createSignal("");
  const [prompt, setPrompt] = createSignal("");
  const [repoLoading, setRepoLoading] = createSignal(false);
  const [repoError, setRepoError] = createSignal<string | null>(null);
  const [launcherError, setLauncherError] = createSignal<string | null>(null);
  const [submitting, setSubmitting] = createSignal(false);
  const [submitError, setSubmitError] = createSignal<string | null>(null);

  async function loadLaunchers() {
    try {
      const info = await getServerInfo();
      setLaunchers(info.availableLaunchers);
      if (!launcher() && info.availableLaunchers.length > 0) {
        setLauncher(info.availableLaunchers[0]!);
      }
      setLauncherError(null);
    } catch {
      setLaunchers([]);
      setLauncher("");
      setLauncherError("Failed to load launchers.");
    }
  }

  async function refreshRepos(nextQuery = query()) {
    setRepoLoading(true);
    try {
      const response = await listRepos(nextQuery);
      setRepos(response.repos);
      setRepoError(null);
    } catch {
      setRepos([]);
      setRepoError("Failed to load repositories.");
    } finally {
      setRepoLoading(false);
    }
  }

  async function updateQuery(nextQuery: string) {
    setQuery(nextQuery);
    await refreshRepos(nextQuery);
  }

  function selectRepo(repo: RepoSummary) {
    setSelectedRepo(repo);
    setQuery(repo.name);
    setRepoError(null);
  }

  const canSubmit = createMemo(
    () => selectedRepo() != null && launcher() !== "" && prompt().trim() !== "" && !submitting()
  );

  async function submit() {
    if (!canSubmit()) {
      return null;
    }

    setSubmitting(true);
    setSubmitError(null);
    try {
      const session = await createSession(launcher(), selectedRepo()!.path, prompt().trim());
      return session.id;
    } catch {
      setSubmitError("Failed to create session.");
      return null;
    } finally {
      setSubmitting(false);
    }
  }

  onMount(() => {
    void loadLaunchers();
    void refreshRepos("");
  });

  return {
    query,
    repos,
    selectedRepo,
    launchers,
    launcher,
    prompt,
    repoLoading,
    repoError,
    launcherError,
    submitting,
    submitError,
    canSubmit,
    updateQuery,
    selectRepo,
    setLauncher,
    setPrompt,
    refreshRepos,
    submit
  };
}
