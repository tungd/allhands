from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class LaunchCommand:
    argv: list[str]
    cwd: Path


class Launcher:
    slug: str

    def build_start_command(
        self,
        repo_path: Path,
        worktree_path: Path,
        prompt: str,
    ) -> LaunchCommand:
        raise NotImplementedError

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        raise NotImplementedError
