from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RepoRecord:
    name: str
    path: str


class RepoCatalog:
    def __init__(self, project_root: Path):
        self.project_root = project_root.resolve()
        self._cache: list[RepoRecord] | None = None

    def list_repos(self, query: str = "") -> list[RepoRecord]:
        repos = self._cache if self._cache is not None else self.refresh()
        needle = query.strip().lower()
        if not needle:
            return repos
        return [
            repo
            for repo in repos
            if needle in repo.name.lower() or needle in repo.path.lower()
        ]

    def refresh(self) -> list[RepoRecord]:
        if not self.project_root.exists():
            self._cache = []
            return self._cache

        discovered: dict[str, RepoRecord] = {}
        for marker in self.project_root.rglob(".git"):
            if ".worktrees" in marker.parts:
                continue
            repo_path = marker.parent.resolve()
            discovered[str(repo_path)] = RepoRecord(name=repo_path.name, path=str(repo_path))

        self._cache = sorted(discovered.values(), key=lambda repo: repo.name.lower())
        return self._cache
