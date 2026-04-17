import styles from "./prompt-box.module.css";

export function PromptBox() {
  return (
    <form class={styles.box}>
      <textarea class={styles.input} name="prompt" rows={4} />
      <button type="submit">Send</button>
    </form>
  );
}
