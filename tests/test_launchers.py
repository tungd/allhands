from pathlib import Path

from allhands_host.launchers.catalog import LauncherCatalog


def test_catalog_returns_resume_capable_launcher(tmp_path: Path):
    catalog = LauncherCatalog(project_root=tmp_path)
    launcher = catalog.get("codex")

    command = launcher.build_start_command(
        repo_path=tmp_path / "repo",
        worktree_path=tmp_path / "repo/.worktrees/session_1",
        prompt="Fix the API",
    )
    resume = launcher.build_resume_command(session_token="abc123")

    assert command.argv[0]
    assert resume.argv[0]
    assert launcher.slug == "codex"
