#!/usr/bin/env python3
"""Node Manager dev runner. Maintainer tool: not shipped to nodes, not updater-tracked.

Serves ui/server.py with its subprocess calls answered from fixtures, so the page in
ui/static/index.html can be exercised on a laptop without sudo, the privileged helper or
a node. Nothing on disk is read for node state and nothing is written.

    <venv>/bin/python ui/dev/serve.py [--port 8099] [--scenario public] [--role validator]

then open http://127.0.0.1:8099/ (the SSH-tunnel view: management enabled). Send the
header `X-TN-Dashboard-Public: 1` to see the public read-only view.

Scenarios:
  public    RPC served on node7.adiri.telcoin.network and advertised (https and wss),
            Caddy block stale; dashboard on dashboard.node7.adiri.telcoin.network;
            role read from the network; validator view.
  private   no public RPC; the dashboard sits on node7.adiri.telcoin.network, so typing
            that name in the RPC card shows the move-dashboard box; role from a cached
            answer.
  unserved  node-info.yaml advertises an RPC URL that Caddy no longer serves; the
            privileged helper is outdated; role unknown (no execution address yet);
            update apply fails without a done event.
  legacy    today's payloads: every field UI 1.9.0 adds is stripped, so the page has to
            show "unknown" states and no notices.
  fresh     no node yet, so the Setup tab shows. Keygen and finalize stream and succeed;
            after finalize the node is installed. A public RPC hostname is enabled
            unless it contains "nodns", which leaves RPC private with the URL already
            advertised (DNS not ready), as setup-node.sh does.
  fresh-reject
            as `fresh`, but finalize on the public path answers 400 for a missing
            rpc_domain, so the wizard shows the server's message.

Validator view (--role validator): each scenario has its own epoch data. public is an
active validator seated in the current epoch, two hours from the boundary. private is
pending activation, not in the next three committees, ten minutes from the boundary,
with the fixture server's clock 15 minutes ahead of this machine's (the page corrects
for it, so the countdown still reads ten minutes). unserved is staked but not activated,
with the boundary already passed ("ending now"). legacy sends no epoch fields.

Patched (in this process only):
  server.run                 helper subcommands and host commands answer from fixtures
  server.subprocess.Popen    action streams (update, setup, Caddy, RPC, config) replay
                             canned events, including a stray line that is not JSON
  server.detect_nodes        one unified `telcoin` node in the --role slot (none in
                             `fresh` until finalize succeeds)
  /api/status, /api/validator
                             fixtures (the server reads these from files and the node's RPC)
  /api/setup/<t>/{keygen,finalize}
                             wrapped: record the RPC hostname for the canned streams and,
                             while the running server predates package UI-2a, answer the
                             A.4 400s for rpc_domain itself
  urllib.request.urlopen     no network: only the preflight's github.com probe answers
An after-request hook adds the UI 1.9.0 fields (package UI-2) that the running server
does not send yet; keys the server sends win, with one exception: on /api/nodes the
scenario's `helper` replaces the server's own check, because the fixture's helper-version
answer cannot describe a helper that answers API 1 (a real one has no helper-version, so
the server reports its API as unknown). Operator-only fields (helper, role_source,
role_checked_at, role_address) are never added to a public read-only request. For `legacy` the hook
strips the 1.9.0 fields instead and puts back the logical CPU counts today's server
reports.

Needs Python 3.10+ and Flask (ui/requirements.txt), nothing else.
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time
import types
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import server  # noqa: E402  (ui/server.py)
from flask import jsonify, request  # noqa: E402

RPC_HOST = "node7.adiri.telcoin.network"
DASH_HOST = "dashboard." + RPC_HOST
PUBLIC_IP = "203.0.113.10"
EXEC_ADDRESS = "0x7e1a00000000000000000000000000000000beef"
STREAM_DELAY = 0.25  # seconds between canned stream lines, so progress is visible

NOW = int(time.time())

# What the server answers when rpc_public comes without rpc_domain (spec A.4): its own
# text, so the walk shows what operators see; a copy while the running server predates
# package UI-2a.
NO_DOMAIN_ERROR = getattr(server, "RPC_PUBLIC_NEEDS_HOST",
                          "Public RPC needs a hostname. Enter one or choose Private.")

# Validator record and epoch timing per scenario, used when the node sits in the validator
# slot. ends_in: seconds from start-up to the epoch boundary (fixed, so the countdown runs
# down); skew: how far the fixture server's clock runs ahead of this machine's.
VAL_ACTIVE = {"status": 3, "activation_epoch": 412, "in_committee": True, "in_next_committee": True,
              "seat_epoch": 580, "ends_in": 2 * 3600, "skew": 0}
VAL_PENDING = {"status": 2, "activation_epoch": 581, "in_committee": False, "in_next_committee": False,
               "seat_epoch": None, "ends_in": 600, "skew": 900}
VAL_STAKED = {"status": 1, "activation_epoch": 0, "in_committee": False, "in_next_committee": False,
              "seat_epoch": None, "ends_in": -45, "skew": 0}

# p2p_ports as firewall-setup.sh 1.6.0 prints them: primary and worker 0 on the default
# ports (the page's toggle rows), then three more workers. A real answer has allowed
# null for every port or for none (null means ufw is inactive); one of each value is
# mixed here so the firewall card shows open, closed and reported together.
P2P_PORTS = [
    {"port": 49590, "proto": "udp", "label": "primary", "allowed": True},
    {"port": 49594, "proto": "udp", "label": "worker-0", "allowed": True},
    {"port": 49595, "proto": "udp", "label": "worker-1", "allowed": True},
    {"port": 49596, "proto": "udp", "label": "worker-2", "allowed": False},
    {"port": 49597, "proto": "udp", "label": "worker-3", "allowed": None},
]

# Firewall status as firewall-setup.sh --json --status prints it; scenarios add p2p_ports.
FIREWALL = {
    "installed": True, "active": True, "default_incoming": "deny", "ssh_port": "22",
    "kuma": "open", "kuma_extra": [], "caddy_managed": True,
    "desired": [
        {"spec": "49590/udp", "label": "Node P2P (primary)", "source": "anywhere", "ok": True},
        {"spec": "49594/udp", "label": "Node P2P (worker)", "source": "anywhere", "ok": True},
        {"spec": "443/tcp", "label": "HTTPS (Caddy)", "source": "anywhere", "ok": True},
    ],
    "unexpected": [],
    "ports": {"49590/udp": True, "49594/udp": True, "43174/tcp": False},
}

SCENARIOS = {
    "public": {
        "role": "validator",
        "nodes": {"role_source": "network", "role_checked_at": NOW - 20,
                  "role_address": EXEC_ADDRESS,
                  "helper": {"ok": True, "api": 2, "required": 2, "error": ""}},
        "caddy": {"installed": True, "running": True, "enabled": True,
                  "domain": DASH_HOST, "username": "admin"},
        "rpc": {"installed": True, "running": True, "enabled": True, "domain": RPC_HOST,
                "advertised_http": "https://" + RPC_HOST, "advertised_ws": "wss://" + RPC_HOST,
                "ws_listening": True, "block_stale": True},
        "meta_domain": RPC_HOST,
        "p2p_ports": P2P_PORTS,
        "helper_api": "2",
        "apply_fails": False,
        "val": VAL_ACTIVE,
    },
    "private": {
        "role": "observer",
        "nodes": {"role_source": "cached", "role_checked_at": NOW - 3600,
                  "role_address": EXEC_ADDRESS,
                  "helper": {"ok": True, "api": 2, "required": 2, "error": ""}},
        "caddy": {"installed": True, "running": True, "enabled": True,
                  "domain": RPC_HOST, "username": "admin"},
        "rpc": {"installed": True, "running": True, "enabled": False, "domain": "",
                "advertised_http": "", "advertised_ws": "", "ws_listening": False,
                "block_stale": False},
        "meta_domain": "",
        "p2p_ports": P2P_PORTS,
        "helper_api": "2",
        "apply_fails": False,
        "val": VAL_PENDING,
    },
    "unserved": {
        "role": "observer",
        "nodes": {"role_source": "default", "role_checked_at": None, "role_address": None,
                  "helper": {"ok": False, "api": 1, "required": 2,
                             "error": "unknown subcommand: helper-version"}},
        "caddy": {"installed": True, "running": True, "enabled": False,
                  "domain": "", "username": ""},
        "rpc": {"installed": True, "running": True, "enabled": False, "domain": "",
                "advertised_http": "https://" + RPC_HOST, "advertised_ws": "",
                "ws_listening": False},
        "meta_domain": "",
        "p2p_ports": P2P_PORTS,
        "helper_api": None,
        "apply_fails": True,
        "val": VAL_STAKED,
    },
    "legacy": {
        "role": "observer",
        "nodes": {},
        "caddy": {"installed": True, "running": True, "enabled": True,
                  "domain": DASH_HOST, "username": "admin"},
        "rpc": {"installed": True, "running": True, "enabled": True, "domain": RPC_HOST},
        "meta_domain": None,
        "p2p_ports": P2P_PORTS,
        "helper_api": "2",
        "apply_fails": False,
        "val": VAL_ACTIVE,
    },
    "fresh": {
        "role": "observer",
        "fresh": True,
        "nodes": {"role_source": "network", "role_checked_at": NOW - 5,
                  "role_address": EXEC_ADDRESS,
                  "helper": {"ok": True, "api": 2, "required": 2, "error": ""}},
        "caddy": {"installed": False, "running": False, "enabled": False,
                  "domain": "", "username": ""},
        "rpc": {"installed": False, "running": False, "enabled": False, "domain": "",
                "advertised_http": "", "advertised_ws": "", "ws_listening": False,
                "block_stale": False},
        "meta_domain": "",
        "p2p_ports": P2P_PORTS,
        "helper_api": "2",
        "apply_fails": False,
        "val": VAL_PENDING,
    },
}
SCENARIOS["fresh-reject"] = dict(SCENARIOS["fresh"], reject_finalize=True)

# Setup progress in the `fresh` scenarios: the RPC hostname the wizard sent ('' for
# private) and whether finalize has succeeded. Other scenarios start installed.
SETUP = {"domain": "", "installed": True}

# Fields UI 1.9.0 adds per route (spec A.4). `legacy` strips them.
A4_FIELDS = {
    "/api/nodes": ("role_source", "role_checked_at", "role_address", "helper"),
    "/api/rpc/status": ("meta_domain", "advertised_http", "advertised_ws", "ws_listening",
                        "block_stale"),
    "/api/system": ("cpu_threads",),
}
A4_PREFLIGHT = ("cpu_physical", "cpu_threads")   # top level of /api/setup/preflight
A4_VALIDATOR = ("epoch_started_at", "epoch_duration", "epoch_ends_at", "now",
                "earliest_seat_epoch", "seat_epoch")
OPERATOR_ONLY = ("helper", "role_source", "role_checked_at", "role_address")   # never public

SC = {}  # the active scenario, set in main()


def ev(event, msg="", **kw):
    """One JSON event line, as the scripts print with --json."""
    return json.dumps(dict({"event": event, "msg": msg}, **kw))


# ---------------------------------------------------------------------------
# server.run: helper subcommands and host commands
# ---------------------------------------------------------------------------

def after_fresh_setup():
    """True once a `fresh` scenario's finalize has succeeded."""
    return bool(SC.get("fresh")) and SETUP["installed"]


