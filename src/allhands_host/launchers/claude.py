from pathlib import Path

from allhands_host.launchers.base import LaunchCommand, Launcher


class ClaudeLauncher(Launcher):
    slug = "claude"

    def build_start_command(
        self,
        repo_path: Path,
        worktree_path: Path,
        prompt: str,
    ) -> LaunchCommand:
        return LaunchCommand(
            argv=["claude", "--experimental-acp", "--prompt", prompt],
            cwd=worktree_path,
        )

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        return LaunchCommand(
            argv=["claude", "--experimental-acp", "--resume", session_token],
            cwd=Path("."),
        )
