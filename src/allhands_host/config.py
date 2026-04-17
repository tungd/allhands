from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    project_root: Path = Path.cwd()


def load_settings() -> Settings:
    return Settings()
