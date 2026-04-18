import asyncio
import contextlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import acp

from allhands_host.models import SessionRecord
from allhands_host.store import SessionStore


class AttentionRequiredError(RuntimeError):
    pass


class RecordingClient:
    def __init__(self, session: SessionRecord, store: SessionStore):
        self.session = session
        self.store = store
        self.attention_required: AttentionRequiredError | None = None

    async def request_permission(self, options, session_id, tool_call, **kwargs):
        self.attention_required = AttentionRequiredError("Agent needs permission to continue.")
        self.store.append_event(
            self.session.id,
            "acp.permission_requested",
            {
                "options": [
                    {
                        "id": option.option_id,
                        "label": getattr(option, "name", option.option_id),
                    }
                    for option in options
                ],
            },
        )
        return acp.RequestPermissionResponse(outcome={"outcome": "cancelled"})

    async def session_update(self, session_id, update, **kwargs):
        if getattr(update, "session_update", None) == "agent_thought_chunk":
            text = getattr(update.content, "text", "")
            self.store.append_event(self.session.id, "acp.thought", {"text": text})

    async def write_text_file(self, content, path, session_id, **kwargs):
        return None

    async def read_text_file(self, path, session_id, limit=None, line=None, **kwargs):
        raise NotImplementedError

    async def create_terminal(self, command, session_id, args=None, cwd=None, env=None, output_byte_limit=None, **kwargs):
        raise NotImplementedError

    async def terminal_output(self, session_id, terminal_id, **kwargs):
        raise NotImplementedError

    async def release_terminal(self, session_id, terminal_id, **kwargs):
        return None

    async def wait_for_terminal_exit(self, session_id, terminal_id, **kwargs):
        raise NotImplementedError

    async def kill_terminal(self, session_id, terminal_id, **kwargs):
        return None

    async def ext_method(self, method, params):
        raise NotImplementedError(method)

    async def ext_notification(self, method, params):
        return None

    def on_connect(self, conn):
        self.conn = conn

    def consume_attention_required(self) -> AttentionRequiredError | None:
        current = self.attention_required
        self.attention_required = None
        return current


@dataclass
class Attachment:
    session: SessionRecord
    store: SessionStore
    client: RecordingClient
    connection: Any
    process: asyncio.subprocess.Process
    agent_session_id: str

    async def prompt(self, text: str):
        try:
            response = await self.connection.prompt(
                prompt=[acp.text_block(text)],
                session_id=self.agent_session_id,
            )
        except Exception:
            attention_required = self.client.consume_attention_required()
            if attention_required is not None:
                raise attention_required
            raise

        attention_required = self.client.consume_attention_required()
        if attention_required is not None:
            raise attention_required
        return response

    async def cancel(self) -> None:
        with contextlib.suppress(Exception):
            await self.connection.cancel(session_id=self.agent_session_id)
        if self.process.returncode is not None:
            return
        self.process.terminate()
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(self.process.wait(), timeout=2)
            return
        self.process.kill()
        with contextlib.suppress(Exception):
            await self.process.wait()


async def attach_and_initialize(
    session: SessionRecord,
    store: SessionStore,
    argv: list[str],
    cwd: Path,
) -> Attachment:
    process = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(cwd),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    client = RecordingClient(session=session, store=store)
    connection = acp.connect_to_agent(client, process.stdin, process.stdout)
    store.append_event(session.id, "session.attached", {})
    await connection.initialize(protocol_version=acp.PROTOCOL_VERSION)
    store.append_event(session.id, "acp.initialized", {})
    new_session = await connection.new_session(cwd=str(cwd))

    return Attachment(
        session=session,
        store=store,
        client=client,
        connection=connection,
        process=process,
        agent_session_id=new_session.sessionId,
    )


async def attach_and_resume(
    session: SessionRecord,
    store: SessionStore,
    argv: list[str],
    cwd: Path,
    session_token: str,
) -> Attachment:
    process = await asyncio.create_subprocess_exec(
        *argv,
        cwd=str(cwd),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    client = RecordingClient(session=session, store=store)
    connection = acp.connect_to_agent(client, process.stdin, process.stdout)
    store.append_event(session.id, "session.attached", {"mode": "resume"})
    await connection.initialize(protocol_version=acp.PROTOCOL_VERSION)
    store.append_event(session.id, "acp.initialized", {"mode": "resume"})
    await connection.resume_session(cwd=str(cwd), session_id=session_token)

    return Attachment(
        session=session,
        store=store,
        client=client,
        connection=connection,
        process=process,
        agent_session_id=session_token,
    )
