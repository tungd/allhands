import asyncio
import sys
from pathlib import Path

from tornado.log import app_log
from tornado.options import options, parse_command_line

if __package__ in {None, ""}:
    package_dir = Path(__file__).resolve().parent
    src_dir = package_dir.parent
    if sys.path and Path(sys.path[0]).resolve() == package_dir:
        sys.path[0] = str(src_dir)
    else:
        sys.path.insert(0, str(src_dir))

from allhands_host.app import build_app
from allhands_host.config import define_options, load_settings


async def serve(settings=None, stop_event: asyncio.Event | None = None) -> None:
    settings = settings or load_settings(options)
    app = build_app(settings=settings)
    app.listen(settings.port, address=settings.host)
    app_log.info("Listening on http://%s:%d", settings.host, settings.port)
    stop_event = stop_event or asyncio.Event()
    await stop_event.wait()


def main() -> None:
    define_options()
    parse_command_line()
    asyncio.run(serve(load_settings(options)))


if __name__ == "__main__":
    main()
