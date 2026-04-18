from importlib import import_module
from pathlib import Path

import pytest

from allhands_host.config import Settings


def load_codex_daemon_module():
    try:
        return import_module("allhands_host.codex_daemon")
    except ModuleNotFoundError as exc:
        pytest.fail(f"expected allhands_host.codex_daemon module: {exc}")


class FakeProcess:
    def __init__(self):
        self.pid = 4321


@pytest.mark.asyncio
async def test_ensure_running_reuses_healthy_daemon(tmp_path: Path):
    module = load_codex_daemon_module()
    settings = Settings(
        project_root=tmp_path,
        database_path=tmp_path / "allhands.sqlite3",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    spawned = False

    async def probe() -> bool:
        return True

    async def spawn(_argv: list[str]) -> FakeProcess:
        nonlocal spawned
        spawned = True
        return FakeProcess()

    manager = module.CodexDaemonManager(settings=settings, probe_ready=probe, spawn_process=spawn)

    handle = await manager.ensure_running()

    assert handle.endpoint == "ws://127.0.0.1:21992"
    assert spawned is False


@pytest.mark.asyncio
async def test_ensure_running_spawns_when_probe_fails(tmp_path: Path):
    module = load_codex_daemon_module()
    settings = Settings(
        project_root=tmp_path,
        database_path=tmp_path / "allhands.sqlite3",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    probes = iter([False, False, True])
    spawned: list[list[str]] = []

    async def probe() -> bool:
        return next(probes)

    async def spawn(argv: list[str]) -> FakeProcess:
        spawned.append(argv)
        return FakeProcess()

    manager = module.CodexDaemonManager(settings=settings, probe_ready=probe, spawn_process=spawn)

    handle = await manager.ensure_running()

    assert handle.endpoint == "ws://127.0.0.1:21992"
    assert (tmp_path / ".allhands-codex-token").exists()
    assert spawned[0][:2] == ["codex", "app-server"]
