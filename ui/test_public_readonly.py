#!/usr/bin/env python3
"""
The public (Caddy) path of server.py: read-only, a fixed allowlist of GET
routes, no root helper, and /api/status without the operator-only fields.

The UI is reachable two ways:

  * SSH tunnel -> 127.0.0.1:8080, with the per-install token (test_csrf.py).
  * Public     -> through the Caddy reverse proxy, which stamps an unforgeable
                  ``X-TN-Dashboard-Public: 1`` header on every request
                  (install-caddy.sh). The SSH path never carries it.

Covered here:

  1. Every route in ``app.url_map`` is classified below as a read (GET) or a
     write (POST). Adding a route fails the test until it is classified.
  2. Every write is refused (403) on the public path.
  3. Only the reads in server.PUBLIC_ENDPOINTS answer on the public path; every
     other read is refused (403).
  4. A public request never reaches sudo or the helper, and never fills a cache
     the operator view reads.
  5. Public /api/status drops server.PUBLIC_STATUS_DROP, /api/nodes drops
     server.PUBLIC_NODES_DROP and /api/system server.PUBLIC_SYSTEM_DROP;
     /api/version and /api/nodes give the major version only.

    python3 -m pytest -q ui/test_public_readonly.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import server  # noqa: E402
from test_support import local_client  # noqa: E402

local_client(server)

import types  # noqa: E402

from test_server_contract import REAL_RUN, ServerTestCase  # noqa: E402

PUBLIC_HEADER = "X-TN-Dashboard-Public"
PUB = {PUBLIC_HEADER: "1"}

WRITE_ENDPOINTS = {
    "api_caddy_disable", "api_caddy_dns_check", "api_caddy_enable",
    "api_rpc_disable", "api_rpc_dns_check", "api_rpc_enable",
    "api_clear_rotated", "api_set_hostname", "api_set_logrotate",
    "api_firewall_port", "api_jaeger_start", "api_jaeger_stop",
    "api_logs_clear", "api_service", "api_setup_finalize", "api_setup_keygen",
    "api_tracing_disable", "api_tracing_enable", "api_update_discard",
    "api_config_set", "api_update_apply", "api_update_prepare",
    "api_config_credential",
}

READ_ENDPOINTS = {
    "index", "static", "api_addons_status", "api_build_info", "api_caddy_status",
    "api_config", "api_firewall", "api_jaeger_status", "api_logs",
    "api_logs_download", "api_logs_stream", "api_netstat", "api_network_status",
    "api_nodes", "api_setup_defaults", "api_preflight", "api_rpc_status",
    "api_status", "api_system", "api_traces", "api_traces_stats",
    "api_tracing_status", "api_update_status", "api_validator", "api_version",
}


def _concrete_path(rule):
    import re
    return re.sub(r"<[^>]+>", "x", rule.rule)


def _real_methods(rule):
    return sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS"))


def _gate_refuses(path, method, public):
    headers = dict(PUB) if public else {}
    with server.app.test_request_context(path, method=method, headers=headers):
        # Route matching happens on push; request.endpoint is what the gate reads.
        return server._enforce_public_readonly() is not None


class PublicReadonlyBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.rules = list(server.app.url_map.iter_rules())

    def test_every_route_is_classified(self):
        endpoints = {r.endpoint for r in self.rules}
        classified = WRITE_ENDPOINTS | READ_ENDPOINTS
        self.assertEqual(endpoints - classified, set(),
                         "unclassified route(s): add each to WRITE_ENDPOINTS or READ_ENDPOINTS")
        self.assertEqual(classified - endpoints, set(), "classified endpoints that no longer exist")
        self.assertEqual(WRITE_ENDPOINTS & READ_ENDPOINTS, set())

    def test_reads_are_get_and_writes_are_post(self):
        for rule in self.rules:
            with self.subTest(endpoint=rule.endpoint):
                want = ["POST"] if rule.endpoint in WRITE_ENDPOINTS else ["GET"]
                self.assertEqual(_real_methods(rule), want)

    def test_writes_are_refused_on_public_path(self):
        for rule in self.rules:
            if rule.endpoint not in WRITE_ENDPOINTS:
                continue
            with self.subTest(endpoint=rule.endpoint):
                self.assertTrue(_gate_refuses(_concrete_path(rule), "POST", public=True))

    def test_only_allowlisted_reads_answer_on_public_path(self):
        self.assertLessEqual(server.PUBLIC_ENDPOINTS, READ_ENDPOINTS)
        for rule in self.rules:
            if rule.endpoint not in READ_ENDPOINTS:
                continue
            path = _concrete_path(rule)
            with self.subTest(endpoint=rule.endpoint, path=path):
                self.assertEqual(_gate_refuses(path, "GET", public=True),
                                 rule.endpoint not in server.PUBLIC_ENDPOINTS)

    def test_ssh_path_is_never_refused_by_the_public_gate(self):
        for rule in self.rules:
            path = _concrete_path(rule)
            for method in _real_methods(rule):
                with self.subTest(endpoint=rule.endpoint, method=method):
                    self.assertFalse(_gate_refuses(path, method, public=False))

    def test_unknown_path_is_refused_on_public_path(self):
        self.assertTrue(_gate_refuses("/api/nope", "GET", public=True))


class PublicRequestDetectionTest(unittest.TestCase):
    """is_public_request must fail safe: any non-empty header value reads as
    public (-> read-only); an absent header is the trusted SSH path."""

    def _is_public(self, value):
        headers = {} if value is None else {PUBLIC_HEADER: value}
        with server.app.test_request_context("/api/nodes", headers=headers):
            return server.is_public_request()

    def test_ssh_path_has_no_header(self):
        self.assertFalse(self._is_public(None))

    def test_caddy_value_is_public(self):
        self.assertTrue(self._is_public("1"))

    def test_falsy_looking_value_still_reads_public(self):
        self.assertTrue(self._is_public("0"))


class PublicResponsesTest(ServerTestCase):
    """The public endpoints, served through the test client with Caddy's header
    (and a public Host, as Caddy forwards it)."""

    def setUp(self):
        super().setUp()
        # The real run(), so its public-path guard is what is tested; the
        # subprocess underneath answers from the same fixtures.
        self.patch(server, "run", REAL_RUN)
        server.subprocess.run = self.fake_subprocess_run

    def fake_subprocess_run(self, cmd, **_kw):
        rc, out, err = self.fake_run(cmd)
        return types.SimpleNamespace(returncode=rc, stdout=out, stderr=err)

    def get_public(self, path):
        return self.client.get(path, headers=dict(PUB, Host="dashboard.example.com"))

    def test_no_public_route_calls_sudo(self):
        for path in ("/api/nodes", "/api/status/observer", "/api/validator/observer",
                     "/api/version/observer", "/api/system", "/"):
            with self.subTest(path=path):
                self.calls.clear()
                resp = self.get_public(path)
                self.assertLess(resp.status_code, 500)
                self.assertEqual([c for c in self.calls if c[:1] == ["sudo"]], [])

    def test_public_requests_leave_the_operator_caches_alone(self):
        server.clear_meta_cache()
        self.get_public("/api/status/observer")
        self.assertEqual(server._meta_cache, {})
        self.assertIsNone(server._detect_cache["data"])

    def test_public_status_drops_operator_fields(self):
        body = self.get_public("/api/status/observer").get_json()
        self.assertTrue(body.get("installed"))
        for key in server.PUBLIC_STATUS_DROP:
            with self.subTest(key=key):
                self.assertNotIn(key, body)
        operator = self.client.get("/api/status/observer").get_json()
        for key in ("internal_ip", "data_dir", "passphrase_method", "docker_image"):
            with self.subTest(key=key):
                self.assertIn(key, operator)

    def test_public_nodes_drop_image_container_and_service(self):
        body = self.get_public("/api/nodes").get_json()
        self.assertIsNotNone(body["node"])
        for slot in [body[t] for t in server.NODE_TYPES] + [body["node"]]:
            for key in server.PUBLIC_NODES_DROP:
                with self.subTest(slot=slot.get("type"), key=key):
                    self.assertNotIn(key, slot)
        operator = self.client.get("/api/nodes").get_json()
        self.assertIn("service", operator["node"])
        self.assertIn("image", operator["observer"])

    def test_public_system_drops_host_name_and_releases(self):
        body = self.get_public("/api/system").get_json()
        for key in server.PUBLIC_SYSTEM_DROP:
            with self.subTest(key=key):
                self.assertNotIn(key, body)
        self.assertIn("memory", body)
        operator = self.client.get("/api/system").get_json()
        for key in server.PUBLIC_SYSTEM_DROP:
            with self.subTest(key=key):
                self.assertIn(key, operator)

    def test_public_version_is_major_only(self):
        self.patch(server, "node_version", lambda t: {"ref": "v0.16.0-adiri", "kind": "source"})
        self.assertEqual(self.get_public("/api/version/observer").get_json()["ref"], "v0")
        self.assertEqual(self.client.get("/api/version/observer").get_json()["ref"], "v0.16.0-adiri")
        self.assertEqual(self.get_public("/api/nodes").get_json()["ui_version"],
                         server._major(server.UI_VERSION))

    def test_public_path_needs_no_token_but_refuses_the_rest(self):
        resp = self.client.get("/api/firewall", headers=dict(PUB, Host="dashboard.example.com"))
        self.assertEqual(resp.status_code, 403)
        resp = self.client.post("/api/service/observer/restart", json={},
                                headers=dict(PUB, Host="dashboard.example.com"))
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(self.helper_calls(), [])


if __name__ == "__main__":
    unittest.main()
