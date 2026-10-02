#!/usr/bin/env python3
"""
Chain-side tests for ui/server.py: how the node's role is decided and shown,
the strict getValidator decoder, and the epoch fields of /api/validator.

Covered:
  * decode_validator_info on the payload rpc.adiri.tel returned for a committee
    member, and on malformed variants; the 0xed15e6cf revert as "no record";
  * network_stake_status: an endpoint whose eth_chainId differs from the
    node's chain is not trusted, and at most two endpoints are asked;
  * onchain_role through /api/nodes: network, local, cached and default
    sources, and the saved answer used only for the same execution address;
  * detect_nodes: the observer slot first and the chain's remap, external
    containers included; NODE_TYPE in .node-meta has no effect; legacy paths
    follow the unit name, not the slot;
  * /api/validator epoch fields: the boundary from the block timestamp,
    earliest_seat_epoch only for status 2 to 4, seat_epoch null against left
    out, and one tn_getCurrentEpochInfo call per poll with the boundary block
    cached.

No network, no sudo, no node: urllib.request.urlopen answers from a JSON-RPC
table, run() answers helper calls from fixtures, and unit files, configs and
the saved role live in a per-test temp directory. Python 3.10 or later with
Flask (ui/requirements.txt):

    python3 -m unittest discover -s ui -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import server  # noqa: E402

LOCAL = "http://127.0.0.1:8545"
TESTNET_RPC = "https://rpc.adiri.tel"

# A committee member on testnet, and what rpc.adiri.tel answered for it and for
# 0x...dEaD (no ConsensusNFT) on 2026-10-01, read-only.
ADDR = "0x0033a370616805b1fd275b7ffab83fc41d665ccb"
LIVE_COMMITTEE_RESULT = (
    "0x0000000000000000000000000033a370616805b1fd275b7ffab83fc41d665ccb"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000003"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000")
DEAD = "0x000000000000000000000000000000000000dEaD"
LIVE_DEAD_REVERT = {"error": {
    "code": 3, "message": "execution reverted",
    "data": "0xed15e6cf000000000000000000000000000000000000000000000000000000000000dead"}}
OTHER = "0x" + "ab" * 20


def words(*values):
    return "0x" + "".join("%064x" % v for v in values)


def record(status, activation=0, exit_epoch=0, retired=0, version=0, region=0, addr=ADDR):
    """A getValidator result in the v0.15.0-adiri layout."""
    return words(int(addr, 16), activation, exit_epoch, status, retired, version, region)


def ok(result):
    return {"result": result}


def registry(get_validator):
    """An eth_call answer: getValidator gets `get_validator` (a response dict);
    the other registry reads get no answer."""
    def answer(params):
        if params[0]["data"].startswith(server.REGISTRY_SELECTORS["getValidator"]):
            return get_validator
        return None
    return answer


class FakeChain:
    """JSON-RPC answers by (endpoint, method), recording every call. A missing
    answer (or a callable that returns None) behaves like a refused connection."""

    def __init__(self):
        self.answers = {}
        self.calls = []

    def set(self, url, method, answer):
        self.answers[(url, method)] = answer

    def drop(self, url, method=None):
        for key in [k for k in self.answers if k[0] == url and method in (None, k[1])]:
            del self.answers[key]

    def urlopen(self, req, timeout=None):
        url = req.full_url
        body = json.loads(req.data.decode())
        method, params = body["method"], body.get("params") or []
        self.calls.append((url, method, params))
        answer = self.answers.get((url, method))
        resp = answer(params) if callable(answer) else answer
        if resp is None:
            raise urllib.error.URLError("connection refused (no answer in FakeChain)")
        return io.BytesIO(json.dumps(dict({"jsonrpc": "2.0", "id": 1}, **resp)).encode())

    def methods(self, url=None):
        return [m for u, m, _ in self.calls if url is None or u == url]

    def urls(self):
        return [u for u, _, _ in self.calls]


class ChainTestCase(unittest.TestCase):
    """A host with paths in a temp directory, a fake chain, and helper replies
    from fixtures. No unit is installed until a test installs one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        self.systemd = os.path.join(root, "systemd")
        self.etc = os.path.join(root, "etc-telcoin")
        self.var = os.path.join(root, "var-lib-telcoin")
        self.ui_dir = os.path.join(root, "opt-telcoin-ui")
        for d in (self.systemd, self.etc, self.var, self.ui_dir):
            os.makedirs(d)
        self.role_file = os.path.join(self.ui_dir, "node-role.json")

        self.chain = FakeChain()
        self.meta = {"NODE_TYPE": "observer", "NETWORK": "testnet", "RPC_PORT": "8545"}
        self.containers = []
        self.inspect = {}
        self.node_info = ""
        self.run_calls = []
        self.logs = []

        for name, value in (("_log", self.logs.append),
                            ("SYSTEMD_DIR", self.systemd), ("DEFAULT_CONFIG_DIR", self.etc),
                            ("DEFAULT_DATA_DIR", self.var), ("NODE_ROLE_FILE", self.role_file),
                            ("run", self.fake_run)):
            self.patch(server, name, value)
        self.patch(server.urllib.request, "urlopen", self.chain.urlopen)

        server._detect_cache.update({"ts": 0.0, "data": None})
        server.clear_meta_cache()
        server.clear_role_cache()
        server._epoch_start_cache.update({"key": None, "ts": None})
        server._committee_cache.update({"key": None, "committees": {}})
        server._helper_cache.update({"expires": 0.0, "data": None})
        server._chain_mismatch_logged.clear()
        server._role_save_logged["failed"] = False
        self.client = server.app.test_client()

    def patch(self, obj, name, value):
        p = mock.patch.object(obj, name, value)
        p.start()
        self.addCleanup(p.stop)

    def fake_run(self, cmd, timeout=10):
        cmd = [str(c) for c in cmd]
        self.run_calls.append(cmd)
        if cmd[:3] == ["sudo", "-n", server.HELPER] and len(cmd) > 3:
            sub = cmd[3]
            if sub == "meta-cat":
                return 0, "\n".join(f"{k}={v}" for k, v in self.meta.items()), ""
            if sub == "helper-version":
                return 0, "2", ""
            if sub == "docker-detect":
                return 0, "\n".join(self.containers), ""
            if sub == "docker-status":
                return 0, json.dumps([self.inspect]), ""
            if sub == "docker-node-info":
                return 0, self.node_info, ""
            return 1, "", "no fixture for " + sub
        if cmd[:2] == ["systemctl", "is-active"]:
            return 0, "active", ""
        return 127, "", "not found"

    # -- host and chain set-ups ------------------------------------------------

    def install_unit(self, name="telcoin"):
        with open(os.path.join(self.systemd, name + ".service"), "w") as f:
            f.write("[Service]\nExecStart=/usr/bin/docker run --rm --name telcoin "
                    "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri\n"
                    "StandardOutput=append:/var/log/telcoin/telcoin.log\n")

    def node_up(self, synced=True, address=ADDR, url=LOCAL):
        """A running node: chain 2017, its execution address from tn_info, and
        synced (local block at the consensus execution tip) or 990 blocks behind."""
        c = self.chain
        c.set(url, "eth_chainId", ok("0x7e1"))
        c.set(url, "tn_info", ok({"execution_address": address, "bls_public_key": "blsKey",
                                  "name": "node7"}))
        c.set(url, "eth_blockNumber", ok(hex(1000 if synced else 10)))
        c.set(url, "tn_latestConsensusHeader", ok({
            "number": 497019,
            "sub_dag": {"headers": [{"epoch": 580, "latest_execution_block": {"number": 1000}}],
                        "commit_timestamp": int(time.time())}}))

    def local_validator(self, get_validator):
        self.chain.set(LOCAL, "eth_call", registry(get_validator))

    def network(self, get_validator, chain="0x7e1", url=TESTNET_RPC):
        self.chain.set(url, "eth_chainId", ok(chain))
        self.chain.set(url, "eth_call", registry(get_validator))

    def nodes(self, public=False):
        server._detect_cache["data"] = None
        headers = {"X-TN-Dashboard-Public": "1"} if public else {}
        return self.client.get("/api/nodes", headers=headers).get_json()

    def saved(self):
        with open(self.role_file) as f:
            return json.load(f)

    def save(self, **record_):
        data = {"address": ADDR, "chain_id": 2017, "validator": True, "status": 3,
                "source": "network", "checked_at": 1790000000}
        data.update(record_)
        with open(self.role_file, "w") as f:
            json.dump(data, f)


