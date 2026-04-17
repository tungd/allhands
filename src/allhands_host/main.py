import asyncio

from tornado.options import options, parse_command_line

from allhands_host.app import build_app
from allhands_host.config import define_options, load_settings


async def serve(settings=None, stop_event: asyncio.Event | None = None) -> None:
    settings = settings or load_settings(options)
    app = build_app(settings=settings)
    app.listen(settings.port, address=settings.host)
    stop_event = stop_event or asyncio.Event()
    await stop_event.wait()


def main() -> None:
    define_options()
    parse_command_line()
    asyncio.run(serve(load_settings(options)))


if __name__ == "__main__":
    main()
