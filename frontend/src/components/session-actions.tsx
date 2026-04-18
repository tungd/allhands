import styles from "./session-actions.module.css";

export function SessionActions(props: {
  onResume: () => void;
  onCancel: () => void;
  onReset: () => void;
  onArchive: () => void;
}) {
  return (
    <section class={styles.actions} aria-label="Session actions">
      <button type="button" onClick={props.onResume}>
        Resume
      </button>
      <button type="button" onClick={props.onCancel}>
        Cancel run
      </button>
      <button type="button" onClick={props.onReset}>
        Reset workspace
      </button>
      <button type="button" onClick={props.onArchive}>
        Archive
      </button>
    </section>
  );
}