# ---------------------------------------------------------------------------
# decode_validator_info and the getValidator reply
# ---------------------------------------------------------------------------

class DecodeTest(unittest.TestCase):

    def test_live_committee_payload(self):
        self.assertEqual(server.decode_validator_info(LIVE_COMMITTEE_RESULT), {
            "validator_address": ADDR, "activation_epoch": 0, "exit_epoch": 0,
            "status": 3, "is_retired": False, "stake_version": 0, "region": 0})

    def test_every_field_at_its_limit(self):
        info = server.decode_validator_info(words(2**160 - 1, 2**32 - 1, 2**32 - 1, 5, 1, 255, 255))
        self.assertEqual((info["validator_address"], info["activation_epoch"], info["exit_epoch"],
                          info["status"], info["is_retired"], info["stake_version"], info["region"]),
                         ("0x" + "f" * 40, 2**32 - 1, 2**32 - 1, 5, True, 255, 255))

    def test_retired_sentinel(self):
        # _retire stores status 6 (Any) together with isRetired.
        info = server.decode_validator_info(record(6, retired=1))
        self.assertEqual((info["status"], info["is_retired"]), (6, True))
        self.assertIsNone(server.decode_validator_info(record(6, retired=0)))

    def test_rejections(self):
        a = int(ADDR, 16)
        cases = {
            "short payload": LIVE_COMMITTEE_RESULT[:-64],
            "an eighth word": LIVE_COMMITTEE_RESULT + "0" * 64,
            "half a word more": LIVE_COMMITTEE_RESULT + "0" * 32,
            "no 0x prefix": LIVE_COMMITTEE_RESULT[2:],
            "not hex": LIVE_COMMITTEE_RESULT[:-1] + "g",
            "empty result": "0x",
            "address above 160 bits": words(a | 1 << 160, 0, 0, 3, 0, 0, 0),
            "activation epoch above uint32": words(a, 2**32, 0, 3, 0, 0, 0),
            "exit epoch above uint32": words(a, 0, 2**32, 3, 0, 0, 0),
            "status word above uint8": words(a, 0, 0, 0x103, 0, 0, 0),
            "retired 2": record(3, retired=2),
            "status 7": record(7),
            "status 6 without retired": record(6),
            "stake version above uint8": record(3, version=256),
            "region above uint8": record(3, region=256),
        }
        for name, payload in cases.items():
            with self.subTest(name):
                self.assertIsNone(server.decode_validator_info(payload))
        for value in (None, 3, b"0x00", ["0x"]):
            with self.subTest(value=value):
                self.assertIsNone(server.decode_validator_info(value))

    def test_no_record_revert(self):
        self.assertEqual(server._validator_reply(LIVE_DEAD_REVERT, DEAD), server.NO_RECORD)
        upper = {"error": dict(LIVE_DEAD_REVERT["error"],
                               data=LIVE_DEAD_REVERT["error"]["data"].upper().replace("0X", "0x"))}
        self.assertEqual(server._validator_reply(upper, DEAD), server.NO_RECORD)

    def test_other_errors_tell_nothing(self):
        for err in ({"code": 3, "message": "execution reverted"},
                    {"code": 3, "message": "execution reverted", "data": "0x61f51356"},
                    {"code": -32601, "message": "method not found"},
                    "boom"):
            with self.subTest(err=err):
                self.assertIsNone(server._validator_reply({"error": err}, ADDR))
        self.assertIsNone(server._validator_reply(None, ADDR))
        self.assertIsNone(server._validator_reply(ok("0x"), ADDR))

    def test_reply_names_the_address_asked(self):
        self.assertIsNone(server._validator_reply(ok(record(3, addr=OTHER)), ADDR))
        # Whitelisted, never staked: the storage slot is empty, address zero.
        zero = server._validator_reply(ok(record(0, addr="0x" + "0" * 40)), ADDR)
        self.assertEqual(zero["status"], 0)
        # The asked address may come in any case or with spaces.
        self.assertEqual(server._validator_reply(ok(LIVE_COMMITTEE_RESULT),
                                                 " 0X0033A370616805B1FD275B7FFAB83FC41D665CCB ")
                         ["status"], 3)

    def test_registry_stake_status_reads_the_local_node(self):
        logs = []
        chain = FakeChain()
        chain.set(LOCAL, "eth_call", registry(ok(LIVE_COMMITTEE_RESULT)))
        with mock.patch.object(server.urllib.request, "urlopen", chain.urlopen), \
                mock.patch.object(server, "_log", logs.append):
            self.assertEqual(server.registry_stake_status(8545, ADDR)["status"], 3)
            chain.set(LOCAL, "eth_call", registry(LIVE_DEAD_REVERT))
            self.assertEqual(server.registry_stake_status(8545, DEAD), server.NO_RECORD)
            self.assertIsNone(server.registry_stake_status(8545, "not an address"))
        self.assertEqual(len(chain.calls), 2, "an invalid address is never sent")


