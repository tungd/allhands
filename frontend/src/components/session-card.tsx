import styles from "./session-card.module.css";

export type SessionCardProps = {
  title: string;
  status: string;
};

export function SessionCard(props: SessionCardProps) {
  return (
    <article aria-label="Focused session" class={styles.card}>
      <h3>{props.title}</h3>
      <div class={styles.meta}>{props.status}</div>
    </article>
  );
}
