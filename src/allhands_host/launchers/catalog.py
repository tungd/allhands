from pathlib import Path

from allhands_host.launchers.claude import ClaudeLauncher
from allhands_host.launchers.codex import CodexLauncher
from allhands_host.launchers.pi import PiLauncher


class LauncherCatalog:
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self._launchers = {
            "claude": ClaudeLauncher(),
            "codex": CodexLauncher(),
            "pi": PiLauncher(),
        }

    def get(self, slug: str):
        return self._launchers[slug]

    def slugs(self) -> list[str]:
        return sorted(self._launchers)


def available_launchers() -> list[str]:
    return LauncherCatalog(project_root=Path.cwd()).slugs()
