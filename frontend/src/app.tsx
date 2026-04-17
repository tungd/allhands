import type { JSX } from "solid-js";

import { A, Route, Router } from "@solidjs/router";

import "./styles/tokens.css";
import "./styles/app.css";

import { createSessionsState } from "./lib/session-store";
import { ControlRoom } from "./routes/control-room";
import { Inbox } from "./routes/inbox";
import { SessionRoute } from "./routes/session";


function ControlRoomPage() {
  const state = createSessionsState();
  return <ControlRoom sessions={state().sessions} />;
}


function InboxPage() {
  const state = createSessionsState();
  return <Inbox sessions={state().sessions} />;
}


function SessionPage() {
  return <SessionRoute items={[]} />;
}

function AppShell(props: { children: JSX.Element }) {
  return (
    <main class="app-shell">
      <header class="topbar">
        <h1>Control Room</h1>
        <nav>
          <A href="/control-room">Control Room</A>
          <A href="/inbox">Inbox</A>
        </nav>
      </header>
      {props.children}
    </main>
  );
}

export function App() {
  return (
    <Router root={AppShell}>
      <Route path="/" component={ControlRoomPage} />
      <Route path="/control-room" component={ControlRoomPage} />
      <Route path="/inbox" component={InboxPage} />
      <Route path="/session/:sessionId" component={SessionPage} />
    </Router>
  );
}
