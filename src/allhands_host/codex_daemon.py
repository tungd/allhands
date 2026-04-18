import asyncio
from dataclasses import dataclass
import secrets

from allhands_host.config import Settings
from tornado.httpclient import AsyncHTTPClient, HTTPClientError, HTTPRequest


@dataclass(frozen=True)
class CodexDaemonHandle:
    endpoint: str
    token: str


class CodexDaemonManager:
    def __init__(
        self,
        settings: Settings,
        probe_ready=None,
        spawn_process=None,
    ):
        self.settings = settings
        self.endpoint = f"ws://127.0.0.1:{settings.codex_app_server_port}"
        self.token_path = settings.database_path.parent / ".allhands-codex-token"
        self._probe_ready = probe_ready or self._default_probe_ready
        self._spawn_process = spawn_process or self._default_spawn_process
        self._lock = asyncio.Lock()

    async def ensure_running(self) -> CodexDaemonHandle:
        async with self._lock:
            token = self._read_or_create_token()
            if await self._probe_ready():
                return CodexDaemonHandle(endpoint=self.endpoint, token=token)

            argv = [
                self.settings.codex_binary,
                "app-server",
                "--listen",
                self.endpoint,
                "--ws-auth",
                "capability-token",
                "--ws-token-file",
                str(self.token_path),
            ]
            await self._spawn_process(argv)

            for _ in range(20):
                if await self._probe_ready():
                    return CodexDaemonHandle(endpoint=self.endpoint, token=token)
                await asyncio.sleep(0.25)

            raise RuntimeError("codex app-server did not become ready")

    def _read_or_create_token(self) -> str:
        if self.token_path.exists():
            return self.token_path.read_text(encoding="utf-8").strip()

        self.token_path.parent.mkdir(parents=True, exist_ok=True)
        token = secrets.token_urlsafe(32)
        self.token_path.write_text(token, encoding="utf-8")
        return token

    async def _default_probe_ready(self) -> bool:
        base_url = self.endpoint.replace("ws://", "http://", 1)
        client = AsyncHTTPClient()
        for suffix in ("/readyz", "/healthz"):
            try:
                response = await client.fetch(
                    HTTPRequest(f"{base_url}{suffix}", request_timeout=0.5),
                    raise_error=False,
                )
                if response.code == 200:
                    return True
            except HTTPClientError:
                continue
        return False

    async def _default_spawn_process(self, argv: list[str]):
        return await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
