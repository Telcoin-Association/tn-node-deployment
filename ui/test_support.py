"""Shared setup for the ui/test_*.py suites (not a test module itself).

The server answers /api/ only with the per-install token and only on a local
Host, so the suites call local_client() once at import time: it sets a test
token on the server module and makes app.test_client() send that token and
Host: localhost:8080 on every request unless the test passes its own headers
(test_csrf.py does, to check the refusals).
"""

from flask.testing import FlaskClient

TEST_TOKEN = "ab" * 32
LOCAL_BASE = "http://localhost:8080"


class LocalClient(FlaskClient):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.environ_base["HTTP_X_TN_UI_TOKEN"] = TEST_TOKEN

    def open(self, *args, **kwargs):
        kwargs.setdefault("base_url", LOCAL_BASE)
        return super().open(*args, **kwargs)


def local_client(server):
    """Point `server` at the test token and the local test client."""
    server.UI_TOKEN = TEST_TOKEN
    server.app.test_client_class = LocalClient
    server._write_times.clear()
    return server
