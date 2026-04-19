from pathlib import Path
from types import SimpleNamespace

from allhands_host.config import load_settings


def test_load_settings_exposes_codex_app_server_defaults():
    opts = SimpleNamespace(
        project_root=str(Path("/tmp/projects")),
        database_path="",
        host="127.0.0.1",
        port=21991,
        vapid_public_key="pub",
        vapid_private_key="priv",
        codex_app_server_port=21992,
        codex_binary="codex",
        default_username="td",
        default_password="8mGu57TILp27qVRDNi6O",
    )

    settings = load_settings(opts)

    assert getattr(settings, "codex_app_server_port", None) == 21992
    assert getattr(settings, "codex_binary", None) == "codex"
    assert settings.default_username == "td"
    assert settings.default_password == "8mGu57TILp27qVRDNi6O"
