from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess


class ProjectBoundaryError(ValueError):
    pass


@dataclass
class WorktreeManager:
    project_root: Path

    def validate_repo_path(self, repo_path: Path) -> Path:
        repo_path = repo_path.resolve()
        project_root = self.project_root.resolve()
        if project_root not in repo_path.parents and repo_path != project_root:
            raise ProjectBoundaryError(f"{repo_path} is outside {project_root}")
        return repo_path

    def create(self, repo_path: Path, session_id: str) -> Path:
        repo_path = self.validate_repo_path(repo_path)
        worktrees_root = repo_path.parent / ".worktrees"
        worktrees_root.mkdir(parents=True, exist_ok=True)
        worktree_path = worktrees_root / session_id
        branch_name = f"allhands/{session_id}"
        if worktree_path.exists():
            subprocess.run(
                ["git", "-C", str(repo_path), "worktree", "remove", "--force", str(worktree_path)],
                check=False,
            )
            if worktree_path.exists():
                shutil.rmtree(worktree_path)
        subprocess.run(
            ["git", "-C", str(repo_path), "worktree", "add", "-B", branch_name, str(worktree_path)],
            check=True,
        )
        return worktree_path

    def remove(self, repo_path: Path, worktree_path: Path) -> None:
        repo_path = self.validate_repo_path(repo_path)
        if not worktree_path.exists():
            return
        subprocess.run(
            ["git", "-C", str(repo_path), "worktree", "remove", "--force", str(worktree_path)],
            check=True,
        )
