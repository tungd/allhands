import asyncio
from pathlib import Path
import subprocess
from unittest.mock import Mock

import pytest

import allhands_host.main as main_module
from allhands_host.config import Settings
from allhands_host.main import serve


@pytest.mark.asyncio
async def test_serve_binds_to_configured_host_and_port(monkeypatch):
    settings = Settings(
        project_root=Path("/tmp/projects"),
        database_path=Path("/tmp/projects/.allhands.sqlite3"),
        host="0.0.0.0",
        port=43123,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    app = Mock()
    stop_event = asyncio.Event()
    stop_event.set()

    monkeypatch.setattr("allhands_host.main.build_app", lambda settings=None: app)

    await serve(settings=settings, stop_event=stop_event)

    app.listen.assert_called_once_with(43123, address="0.0.0.0")


@pytest.mark.asyncio
async def test_serve_logs_listening_address(monkeypatch):
    settings = Settings(
        project_root=Path("/tmp/projects"),
        database_path=Path("/tmp/projects/.allhands.sqlite3"),
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
    )
    app = Mock()
    stop_event = asyncio.Event()
    stop_event.set()
    log_info = Mock()

    monkeypatch.setattr("allhands_host.main.build_app", lambda settings=None: app)
    monkeypatch.setattr(main_module, "app_log", Mock(info=log_info), raising=False)

    await serve(settings=settings, stop_event=stop_event)

    log_info.assert_called_once_with("Listening on http://%s:%d", "127.0.0.1", 21991)


def test_main_script_runs_directly_from_src_path():
    repo_root = Path(__file__).resolve().parents[1]

    result = subprocess.run(
        ["uv", "run", "python", "src/allhands_host/main.py", "--help"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "--vapid-public-key" in (result.stdout + result.stderr)
