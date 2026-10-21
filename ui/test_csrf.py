#!/usr/bin/env python3
"""
Who may call the UI API (server.py _enforce_local_origin, _json_body, the token)
and what a write leaves behind (the audit line, the redacted stream).

Off the public path every /api/ request needs a loopback Host on port 8080
(127.0.0.1, localhost or [::1]; 421 otherwise) and the per-install token in X-TN-UI-Token (401). A write also needs
no foreign Origin or cross-site Sec-Fetch-Site (403), Content-Type
application/json (415) and a JSON object body (400). No route changes anything
on GET: the url_map walk below proves every write route answers 405 to GET and
refuses a cross-site form POST before any helper call.

    python3 -m pytest -q ui/test_csrf.py
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REAL_POPEN = subprocess.Popen

import server  # noqa: E402
from test_support import TEST_TOKEN, local_client  # noqa: E402

local_client(server)

from test_server_contract import FULL_SETUP, ServerTestCase  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib", "common.sh")


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

    def test_query_string_secrets_are_redacted(self):
        lines = self.audit_lines(lambda: self.client.post(
            "/api/caddy/disable?password=QuerySecret1234567&Token=abc&keep=1", json={},
            buffered=True))
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["args"]["password"], "***")
        self.assertEqual(lines[0]["args"]["Token"], "***")
        self.assertEqual(lines[0]["args"]["keep"], "1")
        self.assertNotIn("QuerySecret1234567", json.dumps(lines))

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

    # A passphrase with a double quote, a backslash, an interior tab and
    # non-ASCII text: each JSON writer spells it differently.
    MIXED = 'p\u00e4ss"w\\rd in\tthe-middle 42!'

    @staticmethod
    def engine_json(sec):
        """setup-node.sh json_escape: UTF-8 kept, backslash and quote escaped,
        tab as a space."""
        return sec.replace("\\", "\\\\").replace('"', '\\"').replace("\t", " ")

    def keygen_output(self, **script):
        self.popen_script = script
        resp = self.client.post("/api/setup/observer/keygen", buffered=True,
                                json=dict(FULL_SETUP, passphrase=self.MIXED))
        self.assertEqual(resp.status_code, 200)
        return resp.data.decode()

    def assert_no_form_of(self, sec, text):
        forms = {sec, json.dumps(sec)[1:-1], json.dumps(sec, ensure_ascii=False)[1:-1],
                 self.engine_json(sec)}
        for form in forms:
            # no form, and no 8-character piece of one
            for i in range(len(form) - 7):
                self.assertNotIn(form[i:i + 8], text, form)

    def test_every_json_form_of_the_passphrase_is_cut(self):
        sec = self.MIXED
        lines = [
            json.dumps({"event": "log", "msg": "ascii " + sec}),
            json.dumps({"event": "log", "msg": "utf8 " + sec}, ensure_ascii=False),
            '{"event":"log","msg":"engine ' + self.engine_json(sec) + '"}',
        ]
        text = self.keygen_output(lines=lines, rc=0)
        self.assert_no_form_of(sec, text)
        self.assertEqual(text.count("***"), 3)

    def test_a_secret_where_the_stderr_tail_is_cut_is_cut_first(self):
        # The tail keeps 12 lines joined with " | " and cut to 900 characters;
        # this puts the passphrase across character 900.
        stderr = "".join("x" * 70 + "\n" for _ in range(11)) + "y" * 81 + " " + self.MIXED + "\n"
        text = self.keygen_output(lines=[], rc=1, stderr_text=stderr)
        self.assert_no_form_of(self.MIXED, text)
        self.assertIn("y" * 81 + " ***", text)

    def test_redact_forms(self):
        sec = 'a"b\\c\td\u00e9'
        out = server._redact("|".join([
            sec, json.dumps(sec)[1:-1], json.dumps(sec, ensure_ascii=False)[1:-1],
            self.engine_json(sec), 'a\\"b\\\\c\\u0009d\u00e9']), [sec])
        self.assertEqual(out, "|".join(["***"] * 5))

    def caddy_enable(self, pw):
        return self.client.post("/api/caddy/enable", buffered=True,
                                json={"domain": "dashboard.example.com", "username": "admin",
                                      "password": pw})

    def test_short_caddy_password_is_refused(self):
        for pw, message in (("fifteen-chars!!", "at least 16 characters"),
                            ("", "at least 16 characters"),
                            ("\u00e9" * 7 + "x", "at least 16 characters"),   # 15 bytes
                            ("sixteen-chars\tok", "control characters"),
                            ("sixteen-chars-ok\n", "control characters")):
            with self.subTest(pw=pw):
                resp = self.caddy_enable(pw)
                self.assertEqual(resp.status_code, 400)
                self.assertIn(message, resp.get_json()["error"])
        self.assertEqual(self.procs, [])

    def test_sixteen_byte_caddy_password_reaches_the_helper(self):
        for pw in ("sixteen-chars-ok", "\u00e9" * 8):
            with self.subTest(pw=pw):
                self.assertEqual(self.caddy_enable(pw).status_code, 200)
                self.assertEqual(self.procs[-1].stdin.data, pw + "\n")


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
            ({"data_dir": "/var/lib/telcoin-ui"}, "invalid data directory"),
            ({"data_dir": "/var/lib/telcoin-staging/x"}, "invalid data directory"),
            ({"data_dir": "/srv/telcoin"}, "invalid data directory"),
            ({"listener_primary": "/ip4/10.0.0.5\nPASSPHRASE_METHOD=env/udp/1/quic-v1"},
             "invalid multiaddr"),
            ({"listener_worker": "/ip4/10.0.0.5 --x/udp/2/quic-v1"}, "invalid multiaddr"),
            ({"external_primary": "/ip4/203.0.113.10\t/udp/1/quic-v1"}, "invalid multiaddr"),
            ({"passphrase_method": "tpm"}, "TPM sealing was removed"),
            ({"docker_image": "docker.io/library/busybox:latest"}, "docker image"),
            ({"docker_image": "us-docker.pkg.dev/telcoin-network/tn-public/adiri:latest"}, "docker image"),
            ({"docker_image": "ghcr.io/telcoin-association/telcoin-network:latest"}, "docker image"),
            ({"passphrase": " padded "}, "passphrase required"),
        ]
        for over, message in cases:
            with self.subTest(over=over):
                resp = self.keygen(**over)
                self.assertEqual(resp.status_code, 400)
                self.assertIn(message, resp.get_json()["error"])
        self.assertEqual(self.helper_calls(), [])

    def test_data_dir_under_var_lib_telcoin_is_accepted(self):
        resp = self.keygen(data_dir="/var/lib/telcoin/node-1")
        self.assertEqual(resp.status_code, 200)

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

    def no_registry(self):
        """Fail the test on any direct HTTP request: the image comes from the
        library only."""
        def urlopen(*a, **k):
            raise AssertionError("the server asked a registry itself")
        self.patch(server.urllib.request, "urlopen", urlopen)

    def test_latest_docker_image_asks_the_library_only(self):
        image = server.GHCR_IMAGE_REPO + "@sha256:" + "c" * 64
        seen = []

        def run(cmd, timeout=10):
            staging = cmd[-2]
            st = os.stat(staging)
            seen.append({"cmd": cmd, "timeout": timeout, "uid": st.st_uid,
                         "mode": st.st_mode & 0o7777, "dir": os.path.isdir(staging)})
            return 0, "a warning the library printed\n" + image, ""

        self.no_registry()
        self.patch(server, "run", run)
        self.assertEqual(server.latest_docker_image("testnet"), image)
        self.assertEqual(len(seen), 1)
        call = seen[0]
        self.assertEqual(call["cmd"][:2], ["bash", "-c"])
        self.assertIn('TN_RELEASE_STAGING_DIR="$2"; export TN_RELEASE_STAGING_DIR;', call["cmd"][2])
        self.assertIn('latest_docker_image "$3"', call["cmd"][2])
        self.assertEqual(call["cmd"][3:5], ["_", server.LIB_COMMON])
        self.assertEqual(call["cmd"][-1], "testnet")
        self.assertTrue(call["dir"])
        self.assertEqual((call["uid"], call["mode"]), (os.getuid(), 0o700),
                         "the staging directory is this user's own, mode 0700")
        self.assertFalse(os.path.exists(call["cmd"][-2]), "the staging directory is removed afterwards")
        self.assertEqual(call["timeout"], server.DOCKER_PROBE_TIMEOUT)

    def test_an_image_the_rule_refuses_falls_back_to_the_default(self):
        self.no_registry()
        for out in ("", server.GHCR_IMAGE_REPO + ":v0.17.0-adiri", "busybox@sha256:" + "a" * 64,
                    server.GHCR_IMAGE_REPO + "@sha256:" + "A" * 64):
            with self.subTest(out=out):
                server._docker_image_cache.clear()
                self.patch(server, "run", lambda cmd, timeout=10, o=out: (0, o, ""))
                self.assertEqual(server.latest_docker_image("testnet"), server.DEFAULT_DOCKER_IMAGE)
        self.assertTrue(server.DEFAULT_DOCKER_IMAGE.startswith(server.TESTNET_LEGACY_IMAGE_REPO + "@sha256:"))
        self.assertTrue(server.image_allowed(server.DEFAULT_DOCKER_IMAGE, "testnet"))

    def test_mainnet_image_stays_off_until_mainnet_is_enabled(self):
        calls = []
        self.no_registry()
        self.patch(server, "run", lambda cmd, timeout=10: calls.append(cmd) or (1, "", ""))
        self.assertIs(server.TN_MAINNET_ENABLED, False)
        self.assertEqual(server.latest_docker_image("mainnet"), "")
        self.assertEqual(server.latest_docker_image("devnet"), "")
        self.assertEqual(calls, [], "nothing is looked up for mainnet while it is off")
        ghcr = server.GHCR_IMAGE_REPO + "@sha256:" + "e" * 64
        legacy = server.TESTNET_LEGACY_IMAGE_REPO + "@sha256:" + "e" * 64
        self.patch(server, "TN_MAINNET_ENABLED", True)
        for rc, out, want in ((1, "", ""), (0, legacy, ""), (0, ghcr, ghcr)):
            with self.subTest(rc=rc, out=out):
                server._docker_image_cache.clear()
                self.patch(server, "run", lambda cmd, timeout=10, r=rc, o=out: calls.append(cmd) or (r, o, ""))
                self.assertEqual(server.latest_docker_image("mainnet"), want,
                                 "mainnet never falls back to the testnet default")
        self.assertEqual(calls[-1][-1], "mainnet")

    def test_latest_docker_image_is_cached_with_bounded_probes(self):
        timeouts = []
        lib_image = server.GHCR_IMAGE_REPO + "@sha256:" + "d" * 64

        def run(cmd, timeout=10):
            timeouts.append(("run", timeout))
            return 0, lib_image + "\n", ""

        clock = [1000.0]
        self.no_registry()
        self.patch(server, "run", run)
        self.patch(server.time, "time", lambda: clock[0])
        self.assertEqual(server.latest_docker_image("testnet"), lib_image)
        self.assertEqual(timeouts, [("run", server.DOCKER_PROBE_TIMEOUT)])
        self.assertEqual(server.DOCKER_PROBE_TIMEOUT, 25)
        clock[0] += server.DOCKER_IMAGE_TTL - 1
        self.assertEqual(server.latest_docker_image("testnet"), lib_image)
        self.assertEqual(len(timeouts), 1, "a second call within the TTL probes nothing")
        self.assertEqual(server.DOCKER_IMAGE_TTL, 600)
        clock[0] += 2
        server.latest_docker_image("testnet")
        self.assertEqual(len(timeouts), 2, "after the TTL it probes again")

    def test_a_failed_image_lookup_is_retried_sooner(self):
        calls = []

        def run(cmd, timeout=10):
            calls.append(timeout)
            return 1, "", ""

        clock = [5000.0]
        self.no_registry()
        self.patch(server, "run", run)
        self.patch(server.time, "time", lambda: clock[0])
        self.assertEqual(server.latest_docker_image("testnet"), server.DEFAULT_DOCKER_IMAGE)
        self.assertEqual(calls, [server.DOCKER_PROBE_TIMEOUT])
        clock[0] += server.DOCKER_IMAGE_FAIL_TTL - 1
        server.latest_docker_image("testnet")
        self.assertEqual(len(calls), 1)
        clock[0] += 2
        server.latest_docker_image("testnet")
        self.assertEqual(len(calls), 2)

    def test_release_tags_are_checked_without_the_library(self):
        ran = []
        self.patch(server, "run", lambda *a, **k: ran.append(a) or (0, "", ""))
        ok, final = server.release_tag_ok, server.release_tag_final
        self.assertTrue(ok("testnet", "v0.16.0-adiri"))
        self.assertTrue(ok("testnet", "v0.17.0-adiri-rc1"))
        self.assertTrue(ok("testnet", "v0.17.0-adiri-rc12"))
        for bad in ("v0.16.0", "v0.17.0-adiri-rc0", "v0.17.0-adiri-rc01", "v0.17.0-adiri-rc",
                    "v0.17.0-rc1", "v0.17.0-adiri-rc1-hotfix"):
            with self.subTest(tag=bad):
                self.assertFalse(ok("testnet", bad))
        self.assertTrue(ok("mainnet", "v1.0.0"))
        self.assertFalse(ok("mainnet", "v1.0.0-adiri"))
        self.assertFalse(ok("mainnet", "v1.0.0-rc1"), "release candidates are testnet only")
        self.assertFalse(ok("devnet", "v1.0.0"))
        self.assertTrue(final("testnet", "v0.17.0-adiri"))
        self.assertFalse(final("testnet", "v0.17.0-adiri-rc1"))
        self.assertTrue(final("mainnet", "v1.0.0"))
        self.assertFalse(final("mainnet", "v1.0.0-rc1"))
        self.assertFalse(final("devnet", "v1.0.0"))
        key = server.release_tag_key
        self.assertLess(key("v0.17.0-adiri-rc1"), key("v0.17.0-adiri-rc2"))
        self.assertLess(key("v0.17.0-adiri-rc2"), key("v0.17.0-adiri-rc10"))
        self.assertLess(key("v0.17.0-adiri-rc10"), key("v0.17.0-adiri"))
        self.assertLess(key("v0.17.0-adiri"), key("v0.17.1-adiri-rc1"))
        self.assertLess(key("v0.9.0-adiri"), key("v0.10.0-adiri"))
        self.assertIsNone(key("main"))
        self.assertEqual(ran, [])

    @unittest.skipUnless(shutil.which("bash"), "bash not installed")
    def test_release_tag_twins_match_the_library(self):
        tags = ("v0.16.0-adiri", "v1.0.0", "v1.2.3-adiri-hotfix", "latest", "v1.0",
                "v01.0.0", "main", "v1.0.0 ", "0.16.0-adiri", "v10.20.30",
                "v0.17.0-adiri-rc1", "v0.17.0-adiri-rc10", "v0.17.0-adiri-rc0", "v0.17.0-adiri-rc01",
                "v0.17.0-adiri-rc", "v0.17.0-adiri-rc1-hotfix", "v1.0.0-rc1", "v1.0.0-adiri-rc1 ")
        vectors = [(n, t) for n in ("testnet", "mainnet", "devnet") for t in tags]
        script = ('source "$1" >/dev/null 2>&1; set +e; shift; while [ $# -gt 1 ]; do '
                  'tn_release_tag_ok "$1" "$2"; a=$?; tn_release_tag_final "$1" "$2"; b=$?; '
                  'echo "$a $b"; shift 2; done')
        args = [a for v in vectors for a in v]
        out = subprocess.run(["bash", "-c", script, "_", LIB] + args,
                             capture_output=True, text=True, timeout=60).stdout.splitlines()
        self.assertEqual(len(out), len(vectors))
        for (net, tag), line in zip(vectors, out):
            with self.subTest(net=net, tag=tag):
                self.assertEqual((server.release_tag_ok(net, tag), server.release_tag_final(net, tag)),
                                 tuple(x == "0" for x in line.split()))

    @unittest.skipUnless(shutil.which("bash"), "bash not installed")
    def test_release_tag_order_matches_the_library(self):
        tags = ["v0.17.0-adiri", "v0.17.0-adiri-rc2", "v0.9.0-adiri", "v0.17.0-adiri-rc10",
                "v0.17.0-adiri-rc1", "v0.17.1-adiri-rc1", "v0.10.0-adiri", "v1.0.0", "v1.0.0-rc3",
                "v0.17.0-adiri", "main", "v1234567890.0.0", "v1.0.0-adiri-rc123456789", "v0.16.0-adiri"]
        script = 'source "$1" >/dev/null 2>&1; set +e; printf "%s\\n" "$2" | tn_release_tags_sort'
        out = subprocess.run(["bash", "-c", script, "_", LIB, "\n".join(tags)],
                             capture_output=True, text=True, timeout=20).stdout.split()
        mine = sorted({t for t in tags if server.release_tag_key(t) is not None}, key=server.release_tag_key)
        self.assertEqual(mine, out)
        self.assertEqual(out[-1], "v1.0.0")

    @unittest.skipUnless(shutil.which("bash"), "bash not installed")
    def test_image_repositories_match_the_library(self):
        script = ('source "$1" >/dev/null 2>&1; printf "%s\\n" "$TN_GHCR_IMAGE_REPO" '
                  '"$TN_TESTNET_LEGACY_IMAGE_REPO" "$TN_MAINNET_IMAGE_REPO" "$DEFAULT_DOCKER_IMAGE" '
                  '"$TN_TESTNET_IMAGE_REPOS"')
        out = subprocess.run(["bash", "-c", script, "_", LIB],
                             capture_output=True, text=True, timeout=20).stdout.splitlines()
        self.assertEqual(out[:4], [server.GHCR_IMAGE_REPO, server.TESTNET_LEGACY_IMAGE_REPO,
                                   server.DOCKER_REPO["mainnet"][0], server.DEFAULT_DOCKER_IMAGE])
        self.assertEqual(server.DOCKER_REPO["mainnet"], (server.GHCR_IMAGE_REPO,))
        self.assertEqual(sorted(out[4].split()), sorted(server.DOCKER_REPO["testnet"]))

    def test_image_rule(self):
        hexd = "a" * 64
        ghcr = server.GHCR_IMAGE_REPO + "@sha256:" + hexd
        legacy = server.TESTNET_LEGACY_IMAGE_REPO + "@sha256:" + hexd
        self.assertTrue(server.image_allowed(ghcr, "testnet"))
        self.assertTrue(server.image_allowed(legacy, "testnet"))
        self.assertTrue(server.image_allowed(ghcr, "mainnet"))
        self.assertFalse(server.image_allowed(legacy, "mainnet"), "the legacy repository is testnet only")
        # A tag is never an image to run; the wizard sends it as the release.
        for base in (server.GHCR_IMAGE_REPO, server.TESTNET_LEGACY_IMAGE_REPO):
            for bad in (base + ":v0.16.0-adiri", base + ":latest", base + ":v0.16.0-devnet",
                        "busybox:v0.16.0-adiri", base + "@sha256:" + "A" * 64, "-" + base + "@sha256:" + hexd,
                        base + "-fork@sha256:" + hexd, base + "@sha256:" + hexd + "\n",
                        base + ":v0.16.0-adiri@sha256:" + hexd):
                with self.subTest(image=bad):
                    self.assertFalse(server.image_allowed(bad, "testnet"))
        for net in ("devnet", "", None):
            self.assertFalse(server.image_allowed(ghcr, net))

    @unittest.skipUnless(shutil.which("bash"), "bash not installed")
    def test_image_rule_matches_the_library(self):
        hexd = "b" * 64
        images = []
        for base in (server.GHCR_IMAGE_REPO, server.TESTNET_LEGACY_IMAGE_REPO, "busybox",
                     server.GHCR_IMAGE_REPO + "-fork"):
            images += [base + "@sha256:" + hexd, base + ":v0.16.0-adiri", base + ":v1.0.0",
                       base + "@sha256:" + "B" * 64, base + "@sha256:" + hexd[:63]]
        vectors = [(n, i) for n in ("testnet", "mainnet", "devnet") for i in images]
        script = ('source "$1" >/dev/null 2>&1; set +e; shift; while [ $# -gt 1 ]; do '
                  'TN_DOCKER_REQUIRE_DIGEST=1 tn_docker_image_allowed "$2" "$1" 2>/dev/null; echo $?; '
                  'shift 2; done')
        args = [a for v in vectors for a in v]
        out = subprocess.run(["bash", "-c", script, "_", LIB] + args,
                             capture_output=True, text=True, timeout=60).stdout.splitlines()
        self.assertEqual(len(out), len(vectors))
        for (net, image), rc in zip(vectors, out):
            with self.subTest(net=net, image=image):
                self.assertEqual(server.image_allowed(image, net), rc == "0")

    def test_wizard_image_field(self):
        ghcr = server.GHCR_IMAGE_REPO
        legacy = server.TESTNET_LEGACY_IMAGE_REPO
        digest = ghcr + "@sha256:" + "a" * 64
        legacy_digest = legacy + "@sha256:" + "a" * 64
        choice = server.docker_image_choice
        for value, net, want in (
                ("v0.16.0-adiri", "testnet", ("v0.16.0-adiri", "", None)),
                ("v0.17.0-adiri-rc1", "testnet", ("v0.17.0-adiri-rc1", "", None)),
                (ghcr + ":v0.17.0-adiri", "testnet", ("v0.17.0-adiri", "", None)),
                (ghcr + ":v0.17.0-adiri-rc2", "testnet", ("v0.17.0-adiri-rc2", "", None)),
                (legacy + ":v0.16.0-adiri", "testnet", ("v0.16.0-adiri", "", None)),
                (digest, "testnet", ("", digest, None)),
                (legacy_digest, "testnet", ("", legacy_digest, None)),
                ("v1.0.0", "mainnet", ("v1.0.0", "", None)),
                (ghcr + ":v1.0.0", "mainnet", ("v1.0.0", "", None)),
                (digest, "mainnet", ("", digest, None)),
                ("", "testnet", ("", "", None))):
            with self.subTest(image=value, network=net):
                self.assertEqual(choice(value, net), want)
        for bad, net in (("latest", "testnet"), (ghcr + ":latest", "testnet"), (legacy + ":latest", "testnet"),
                         ("v1.0.0", "testnet"), ("v0.16.0-adiri", "mainnet"), ("v1.0.0-rc1", "mainnet"),
                         (legacy_digest, "mainnet"), (legacy + ":v1.0.0", "mainnet"), ("main", "testnet"),
                         ("busybox@sha256:" + "a" * 64, "testnet"), (ghcr + "-fork:v0.16.0-adiri", "testnet"),
                         (digest, "devnet")):
            with self.subTest(image=bad, network=net):
                tag, img, err = choice(bad, net)
                self.assertIsNone(tag)
                self.assertIn("docker image", err)
        self.assertIn("latest is refused", choice(ghcr + ":latest", "testnet")[2])

    def test_wizard_env_log_target_and_tpm(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            env, _ = server._setup_env(dict(FULL_SETUP, network="mainnet", install_method="release",
                                            build_ref="v1.0.0", docker_image="",
                                            passphrase="a mainnet passphrase 16+"), want_passphrase=True)
            self.assertEqual((env["TN_SETUP_LOG_TARGET"], env["TN_SETUP_ALLOW_NO_TPM"]), ("journal", ""))
            env, _ = server._setup_env(dict(FULL_SETUP, network="mainnet", install_method="release",
                                            build_ref="v1.0.0", log_target="file", allow_no_tpm=True,
                                            passphrase="a mainnet passphrase 16+"), want_passphrase=True)
            self.assertEqual((env["TN_SETUP_LOG_TARGET"], env["TN_SETUP_ALLOW_NO_TPM"]), ("file", "1"))
            self.assertEqual(env["TN_SETUP_DOCKER_IMAGE"], "")
            env, _ = server._setup_env(dict(FULL_SETUP, allow_no_tpm=True), want_passphrase=False)
            self.assertEqual((env["TN_SETUP_LOG_TARGET"], env["TN_SETUP_ALLOW_NO_TPM"]), ("", ""))
            env, err = server._setup_env(dict(FULL_SETUP, log_target="syslog"), want_passphrase=False)
            self.assertEqual(err, "log target must be journal or file")
            env, err = server._setup_env(dict(FULL_SETUP, network="mainnet", install_method="release",
                                              build_ref=""), want_passphrase=False)
            self.assertIn("required for a release install", err)

    def test_wizard_env_for_each_image_form(self):
        ghcr = server.GHCR_IMAGE_REPO
        digest = ghcr + "@sha256:" + "b" * 64
        legacy_digest = server.TESTNET_LEGACY_IMAGE_REPO + "@sha256:" + "b" * 64
        with mock.patch.dict(os.environ, {}, clear=True):
            for image, ref, img in (("v0.16.0-adiri", "v0.16.0-adiri", ""),
                                    (ghcr + ":v0.17.0-adiri", "v0.17.0-adiri", ""),
                                    (server.TESTNET_LEGACY_IMAGE_REPO + ":v0.16.0-adiri", "v0.16.0-adiri", ""),
                                    (digest, "", digest), (legacy_digest, "", legacy_digest)):
                with self.subTest(image=image):
                    env, err = server._setup_env(dict(FULL_SETUP, docker_image=image), want_passphrase=False)
                    self.assertIsNone(err)
                    self.assertEqual((env["TN_SETUP_BUILD_REF"], env["TN_SETUP_DOCKER_IMAGE"]), (ref, img))

    def test_status_shows_the_digest(self):
        # A node installed from the legacy repository: the image .node-meta records.
        self.helper_replies["meta-cat"] = (0, "DOCKER_IMAGE=" + server.TESTNET_LEGACY_IMAGE_REPO
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

    def free_stream_slots(self):
        taken = 0
        while server._LOG_STREAMS.acquire(blocking=False):
            taken += 1
        for _ in range(taken):
            server._LOG_STREAMS.release()
        return taken

    def test_head_requests_hold_no_live_stream_slot(self):
        path = os.path.join(self.tmp.name, "node.log")
        with open(path, "w") as f:
            f.write("a line\n")
        self.patch(server, "parse_service_file", lambda t: {"log_path": path})
        for _ in range(12):
            resp = self.client.head("/api/logs/observer/stream")
            self.assertEqual(resp.status_code, 200)
            resp.close()
        self.assertEqual(self.free_stream_slots(), 8)

    def test_a_quiet_stream_starts_at_once(self):
        # No log line yet: the first frame is a keepalive comment, so the
        # response and its status reach the page without waiting for the log.
        path = os.path.join(self.tmp.name, "quiet.log")
        open(path, "w").close()
        self.patch(server, "parse_service_file", lambda t: {"log_path": path})
        self.patch(server.subprocess, "Popen", REAL_POPEN)   # a real, quiet tail -F
        started = time.monotonic()
        resp = self.client.get("/api/logs/observer/stream", buffered=False)
        self.assertEqual(next(iter(resp.response)), b": keepalive\n\n")
        self.assertLess(time.monotonic() - started, server._STREAM_KEEPALIVE / 3)
        resp.close()
        self.assertEqual(self.free_stream_slots(), 8)

    def test_a_closed_stream_gives_its_slot_back_once(self):
        # The file is missing, so the stream ends on its own; the generator's
        # end and the response close both run, and the slot comes back once
        # (a second release would raise on the bounded semaphore).
        self.patch(server, "parse_service_file",
                   lambda t: {"log_path": os.path.join(self.tmp.name, "absent.log")})
        for _ in range(10):
            resp = self.client.get("/api/logs/observer/stream", buffered=False)
            self.assertIn(b"log file not found", b"".join(resp.response))
            resp.close()
        self.assertEqual(self.free_stream_slots(), 8)

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
                           ("loadcredential", "stdin"), ("tpm", "env")):
            with self.subTest(meta=meta):
                self.helper_replies["meta-cat"] = (0, f"PASSPHRASE_METHOD={meta}\n", "")
                server.clear_meta_cache()
                self.assertEqual(server.detect_passphrase_method("observer"), want)
        self.assertNotIn("tpm", server.PASSPHRASE_METHODS)


if __name__ == "__main__":
    unittest.main()
