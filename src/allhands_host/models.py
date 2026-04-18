from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import uuid4


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


@dataclass(frozen=True)
class SessionRecord:
    id: str
    launcher: str
    repo_path: str
    worktree_path: str
    status: str
    workspace_state: str
    last_bound_agent_session_id: str | None
    last_activity_at: str
    last_notified_at: str | None
    active_notification_kind: str
    last_seen_event_seq: int
    created_at: str
    updated_at: str

    @classmethod
    def new(cls, launcher: str, repo_path: str, worktree_path: str) -> "SessionRecord":
        now = utc_now()
        return cls(
            id=f"session_{uuid4().hex[:12]}",
            launcher=launcher,
            repo_path=repo_path,
            worktree_path=worktree_path,
            status="created",
            workspace_state="ready",
            last_bound_agent_session_id=None,
            last_activity_at=now,
            last_notified_at=None,
            active_notification_kind="none",
            last_seen_event_seq=0,
            created_at=now,
            updated_at=now,
        )


@dataclass(frozen=True)
class EventRecord:
    session_id: str
    seq: int
    type: str
    payload: dict
    created_at: str
