from tornado.testing import AsyncHTTPTestCase

from allhands_host.app import build_app


class HealthHandlerTest(AsyncHTTPTestCase):
    def get_app(self):
        return build_app()

    def test_healthz(self):
        response = self.fetch("/healthz")
        assert response.code == 200
        assert response.headers["Content-Type"].startswith("application/json")
        assert response.body == b'{"ok":true}'
