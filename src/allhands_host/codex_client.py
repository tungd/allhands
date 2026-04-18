import asyncio
from collections.abc import Awaitable, Callable
import json

from tornado.httpclient import HTTPRequest
from tornado.websocket import WebSocketClientConnection, websocket_connect


class CodexRpcError(RuntimeError):
    pass


class CodexAppServerClient:
    def __init__(
        self,
        endpoint: str,
        token: str,
        on_server_request: Callable[[dict], Awaitable[None]] | None = None,
    ):
        self.endpoint = endpoint
        self.token = token
        self.on_server_request = on_server_request
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._ws: WebSocketClientConnection | None = None
        self._reader_task: asyncio.Task[None] | None = None

    async def connect(self) -> None:
        self._ws = await websocket_connect(
            HTTPRequest(self.endpoint, headers={"Authorization": f"Bearer {self.token}"})
        )
        self._reader_task = asyncio.create_task(self._read_messages())
        await self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "allhands_host",
                    "title": "All Hands Host",
                    "version": "0.1.0",
                }
            },
        )
        await self.notify("initialized", {})

    async def close(self) -> None:
        if self._reader_task is not None:
            self._reader_task.cancel()
            await asyncio.gather(self._reader_task, return_exceptions=True)
            self._reader_task = None
        if self._ws is not None:
            self._ws.close()
            self._ws = None
        for future in self._pending.values():
            if not future.done():
                future.cancel()
        self._pending.clear()

    async def request(self, method: str, params: dict | None = None) -> dict:
        if self._ws is None:
            raise RuntimeError("codex client is not connected")
        self._next_id += 1
        request_id = self._next_id
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        await self._ws.write_message(
            json.dumps({"id": request_id, "method": method, "params": params or {}})
        )
        return await future

    async def notify(self, method: str, params: dict | None = None) -> None:
        if self._ws is None:
            raise RuntimeError("codex client is not connected")
        await self._ws.write_message(json.dumps({"method": method, "params": params or {}}))

    async def respond(self, request_id: object, result: dict | None = None) -> None:
        if self._ws is None:
            raise RuntimeError("codex client is not connected")
        await self._ws.write_message(json.dumps({"id": request_id, "result": result or {}}))

    async def thread_start(self, cwd: str) -> dict:
        payload = await self.request("thread/start", {"cwd": cwd})
        return payload["thread"]

    async def thread_resume(self, thread_id: str) -> dict:
        payload = await self.request("thread/resume", {"threadId": thread_id})
        return payload["thread"]

    async def turn_start(self, thread_id: str, input_items: list[dict], cwd: str) -> dict:
        payload = await self.request(
            "turn/start",
            {
                "threadId": thread_id,
                "input": input_items,
                "cwd": cwd,
                "approvalPolicy": "unlessTrusted",
                "approvalsReviewer": "user",
                "sandboxPolicy": {
                    "type": "workspaceWrite",
                    "writableRoots": [cwd],
                    "networkAccess": False,
                },
            },
        )
        return payload["turn"]

    async def turn_interrupt(self, thread_id: str, turn_id: str) -> None:
        await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

    async def thread_archive(self, thread_id: str) -> None:
        await self.request("thread/archive", {"threadId": thread_id})

    async def _read_messages(self) -> None:
        assert self._ws is not None
        while True:
            message = await self._ws.read_message()
            if message is None:
                break
            payload = json.loads(message)

            if "id" in payload and "method" not in payload:
                future = self._pending.pop(int(payload["id"]), None)
                if future is None or future.done():
                    continue
                if "error" in payload:
                    future.set_exception(CodexRpcError(str(payload["error"])))
                else:
                    future.set_result(payload["result"])
                continue

            if self.on_server_request is not None:
                await self.on_server_request(payload)
