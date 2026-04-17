import asyncio
from pathlib import Path
from unittest.mock import Mock

import pytest

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
    )
    app = Mock()
    stop_event = asyncio.Event()
    stop_event.set()

    monkeypatch.setattr("allhands_host.main.build_app", lambda settings=None: app)

    await serve(settings=settings, stop_event=stop_event)

    app.listen.assert_called_once_with(43123, address="0.0.0.0")
