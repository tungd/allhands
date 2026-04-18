import type { PendingApproval } from "../lib/api";
import styles from "./approval-card.module.css";

export function ApprovalCard(props: {
  approval: PendingApproval;
  onApprove: () => void;
  onDeny: () => void;
}) {
  return (
    <section class={styles.card} aria-label="Pending approval">
      <header class={styles.header}>
        <p class={styles.eyebrow}>Approval required</p>
        <h3 class={styles.summary}>{props.approval.summary}</h3>
        {props.approval.reason ? <p class={styles.reason}>{props.approval.reason}</p> : null}
      </header>
      {props.approval.command ? <pre class={styles.command}>{props.approval.command.join(" ")}</pre> : null}
      <div class={styles.meta}>
        {props.approval.cwd ? <span>{props.approval.cwd}</span> : null}
        {props.approval.grantRoot ? <span>{props.approval.grantRoot}</span> : null}
      </div>
      <div class={styles.actions}>
        <button class={styles.approve} type="button" onClick={props.onApprove}>
          Approve
        </button>
        <button class={styles.deny} type="button" onClick={props.onDeny}>
          Deny
        </button>
      </div>
    </section>
  );
}
