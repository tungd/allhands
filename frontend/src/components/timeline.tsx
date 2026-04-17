import { For } from "solid-js";

import styles from "./timeline.module.css";

export type TimelineProps = {
  items: Array<{ id: string; body: string }>;
};

export function Timeline(props: TimelineProps) {
  return (
    <div class={styles.timeline}>
      <For each={props.items}>{(item) => <div>{item.body}</div>}</For>
    </div>
  );
}
