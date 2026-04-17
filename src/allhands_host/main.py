import tornado.ioloop

from allhands_host.app import build_app


def main() -> None:
    app = build_app()
    app.listen(21991)
    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()
