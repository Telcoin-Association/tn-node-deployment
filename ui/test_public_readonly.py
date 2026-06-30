#!/usr/bin/env python3
"""
Regression test for the public/management read-only boundary (server.py).

Background
----------
The node manager UI is reachable two ways:

  * SSH tunnel -> 127.0.0.1:8080. Fully trusted; no header is present.
  * Public     -> through the Caddy reverse proxy, which stamps an unforgeable
                  ``X-TN-Dashboard-Public: 1`` header on every request
                  (install-caddy.sh). The SSH path never carries it.

``server._enforce_public_readonly`` (a ``before_request`` hook) must refuse
(HTTP 403) every state-mutating request that arrives on the public path, while
leaving read requests untouched. POST/PUT/DELETE/PATCH are always writes; a GET
is a write only if it matches one of the action-stream patterns hard-coded in
``server._is_write_request`` (config "set", update "prepare"/"apply").

Why this test exists (residual risk R2)
---------------------------------------
The read/write split for GET routes is pattern-matched, not declared. A future
mutating endpoint added as a GET that does not match those patterns would be
silently exposed on the public path. This test is the tripwire:

  1. Every route in ``app.url_map`` must be classified below as a read or a
     write. Adding any ``@app.route`` fails this test until the route is
     classified -- forcing a conscious read/write decision.
  2. Every route classified as a write must actually be refused (403) on the
     public path. A GET write that nobody added to ``_is_write_request`` fails
     here -- catching the R2 gap directly.
  3. Every route classified as a read must NOT be refused, so the gate never
     silently breaks legitimate public reads (or over-blocks a read whose path
     happens to resemble a write pattern).

Run with (no third-party deps beyond Flask, which the UI already requires):

    cd ui && python3 -m unittest test_public_readonly
"""

import os
import re
import sys
import unittest

# Import server.py regardless of the working directory the test runs from.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import server  # noqa: E402

PUBLIC_HEADER = "X-TN-Dashboard-Public"

# -- Route classification -----------------------------------------------------
# Keyed by Flask endpoint (the view function name) -- stable and unique. When
# this test fails with "unclassified route", add the new endpoint to exactly
# one set below after deciding whether it mutates node/host state. A mutating
# GET must ALSO be matched by server._is_write_request, or test 2 will fail.

WRITE_ENDPOINTS = {
    # Mutating by HTTP method -- _is_write_request blocks all POST/PUT/DELETE/PATCH.
    "api_caddy_disable",
    "api_caddy_dns_check",
    "api_caddy_enable",
    "api_rpc_disable",
    "api_rpc_dns_check",
    "api_rpc_enable",
    "api_clear_rotated",
    "api_set_hostname",
    "api_set_logrotate",
    "api_firewall_port",
    "api_jaeger_start",
    "api_jaeger_stop",
    "api_logs_clear",
    "api_service",
    "api_setup_finalize",
    "api_setup_keygen",
    "api_tracing_disable",
    "api_tracing_enable",
    "api_update_discard",
    # GET action streams -- mutating despite the verb. Each MUST be matched by
    # server._is_write_request (config "/set", update "prepare/"/"apply/").
    "api_config_set",
    "api_update_apply",
    "api_update_prepare",
}

READ_ENDPOINTS = {
    "index",
    "static",
    "api_addons_status",
    "api_build_info",
    "api_caddy_status",
    "api_config",
    "api_firewall",
    "api_jaeger_status",
    "api_logs",
    "api_logs_download",
    "api_logs_stream",
    "api_netstat",
    "api_network_status",
    "api_nodes",
    "api_setup_defaults",
    "api_preflight",
    "api_rpc_status",
    "api_status",
    "api_system",
    "api_traces",
    "api_traces_stats",
    "api_tracing_status",
    "api_update_status",
    "api_validator",
    "api_version",
}


def _concrete_path(rule):
    """A real path for a rule pattern: replace every ``<converter>`` placeholder
    with a dummy segment. Only the prefix/suffix matters to _is_write_request,
    and the dummy preserves those (e.g. ``/api/config/x/set`` still ends /set)."""
    return re.sub(r"<[^>]+>", "x", rule.rule)


def _real_methods(rule):
    """The HTTP methods a rule actually serves (drop auto-added HEAD/OPTIONS)."""
    return sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS"))


def _gate_refuses(path, method, public):
    """True if _enforce_public_readonly refuses a request to (path, method).

    public=True simulates the Caddy path (header stamped); public=False the SSH
    tunnel (no header)."""
    headers = {PUBLIC_HEADER: "1"} if public else {}
    with server.app.test_request_context(path, method=method, headers=headers):
        return server._enforce_public_readonly() is not None


class PublicReadonlyBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.rules = list(server.app.url_map.iter_rules())

    def test_every_route_is_classified(self):
        """Tripwire: a new route must be declared read or write in this file."""
        endpoints = {r.endpoint for r in self.rules}
        classified = WRITE_ENDPOINTS | READ_ENDPOINTS

        unclassified = endpoints - classified
        self.assertEqual(
            unclassified,
            set(),
            "Unclassified route(s) %s. Add each to WRITE_ENDPOINTS or "
            "READ_ENDPOINTS here after deciding whether it mutates state. A "
            "mutating GET must also be added to server._is_write_request."
            % sorted(unclassified),
        )

        stale = classified - endpoints
        self.assertEqual(
            stale, set(),
            "Classified endpoint(s) no longer exist in app.url_map: %s"
            % sorted(stale),
        )

        overlap = WRITE_ENDPOINTS & READ_ENDPOINTS
        self.assertEqual(
            overlap, set(),
            "Endpoint(s) classified as BOTH read and write: %s" % sorted(overlap),
        )

    def test_writes_are_refused_on_public_path(self):
        """Every write route returns 403 on the public path, for every method
        it serves. A mutating GET not matched by _is_write_request fails here."""
        for rule in self.rules:
            if rule.endpoint not in WRITE_ENDPOINTS:
                continue
            path = _concrete_path(rule)
            for method in _real_methods(rule):
                with self.subTest(endpoint=rule.endpoint, method=method, path=path):
                    self.assertTrue(
                        _gate_refuses(path, method, public=True),
                        "WRITE route %s [%s] is NOT refused on the public path. "
                        "If it is a GET, extend server._is_write_request to match it."
                        % (path, method),
                    )

    def test_reads_are_allowed_on_public_path(self):
        """No read route is refused on the public path (gate must not over-block)."""
        for rule in self.rules:
            if rule.endpoint not in READ_ENDPOINTS:
                continue
            path = _concrete_path(rule)
            with self.subTest(endpoint=rule.endpoint, path=path):
                self.assertFalse(
                    _gate_refuses(path, "GET", public=True),
                    "READ route %s is refused on the public path (gate over-blocks)."
                    % path,
                )

    def test_ssh_path_is_never_refused(self):
        """The trusted loopback path (no header) keeps full management: the gate
        must never fire there, not even for writes."""
        for rule in self.rules:
            path = _concrete_path(rule)
            for method in _real_methods(rule):
                with self.subTest(endpoint=rule.endpoint, method=method, path=path):
                    self.assertFalse(
                        _gate_refuses(path, method, public=False),
                        "Route %s [%s] was refused on the SSH path -- management "
                        "must work over the tunnel." % (path, method),
                    )


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
        # Caddy only ever Sets "1", but any non-empty value of any shape must
        # still read as public so the gate fails safe rather than open.
        self.assertTrue(self._is_public("0"))


if __name__ == "__main__":
    unittest.main()
