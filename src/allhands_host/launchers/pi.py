from pathlib import Path

from allhands_host.launchers.base import LaunchCommand, Launcher


class PiLauncher(Launcher):
    slug = "pi"

    def build_start_command(
        self,
        repo_path: Path,
        worktree_path: Path,
        prompt: str,
    ) -> LaunchCommand:
        return LaunchCommand(
            argv=["pi", "--experimental-acp"],
            cwd=worktree_path,
        )

    def build_resume_command(self, session_token: str) -> LaunchCommand:
        return LaunchCommand(
            argv=["pi", "--experimental-acp", "--resume", session_token],
            cwd=Path("."),
        )