# ---------------------------------------------------------------------------
# network_stake_status
# ---------------------------------------------------------------------------

class NetworkStakeTest(ChainTestCase):

    def test_testnet_endpoint(self):
        self.network(ok(LIVE_COMMITTEE_RESULT))
        self.assertEqual(server.network_stake_status(ADDR, 2017)["status"], 3)
        self.assertEqual(self.chain.methods(), ["eth_chainId", "eth_call"])
        self.network(LIVE_DEAD_REVERT)
        self.assertEqual(server.network_stake_status(DEAD, 2017), server.NO_RECORD)

    def test_chain_id_mismatch_makes_an_endpoint_untrusted(self):
        devnet = server.NETWORK_PUBLIC_RPC[32285]
        # The first devnet endpoint answers for testnet; its registry is never asked.
        self.network(ok(record(3)), chain="0x7e1", url=devnet[0])
        self.network(ok(record(1)), chain=hex(32285), url=devnet[1])
        answer = server.network_stake_status(ADDR, 32285)
        self.assertEqual(answer["status"], 1)
        self.assertEqual(self.chain.methods(devnet[0]), ["eth_chainId"])
        self.assertEqual(self.chain.methods(devnet[1]), ["eth_chainId", "eth_call"])
        server.network_stake_status(ADDR, 32285)
        mismatch = [m for m in self.logs if "serves chain 2017, not 32285" in m]
        self.assertEqual(len(mismatch), 1, "the mismatch is logged once, not on every check")

    def test_mainnet_hostname_serving_testnet_is_not_a_mainnet_answer(self):
        # rpc.telcoin.network answers eth_chainId 0x7e1 until mainnet launches.
        self.patch(server, "NETWORK_PUBLIC_RPC", {487: ["https://rpc.telcoin.network"]})
        self.network(ok(record(3)), chain="0x7e1", url="https://rpc.telcoin.network")
        self.assertIsNone(server.network_stake_status(ADDR, 487))
        self.assertEqual(self.chain.methods(), ["eth_chainId"])

    def test_at_most_two_endpoints(self):
        self.assertIsNone(server.network_stake_status(ADDR, 32285))
        self.assertEqual(sorted(set(self.chain.urls())),
                         sorted(server.NETWORK_PUBLIC_RPC[32285][:2]))

    def test_an_unusable_answer_moves_on(self):
        devnet = server.NETWORK_PUBLIC_RPC[32285]
        self.network(ok(record(7)), chain=hex(32285), url=devnet[0])     # malformed
        self.network(ok(record(4)), chain=hex(32285), url=devnet[1])
        self.assertEqual(server.network_stake_status(ADDR, 32285)["status"], 4)

    def test_nothing_to_ask(self):
        self.assertIsNone(server.network_stake_status(ADDR, None))
        self.assertIsNone(server.network_stake_status(ADDR, 487))      # no endpoint listed
        self.assertIsNone(server.network_stake_status("0x123", 2017))  # not an address
        self.assertEqual(self.chain.calls, [])

    def test_each_endpoint_gets_three_seconds(self):
        seen = []
        real = self.chain.urlopen

        def timed(req, timeout=None):
            seen.append(timeout)
            return real(req, timeout)
        self.patch(server.urllib.request, "urlopen", timed)
        self.network(ok(LIVE_COMMITTEE_RESULT))
        server.network_stake_status(ADDR, 2017)
        self.assertEqual(seen[0], 3.0)
        self.assertTrue(0 < seen[1] < 3.0, "the second call gets what is left of the three")


