import { For, Show, onMount } from "solid-js";

import type { RepoSummary } from "../lib/api";
import styles from "./new-session-sheet.module.css";

export type NewSessionSheetProps = {
  query: string;
  repos: RepoSummary[];
  selectedRepoPath: string;
  launchers: string[];
  launcher: string;
  prompt: string;
  repoLoading: boolean;
  repoError: string | null;
  launcherError: string | null;
  submitError: string | null;
  submitting: boolean;
  canSubmit: boolean;
  onClose: () => void;
  onQueryInput: (value: string) => void;
  onRetryRepos: () => void;
  onSelectRepo: (repo: RepoSummary) => void;
  onLauncherChange: (value: string) => void;
  onPromptInput: (value: string) => void;
  onSubmit: () => void | Promise<void>;
};

export function NewSessionSheet(props: NewSessionSheetProps) {
  let repoInput!: HTMLInputElement;

  onMount(() => {
    repoInput.focus();
  });

  return (
    <div class={styles.backdrop}>
      <section aria-label="New session" aria-modal="true" class={styles.sheet} role="dialog">
        <div class={styles.header}>
          <h3>New session</h3>
          <button class={styles.close} type="button" onClick={props.onClose}>
            Close
          </button>
        </div>

        <label class={styles.field}>
          <span>Repository</span>
          <input
            ref={repoInput}
            aria-label="Repository"
            class={styles.input}
            value={props.query}
            onInput={(event) => void props.onQueryInput(event.currentTarget.value)}
            placeholder="Search repositories"
          />
        </label>

        <Show when={props.repoLoading}>
          <p class={styles.hint}>Loading repositories...</p>
        </Show>

        <Show when={props.repoError}>
          <div class={styles.errorRow}>
            <p class={styles.error}>{props.repoError}</p>
            <button type="button" onClick={props.onRetryRepos}>
              Retry repository search
            </button>
          </div>
        </Show>

        <div class={styles.repoList}>
          <For each={props.repos}>
            {(repo) => (
              <button
                class={styles.repoButton}
                classList={{ [styles.repoSelected]: props.selectedRepoPath === repo.path }}
                type="button"
                onClick={() => props.onSelectRepo(repo)}
              >
                <span>{repo.name}</span>
                <Show when={props.selectedRepoPath === repo.path}>
                  <span class={styles.selectedBadge}>Selected</span>
                </Show>
              </button>
            )}
          </For>
        </div>

        <label class={styles.field}>
          <span>Launcher</span>
          <select
            class={styles.select}
            value={props.launcher}
            onChange={(event) => props.onLauncherChange(event.currentTarget.value)}
          >
            <For each={props.launchers}>{(launcher) => <option value={launcher}>{launcher}</option>}</For>
          </select>
        </label>

        <Show when={props.launcherError}>
          <p class={styles.error}>{props.launcherError}</p>
        </Show>

        <label class={styles.field}>
          <span>Prompt</span>
          <textarea
            aria-label="Prompt"
            class={styles.textarea}
            rows={5}
            value={props.prompt}
            onInput={(event) => props.onPromptInput(event.currentTarget.value)}
            placeholder="Describe what the session should do"
          />
        </label>

        <Show when={props.submitError}>
          <p class={styles.error}>{props.submitError}</p>
        </Show>

        <div class={styles.footer}>
          <button
            class={styles.primary}
            type="button"
            disabled={!props.canSubmit || props.submitting}
            onClick={() => void props.onSubmit()}
          >
            {props.submitting ? "Creating..." : "Create session"}
          </button>
        </div>
      </section>
    </div>
  );
}
