from dataclasses import dataclass
from pathlib import Path

from tornado.options import define, options


@dataclass(frozen=True)
class Settings:
    project_root: Path
    database_path: Path
    host: str
    port: int
    vapid_public_key: str
    vapid_private_key: str
    codex_app_server_port: int
    codex_binary: str
    default_username: str = "td"
    default_password: str = "8mGu57TILp27qVRDNi6O"


_OPTIONS_DEFINED = False


def define_options() -> None:
    global _OPTIONS_DEFINED
    if _OPTIONS_DEFINED:
        return

    define("project_root", default=str(Path.cwd()), help="Root directory for allowed repositories")
    define("database_path", default="", help="SQLite database path")
    define("host", default="127.0.0.1", help="Bind host")
    define("port", default=21991, type=int, help="Bind port")
    define("vapid_public_key", default="", help="Web Push VAPID public key")
    define("vapid_private_key", default="", help="Web Push VAPID private key")
    define("codex_app_server_port", default=21992, type=int, help="Loopback port for shared codex app-server")
    define("codex_binary", default="codex", help="Codex CLI binary")
    define("default_username", default="td", help="Default HTTP Basic Auth username")
    define("default_password", default="8mGu57TILp27qVRDNi6O", help="Default HTTP Basic Auth password")
    _OPTIONS_DEFINED = True


def load_settings(opts=options) -> Settings:
    define_options()
    project_root = Path(opts.project_root).resolve()
    database_path = Path(
        opts.database_path or (project_root / ".allhands.sqlite3")
    ).resolve()
    return Settings(
        project_root=project_root,
        database_path=database_path,
        host=opts.host,
        port=opts.port,
        vapid_public_key=opts.vapid_public_key,
        vapid_private_key=opts.vapid_private_key,
        codex_app_server_port=opts.codex_app_server_port,
        codex_binary=opts.codex_binary,
        default_username=opts.default_username,
        default_password=opts.default_password,
    )
