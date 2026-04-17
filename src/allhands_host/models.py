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