def rpc_status():
    """rpc-status as the helper prints it. After a `fresh` setup it follows what
    setup-node.sh would have left: public RPC served on the hostname, or (DNS not ready,
    "nodns" in the name) private with the URL already advertised by keygen."""
    if not after_fresh_setup():
        return SC["rpc"]
    d = SETUP["domain"]
    served = bool(d) and "nodns" not in d
    st = {"installed": served, "running": served, "enabled": served, "domain": d if served else "",
          "advertised_http": "", "advertised_ws": "", "ws_listening": True, "block_stale": False}
    if d:
        st.update(advertised_http="https://%s/" % d, advertised_ws="wss://%s/" % d)
    return st


def meta_domain():
    return SETUP["domain"] if after_fresh_setup() else (SC["meta_domain"] or "")


def helper_reply(sub, args):
    """(rc, stdout, stderr) for `sudo -n <helper> <sub> <args...>`."""
    if sub == "helper-version":
        api = SC["helper_api"]
        return (0, api, "") if api else (1, "", "unknown subcommand: helper-version")
    if sub == "caddy-status":
        return 0, json.dumps(SC["caddy"]), ""
    if sub == "rpc-status":
        return 0, json.dumps(rpc_status()), ""
    if sub in ("caddy-dns-check", "rpc-dns-check"):
        host = args[0] if args else ""
        if "nodns" in host:
            return 0, json.dumps({"propagated": False, "resolved_ip": "", "public_ip": PUBLIC_IP,
                                  "egress_ip": PUBLIC_IP, "local_ips": ["10.0.0.5"],
                                  "note": host + " has no A record yet."}), ""
        return 0, json.dumps({"propagated": True, "resolved_ip": PUBLIC_IP,
                              "public_ip": PUBLIC_IP}), ""
    if sub == "firewall-status":
        fw = dict(FIREWALL)
        if SC["p2p_ports"] is not None:
            fw["p2p_ports"] = SC["p2p_ports"]
        return 0, json.dumps(fw), ""
    if sub == "firewall-port":
        return 0, json.dumps({"ok": True}), ""
    if sub == "update-check":
        return 0, json.dumps({"install_method": "docker", "current_ref": "v0.14.0-adiri",
                              "latest_ref": "v0.15.0-adiri", "update_available": True,
                              "pending": None}), ""
    if sub == "update-discard":
        return 0, "", ""
    if sub == "addons-status":
        return 0, json.dumps({
            "network": "testnet", "region": "us-central",
            "health": {"enabled": True, "responding": True, "port": 43174, "extra_src": ""},
            "logging": {"enabled": False, "running": False},
            "vpn": {"state": "false", "wg_up": False, "handshake": False,
                    "overlay_ip": "", "pubkey": ""}}), ""
    if sub == "meta-cat":
        return 0, ("NODE_TYPE=observer\nINSTALL_METHOD=docker\nDATA_DIR=/var/lib/telcoin\n"
                   "SERVICE=telcoin\nPUBLIC_RPC_DOMAIN=" + meta_domain() + "\n"), ""
    if sub == "restart-count":
        return 0, "0", ""
    if sub == "internal-ip":
        return 0, "10.0.0.5", ""
    if sub == "docker-detect":
        return 0, "", ""
    if sub in ("set-hostname", "set-logrotate", "clear-rotated", "log-clear",
               "tracing-enable", "tracing-disable", "jaeger-start", "jaeger-stop"):
        return 0, json.dumps({"ok": True}), ""
    return 1, "", "ui/dev/serve.py: no fixture for helper subcommand " + sub


