from pathlib import Path

from allhands_host.launchers.catalog import LauncherCatalog, available_launchers


def test_catalog_keeps_acp_launchers_while_exposing_codex(tmp_path: Path):
    catalog = LauncherCatalog(project_root=tmp_path)

    assert catalog.slugs() == ["claude", "pi"]
    assert available_launchers() == ["claude", "codex", "pi"]
