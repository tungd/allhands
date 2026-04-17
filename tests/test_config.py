from pathlib import Path
from types import SimpleNamespace

from allhands_host.config import load_settings


def test_load_settings_reads_option_values():
    settings = load_settings(
        SimpleNamespace(
            project_root="/tmp/projects",
            database_path="/tmp/projects/.allhands.sqlite3",
            host="0.0.0.0",
            port=43123,
            vapid_public_key="pub",
            vapid_private_key="priv",
        )
    )

    assert settings.project_root == Path("/tmp/projects").resolve()
    assert settings.database_path == Path("/tmp/projects/.allhands.sqlite3").resolve()
    assert settings.host == "0.0.0.0"
    assert settings.port == 43123