LSCPU_PARSE = "# Core,Socket\n" + "".join(f"{c},0\n{c},0\n" for c in range(8))
LSCPU_HUMAN = "CPU(s): 16\nThread(s) per core: 2\nCore(s) per socket: 8\nSocket(s): 1\n"


def fake_run(cmd, timeout=10):
    """Stand-in for server.run: (rc, stdout, stderr), never raises."""
    cmd = [str(c) for c in cmd]
    if cmd[:2] == ["sudo", "-n"] and len(cmd) > 3 and cmd[2] == server.HELPER:
        return helper_reply(cmd[3], cmd[4:])
    name = cmd[0] if cmd else ""
    if name == "hostname":
        return 0, ("10.0.0.5 172.17.0.1" if "-I" in cmd else "tn-dev-node7"), ""
    if name == "uptime":
        return 0, "up 3 days, 4 hours", ""
    if name == "nproc":
        return 0, "16", ""
    if name == "uname":
        return 0, "6.8.0-45-generic", ""
    if name == "sysctl" and "hw.physicalcpu" in cmd:
        return 0, "8", ""
    if name == "lscpu":
        parse = any(a.startswith("-p") or a.startswith("--parse") for a in cmd[1:])
        return 0, (LSCPU_PARSE if parse else LSCPU_HUMAN).strip(), ""
    if name == "df":
        return 0, "Used  Size Use%\n 120G  1.8T   7%", ""
    if name == "systemctl":
        if "--version" in cmd:
            return 0, "systemd 255 (255.4-1ubuntu8)", ""
        if "is-active" in cmd:
            return 0, "active", ""
        return 0, "", ""
    return 127, "", "not found"


