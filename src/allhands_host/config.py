from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True)
class Settings:
    project_root: Path
    database_path: Path
    host: str
    port: int
    vapid_public_key: str
    vapid_private_key: str


def load_settings() -> Settings:
    project_root = Path(os.environ.get("ALLHANDS_PROJECT_ROOT", Path.cwd())).resolve()
    database_path = Path(
        os.environ.get("ALLHANDS_DB_PATH", project_root / ".allhands.sqlite3")
    ).resolve()
    return Settings(
        project_root=project_root,
        database_path=database_path,
        host=os.environ.get("ALLHANDS_HOST", "127.0.0.1"),
        port=int(os.environ.get("ALLHANDS_PORT", "21991")),
        vapid_public_key=os.environ.get("ALLHANDS_VAPID_PUBLIC_KEY", ""),
        vapid_private_key=os.environ.get("ALLHANDS_VAPID_PRIVATE_KEY", ""),
    )
