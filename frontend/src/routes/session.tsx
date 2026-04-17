import { PromptBox } from "../components/prompt-box";
import { Timeline } from "../components/timeline";

export type SessionRouteProps = {
  items: Array<{ id: string; body: string }>;
};

export function SessionRoute(props: SessionRouteProps) {
  return (
    <section>
      <h2>Session</h2>
      <Timeline items={props.items} />
      <PromptBox />
    </section>
  );
}