# ---------------------------------------------------------------------------
# server.subprocess.Popen: canned action streams
# ---------------------------------------------------------------------------

def stream_lines(argv):
    """(stdout lines, rc, stderr text) for one streamed helper call."""
    sub = argv[3] if len(argv) > 3 and argv[2] == server.HELPER else ""
    stray = "Status: Downloaded newer image for us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri"
    if sub == "update-prepare":
        ref = argv[-1]
        return [ev("step", "Checking " + ref),
                ev("log", "Pulling us-docker.pkg.dev/telcoin-network/tn-public/adiri:" + ref),
                stray,
                ev("log", "warning: the pull took longer than 60 s"),
                ev("done", "Prepared " + ref + "; apply it to restart on the new version",
                   ok=True, phase="prepare", new_ref=ref)], 0, ""
    if sub == "update-apply":
        lines = [ev("step", "Stopping telcoin"),
                 ev("log", "telcoin.service: deactivated"),
                 stray]
        if SC["apply_fails"]:
            return lines, 1, "update-node.sh: docker image swap failed: no space left on device\n"
        return lines + [ev("step", "Starting telcoin on v0.15.0-adiri"),
                        ev("done", "Updated to v0.15.0-adiri", ok=True, phase="apply",
                           new_ref="v0.15.0-adiri")], 0, ""
    if sub == "setup-keygen":
        d = SETUP["domain"]
        info = "name: node7\nprimary_network_address: /ip4/203.0.113.10/udp/49590/quic-v1\n"
        keytool = "keytool generate validator" + (" --rpc-http https://%s/ --rpc-ws wss://%s/" % (d, d) if d else "")
        return [ev("step", "Generating keys"), ev("log", keytool), stray,
                ev("done", "keys generated -- BACK THEM UP before finalizing", ok=True, phase="keygen",
                   keys_dir="/var/lib/telcoin/node-keys", node_info_path="/var/lib/telcoin/node-info.yaml",
                   node_info=info)], 0, ""
    if sub == "setup-finalize":
        # The lines setup-node.sh --json prints for the hostname the wizard sent.
        d = SETUP["domain"]
        lines = [ev("step", "Writing the service"), ev("step", "Starting telcoin")]
        if d and "nodns" in d:
            lines += [ev("log", "public RPC not enabled yet: DNS for %s does not point at this server yet. %s has no "
                                "A record yet. -- to finish, run: sudo bash ~/telcoin-node-scripts/install-caddy.sh "
                                "--phase=rpc-enable --rpc-domain %s --public-ip %s" % (d, d, d, PUBLIC_IP)),
                      ev("log", "node-info.yaml already advertises https://%s/: the advertisement is live in the node "
                                "record and will serve once rpc-enable completes. To withdraw it instead, run: "
                                "sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable" % d)]
        elif d:
            lines += [ev("log", "Checking that %s resolves to this server..." % d), stray,
                      ev("log", "Enabling public RPC for %s (Caddy + node-info.yaml advertisement)..." % d)]
        return lines + [ev("done", "telcoin finalized and started -- following consensus as a full node; "
                                   "staking to validate is optional (see docs)",
                           ok=True, phase="finalize", service="telcoin", rpc_port="8545")], 0, ""
    if sub in ("caddy-enable", "caddy-disable"):
        return [ev("step", "Writing the Caddy site"), stray, ev("log", "caddy reload: ok"),
                ev("done", "Caddy updated", ok=True)], 0, ""
    if sub == "rpc-enable":
        lines = [ev("step", "Checking DNS for " + argv[4])]
        if len(argv) > 6:
            lines.append(ev("step", "Moving the dashboard to " + argv[6]))
        lines += [ev("log", "keytool set-rpc --http https://" + argv[4]), stray,
                  ev("warn", "The node is in the committee; waiting for the epoch boundary is skipped in the dev runner"),
                  ev("done", "Public RPC enabled on https://" + argv[4], ok=True)]
        return lines, 0, ""
    if sub == "rpc-disable":
        return [ev("step", "Clearing the advertised RPC in node-info.yaml"), stray,
                ev("done", "Public RPC disabled", ok=True)], 0, ""
    if sub == "config-set":
        field, value = argv[-2], argv[-1]
        return [ev("step", "Saving " + field), ev("log", "edit-config.sh --json --set " + field + "=" + value),
                stray, ev("done", "Saved", ok=True, field=field, value=value)], 0, ""
    # Anything else (for example the log tail): a few plain lines, then end.
    return ["2026-10-01T12:00:00Z INFO dev runner log line %d" % i for i in range(3)], 0, ""


