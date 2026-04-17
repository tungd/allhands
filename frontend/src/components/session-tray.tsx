import { For } from "solid-js";

import styles from "./session-tray.module.css";

export type SessionTrayProps = {
  sessions: Array<{ id: string; title: string }>;
};

export function SessionTray(props: SessionTrayProps) {
  return (
    <div class={styles.tray}>
      <For each={props.sessions}>
        {(session) => (
          <button class={styles.button} type="button">
            {session.title}
          </button>
        )}
      </For>
    </div>
  );
}
