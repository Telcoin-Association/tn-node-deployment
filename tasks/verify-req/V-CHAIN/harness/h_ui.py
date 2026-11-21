"""V-CHAIN harness: ui/server.py per chain id (verifier-owned, not collected by pytest).

resolve_network for each id with and without a .node-meta NETWORK, hex_to_dec of
the hex forms, _node_chain_id for a stopped node, NETWORK_PUBLIC_RPC, and
network_stake_status trusting an endpoint only when its eth_chainId equals the
table key. No network: _public_rpc and read_meta are replaced.

    python -I tasks/verify-req/V-CHAIN/harness/h_ui.py
"""
import os
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../.."))
sys.path.insert(0, os.path.join(REPO, "ui"))
import server  # noqa: E402

FAILS = []
CHECKS = [0]


def check(name, want, got):
    CHECKS[0] += 1
    if want == got:
        print("ok    " + name)
    else:
        FAILS.append(name)
        print("FAIL  %s\n      want %r\n      got  %r" % (name, want, got))


print("== tables")
print("   NETWORKS keys:", sorted(server.NETWORKS))
print("   NETWORK_PUBLIC_RPC:", {k: v for k, v in sorted(server.NETWORK_PUBLIC_RPC.items())})
check("NETWORKS keys", [731, 2017, 32285], sorted(server.NETWORKS))
check("NETWORK_PUBLIC_RPC keys", [731, 2017, 32285], sorted(server.NETWORK_PUBLIC_RPC))
check("mainnet public RPC list empty until launch", [], server.NETWORK_PUBLIC_RPC[731])
check("731 is the only mainnet slug", [731], [k for k, m in server.NETWORKS.items() if m["slug"] == "mainnet"])

print("== hex_to_dec")
for h in ("0x2db", "0x2DB", "0x02db", "0x1e7", "0x7e1", "0x7e1d"):
    print("   %-7s -> %r" % (h, server.hex_to_dec(h)))
check("hex_to_dec 0x2db / 0x2DB / 0x02db", [731, 731, 731],
      [server.hex_to_dec(h) for h in ("0x2db", "0x2DB", "0x02db")])

print("== resolve_network, no .node-meta")
META = {}
server.read_meta = lambda t=None: dict(META)
for cid in (731, 487, 2017, 32285, 12345, None):
    print("   %-6r -> %r" % (cid, server.resolve_network(cid, None)))
check("resolve 731", ("mainnet", "Telcoin Mainnet", True), server.resolve_network(731, None))
check("resolve 487", ("", "", False), server.resolve_network(487, None))
check("resolve 487 with t, empty meta", ("", "", False), server.resolve_network(487, "observer"))

print("== resolve_network, .node-meta NETWORK set")
for net in ("mainnet", "devnet", "testnet"):
    META.clear()
    META["NETWORK"] = net
    for cid in (731, 487, 2017, 32285):
        print("   NETWORK=%-7s chain %-6r -> %r" % (net, cid, server.resolve_network(cid, "observer")))
META.clear()
META["NETWORK"] = "mainnet"
check("node on 487 with NETWORK=mainnet is shown as mainnet, configured",
      ("mainnet", "Telcoin Mainnet", True), server.resolve_network(487, "observer"))
META["NETWORK"] = "testnet"
check("node on 731 with NETWORK=testnet: the chain id wins",
      ("mainnet", "Telcoin Mainnet", True), server.resolve_network(731, "observer"))

print("== _node_chain_id, a stopped node")
server.local_rpc = lambda port, method, params=None: None
for net in ("mainnet", "testnet", "devnet", ""):
    META.clear()
    META["NETWORK"] = net
    print("   NETWORK=%-7r -> %r" % (net, server._node_chain_id("observer", 8545)))
META.clear()
META["NETWORK"] = "mainnet"
check("stopped node, NETWORK=mainnet -> 731", 731, server._node_chain_id("observer", 8545))

print("== network_stake_status: trust needs eth_chainId == key")
ADDR = "0x" + "11" * 20
RECORD = "0x" + "".join("%064x" % v for v in (int(ADDR, 16), 1, 0, 3, 0, 1, 0))
ANSWERS = {}
ASKED = []


def fake_public_rpc(url, method, params, timeout):
    ASKED.append((url, method))
    return ANSWERS.get((url, method))


server._public_rpc = fake_public_rpc
logs = []
server._log = logs.append
OLD, NEW = "https://old.invalid", "https://new.invalid"
server.NETWORK_PUBLIC_RPC = {731: [OLD, NEW]}
ANSWERS[(OLD, "eth_chainId")] = {"result": "0x1e7"}
ANSWERS[(OLD, "eth_call")] = {"result": RECORD}
ANSWERS[(NEW, "eth_chainId")] = {"result": "0x2db"}
ANSWERS[(NEW, "eth_call")] = {"result": RECORD}
got = server.network_stake_status(ADDR, 731)
print("   asked:", ASKED)
print("   logs:", logs)
check("answer comes from the 0x2db endpoint", 3, got and got["status"])
check("the 0x1e7 endpoint is never asked eth_call", False, (OLD, "eth_call") in ASKED)
check("the mismatch is logged with 487 and 731", True,
      any("serves chain 487, not 731" in m for m in logs))
# A 487 key is not a mainnet key: nothing is asked for chain 487.
server._endpoints.clear()
ASKED.clear()
server.NETWORK_PUBLIC_RPC = {731: [NEW]}
check("chain 487: no endpoint, None", None, server.network_stake_status(ADDR, 487))
check("chain 487: nothing asked", [], ASKED)

print("\n%d checks, %d failures" % (CHECKS[0], len(FAILS)))
sys.exit(1 if FAILS else 0)