class _SlowLines:
    """A text stdout whose readline() hands out canned lines with a short delay."""

    def __init__(self, lines):
        self._lines = [ln + "\n" for ln in lines]

    def readline(self):
        if not self._lines:
            return ""
        time.sleep(STREAM_DELAY)
        return self._lines.pop(0)

    def __iter__(self):
        return iter(self.readline, "")

    def close(self):
        self._lines = []


class FakePopen:
    def __init__(self, argv, stdout=None, stderr=None, text=None, env=None, **_kw):
        self.args = [str(a) for a in argv]
        self._sub = self.args[3] if len(self.args) > 3 and self.args[2] == server.HELPER else ""
        lines, self._rc, err = stream_lines(self.args)
        self.stdout = _SlowLines(lines)
        self.returncode = None
        if err and hasattr(stderr, "write"):
            stderr.write(err)
            stderr.flush()

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is None:
            self.returncode = self._rc
            if self._rc == 0 and self._sub == "setup-finalize":
                SETUP["installed"] = True   # the server waits once stdout ends: the node now exists
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9


# ---------------------------------------------------------------------------
# Route fixtures, network stubs and the A.4 overlay
# ---------------------------------------------------------------------------

def fake_detect_nodes():
    empty = {"mode": None, "status": "not installed", "container": None, "image": None,
             "rpc_port": None, "node_info_path": None}
    out = {t: dict(empty) for t in server.NODE_TYPES}
    if SETUP["installed"]:
        out[SC["role"]] = {"mode": "scripts", "status": "active", "container": None, "image": None,
                           "rpc_port": 8545, "node_info_path": None,
                           "staked": SC["role"] == "validator"}
    return out


