"""V5's checks of the UI-S package: the mainnet switch tie (by mutation), the
status page link per network, the P2P sources of /api/firewall/enable and
/api/firewall, the page's source, and the UI unit.

Uses the stubbing of ui/test_server_contract.py (its ServerTestCase replaces
run(), Popen and the network). V5_SRC (default: this checkout) names the tree.

    python -m pytest -q tasks/verify-fup/V5
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("V5_SRC") or os.path.abspath(os.path.join(HERE, "..", "..", ".."))
UI = os.path.join(SRC, "ui")
sys.path.insert(0, UI)

import server  # noqa: E402
import test_server_contract as tsc  # noqa: E402

HELPER = tsc.HELPER_PATH
INDEX = os.path.join(UI, "static", "index.html")
UNIT = os.path.join(UI, "telcoin-ui.service")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


class MainnetFlagMutation(unittest.TestCase):
    """ui/test_mainnet_flag.py must fail when any one of the three switches is
    changed alone, and pass on the tree as it is and with all three flipped."""

    SWITCHES = (
        ("lib/common.sh", "readonly TN_MAINNET_ENABLED=0", "readonly TN_MAINNET_ENABLED=1"),
        ("ui/server.py", "TN_MAINNET_ENABLED = False", "TN_MAINNET_ENABLED = True"),
        ("ui/static/index.html", "const SETUP_MAINNET_ENABLED = false;", "const SETUP_MAINNET_ENABLED = true;"),
    )

    def run_copy(self, edits):
        tmp = tempfile.mkdtemp(prefix="v5flag.")
        self.addCleanup(shutil.rmtree, tmp, True)
        shutil.copytree(UI, os.path.join(tmp, "ui"),
                        ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
        os.makedirs(os.path.join(tmp, "lib"))
        shutil.copy(os.path.join(SRC, "lib", "common.sh"), os.path.join(tmp, "lib", "common.sh"))
        for rel, old, new in edits:
            p = os.path.join(tmp, rel)
            text = read(p)
            self.assertEqual(text.count(old), 1, "%s holds %r once" % (rel, old))
            with open(p, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
        r = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
                            "ui/test_mainnet_flag.py"], cwd=tmp, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def test_unchanged_copy_passes(self):
        rc, out = self.run_copy([])
        self.assertEqual(rc, 0, out)

    def test_each_switch_alone_fails(self):
        for sw in self.SWITCHES:
            with self.subTest(switch=sw[0]):
                rc, out = self.run_copy([sw])
                self.assertNotEqual(rc, 0, out)
                self.assertIn("must change together", out)

    def test_all_three_flipped_together_pass(self):
        rc, out = self.run_copy(list(self.SWITCHES))
        self.assertEqual(rc, 0, out)

    def test_library_line_removed_fails(self):
        rc, out = self.run_copy([("lib/common.sh", "readonly TN_MAINNET_ENABLED=0\n", "\n")])
        self.assertNotEqual(rc, 0, out)


class StatusPageLink(tsc.ServerTestCase):

    def status(self, slug):
        return self.client.get("/api/network/status?slug=" + slug).get_json()

    def test_unreachable_answer_per_network(self):
        want = {"testnet": "https://status.adiri.telcoin.network/", "mainnet": "", "devnet": "", "nope": ""}
        for slug, url in want.items():
            server._network_cache.clear()
            with self.subTest(slug=slug):
                self.assertEqual(self.status(slug).get("status_page"), url)

    def test_fresh_and_cached_answer_per_network(self):
        self.patch(server, "_http_get_json", lambda *a, **k: {})
        for slug, url in (("testnet", "https://status.adiri.telcoin.network/"), ("mainnet", ""), ("devnet", "")):
            server._network_cache.clear()
            with self.subTest(slug=slug):
                first = self.status(slug)
                self.assertTrue(first.get("available"))
                self.assertEqual(first.get("status_page"), url)
                self.assertEqual(self.status(slug).get("status_page"), url)   # cached

    def test_page_names_no_adiri_status_host(self):
        page = read(INDEX)
        self.assertNotIn("status.adiri", page)
        self.assertNotRegex(page, r"https://status\.[a-z.]*adiri")
        self.assertIn("statusPageLink(d)", page)
        self.assertRegex(page, r"https:\\/\\/")       # the link accepts https URLs only

    def test_server_constant_is_marked_network_gated(self):
        line = [l for l in read(os.path.join(UI, "server.py")).splitlines() if "status.adiri" in l]
        self.assertEqual(len(line), 1, line)
        self.assertIn("# network-gated: status page per network", line[0])


class FirewallEnableP2P(tsc.ServerTestCase):

    def post(self, body):
        self.calls.clear()
        server._write_times.clear()
        return self.client.post("/api/firewall/enable", json=body)

    def argv_of(self):
        return [c for c in self.helper_calls() if len(c) > 3 and c[3] == "firewall-enable"]

    def test_argv_shapes(self):
        cases = (
            ({}, []),
            ({"ssh_from": "203.0.113.7"}, ["203.0.113.7"]),
            ({"p2p_from": "198.51.100.0/24, 2001:db8::/48"}, ["-", "198.51.100.0/24,2001:db8::/48"]),
            ({"ssh_from": "203.0.113.7", "p2p_from": "198.51.100.7\n192.0.2.0/24"},
             ["203.0.113.7", "198.51.100.7,192.0.2.0/24"]),
            ({"ssh_from": "", "p2p_from": ""}, []),
            ({"p2p_from": "10.0.0.1,"}, ["-", "10.0.0.1"]),        # trailing comma dropped
        )
        rules = tsc.helper_rules(tsc.split_transitional(tsc.sudoers_text())[0])
        for body, extra in cases:
            with self.subTest(body=body):
                r = self.post(body)
                self.assertEqual(r.status_code, 200, r.get_json())
                self.assertEqual(self.argv_of(), [["sudo", "-n", HELPER, "firewall-enable"] + extra])
                self.assertTrue(tsc.sudo_allows(["sudo", "-n", HELPER, "firewall-enable"] + extra, rules))

    def test_refusals(self):
        bad = {
            "10.0.0.0/4": "P2P sources", "0.0.0.0/0": "P2P sources", "::": "P2P sources",
            "/etc/passwd": "P2P sources", "/10.0.0.1": "P2P sources", "010.0.0.1": "P2P sources",
            "１０.0.0.1": "P2P sources", "10.0.0.1;id": "P2P sources", "$(id)": "P2P sources",
            "10.0.0.1/33": "P2P sources", "-": "P2P sources",
            ",".join("10.0.%d.0/24" % i for i in range(17)): "at most 16 P2P sources",
        }
        for value, msg in bad.items():
            with self.subTest(value=value):
                r = self.post({"ssh_from": "203.0.113.7", "p2p_from": value})
                self.assertEqual(r.status_code, 400)
                self.assertIn(msg, r.get_json()["error"])
                self.assertEqual(self.argv_of(), [])

    def test_sixteen_taken(self):
        r = self.post({"p2p_from": ",".join("10.0.%d.0/24" % i for i in range(16))})
        self.assertEqual(r.status_code, 200)

    def test_non_string(self):
        for value in (123, ["10.0.0.1"], {"a": 1}, True):
            with self.subTest(value=value):
                r = self.post({"p2p_from": value})
                self.assertEqual(r.status_code, 400, value)
                self.assertIn("p2p_from must be text", r.get_json()["error"])
                self.assertEqual(self.argv_of(), [])

    def test_falsy_non_string_is_taken_as_empty(self):
        # Recorded, not required by the spec: 0, [], false and null read as "no list".
        for value in (0, [], False, None):
            with self.subTest(value=value):
                r = self.post({"p2p_from": value})
                self.assertEqual(r.status_code, 200)
                self.assertEqual(self.argv_of(), [["sudo", "-n", HELPER, "firewall-enable"]])

    def test_bad_ssh_refused_first(self):
        r = self.post({"ssh_from": "10.0.0.0/4", "p2p_from": "10.0.0.0/4"})
        self.assertEqual(r.status_code, 400)
        self.assertIn("SSH sources", r.get_json()["error"])

    def test_external_node_refused(self):
        self.nodes = tsc.external_nodes()
        r = self.post({"p2p_from": "10.0.0.0/4"})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(self.argv_of(), [])


class FirewallStatusP2P(tsc.ServerTestCase):

    LIMIT = {"active": True, "rate": 20, "burst": 40, "reason": None, "persistent": False}

    def get(self, meta=None, engine=None):
        server.clear_meta_cache()
        if meta is not None:
            self.helper_replies["meta-cat"] = meta
        if engine is not None:
            self.helper_replies["firewall-status"] = (0, json.dumps(engine), "")
        return self.client.get("/api/firewall").get_json()

    def test_p2p_sources_shapes(self):
        self.assertEqual(self.get((0, "NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8,192.0.2.7\n", ""))["p2p_sources"],
                         ["10.0.0.0/8", "192.0.2.7"])
        self.assertEqual(self.get((0, "NETWORK=testnet\n", ""))["p2p_sources"], [])
        self.assertIsNone(self.get((1, "", "sudo: a password is required"))["p2p_sources"])

    def test_limit_passes_through(self):
        for lim in (self.LIMIT, {"active": False, "rate": None, "burst": None, "reason": "nft-missing", "persistent": False}):
            with self.subTest(lim=lim):
                d = self.get((0, "NETWORK=testnet\n", ""), {"installed": True, "active": True, "p2p_new_flow_limit": lim})
                self.assertEqual(d["p2p_new_flow_limit"], lim)

    def test_engine_p2p_sources_wins(self):
        d = self.get((0, "P2P_ALLOW_FROM=10.0.0.0/8\n", ""), {"installed": True, "p2p_sources": ["x"]})
        self.assertEqual(d["p2p_sources"], ["x"])

    def test_doubled_key_recorded(self):
        # The engine refuses a .node-meta that sets P2P_ALLOW_FROM twice; record what the UI shows.
        d = self.get((0, "P2P_ALLOW_FROM=10.0.0.0/8\nP2P_ALLOW_FROM=192.0.2.0/24\n", ""))
        print("V5 doubled P2P_ALLOW_FROM -> p2p_sources", d["p2p_sources"])

    def test_meta_cache_dropped_after_enable(self):
        self.get((0, "NETWORK=testnet\n", ""))
        self.helper_replies["meta-cat"] = (0, "P2P_ALLOW_FROM=198.51.100.0/24\n", "")
        self.client.post("/api/firewall/enable", json={"p2p_from": "198.51.100.0/24"})
        self.assertEqual(self.client.get("/api/firewall").get_json()["p2p_sources"], ["198.51.100.0/24"])


class PageAndUnitSource(unittest.TestCase):

    def test_card_rows_and_reasons(self):
        page = read(INDEX)
        for token in ("P2P sources", "P2P new-flow limit", "fwP2pSourcesText(f)",
                      "fwNewFlowLimitText(f.p2p_new_flow_limit)", "'every address'",
                      "' (not restored at boot)'", "'p2p-list'", "'nft-missing'", "'not-applied'", "'unreadable'",
                      'id="fwP2pFrom"', "p2p_from: p2p.list"):
            with self.subTest(token=token):
                self.assertIn(token, page)

    def test_unit_limitcore_and_nonewprivileges_comment(self):
        text = read(UNIT)
        svc = text.split("[Service]", 1)[1].split("[Install]", 1)[0]
        self.assertRegex(svc, r"(?m)^LimitCORE=0$")
        self.assertNotRegex(text, r"(?m)^NoNewPrivileges=")
        self.assertRegex(text, r"(?m)^#.*NoNewPrivileges")


if __name__ == "__main__":
    unittest.main()
