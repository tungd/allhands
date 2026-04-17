from pathlib import Path
import sys

import pytest

from allhands_host.acp_attachment import attach_and_initialize
from allhands_host.db import Database
from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


@pytest.mark.asyncio
async def test_attachment_records_initialize_and_prompt_events(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new("codex", "/tmp/repo", "/tmp/repo/.worktrees/session_1")
    store.create_session(session)

    fixture = Path("tests/fixtures/fake_acp_agent.py").resolve()
    attachment = await attach_and_initialize(
        session=session,
        store=store,
        argv=[sys.executable, str(fixture)],
        cwd=tmp_path,
    )
    await attachment.prompt("hello")

    events = store.list_events(session.id, after_seq=0)
    assert [event.type for event in events] == [
        "session.attached",
        "acp.initialized",
        "acp.thought",
    ]