def status_fixture(node_type):
    return jsonify({
        "installed": True, "status": "active", "service": "telcoin", "uptime": "2026-09-28 08:00:00 UTC",
        "uptime_human": "3d 4h", "restart_count": 0, "rpc_ok": True, "rpc_port": 8545,
        "chain_id": 2017, "network": "Adiri Testnet", "network_slug": "testnet", "network_configured": True,
        "block_number": 4970190, "synced": True, "block_age": "2s ago",
        "consensus": {"block": 497019, "epoch": 580, "age": "1s ago"},
        "network_consensus_block": 497019, "consensus_lag": 0, "network_epoch": 580,
        "peers": {"primary": 7, "worker": 6, "split": True},
        "external_primary": "/ip4/" + PUBLIC_IP + "/udp/49590/quic-v1", "public_ip": PUBLIC_IP,
        "advertised_name": "node7", "region": "us-central",
        "cpu_percent": 23.5, "memory": {"percent": 41, "used_gb": 26.2, "total_gb": 64},
        "disk": {"percent": 7, "used": "120G", "total": "1.8T"},
        "log_error_count_1h": 0, "log_warn_count_1h": 2, "last_restart": "2026-09-28 08:00:00 UTC",
        "log_size": 104857600, "log_size_human": "100 MB", "recent_log_events": [],
        "node_id": "12D3KooWDevRunnerNodeId", "install_method": "docker", "passphrase_method": "loadcredential",
        "internal_ip": "10.0.0.5", "data_dir": "/var/lib/telcoin", "config_file": "/etc/telcoin/node.env",
        "docker_image": "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.14.0-adiri",
        "tracing_enabled": False,
    })


