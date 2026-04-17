from pathlib import Path
import subprocess

import pytest

from allhands_host.worktrees import ProjectBoundaryError, WorktreeManager


def init_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(
        ["git", "-C", str(path), "config", "user.email", "tests@example.com"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(path), "config", "user.name", "All Hands Tests"],
        check=True,
    )
    (path / "README.md").write_text("hello\n")
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "init"], check=True)


def test_rejects_paths_outside_root(tmp_path: Path):
    manager = WorktreeManager(project_root=tmp_path / "allowed")
    with pytest.raises(ProjectBoundaryError):
        manager.validate_repo_path(tmp_path / "outside")


def test_creates_worktree_under_hidden_dir(tmp_path: Path):
    root = tmp_path / "allowed"
    repo = root / "api"
    repo.mkdir(parents=True)
    init_repo(repo)

    manager = WorktreeManager(project_root=root)
    worktree = manager.create(repo_path=repo, session_id="session_123")

    assert worktree.parent.parent == root
    assert worktree.exists()
