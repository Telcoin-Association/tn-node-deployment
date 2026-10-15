#!/usr/bin/env python3
"""
Who may call the UI API (server.py _enforce_local_origin, _json_body, the token)
and what a write leaves behind (the audit line, the redacted stream).

Off the public path every /api/ request needs Host on localhost:8080 (421
otherwise) and the per-install token in X-TN-UI-Token (401). A write also needs
no foreign Origin or cross-site Sec-Fetch-Site (403), Content-Type
application/json (415) and a JSON object body (400). No route changes anything
on GET: the url_map walk below proves every write route answers 405 to GET and
refuses a cross-site form POST before any helper call.

    python3 -m pytest -q ui/test_csrf.py
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import server  # noqa: E402
from test_support import TEST_TOKEN, local_client  # noqa: E402

local_client(server)

from test_server_contract import FULL_SETUP, ServerTestCase  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def write_rules():
    """(endpoint, concrete path) for every POST route."""
    import re
    out = []
    for rule in server.app.url_map.iter_rules():
        if "POST" in rule.methods:
            out.append((rule.endpoint, re.sub(r"<[^>]+>", "observer", rule.rule)
                        .replace("/observer/observer", "/observer/restart")))
    return out


class LocalOriginTest(ServerTestCase):

    def test_cross_site_post_is_refused(self):
        resp = self.client.post("/api/service/observer/restart", json={},
                                headers={"Sec-Fetch-Site": "cross-site"})
        self.assertEqual(resp.status_code, 403)
        resp = self.client.post("/api/service/observer/restart", json={},
                                headers={"Sec-Fetch-Site": "same-site"})
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(self.helper_calls(), [])
        self.assertEqual([c for c in self.calls if c[:1] == ["sudo"]], [])

    def test_foreign_origin_is_refused(self):
        for origin in ("http://evil.example", "http://localhost:8081", "null",
                       "https://localhost:8080"):
            with self.subTest(origin=origin):
                resp = self.client.post("/api/jaeger/start", json={}, headers={"Origin": origin})
                self.assertEqual(resp.status_code, 403)
        self.assertEqual(self.helper_calls(), [])

    def test_local_origins_pass(self):
        for origin in ("http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"):
            with self.subTest(origin=origin):
                resp = self.client.post("/api/jaeger/start", json={},
                                        headers={"Origin": origin, "Sec-Fetch-Site": "same-origin"})
                self.assertEqual(resp.status_code, 200)

    def test_text_plain_is_refused(self):
        resp = self.client.post("/api/jaeger/start", data="{}",
                                headers={"Content-Type": "text/plain"})
        self.assertEqual(resp.status_code, 415)
        resp = self.client.post("/api/config/observer/hostname", data={"name": "x"})
        self.assertEqual(resp.status_code, 415)
        resp = self.client.post("/api/jaeger/start")
        self.assertEqual(resp.status_code, 415, "a write without a body is refused too")
        self.assertEqual(self.helper_calls(), [])

    def test_body_must_be_an_object(self):
        for body in ("[]", '"x"', "nope", "1"):
            with self.subTest(body=body):
                resp = self.client.post("/api/config/observer/hostname", data=body,
                                        content_type="application/json")
                self.assertEqual(resp.status_code, 400)
        self.assertEqual(self.helper_calls(), [])

    def test_get_on_a_mutating_route_is_405(self):
        resp = self.client.get("/api/config/observer/set?field=verbosity&value=-vv")
        self.assertEqual(resp.status_code, 405)
        self.assertEqual(self.helper_calls(), [])

    def test_foreign_host_is_421(self):
        for host in ("evil.example:8080", "localhost", "127.0.0.1:8081", "localhost.evil.example:8080"):
            with self.subTest(host=host):
                self.assertEqual(self.client.get("/api/nodes", headers={"Host": host}).status_code, 421)
                self.assertEqual(self.client.post("/api/jaeger/start", json={},
                                                  headers={"Host": host}).status_code, 421)
        self.assertEqual(self.client.get("/", headers={"Host": "evil.example:8080"}).status_code, 421)
        for host in ("127.0.0.1:8080", "[::1]:8080"):
            with self.subTest(host=host):
                self.assertEqual(self.client.get("/api/system", headers={"Host": host}).status_code, 200)

    def test_missing_or_wrong_token_is_401(self):
        for tok in ("", "cd" * 32, TEST_TOKEN.upper(), TEST_TOKEN + "x"):
            with self.subTest(token=tok[:6]):
                resp = self.client.post("/api/jaeger/start", json={},
                                        headers={"X-TN-UI-Token": tok})
                self.assertEqual(resp.status_code, 401)
                self.assertEqual(self.client.get("/api/firewall",
                                                 headers={"X-TN-UI-Token": tok}).status_code, 401)
        self.assertEqual(self.helper_calls(), [])

    def test_no_token_configured_refuses_everything(self):
        self.patch(server, "UI_TOKEN", None)
        self.assertEqual(self.client.get("/api/nodes").status_code, 401)

    def test_page_and_static_need_no_token(self):
        self.assertEqual(self.client.get("/", headers={"X-TN-UI-Token": ""}).status_code, 200)
        self.assertEqual(self.client.get("/static/index.html",
                                         headers={"X-TN-UI-Token": ""}).status_code, 200)

    def test_url_map_walk(self):
        """Every route is GET-only or POST-only; every POST route answers 405 to
        GET and refuses a cross-site form POST before any helper call."""
        for rule in server.app.url_map.iter_rules():
            methods = sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS"))
            with self.subTest(endpoint=rule.endpoint):
                self.assertIn(methods, (["GET"], ["POST"]))
        rules = write_rules()
        self.assertGreater(len(rules), 15)
        for endpoint, path in rules:
            with self.subTest(endpoint=endpoint, path=path):
                self.calls.clear()
                self.assertEqual(self.client.get(path).status_code, 405)
                form = self.client.post(path, data={"a": "b"},
                                        headers={"Sec-Fetch-Site": "cross-site",
                                                 "Origin": "http://evil.example",
                                                 "X-TN-UI-Token": ""})
                self.assertEqual(form.status_code, 403)
                plain = self.client.post(path, data="{}", headers={"Content-Type": "text/plain"})
                self.assertEqual(plain.status_code, 415)
                notoken = self.client.post(path, json={}, headers={"X-TN-UI-Token": ""})
                self.assertEqual(notoken.status_code, 401)
                self.assertEqual([c for c in self.calls if c[:1] == ["sudo"]], [])

    def test_writes_are_rate_limited(self):
        codes = [self.client.post("/api/jaeger/start", json={}).status_code
                 for _ in range(server._WRITE_LIMIT + 1)]
        self.assertEqual(codes[:-1], [200] * server._WRITE_LIMIT)
        self.assertEqual(codes[-1], 429)

    def test_large_bodies_are_refused(self):
        resp = self.client.post("/api/config/observer/hostname",
                                data=json.dumps({"name": "x" * 70000}),
                                content_type="application/json")
        self.assertEqual(resp.status_code, 413)

    def test_security_headers(self):
        resp = self.client.get("/")
        self.assertEqual(resp.headers.get("X-Frame-Options"), "DENY")
        self.assertEqual(resp.headers.get("Referrer-Policy"), "no-referrer")


class TokenFileTest(unittest.TestCase):

    def test_load_token(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "token")
            with open(p, "w") as f:
                f.write("ab" * 32 + "\n")
            self.assertEqual(server.load_token(p), "ab" * 32)
            for bad in ("", "xyz", "AB" * 32, "ab" * 31):
                with open(p, "w") as f:
                    f.write(bad)
                self.assertIsNone(server.load_token(p), bad)
            self.assertIsNone(server.load_token(os.path.join(d, "missing")))

    def test_server_refuses_to_start_without_a_token(self):
        env = dict(os.environ, TN_UI_TOKEN_FILE="/nonexistent/token")
        p = subprocess.run([sys.executable, os.path.join(HERE, "server.py")], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no UI token", p.stderr)


class AuditTest(ServerTestCase):

    def audit_lines(self, fn):
        buf = io.StringIO()
        with mock.patch.object(sys, "stderr", buf):
            fn()
        out = []
        for line in buf.getvalue().splitlines():
            if line.startswith("[tn-ui] {"):
                out.append(json.loads(line[len("[tn-ui] "):]))
        return [d for d in out if d.get("audit") == 1]

    def test_write_and_refusal_are_logged_with_secrets_redacted(self):
        lines = self.audit_lines(lambda: self.client.post(
            "/api/caddy/enable", buffered=True,
            json={"domain": "dashboard.example.com", "username": "admin",
                  "password": "a very secret password"}))
        self.assertEqual(len(lines), 1)
        d = lines[0]
        self.assertEqual((d["method"], d["path"], d["status"]), ("POST", "/api/caddy/enable", 200))
        self.assertEqual(d["args"]["password"], "***")
        self.assertEqual(d["token"], server.hashlib.sha256(TEST_TOKEN.encode()).hexdigest()[:8])
        self.assertNotIn("a very secret password", json.dumps(lines))
        lines = self.audit_lines(lambda: self.client.post(
            "/api/jaeger/start", json={}, headers={"Origin": "http://evil.example"}))
        self.assertEqual((lines[0]["status"], lines[0]["origin"]), (403, "http://evil.example"))
        lines = self.audit_lines(lambda: self.client.get("/api/nodes", headers={"X-TN-UI-Token": ""}))
        self.assertEqual((lines[0]["status"], lines[0]["token"]), (401, "none"))

    def test_reads_are_not_logged(self):
        self.assertEqual(self.audit_lines(lambda: self.client.get("/api/system")), [])


class SecretStreamTest(ServerTestCase):
    """The setup passphrase and the dashboard password reach the helper on
    stdin only, and never come back in a stream frame."""

    PASS = "correct horse battery staple"

    def test_keygen_failure_never_echoes_the_passphrase(self):
        leak = json.dumps({"event": "log", "msg": "got " + self.PASS})
        self.popen_script = {"lines": [leak, "plain " + self.PASS], "rc": 1,
                             "stderr_text": "error: passphrase " + self.PASS + " rejected\n"}
        resp = self.client.post("/api/setup/observer/keygen", json=FULL_SETUP, buffered=True)
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn(self.PASS, resp.data.decode())
        self.assertIn("***", resp.data.decode())
        proc = self.procs[-1]
        self.assertEqual(proc.stdin.data, self.PASS + "\n")
        self.assertTrue(proc.stdin.closed)
        self.assertNotIn(self.PASS, json.dumps(proc.args))
        self.assertNotIn(self.PASS, json.dumps(proc.env))

    def test_caddy_password_goes_on_stdin(self):
        pw = "a-dashboard-password-1"
        self.popen_script = {"lines": ["echo " + pw], "rc": 2, "stderr_text": pw + "\n"}
        resp = self.client.post("/api/caddy/enable", buffered=True,
                                json={"domain": "dashboard.example.com", "username": "admin",
                                      "password": pw})
        self.assertNotIn(pw, resp.data.decode())
        proc = self.procs[-1]
        self.assertEqual(proc.stdin.data, pw + "\n")
        self.assertNotIn("TN_CADDY_PASSWORD", proc.env)

    def test_short_caddy_password_is_refused(self):
        resp = self.client.post("/api/caddy/enable",
                                json={"domain": "dashboard.example.com", "username": "admin",
                                      "password": "fifteen-chars!!"})
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(self.procs, [])


class PassphraseRuleTest(unittest.TestCase):
    """server.passphrase_ok is the twin of lib/common.sh tn_passphrase_ok:
    bytes, and the six ASCII whitespace characters."""

    VECTORS = [
        ("", "testnet", False), ("abc", "testnet", True), ("abc", "mainnet", False),
        (" abc", "testnet", False), ("abc ", "testnet", False), ("abc\n", "testnet", False),
        ("ab\rc", "testnet", False), ("abcdefghijklmnop", "mainnet", True),
        ("abcdefghijklmno", "mainnet", False), ("a b c d e f g h i", "mainnet", True),
        ("\tabc", "testnet", False), ("abc\v", "testnet", False), ("\fabc", "testnet", False),
        # Not ASCII whitespace: a no-break space at the end is allowed, as in bash.
        ("abc ", "testnet", True),
        # Bytes, not characters: eight two-byte characters are 16 bytes.
        ("éééééééé", "mainnet", True), ("ééééééé", "mainnet", False),
    ]

    def test_vectors(self):
        for value, net, want in self.VECTORS:
            with self.subTest(value=value, net=net):
                self.assertEqual(server.passphrase_ok(value, net), want)


class SetupRefusalTest(ServerTestCase):

    def keygen(self, **over):
        return self.client.post("/api/setup/observer/keygen", json=dict(FULL_SETUP, **over))

    def test_refusals(self):
        cases = [
            ({"network": ""}, "network required"),
            ({"network": "devnet"}, "invalid network"),
            ({"service_user": "root"}, "invalid service user"),
            ({"service_user": "telcoin-ui"}, "invalid service user"),
            ({"service_group": "root"}, "invalid service group"),
            ({"data_dir": "/usr/local/sbin"}, "invalid data directory"),
            ({"data_dir": "/var/lib/telcoin/../../etc"}, "invalid data directory"),
            ({"passphrase_method": "tpm"}, "TPM sealing was removed"),
            ({"docker_image": "docker.io/library/busybox:latest"}, "docker image"),
            ({"docker_image": "us-docker.pkg.dev/telcoin-network/tn-public/adiri:latest"}, "docker image"),
            ({"passphrase": " padded "}, "passphrase required"),
        ]
        for over, message in cases:
            with self.subTest(over=over):
                resp = self.keygen(**over)
                self.assertEqual(resp.status_code, 400)
                self.assertIn(message, resp.get_json()["error"])
        self.assertEqual(self.helper_calls(), [])

    def test_installed_node_is_409(self):
        os.makedirs(server.SYSTEMD_DIR)
        open(os.path.join(server.SYSTEMD_DIR, "telcoin.service"), "w").close()
        for phase in ("keygen", "finalize"):
            with self.subTest(phase=phase):
                resp = self.client.post("/api/setup/observer/" + phase, json=FULL_SETUP)
                self.assertEqual(resp.status_code, 409)
        self.assertEqual(self.procs, [])

    def test_keygen_after_keygen_is_409_but_finalize_runs(self):
        os.makedirs(server.DEFAULT_CONFIG_DIR)
        open(os.path.join(server.DEFAULT_CONFIG_DIR, ".node-meta"), "w").close()
        self.assertEqual(self.keygen().status_code, 409)
        resp = self.client.post("/api/setup/observer/finalize", json=FULL_SETUP, buffered=True)
        self.assertEqual(resp.status_code, 200)

    def test_finalize_needs_both_listeners(self):
        resp = self.client.post("/api/setup/observer/finalize",
                                json=dict(FULL_SETUP, listener_worker=""))
        self.assertEqual(resp.status_code, 400)
        self.assertIn("listener", resp.get_json()["error"])


class MainnetAndImagesTest(ServerTestCase):

    def test_chain_487(self):
        self.assertEqual(server.resolve_network(487), ("mainnet", "Telcoin Mainnet", True))
        self.assertEqual(server.NETWORK_PUBLIC_RPC[487], [], "set at launch, no invented URL")
        self.assertIn("mainnet", server.KNOWN_SLUGS)

    def test_latest_docker_image_takes_release_tags_only(self):
        tags = {"tags": ["latest", "v0.17.0-devnet", "v0.16.0-adiri", "v0.16.1-adiri-hotfix",
                         "v0.15.9-adiri", "v1.0.0"]}

        class Resp(io.BytesIO):
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def urlopen(req, timeout=None):
            if getattr(req, "method", None) == "HEAD" or req.get_method() == "HEAD":
                r = Resp(b"")
                r.headers = {"Docker-Content-Digest": "sha256:" + "c" * 64}
                return r
            return Resp(json.dumps(tags).encode())

        self.patch(server.urllib.request, "urlopen", urlopen)
        img = server.latest_docker_image("testnet")
        self.assertEqual(img, server.GAR_IMAGE_BASE + "@sha256:" + "c" * 64)
        self.assertTrue(server.image_allowed(img, "testnet"))
        self.assertEqual(server.latest_docker_image("mainnet"), "")

    def test_image_rule(self):
        base = server.GAR_IMAGE_BASE
        self.assertTrue(server.image_allowed(base + ":v0.16.0-adiri", "testnet"))
        self.assertTrue(server.image_allowed(base + "@sha256:" + "a" * 64, "testnet"))
        for bad in (base + ":latest", base + ":v0.16.0-devnet", "busybox:v0.16.0-adiri",
                    base + "@sha256:" + "A" * 64, "-" + base + ":v0.16.0-adiri"):
            with self.subTest(image=bad):
                self.assertFalse(server.image_allowed(bad, "testnet"))
        self.assertFalse(server.image_allowed(base + ":v0.16.0-adiri", "mainnet"))

    def test_status_shows_the_digest(self):
        self.helper_replies["meta-cat"] = (0, "DOCKER_IMAGE=" + server.GAR_IMAGE_BASE
                                           + "@sha256:" + "d" * 64 + "\n", "")
        server.clear_meta_cache()
        body = self.client.get("/api/status/observer").get_json()
        self.assertEqual(body["docker_image_digest"], "sha256:" + "d" * 64)


class LogLimitsTest(ServerTestCase):

    def test_ninth_live_stream_is_429(self):
        taken = 0
        while server._LOG_STREAMS.acquire(blocking=False):
            taken += 1
        try:
            self.assertEqual(taken, 8)
            self.assertEqual(self.client.get("/api/logs/observer/stream").status_code, 429)
        finally:
            for _ in range(taken):
                server._LOG_STREAMS.release()

    def test_download_is_capped(self):
        path = os.path.join(self.tmp.name, "big.log")
        with open(path, "wb") as f:
            f.write(b"a" * 1000 + b"TAIL")
        self.patch(server, "LOG_DOWNLOAD_CAP", 10)
        self.patch(server, "parse_service_file", lambda t: {"log_path": path})
        resp = self.client.get("/api/logs/observer/download")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data, b"aaaaaaTAIL")

    def test_journal_target_reads_through_the_helper(self):
        self.helper_replies["meta-cat"] = (0, "LOG_TARGET=journal\n", "")
        server.clear_meta_cache()
        body = self.client.get("/api/logs/observer?lines=5").get_json()
        self.assertEqual(body["lines"], ["journal one", "journal two"])
        self.assertIn(["sudo", "-n", server.HELPER, "journal-tail", "5"], self.calls)


class PassphraseDisplayTest(ServerTestCase):

    def test_methods(self):
        for meta, want in (("credential", "credential"), ("stdin", "stdin"), ("env", "env"),
                           ("loadcredential", "env"), ("tpm", "env")):
            with self.subTest(meta=meta):
                self.helper_replies["meta-cat"] = (0, f"PASSPHRASE_METHOD={meta}\n", "")
                server.clear_meta_cache()
                self.assertEqual(server.detect_passphrase_method("observer"), want)
        self.assertNotIn("tpm", server.PASSPHRASE_METHODS)


if __name__ == "__main__":
    unittest.main()