# ---------------------------------------------------------------------------
# onchain_role through /api/nodes
# ---------------------------------------------------------------------------

class RoleSourceTest(ChainTestCase):

    def setUp(self):
        super().setUp()
        self.install_unit()

    def test_network_answer(self):
        self.node_up()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        before = int(time.time())
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("validator", "network"))
        self.assertTrue(before <= data["role_checked_at"] <= int(time.time()))
        self.assertEqual(data["role_address"], ADDR)
        self.assertTrue(data["validator"]["staked"])
        self.assertFalse(data["observer"]["installed"])
        self.assertNotIn("eth_call", self.chain.methods(LOCAL), "the network answered first")
        saved = self.saved()
        self.assertEqual({k: saved[k] for k in ("address", "chain_id", "validator", "status", "source")},
                         {"address": ADDR, "chain_id": 2017, "validator": True, "status": 3,
                          "source": "network"})
        self.assertEqual(saved["checked_at"], data["role_checked_at"])
        self.assertEqual([n for n in os.listdir(self.ui_dir)], ["node-role.json"],
                         "no temp file left behind")

    def test_network_no_record(self):
        self.node_up()
        self.network(LIVE_DEAD_REVERT)
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("observer", "network"))
        self.assertFalse(data["observer"]["staked"])
        self.assertEqual((self.saved()["validator"], self.saved()["status"]), (False, None))

    def test_network_does_not_wait_for_sync(self):
        self.node_up(synced=False)
        self.network(ok(record(2, activation=581)))
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("validator", "network"))

    def test_local_answer_when_the_network_is_down(self):
        self.node_up()
        self.local_validator(ok(record(2, activation=581)))
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("validator", "local"))
        self.assertIsInstance(data["role_checked_at"], int)
        self.assertEqual(self.saved()["source"], "local")

    def test_unsynced_local_node_is_not_asked(self):
        self.node_up(synced=False)
        self.local_validator(ok(record(3)))
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"], data["role_checked_at"]),
                         ("observer", "default", None))
        self.assertNotIn("eth_call", self.chain.methods(LOCAL))
        self.assertFalse(os.path.exists(self.role_file), "nothing definitive to save")

    def test_cached_answer_for_the_same_address(self):
        self.node_up(synced=False)
        self.save(validator=True, status=3, checked_at=1790000000)
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"], data["role_checked_at"]),
                         ("validator", "cached", 1790000000))
        self.assertEqual(data["role_address"], ADDR)

    def test_cached_not_used_for_another_address(self):
        self.node_up(synced=False)
        self.save(address=OTHER)
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("observer", "default"))
        self.assertIsNone(data["role_checked_at"])
        self.assertEqual(data["role_address"], ADDR, "the chain was unreachable, not the address")

    def test_no_execution_address(self):
        self.node_up(address=None)
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"], data["role_address"]),
                         ("observer", "default", None))
        self.assertIsNone(data["role_checked_at"])

    def test_cached_not_used_for_another_chain(self):
        self.node_up(synced=False)
        self.save(chain_id=32285)
        self.assertEqual(self.nodes()["role_source"], "default")

    def test_unreadable_saved_answer(self):
        self.node_up(synced=False)
        with open(self.role_file, "w") as f:
            f.write("{not json")
        self.assertEqual(self.nodes()["role_source"], "default")
        self.save(validator="yes")
        server.clear_role_cache()
        self.assertEqual(self.nodes()["role_source"], "default")

    def test_stopped_node_asks_the_network_from_its_meta(self):
        # The node is down: the chain comes from .node-meta NETWORK, the address
        # from node-info.yaml in its data dir.
        self.meta["DATA_DIR"] = self.var
        with open(os.path.join(self.var, "node-info.yaml"), "w") as f:
            f.write("name: node7\nexecution_address: %s\n" % ADDR)
        self.network(ok(LIVE_COMMITTEE_RESULT))
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("validator", "network"))
        self.assertEqual(data["validator"]["status"], "active")

    def test_stopped_node_with_nothing_to_go_on(self):
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("observer", "default"))
        self.assertEqual(self.chain.urls(), [LOCAL, LOCAL], "eth_chainId and tn_info only")

    def test_answer_cached_for_thirty_seconds(self):
        self.node_up()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        self.nodes()
        asked = len(self.chain.calls)
        self.nodes()
        self.nodes()
        self.assertEqual(len(self.chain.calls), asked, "within the TTL nothing is asked again")
        self.client.get("/api/nodes?fresh=1")
        self.assertGreater(len(self.chain.calls), asked, "?fresh=1 asks again")

    def test_a_changed_answer_moves_the_node_back(self):
        self.node_up()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        self.assertEqual(self.nodes()["role"], "validator")
        self.network(ok(record(5, exit_epoch=600)))
        server.clear_role_cache()
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("observer", "network"))

    def test_public_path_carries_no_role_fields(self):
        self.node_up()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        data = self.nodes(public=True)
        self.assertEqual(data["role"], "validator")
        for key in ("role_source", "role_checked_at", "helper"):
            self.assertNotIn(key, data)

    def test_save_failure_is_not_fatal(self):
        self.patch(server, "NODE_ROLE_FILE", os.path.join(self.tmp.name, "missing", "r.json"))
        self.node_up()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        self.assertEqual(self.nodes()["role_source"], "network")


