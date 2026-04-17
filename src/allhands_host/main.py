import tornado.ioloop
from tornado.options import options, parse_command_line

from allhands_host.app import build_app
from allhands_host.config import define_options, load_settings


def main() -> None:
    define_options()
    parse_command_line()
    settings = load_settings(options)
    app = build_app(settings=settings)
    app.listen(settings.port, address=settings.host)
    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()
