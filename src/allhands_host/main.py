import tornado.ioloop

from allhands_host.app import build_app
from allhands_host.logging import configure_logging


def main() -> None:
    configure_logging()
    app = build_app()
    app.listen(21991)
    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()
