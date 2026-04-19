import { For } from "solid-js";
import { useNavigate } from "@solidjs/router";

import styles from "./session-tray.module.css";
export type SessionTrayProps = {
  sessions: Array<{ id: string; title: string }>;
};

export function SessionTray(props: SessionTrayProps) {
  const navigate = useNavigate();

  return (
    <div class={styles.tray}>
      <For each={props.sessions}>
        {(session) => (
          <button
            class={styles.button}
            type="button"
            onClick={() => navigate(`/session/${session.id}`)}
          >
            {session.title}
          </button>
        )}
      </For>
    </div>
  );
}