class NodeTypeMetaTest(ChainTestCase):

    def setUp(self):
        super().setUp()
        self.install_unit()
        self.node_up()

    def test_node_type_validator_has_no_effect(self):
        self.meta["NODE_TYPE"] = "validator"
        for answer, role in ((ok(record(5)), "observer"), (LIVE_DEAD_REVERT, "observer"),
                             (None, "observer"), (ok(record(1)), "validator")):
            with self.subTest(answer=answer):
                server.clear_role_cache()
                self.network(answer) if answer else self.chain.drop(TESTNET_RPC)
                self.assertEqual(self.nodes()["role"], role)

    def test_node_type_observer_has_no_effect(self):
        self.meta["NODE_TYPE"] = "observer"
        self.network(ok(record(4)))
        self.assertEqual(self.nodes()["role"], "validator")


class ExternalContainerTest(ChainTestCase):

    def setUp(self):
        super().setUp()
        self.containers = ["tn-ext"]
        self.inspect = {"Config": {"Cmd": ["node", "--http.port", "8545"],
                                   "Image": "adiri:v0.15.0-adiri"},
                        "State": {"Running": True},
                        "HostConfig": {"Binds": [self.var + ":/data"], "NetworkMode": "host"}}
        self.node_up()

    def test_staked_container_moves_to_the_validator_slot(self):
        self.network(ok(LIVE_COMMITTEE_RESULT))
        data = self.nodes()
        self.assertEqual((data["role"], data["role_source"]), ("validator", "network"))
        self.assertEqual((data["node"]["mode"], data["node"]["container"]), ("external", "tn-ext"))
        self.assertTrue(data["node"]["staked"])

    def test_unstaked_container_stays_in_the_observer_slot(self):
        # node-info.yaml with a proof of possession no longer makes it a validator.
        self.node_info = "node_type: validator\nproof_of_possession: abc\n"
        self.network(LIVE_DEAD_REVERT)
        data = self.nodes()
        self.assertEqual((data["role"], data["node"]["mode"]), ("observer", "external"))

    def test_a_unit_wins_and_docker_is_not_asked(self):
        self.install_unit()
        self.network(ok(LIVE_COMMITTEE_RESULT))
        data = self.nodes()
        self.assertEqual(data["node"]["mode"], "scripts")
        self.assertNotIn("docker-detect", [c[3] for c in self.run_calls if len(c) > 3])


