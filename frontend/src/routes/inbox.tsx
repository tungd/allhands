import { For } from "solid-js";

export type InboxProps = {
  sessions: Array<{ id: string; title: string; status: string }>;
};

export function Inbox(props: InboxProps) {
  return (
    <section>
      <h2>Inbox</h2>
      <For each={props.sessions}>{(session) => <div>{session.title}</div>}</For>
    </section>
  );
}
