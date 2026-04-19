import { A } from "@solidjs/router";

import styles from "./session-card.module.css";

export type SessionCardProps = {
  id: string;
  title: string;
  status: string;
};

export function SessionCard(props: SessionCardProps) {
  return (
    <A href={`/session/${props.id}`}>
      <article aria-label="Focused session" class={styles.card}>
        <h3>{props.title}</h3>
        <div class={styles.meta}>{props.status}</div>
      </article>
    </A>
  );
}