class LegacyPathTest(ChainTestCase):

    def test_legacy_observer_install_shown_as_validator_keeps_its_paths(self):
        self.install_unit("telcoin-observer")
        self.meta = {"NODE_TYPE": "observer", "NETWORK": "testnet", "RPC_PORT": "8541"}
        self.node_up(url="http://127.0.0.1:8541")
        self.network(ok(LIVE_COMMITTEE_RESULT))
        data = self.nodes()
        self.assertEqual((data["role"], data["node"]["service"]), ("validator", "telcoin-observer"))
        self.assertEqual(server.detect_type("validator")["rpc_port"], 8541)
        self.assertEqual(server._legacy_role(), "observer")
        self.assertEqual(server.data_dir("validator"), os.path.join(self.var, "observer"))
        self.assertEqual(server.config_dir("validator"), os.path.join(self.etc, "observer"))

    def test_legacy_config_dir_without_a_unit(self):
        os.makedirs(os.path.join(self.etc, "validator"))
        open(os.path.join(self.etc, "validator", ".node-meta"), "w").close()
        self.assertEqual(server._legacy_role(), "validator")
        self.assertEqual(server.data_dir("observer"), os.path.join(self.var, "validator"))

    def test_unified_layout_ignores_the_slot(self):
        self.install_unit()
        open(os.path.join(self.etc, ".node-meta"), "w").close()
        self.assertIsNone(server._legacy_role())
        for t in server.NODE_TYPES:
            self.assertEqual(server.config_dir(t), self.etc)
            self.assertEqual(server.data_dir(t), self.var)
        self.meta["DATA_DIR"] = "/data/telcoin"
        server.clear_meta_cache()
        self.assertEqual(server.data_dir("validator"), "/data/telcoin")


