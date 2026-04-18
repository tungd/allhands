from pathlib import Path
import subprocess

from allhands_host.repo_catalog import RepoCatalog


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


def test_lists_git_repos_under_project_root_alphabetically(tmp_path: Path):
    root = tmp_path / "projects"
    api = root / "api"
    docs = root / "docs"
    api.mkdir(parents=True)
    docs.mkdir(parents=True)
    init_repo(api)
    init_repo(docs)

    ignored_worktree = root / ".worktrees" / "session-1"
    ignored_worktree.mkdir(parents=True)
    (ignored_worktree / ".git").write_text("gitdir: /tmp/common\n")

    catalog = RepoCatalog(root)
    repos = catalog.list_repos()

    assert [repo.name for repo in repos] == ["api", "docs"]
    assert [repo.path for repo in repos] == [str(api.resolve()), str(docs.resolve())]


def test_filters_repo_names_and_paths(tmp_path: Path):
    root = tmp_path / "projects"
    frontend = root / "frontend-web"
    backend = root / "services" / "backend-api"
    frontend.mkdir(parents=True)
    backend.mkdir(parents=True)
    init_repo(frontend)
    init_repo(backend)

    catalog = RepoCatalog(root)

    assert [repo.name for repo in catalog.list_repos("front")] == ["frontend-web"]
    assert [repo.name for repo in catalog.list_repos("backend")] == ["backend-api"]
