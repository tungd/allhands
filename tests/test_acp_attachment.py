import asyncio
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

    deadline = asyncio.get_running_loop().time() + 1.0
    while True:
        events = store.list_events(session.id, after_seq=0)
        if [event.type for event in events] == [
            "session.attached",
            "acp.initialized",
            "acp.thought",
        ]:
            break
        if asyncio.get_running_loop().time() >= deadline:
            break
        await asyncio.sleep(0.01)

    assert [event.type for event in events] == [
        "session.attached",
        "acp.initialized",
        "acp.thought",
    ]


@pytest.mark.asyncio
async def test_attachment_fails_fast_when_agent_exits_before_initialize(tmp_path: Path):
    db = Database(tmp_path / "allhands.sqlite3")
    db.migrate()
    store = SessionStore(db)
    session = SessionRecord.new("codex", "/tmp/repo", "/tmp/repo/.worktrees/session_1")
    store.create_session(session)

    with pytest.raises(RuntimeError, match="unexpected argument '--experimental-acp' found"):
        await asyncio.wait_for(
            attach_and_initialize(
                session=session,
                store=store,
                argv=[
                    sys.executable,
                    "-c",
                    "import sys; sys.stderr.write(\"error: unexpected argument '--experimental-acp' found\\n\");"
                    " sys.stderr.flush(); sys.exit(2)",
                ],
                cwd=tmp_path,
            ),
            timeout=1,
        )
