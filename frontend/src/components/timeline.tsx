import { For } from "solid-js";

import { MarkdownContent } from "./markdown-content";
import styles from "./timeline.module.css";

export type TimelineProps = {
  items: Array<{ seq: number; type: string; body: string; markdown?: string; raw?: string; createdAt?: string }>;
  rawMode: boolean;
  onToggleMode: () => void;
};

export function Timeline(props: TimelineProps) {
  return (
    <section class={styles.timeline}>
      <div class={styles.header}>
        <h3>Timeline</h3>
        <button class={styles.toggle} type="button" onClick={props.onToggleMode}>
          {props.rawMode ? "Show curated timeline" : "Show raw events"}
        </button>
      </div>
      <For each={props.items}>
        {(item) => (
          <article class={styles.item}>
            <div class={styles.meta}>
              <span>#{item.seq}</span>
              <span>{item.createdAt ?? ""}</span>
            </div>
            <div class={item.markdown != null && !props.rawMode ? styles.markdown : undefined}>
              {props.rawMode ? item.raw ?? item.type : item.markdown != null ? <MarkdownContent text={item.markdown} /> : item.body}
            </div>
          </article>
        )}
      </For>
    </section>
  );
}
