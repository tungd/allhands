import { children, createEffect, onCleanup, type JSX } from "solid-js";

import { A, Route, Router, useLocation, useNavigate } from "@solidjs/router";

import "./styles/tokens.css";
import "./styles/app.css";

import { NewSessionSheet } from "./components/new-session-sheet";
import { AUTH_REQUIRED_EVENT, buildLoginPath, clearStoredCredentials, getStoredCredentials } from "./lib/auth";
import { createNewSessionState } from "./lib/new-session-store";
import { createSessionsState } from "./lib/session-store";
import { ControlRoom } from "./routes/control-room";
import { Inbox } from "./routes/inbox";
import { LoginRoute } from "./routes/login";
import { SessionRoute } from "./routes/session";

function SessionPage() {
  return <SessionRoute />;
}

function AppShell(props: { children: JSX.Element }) {
  const location = useLocation();
  const navigate = useNavigate();

  createEffect(() => {
    const handleAuthRequired = () => {
      navigate(buildLoginPath(`${location.pathname}${location.search}`), { replace: true });
    };

    window.addEventListener(AUTH_REQUIRED_EVENT, handleAuthRequired);
    onCleanup(() => {
      window.removeEventListener(AUTH_REQUIRED_EVENT, handleAuthRequired);
    });
  });

  const showNavigation = () => location.pathname !== "/login";

  return (
    <main class={`app-shell${showNavigation() ? "" : " app-shell-auth"}`}>
      {showNavigation() ? (
        <header class="topbar">
          <h1>Control Room</h1>
          <nav>
            <A href="/control-room">Control Room</A>
            <A href="/inbox">Inbox</A>
            <button
              class="topbar-button"
              type="button"
              onClick={() => {
                clearStoredCredentials();
                navigate(buildLoginPath("/control-room"), { replace: true });
              }}
            >
              Sign out
            </button>
          </nav>
        </header>
      ) : null}
      {props.children}
    </main>
  );
}

export function App(props: { vapidPublicKey?: string }) {
  function ProtectedRoute(props: { children: JSX.Element }) {
    const navigate = useNavigate();
    const location = useLocation();
    const content = children(() => props.children);

    createEffect(() => {
      if (getStoredCredentials() == null) {
        navigate(buildLoginPath(`${location.pathname}${location.search}`), { replace: true });
      }
    });

    return getStoredCredentials() == null ? null : content();
  }

  function HomePage() {
    const navigate = useNavigate();

    createEffect(() => {
      navigate(getStoredCredentials() == null ? buildLoginPath("/control-room") : "/control-room", { replace: true });
    });

    return null;
  }

  function ControlRoomPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");

    return (
      <ControlRoom sessions={state().sessions} />
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

  function ControlRoomNewPage() {
    const state = createSessionsState(props.vapidPublicKey ?? "");

    return (
      <ControlRoom sessions={state().sessions} sheetOpen>
        <NewSessionPage />
      </ControlRoom>
    );
  }

  function ProtectedControlRoomPage() {
    return (
      <ProtectedRoute>
        <ControlRoomPage />
      </ProtectedRoute>
    );
  }

  function ProtectedControlRoomNewPage() {
    return (
      <ProtectedRoute>
        <ControlRoomNewPage />
      </ProtectedRoute>
    );
  }

  function ProtectedInboxPage() {
    return (
      <ProtectedRoute>
        <InboxPage />
      </ProtectedRoute>
    );
  }

  function ProtectedSessionPage() {
    return (
      <ProtectedRoute>
        <SessionPage />
      </ProtectedRoute>
    );
  }

  return (
    <Router root={AppShell}>
      <Route path="/login" component={LoginRoute} />
      <Route path="/control-room" component={ProtectedControlRoomPage} />
      <Route path="/control-room/new" component={ProtectedControlRoomNewPage} />
      <Route path="/inbox" component={ProtectedInboxPage} />
      <Route path="/session/:sessionId" component={ProtectedSessionPage} />
      <Route path="/*all" component={HomePage} />
    </Router>
  );
}
