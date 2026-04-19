import { createMemo, createSignal } from "solid-js";
import { useLocation, useNavigate } from "@solidjs/router";

import { getServerInfo } from "../lib/api";
import { resolveNextPath, storeCredentials } from "../lib/auth";
import styles from "./login.module.css";

export function LoginRoute() {
  const navigate = useNavigate();
  const location = useLocation();
  const [username, setUsername] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [error, setError] = createSignal<string | null>(null);
  const [submitting, setSubmitting] = createSignal(false);

  const nextPath = createMemo(() => {
    const params = new URLSearchParams(location.search);
    return resolveNextPath(params.get("next"));
  });

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    storeCredentials({
      username: username().trim(),
      password: password()
    });

    try {
      await getServerInfo();
      navigate(nextPath(), { replace: true });
    } catch {
      setError("Invalid username or password.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <section class={styles.shell}>
      <div class={styles.panel}>
        <p class={styles.eyebrow}>Secure Access</p>
        <h2 class={styles.title}>Sign in to All Hands</h2>
        <p class={styles.copy}>
          Enter the HTTP Basic Auth credentials for this host. The app stores them locally and adds the
          authorization header to protected API requests.
        </p>
        <form class={styles.form} onSubmit={(event) => void handleSubmit(event)}>
          <label class={styles.field}>
            <span>Username</span>
            <input
              autocomplete="username"
              name="username"
              required
              value={username()}
              onInput={(event) => setUsername(event.currentTarget.value)}
            />
          </label>
          <label class={styles.field}>
            <span>Password</span>
            <input
              autocomplete="current-password"
              name="password"
              required
              type="password"
              value={password()}
              onInput={(event) => setPassword(event.currentTarget.value)}
            />
          </label>
          {error() ? <p class={styles.error}>{error()}</p> : null}
          <button class={styles.submit} disabled={submitting()} type="submit">
            {submitting() ? "Signing in..." : "Sign in"}
          </button>
        </form>
      </div>
    </section>
  );
}