# ---------------------------------------------------------------------------
# /api/validator epoch fields
# ---------------------------------------------------------------------------

EPOCH_FIELDS = ("epoch_started_at", "epoch_duration", "epoch_ends_at", "now",
                "earliest_seat_epoch", "seat_epoch")
START = 1790900000   # timestamp of block blockHeight - 1


class EpochFieldsTest(ChainTestCase):

    def setUp(self):
        super().setUp()
        self.install_unit()
        self.node_up()
        self.committees = {580: [ADDR.upper().replace("0X", "0x"), OTHER],
                           581: [OTHER], 582: [OTHER]}
        self.epoch_info = {"epochId": 580, "blockHeight": 497019, "epochDuration": 21600,
                           "epochIssuance": "0x0", "stakeVersion": 0}
        self.chain.set(LOCAL, "tn_getCurrentEpochInfo",
                       lambda _p: ok(dict(self.epoch_info,
                                          committee=self.committees[self.epoch_info["epochId"]])))
        self.chain.set(LOCAL, "tn_getEpochInfo",
                       lambda p: ok(dict(self.epoch_info, epochId=p[0],
                                         committee=self.committees[p[0]]))
                       if p[0] in self.committees else None)
        self.blocks = {497018: START}
        self.chain.set(LOCAL, "eth_getBlockByNumber",
                       lambda p: ok({"number": p[0], "timestamp": hex(self.blocks[int(p[0], 16)])})
                       if int(p[0], 16) in self.blocks else None)
        self.status(3, activation=412)

    def status(self, status, activation=0):
        rec = ok(record(status, activation=activation))
        self.network(rec)
        self.local_validator(rec)
        server.clear_role_cache()
        server._detect_cache["data"] = None
        self.slot = "validator" if status in server.STAKED_STATUSES else "observer"

    def poll(self):
        resp = self.client.get("/api/validator/" + self.slot)
        self.assertEqual(resp.status_code, 200)
        return resp.get_json()

    def test_epoch_timing(self):
        before = int(time.time())
        v = self.poll()
        self.assertEqual((v["epoch_started_at"], v["epoch_duration"], v["epoch_ends_at"]),
                         (START, 21600, START + 21600))
        self.assertTrue(before <= v["now"] <= int(time.time()))
        for key in ("epoch_started_at", "epoch_duration", "epoch_ends_at", "now"):
            self.assertIs(type(v[key]), int, key + " is a JSON number")
        block_params = [p for _u, m, p in self.chain.calls if m == "eth_getBlockByNumber"]
        self.assertEqual(block_params, [[hex(497018), False]], "the block before the first block")

    def test_genesis_epoch_starts_at_block_zero(self):
        self.epoch_info.update(epochId=580, blockHeight=0)
        self.blocks[0] = 1780000000
        v = self.poll()
        self.assertEqual(v["epoch_started_at"], 1780000000)

    def test_earliest_seat_only_for_activated_validators(self):
        for status, expected in ((1, None), (2, 414), (3, 414), (4, 414), (5, None), (0, None)):
            with self.subTest(status=status):
                self.status(status, activation=412)
                v = self.poll()
                if expected is None:
                    self.assertNotIn("earliest_seat_epoch", v)
                else:
                    self.assertEqual(v["earliest_seat_epoch"], expected)
                self.assertEqual(v["status"], status)

    def test_no_record_sends_no_earliest_seat(self):
        self.network(LIVE_DEAD_REVERT)
        self.local_validator(LIVE_DEAD_REVERT)
        self.slot = "observer"
        v = self.poll()
        self.assertIsNone(v["status"])
        self.assertNotIn("earliest_seat_epoch", v)
        self.assertIn("epoch_ends_at", v)

    def test_seat_epoch(self):
        cases = ((["c"], 580), (["n1"], 581), (["n2"], 582), ([], None))
        for where, expected in cases:
            with self.subTest(where=where):
                self.committees = {580: [OTHER] + ([ADDR] if "c" in where else []),
                                   581: [OTHER] + ([ADDR] if "n1" in where else []),
                                   582: [OTHER] + ([ADDR] if "n2" in where else [])}
                server._committee_cache.update({"key": None, "committees": {}})
                v = self.poll()
                self.assertIn("seat_epoch", v)
                self.assertEqual(v["seat_epoch"], expected)

    def test_seat_epoch_left_out_when_a_lookup_fails(self):
        self.committees = {580: [OTHER], 582: [ADDR]}    # 581 cannot be read
        v = self.poll()
        self.assertNotIn("seat_epoch", v)
        self.assertIn("epoch_ends_at", v)

    def test_seat_epoch_needs_the_current_committee(self):
        self.chain.set(LOCAL, "tn_getCurrentEpochInfo", ok(dict(self.epoch_info)))
        v = self.poll()
        self.assertNotIn("seat_epoch", v)
        self.assertEqual(v["epoch_ends_at"], START + 21600)

    def test_missing_boundary_block_drops_only_the_timing(self):
        self.blocks = {}
        v = self.poll()
        for key in ("epoch_started_at", "epoch_duration", "epoch_ends_at", "now"):
            self.assertNotIn(key, v)
        self.assertEqual((v["earliest_seat_epoch"], v["seat_epoch"]), (414, 580))

    def test_unsynced_node_sends_nothing_new(self):
        self.node_up(synced=False)
        v = self.poll()
        for key in EPOCH_FIELDS:
            self.assertNotIn(key, v)
        self.assertNotIn("tn_getCurrentEpochInfo", self.chain.methods())
        self.assertEqual(v["status"], 3, "the existing fields still come")

    def test_one_epoch_info_call_per_poll_and_cached_lookups(self):
        self.committees = {580: [OTHER], 581: [OTHER], 582: [ADDR]}
        first = self.poll()
        second = self.poll()
        self.assertEqual(first["seat_epoch"], 582)
        self.assertEqual(second["epoch_ends_at"], first["epoch_ends_at"])
        calls = self.chain.methods(LOCAL)
        self.assertEqual(calls.count("tn_getCurrentEpochInfo"), 2, "one per poll")
        self.assertEqual(calls.count("eth_getBlockByNumber"), 1, "boundary block cached")
        self.assertEqual(calls.count("tn_getEpochInfo"), 2, "581 and 582 once each")

        # The next epoch: new boundary block, new committee lookups.
        self.epoch_info.update(epochId=581, blockHeight=500000)
        self.blocks[499999] = START + 21610
        self.committees.update({581: [OTHER], 582: [OTHER], 583: [ADDR]})
        third = self.poll()
        self.assertEqual((third["epoch_started_at"], third["seat_epoch"]), (START + 21610, 583))
        calls = self.chain.methods(LOCAL)
        self.assertEqual(calls.count("tn_getCurrentEpochInfo"), 3)
        self.assertEqual(calls.count("eth_getBlockByNumber"), 2)
        self.assertEqual(calls.count("tn_getEpochInfo"), 4)


if __name__ == "__main__":
    unittest.main()
