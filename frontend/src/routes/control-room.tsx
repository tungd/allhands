import { SessionCard } from "../components/session-card";
import { SessionTray } from "../components/session-tray";

export type ControlRoomProps = {
  sessions: Array<{ id: string; title: string; status: string }>;
};

export function ControlRoom(props: ControlRoomProps) {
  const focused = () => props.sessions[0];

  return (
    <section>
      <h2>Control Room</h2>
      {focused() ? (
        <SessionCard title={focused()!.title} status={focused()!.status} />
      ) : (
        <article>No sessions yet</article>
      )}
      <SessionTray sessions={props.sessions.map((session) => ({ id: session.id, title: session.title }))} />
    </section>
  );
}
