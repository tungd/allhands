import { Show } from "solid-js";

import styles from "./prompt-box.module.css";

export function PromptBox(props: {
  disabled?: boolean;
  hint?: string;
  onSubmit?: (prompt: string) => Promise<void> | void;
}) {
  let input!: HTMLTextAreaElement;

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    if (props.disabled || props.onSubmit == null) {
      return;
    }

    const nextPrompt = input.value.trim();
    if (!nextPrompt) {
      return;
    }

    await props.onSubmit(nextPrompt);
    input.value = "";
  }

  return (
    <form class={styles.box} onSubmit={handleSubmit}>
      <textarea
        ref={input}
        class={styles.input}
        name="prompt"
        rows={4}
        disabled={props.disabled}
        placeholder="Send the next instruction"
      />
      <button class={styles.button} type="submit" disabled={props.disabled}>
        Send
      </button>
      <Show when={props.hint}>
        <p class={styles.hint}>{props.hint}</p>
      </Show>
    </form>
  );
}
