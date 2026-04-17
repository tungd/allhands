import asyncio

import acp


class FakeAgent:
    def __init__(self):
        self.client = None

    def on_connect(self, conn):
        self.client = conn

    async def initialize(self, protocol_version, client_capabilities=None, client_info=None, **kwargs):
        return acp.InitializeResponse(protocolVersion=protocol_version)

    async def new_session(self, cwd, mcp_servers=None, **kwargs):
        return acp.NewSessionResponse(sessionId="fake-session")

    async def prompt(self, prompt, session_id, message_id=None, **kwargs):
        await self.client.session_update(
            session_id=session_id,
            update=acp.update_agent_thought_text("thinking"),
        )
        return acp.PromptResponse(stopReason="end_turn")

    async def load_session(self, cwd, session_id, mcp_servers=None, **kwargs):
        return None

    async def list_sessions(self, cursor=None, cwd=None, **kwargs):
        return acp.ListSessionsResponse(sessions=[], nextCursor=None)

    async def set_session_mode(self, mode_id, session_id, **kwargs):
        return None

    async def set_session_model(self, model_id, session_id, **kwargs):
        return None

    async def set_config_option(self, config_id, session_id, value, **kwargs):
        return None

    async def authenticate(self, method_id, **kwargs):
        return None

    async def fork_session(self, cwd, session_id, mcp_servers=None, **kwargs):
        raise NotImplementedError

    async def resume_session(self, cwd, session_id, mcp_servers=None, **kwargs):
        raise NotImplementedError

    async def close_session(self, session_id, **kwargs):
        return None

    async def cancel(self, session_id, **kwargs):
        return None

    async def ext_method(self, method, params):
        raise NotImplementedError(method)

    async def ext_notification(self, method, params):
        return None


async def main():
    await acp.run_agent(FakeAgent())


if __name__ == "__main__":
    asyncio.run(main())
