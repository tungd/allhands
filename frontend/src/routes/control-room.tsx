import type { JSX } from "solid-js";
import { Show } from "solid-js";

import { SessionCard } from "../components/session-card";
import { SessionTray } from "../components/session-tray";
import styles from "./control-room.module.css";

export type ControlRoomProps = {
  sessions: Array<{ id: string; title: string; status: string }>;
  children?: JSX.Element;
  sheetOpen?: boolean;
};

export function ControlRoom(props: ControlRoomProps) {
  const focused = () => props.sessions[0];

  return (
    <section class={styles.room}>
      <div class={styles.header}>
        <h2>Control Room</h2>
        <a class={styles.newSession} href="/control-room/new">
          New session
        </a>
      </div>

      <div classList={{ [styles.content]: true, [styles.dimmed]: props.sheetOpen ?? false }}>
        {focused() ? (
          <SessionCard id={focused()!.id} title={focused()!.title} status={focused()!.status} />
        ) : (
          <article class={styles.empty}>No sessions yet</article>
        )}
        <SessionTray sessions={props.sessions.map((session) => ({ id: session.id, title: session.title }))} />
      </div>

      <Show when={props.children}>{props.children}</Show>
    </section>
  );
}
