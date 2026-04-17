from dataclasses import dataclass


@dataclass(frozen=True)
class LauncherInfo:
    slug: str