def validator_fixture(node_type):
    staked = SC["role"] == "validator"
    timing = SC["val"]
    rec = timing if staked else {"status": 0, "activation_epoch": None, "in_committee": False,
                                 "in_next_committee": False, "seat_epoch": None}
    act = rec["activation_epoch"]
    ends = NOW + timing["skew"] + timing["ends_in"]   # boundary on the fixture server's clock
    v = {
        "installed": True, "status": rec["status"], "nft_held": True, "is_retired": False,
        "in_committee": rec["in_committee"], "in_next_committee": rec["in_next_committee"],
        "current_epoch": 580, "epoch": 580, "block": 497019, "age": "1s ago", "next_committee_size": 5,
        "stake_config": {"stake_amount": 1000000},
        "balance_breakdown": {"stake": 1000000 if staked else 0, "rewards": 1234.5 if staked else 0},
        "activation_epoch": act, "stake_version": 0, "name": "node7",
        "execution_address": EXEC_ADDRESS,
        "bls_public_key": "rBLSDevRunnerKeyBase58xxxxxxxxxxxxxxxxxxxx",
        "authority_id": "G6A8BRn31vofiVH8KZzETW2kcPsbomNTQYMgvZg52jTg",
        "primary_external_address": "/ip4/" + PUBLIC_IP + "/udp/49590/quic-v1/p2p/12D3KooWDevRunnerPrimary",
        "worker_external_address": "/ip4/" + PUBLIC_IP + "/udp/49594/quic-v1/p2p/12D3KooWDevRunnerWorker",
        # UI 1.9.0 epoch fields (package UI-2b), read by the validator epoch tile (UI-3b).
        # Unix seconds on the fixture server's clock, which runs `skew` seconds ahead.
        "epoch_started_at": ends - 21600, "epoch_duration": 21600, "epoch_ends_at": ends,
        "now": int(time.time() + timing["skew"]),
        "earliest_seat_epoch": act + 2 if act is not None else None,
        "seat_epoch": rec["seat_epoch"],
    }
    if SC["name"] == "legacy":
        for k in A4_VALIDATOR:
            v.pop(k, None)
    return jsonify(v)


class _FakeHTTPResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def fake_urlopen(req, *args, **kwargs):
    url = req if isinstance(req, str) else req.get_full_url()
    if url.startswith("https://github.com"):
        return _FakeHTTPResponse(b"ok")
    raise urllib.error.URLError("network disabled in ui/dev/serve.py: " + url)


def overlay(resp):
    """Add (or, for `legacy`, strip) the A.4 fields on the JSON routes the page reads."""
    if resp.mimetype != "application/json" or resp.direct_passthrough:
        return resp
    path = request.path
    if path not in A4_FIELDS and path != "/api/setup/preflight":
        return resp
    data = resp.get_json(silent=True)
    if not isinstance(data, dict):
        return resp
    legacy = SC["name"] == "legacy"
    if path == "/api/setup/preflight":
        threads = data.get("cpu_threads")
        if legacy:
            # Today's server: no top-level counts, and hardware.cpu is the logical count.
            for k in A4_PREFLIGHT:
                data.pop(k, None)
            if isinstance(data.get("hardware"), dict) and threads is not None:
                data["hardware"]["cpu"] = threads
        elif "cpu_physical" not in data:
            data.update({"cpu_physical": 8, "cpu_threads": 16})
    elif legacy:
        if path == "/api/system" and data.get("cpu_threads") is not None:
            data["cpu_cores"] = str(data["cpu_threads"])   # today's server: logical CPUs
        for k in A4_FIELDS[path]:
            data.pop(k, None)
    elif path == "/api/nodes":
        public = server.is_public_request()
        for k, v in SC["nodes"].items():
            if public and k in OPERATOR_ONLY:
                continue
            if k == "helper":
                data[k] = v
            else:
                data.setdefault(k, v)
    elif path == "/api/rpc/status":
        data.setdefault("meta_domain", meta_domain())
    elif path == "/api/system" and "cpu_threads" not in data:
        data["cpu_cores"] = "8"   # what a UI 1.9.0 server reports: physical cores
        data["cpu_threads"] = 16
    resp.set_data(json.dumps(data))
    return resp


