from importlib import import_module
import json

import pytest
from tornado.httpserver import HTTPServer
from tornado.testing import bind_unused_port
import tornado.web
from tornado.websocket import WebSocketHandler


def load_codex_client_module():
    try:
        return import_module("allhands_host.codex_client")
    except ModuleNotFoundError as exc:
        pytest.fail(f"expected allhands_host.codex_client module: {exc}")


@pytest.mark.asyncio
async def test_client_initializes_before_thread_start():
    module = load_codex_client_module()
    seen_methods: list[str] = []

    class FakeCodexHandler(WebSocketHandler):
        def initialize(self, seen_methods: list[str]) -> None:
            self.seen_methods = seen_methods

        def check_origin(self, origin: str) -> bool:
            return True

        async def open(self) -> None:
            assert self.request.headers["Authorization"].startswith("Bearer ")

        async def on_message(self, message: str) -> None:
            payload = json.loads(message)
            self.seen_methods.append(payload["method"])
            if payload["method"] == "initialize":
                await self.write_message(
                    json.dumps(
                        {
                            "id": payload["id"],
                            "result": {
                                "userAgent": "codex",
                                "codexHome": "/tmp/.codex",
                                "platformFamily": "unix",
                                "platformOs": "darwin",
                            },
                        }
                    )
                )
            elif payload["method"] == "thread/start":
                await self.write_message(json.dumps({"id": payload["id"], "result": {"thread": {"id": "thr_123"}}}))
                self.close()

    socket, port = bind_unused_port()
    server = HTTPServer(tornado.web.Application([(r"/", FakeCodexHandler, {"seen_methods": seen_methods})]))
    server.add_sockets([socket])

    client = module.CodexAppServerClient(endpoint=f"ws://127.0.0.1:{port}/", token="secret")
    try:
        await client.connect()
        thread = await client.thread_start(cwd="/tmp/projects/api")
    finally:
        await client.close()
        server.stop()
        socket.close()

    assert thread["id"] == "thr_123"
    assert seen_methods == ["initialize", "initialized", "thread/start"]
