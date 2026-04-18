import type { JSX } from "solid-js";

import { A, Route, Router, useLocation, useNavigate } from "@solidjs/router";

import "./styles/tokens.css";
import "./styles/app.css";

import { NewSessionSheet } from "./components/new-session-sheet";
import { createNewSessionState } from "./lib/new-session-store";
import { createSessionsState } from "./lib/session-store";
import { ControlRoom } from "./routes/control-room";
import { Inbox } from "./routes/inbox";
import { SessionRoute } from "./routes/session";

function SessionPage() {
  return <SessionRoute />;
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

export function App(props: { vapidPublicKey?: string }) {
  function ControlRoomPage(routeProps: { children?: JSX.Element }) {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    const location = useLocation();

    return (
      <ControlRoom sessions={state().sessions} sheetOpen={location.pathname === "/control-room/new"}>
        {routeProps.children}
      </ControlRoom>
    );
  }

  function NewSessionPage() {
    const state = createNewSessionState();
    const navigate = useNavigate();

    return (
      <NewSessionSheet
        query={state.query()}
        repos={state.repos()}
        selectedRepoPath={state.selectedRepo()?.path ?? ""}
        launchers={state.launchers()}
        launcher={state.launcher()}
        prompt={state.prompt()}
        repoLoading={state.repoLoading()}
        repoError={state.repoError()}
        launcherError={state.launcherError()}
        submitError={state.submitError()}
        submitting={state.submitting()}
        canSubmit={state.canSubmit()}
        onClose={() => navigate("/control-room", { replace: true })}
        onQueryInput={(value) => void state.updateQuery(value)}
        onRetryRepos={() => void state.refreshRepos()}
        onSelectRepo={state.selectRepo}
        onLauncherChange={state.setLauncher}
        onPromptInput={state.setPrompt}
        onSubmit={async () => {
          const sessionId = await state.submit();
          if (sessionId) {
            navigate(`/session/${sessionId}`, { replace: true });
          }
        }}
      />
    );
  }

  function InboxPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");
    return <Inbox sessions={state().sessions} />;
  }

  return (
    <Router root={AppShell}>
      <Route path="/" component={ControlRoomPage} />
      <Route path="/control-room" component={ControlRoomPage}>
        <Route path="/new" component={NewSessionPage} />
      </Route>
      <Route path="/inbox" component={InboxPage} />
      <Route path="/session/:sessionId" component={SessionPage} />
    </Router>
  );
}
