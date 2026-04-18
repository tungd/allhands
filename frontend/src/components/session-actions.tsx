import styles from "./session-actions.module.css";

export function SessionActions(props: {
  onResume: () => void;
  onCancel: () => void;
  onReset: () => void;
  onArchive: () => void;
  disabled?: boolean;
}) {
  return (
    <section class={styles.actions} aria-label="Session actions">
      <button type="button" onClick={props.onResume} disabled={props.disabled}>
        Resume
      </button>
      <button type="button" onClick={props.onCancel} disabled={props.disabled}>
        Cancel run
      </button>
      <button type="button" onClick={props.onReset} disabled={props.disabled}>
        Reset workspace
      </button>
      <button type="button" onClick={props.onArchive} disabled={props.disabled}>
        Archive
      </button>
    </section>
  );
}