_HOST_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+")


def _norm_host(s):
    h = str(s or "").strip().lower()
    return h[:-1] if h.endswith(".") else h


def _valid_host(h):
    """The strict hostname rule of spec A.1 (server, helper and page share it)."""
    return len(h) <= 253 and bool(_HOST_RE.fullmatch(h)) and not re.fullmatch(r"[0-9.]+", h)


def setup_view(view, phase):
    """Wrap a setup route. Records the RPC hostname for the canned streams; in
    `fresh-reject` answers finalize on the public path with the 400 for a missing
    rpc_domain; and, while the running server predates package UI-2a (no norm_host),
    applies the A.4 rpc_domain checks itself so the page sees the 1.9.0 answers."""
    def wrapped(node_type):
        data = request.get_json(silent=True) or {}
        dom = _norm_host(data.get("rpc_domain"))
        if SC.get("reject_finalize") and phase == "finalize" and data.get("rpc_public"):
            return jsonify({"error": NO_DOMAIN_ERROR}), 400
        if SC["name"] != "legacy" and not hasattr(server, "norm_host"):
            if data.get("rpc_public") and not dom:
                return jsonify({"error": NO_DOMAIN_ERROR}), 400
            if dom and not _valid_host(dom):
                return jsonify({"error": f'That public RPC hostname is not valid: "{dom}".'}), 400
        SETUP["domain"] = dom if _valid_host(dom) else ""
        return view(node_type)
    wrapped.__name__ = view.__name__
    return wrapped


def install(scenario, role):
    SC.clear()
    SC.update(SCENARIOS[scenario], name=scenario)
    if role:
        SC["role"] = role
    SETUP.update(domain="", installed=not SC.get("fresh"))
    server.run = fake_run
    proxy = types.SimpleNamespace(**{k: getattr(subprocess, k) for k in dir(subprocess)
                                     if not k.startswith("__")})
    proxy.Popen = FakePopen
    server.subprocess = proxy
    server.detect_nodes = fake_detect_nodes
    for name, value in (("resolve_service_unit", lambda t: "telcoin"),
                        ("detect_public_ip", lambda: PUBLIC_IP),
                        ("latest_docker_image",
                         lambda: "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri"),
                        ("latest_source_tag", lambda: "v0.15.0-adiri")):
        if hasattr(server, name):
            setattr(server, name, value)
    urllib.request.urlopen = fake_urlopen
    server.app.view_functions["api_status"] = status_fixture
    server.app.view_functions["api_validator"] = validator_fixture
    for endpoint, phase in (("api_setup_keygen", "keygen"), ("api_setup_finalize", "finalize")):
        server.app.view_functions[endpoint] = setup_view(server.app.view_functions[endpoint], phase)
    server.app.after_request(overlay)


def main(argv=None):
    p = argparse.ArgumentParser(description="Serve the Node Manager page with fixture data.")
    p.add_argument("--port", type=int, default=8099)
    p.add_argument("--scenario", choices=sorted(SCENARIOS), default="public")
    p.add_argument("--role", choices=server.NODE_TYPES, default=None,
                   help="slot the node is shown in (default: the scenario's)")
    args = p.parse_args(argv)
    install(args.scenario, args.role)
    print(f"ui/dev/serve.py: scenario {args.scenario}, role {SC['role']}, "
          f"http://127.0.0.1:{args.port}/", flush=True)
    server.app.run(host="127.0.0.1", port=args.port, threaded=True, debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
