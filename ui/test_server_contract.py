#!/usr/bin/env python3
"""
Contract tests for ui/server.py: what the server sends the privileged helper,
whether the sudoers whitelist in install-ui.sh allows it, and the shapes the
page reads back.

Covered:
  * every helper call the server makes matches a sudoers line byte for byte,
    every whitelisted subcommand exists in the helper's dispatch, env_keep
    covers every TN_* variable the server sets, and install-ui.sh runs its
    steps in the order that installs the whitelist last;
  * the setup environment (_setup_env) and its 400s;
  * the public RPC enable call: its four argv shapes and its 400s;
  * the action streams: one `done`, then `closed`, stray output as `log`
    events, a made-up `done` when the script sends none, a client that goes
    away mid-stream;
  * _parse_json_tail, the hostname rule, physical_cores, and the operator-only
    fields of /api/nodes.

No network, no sudo, no node: run() and subprocess.Popen are replaced by
recorders, and temp files go to a per-test directory. Python 3.10 or later
with Flask (ui/requirements.txt):

    python3 -m unittest discover -s ui -p 'test_*.py'
"""

import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import server  # noqa: E402

SERVER_PY = os.path.join(HERE, "server.py")
INSTALLER = os.path.join(HERE, "install-ui.sh")
HELPER_SH = os.path.join(HERE, "telcoin-ui-helper.sh")
HELPER_PATH = "/usr/local/sbin/telcoin-ui-helper"

# The 14 node subcommands and the arguments each takes once the role is gone
# (A.1). The server must send exactly this many.
NODE_SUBCOMMAND_ARITY = {
    "tracing-enable": 0, "tracing-disable": 0, "update-check": 0,
    "update-prepare": 1, "update-apply": 0, "update-discard": 0,
    "restart-count": 0, "log-clear": 0, "config-set": 2, "set-hostname": 1,
    "addons-status": 0, "meta-cat": 0, "setup-keygen": 0, "setup-finalize": 0,
}

DONE_OK = json.dumps({"event": "done", "ok": True, "msg": "finished"})


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# install-ui.sh and telcoin-ui-helper.sh, parsed
# ---------------------------------------------------------------------------

def sudoers_text():
    """The sudoers heredoc install-ui.sh writes, as text."""
    m = re.search(r'cat > "\$\{SUDOERS_TMP\}" <<EOF\n(.*?)\nEOF\n', read(INSTALLER), re.S)
    if not m:
        raise AssertionError("sudoers heredoc not found in install-ui.sh")
    return m.group(1)


def split_transitional(text):
    """(text without the TRANSITIONAL block, the block). The block keeps the old
    observer|validator lines for servers before 1.9.0 and is removed in UI-4,
    so this server must not need any line in it."""
    m = re.search(r"^# TRANSITIONAL\b.*?^# END TRANSITIONAL$", text, re.S | re.M)
    if not m:
        return text, ""
    return text[:m.start()] + text[m.end():], m.group(0)


_HELPER_LINE_RE = re.compile(
    r"^\$\{SVC_USER\} ALL=\(ALL\) NOPASSWD: " + re.escape(HELPER_PATH) + r" (.+)$", re.M)


def helper_rules(text):
    """The argument patterns of the helper lines in a sudoers text, such as
    'update-check' or 'config-set *'."""
    return [r.rstrip() for r in _HELPER_LINE_RE.findall(text)]


def env_keep_vars():
    m = re.search(r'^Defaults!' + re.escape(HELPER_PATH) + r' env_keep \+= "([^"]*)"$',
                  sudoers_text(), re.M)
    if not m:
        raise AssertionError("env_keep line for the helper not found")
    return set(m.group(1).split())


def sudo_allows(argv, rules):
    """True when sudo would run argv under one of `rules`. A rule without
    wildcards allows exactly those arguments; with `*` it allows any match,
    spaces included (sudoers matches the arguments joined by spaces)."""
    if argv[:3] != ["sudo", "-n", HELPER_PATH] or len(argv) < 4:
        return False
    args = " ".join(argv[3:])
    for rule in rules:
        if any(ch in rule for ch in "*?["):
            if fnmatch.fnmatchcase(args, rule):
                return True
        elif args == rule:
            return True
    return False


def helper_dispatch():
    """Subcommand names in the `case "$sub" in` block of the helper's main()."""
    text = read(HELPER_SH)
    m = re.search(r'^main\(\) \{.*?case "\$sub" in\n(.*?)^\s*esac', text, re.S | re.M)
    if not m:
        raise AssertionError("dispatch case not found in telcoin-ui-helper.sh")
    return set(re.findall(r"^\s*([a-z][a-z-]*)\)", m.group(1), re.M))


def server_subcommands():
    """Every helper subcommand named in server.py's source."""
    return set(re.findall(r'\bHELPER,\s*"([a-z][a-z-]*)"', read(SERVER_PY)))


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

class FakeStdout:
    def __init__(self, lines):
        self._lines = [ln if ln.endswith("\n") else ln + "\n" for ln in lines]
        self.closed = False

    def readline(self):
        return self._lines.pop(0) if self._lines else ""

    def close(self):
        self.closed = True


class FakePopen:
    """A finished (or hanging) child: canned stdout lines, an exit code, and
    stderr text written to the file the server passes, as a real child would."""

    def __init__(self, argv, stderr, env, kwargs, lines=(), rc=0, stderr_text="",
                 hang=False, start_error=None):
        if start_error is not None:
            raise start_error
        self.args = list(argv)
        self.env = env
        self.kwargs = kwargs
        self.stdout = FakeStdout(list(lines))
        self.returncode = None
        self.terminated = False
        self._rc = rc
        self._hang = hang
        if stderr_text:
            stderr.write(stderr_text)
            stderr.flush()

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is None:
            if self._hang:
                raise subprocess.TimeoutExpired(self.args, timeout)
            self.returncode = self._rc
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def kill(self):
        self.returncode = -9


def scripts_nodes(slot="observer", **extra):
    """detect_nodes() output with one scripts-managed node in `slot`."""
    empty = {"mode": None, "status": "not installed", "container": None,
             "image": None, "rpc_port": None, "node_info_path": None}
    out = {t: dict(empty) for t in server.NODE_TYPES}
    out[slot] = dict(empty, mode="scripts", status="active", rpc_port=8545, **extra)
    return out


def external_nodes(slot="observer"):
    out = scripts_nodes(slot)
    out[slot].update(mode="external", container="tn-ext", image="adiri:v0.15.0-adiri",
                     inspect={"State": {"Running": True}})
    return out


# Helper replies by subcommand: (rc, stdout, stderr).
HELPER_REPLIES = {
    "helper-version": (0, "2", ""),
    "meta-cat": (0, "NODE_TYPE=observer\nDATA_DIR=/var/lib/telcoin\n"
                    "PUBLIC_RPC_DOMAIN=node7.example.com\n", ""),
    "caddy-status": (0, json.dumps({"installed": True, "running": True, "enabled": True,
                                    "domain": "dashboard.example.com",
                                    "username": "admin"}), ""),
    "rpc-status": (0, json.dumps({"installed": True, "running": True, "enabled": True,
                                  "domain": "node7.example.com"}), ""),
    "caddy-dns-check": (0, json.dumps({"propagated": True}), ""),
    "rpc-dns-check": (0, json.dumps({"propagated": True}), ""),
    "firewall-status": (0, json.dumps({"installed": True, "active": True}), ""),
    "firewall-port": (0, json.dumps({"ok": True}), ""),
    "update-check": (0, json.dumps({"current_ref": "v0.14.0-adiri",
                                    "latest_ref": "v0.15.0-adiri"}), ""),
    "update-discard": (0, "", ""),
    "addons-status": (0, json.dumps({"network": "testnet"}), ""),
    "restart-count": (0, "3", ""),
    "log-clear": (0, "ok", ""),
    "set-hostname": (0, "ok", ""),
    "set-logrotate": (0, "ok", ""),
    "clear-rotated": (0, "removed 2", ""),
    "internal-ip": (0, "10.0.0.5", ""),
    "docker-detect": (0, "tn-ext", ""),
    "docker-status": (0, json.dumps([{"Config": {"Cmd": [], "Image": "adiri:v1"},
                                      "State": {"Running": True}}]), ""),
    "docker-stats": (0, "1.5%\t1GiB / 2GiB\t1kB / 2kB\t0B / 0B", ""),
    "docker-log-size": (0, "123", ""),
    "docker-node-info": (0, "node_type: observer\n", ""),
    "docker-logs": (0, "line one\nline two", ""),
    "docker-logs-full": (0, "line one\nline two", ""),
    "jaeger-status": (0, "running", ""),
    "jaeger-start": (0, "", ""),
    "jaeger-stop": (0, "", ""),
    "tracing-enable": (0, "", ""),
    "tracing-disable": (0, "", ""),
}


class ServerTestCase(unittest.TestCase):
    """Patches every way the server reaches the host or the network, and
    records each argv it runs (run) or spawns (Popen) in self.calls."""

    def setUp(self):
        self.calls = []
        self.procs = []
        self.helper_replies = dict(HELPER_REPLIES)
        self.host_replies = {}          # argv[0] -> (rc, stdout, stderr)
        self.popen_script = {"lines": [DONE_OK], "rc": 0}
        self.nodes = scripts_nodes()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

        proxy = types.SimpleNamespace(**{k: getattr(subprocess, k) for k in dir(subprocess)
                                         if not k.startswith("__")})
        proxy.Popen = self.popen
        self.patch(server, "subprocess", proxy)
        self.patch(server, "run", self.fake_run)
        self.patch(server, "detect_nodes", lambda: self.nodes)
        self.patch(server.tempfile, "tempdir", self.tmp.name)
        self.patch(server.urllib.request, "urlopen", self.no_network)
        self.patch(server, "jaeger_get", lambda *a, **k: None)
        self.patch(server, "CPUINFO_PATH", os.path.join(self.tmp.name, "no-cpuinfo"))

        server._helper_cache.update({"expires": 0.0, "data": None})
        server.clear_meta_cache()
        server._docker_stats_cache.clear()
        server._setup_running["active"] = False
        self.client = server.app.test_client()

    def patch(self, obj, name, value):
        p = mock.patch.object(obj, name, value)
        p.start()
        self.addCleanup(p.stop)

    @staticmethod
    def no_network(*_a, **_k):
        raise OSError("network disabled in test_server_contract.py")

    def fake_run(self, cmd, timeout=10):
        cmd = [str(c) for c in cmd]
        self.calls.append(cmd)
        if cmd[:3] == ["sudo", "-n", server.HELPER] and len(cmd) > 3:
            return self.helper_replies.get(cmd[3], (1, "", "no reply for " + cmd[3]))
        return self.host_replies.get(cmd[0] if cmd else "", (127, "", "not found"))

    def popen(self, argv, stdout=None, stderr=None, env=None, **kwargs):
        self.calls.append([str(a) for a in argv])
        proc = FakePopen(argv, stderr, env, kwargs, **self.popen_script)
        self.procs.append(proc)
        return proc

    def helper_calls(self):
        return [c for c in self.calls if server.HELPER in c]

    def events(self, resp):
        """The JSON events of a stream response, each from one `data:` frame."""
        out = []
        for chunk in resp.response:
            self.assertTrue(chunk.startswith("data: ") and chunk.endswith("\n\n"), chunk)
            self.assertNotIn("\n", chunk[:-2], "one line per frame")
            out.append(json.loads(chunk[len("data: "):-2]))
        resp.close()
        return out

    def stream_events(self, data):
        """Parse a buffered text/event-stream body."""
        out = []
        for frame in data.decode().split("\n\n"):
            if frame.startswith("data: "):
                out.append(json.loads(frame[len("data: "):]))
        return out


# ---------------------------------------------------------------------------
# Cross-file contract: server.py <-> sudoers <-> helper <-> installer
# ---------------------------------------------------------------------------

FULL_SETUP = {
    "network": "testnet", "install_method": "docker",
    "docker_image": "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri",
    "passphrase_method": "loadcredential", "address": "0x" + "ab" * 20,
    "external_primary": "/ip4/203.0.113.10/udp/49590/quic-v1",
    "external_worker": "/ip4/203.0.113.10/udp/49594/quic-v1",
    "listener_primary": "/ip4/10.0.0.5/udp/49590/quic-v1",
    "listener_worker": "/ip4/10.0.0.5/udp/49594/quic-v1",
    "public_ip": "203.0.113.10", "rpc_public": True, "rpc_domain": "node7.example.com",
    "service_user": "telcoin", "service_group": "telcoin", "advertised_name": "node7",
    "data_dir": "/var/lib/telcoin", "passphrase": "correct horse battery staple",
}


class CrossFileContractTest(ServerTestCase):

    def exercise_every_helper_call(self):
        """Drive every code path that calls the helper, with valid input."""
        c = self.client
        server.helper_status()
        server.read_meta()
        server.service_restart_count("observer")
        server.internal_ip()
        server._docker_detect()
        server._docker_inspect("tn-ext")
        server._docker_stats("tn-ext")
        server._docker_log_size("tn-ext")
        # docker-node-info: an external node's node-info.yaml (identity and the
        # execution address the role check asks the chain about).
        server.read_node_info_text("observer", external_nodes()["observer"])

        self.nodes = external_nodes()
        c.get("/api/logs/observer?lines=50")
        c.get("/api/logs/observer/download")
        self.nodes = scripts_nodes()

        c.post("/api/logs/observer/clear")
        c.get("/api/config/observer/set?field=verbosity&value=-vv", buffered=True)
        c.post("/api/config/observer/hostname", json={"name": "node7"})
        c.post("/api/config/observer/logrotate", json={"size": "1G"})
        c.post("/api/config/observer/clear-rotated")
        c.get("/api/firewall")
        for spec in server.FIREWALL_PORTS:
            port, proto = spec.split("/")
            for state in ("on", "off"):
                c.post("/api/firewall/port", json={"port": port, "proto": proto,
                                                   "state": state})
        c.post("/api/setup/observer/keygen", json=FULL_SETUP, buffered=True)
        c.post("/api/setup/observer/finalize", json=FULL_SETUP, buffered=True)
        c.get("/api/caddy/status")
        c.post("/api/caddy/dns-check", json={"domain": "dashboard.example.com"})
        c.post("/api/caddy/dns-check", json={"domain": "dashboard.example.com",
                                             "public_ip": "203.0.113.10"})
        c.post("/api/caddy/enable", json={"domain": "dashboard.example.com",
                                          "username": "admin", "password": "long enough",
                                          "public_ip": "203.0.113.10"}, buffered=True)
        c.post("/api/caddy/disable", buffered=True)
        c.get("/api/rpc/status")
        c.post("/api/rpc/dns-check", json={"domain": "node7.example.com",
                                           "public_ip": "203.0.113.10"})
        for body in ({"domain": "node7.example.com"},
                     {"domain": "node7.example.com", "public_ip": "203.0.113.10"},
                     {"domain": "node7.example.com",
                      "move_dashboard_to": "dashboard.node7.example.com"},
                     {"domain": "node7.example.com", "public_ip": "203.0.113.10",
                      "move_dashboard_to": "dashboard.node7.example.com"}):
            c.post("/api/rpc/enable", json=body, buffered=True)
        c.post("/api/rpc/disable", buffered=True)
        c.get("/api/addons/status?node_type=observer")
        c.get("/api/update/status/observer")
        c.get("/api/update/prepare/observer?ref=v0.15.0-adiri", buffered=True)
        c.get("/api/update/apply/observer", buffered=True)
        c.post("/api/update/discard/observer")
        c.get("/api/jaeger/status")
        c.post("/api/jaeger/start")
        c.post("/api/jaeger/stop")
        c.post("/api/tracing/enable/observer")
        c.post("/api/tracing/disable/observer")

    def test_helper_path_matches_sudoers(self):
        self.assertEqual(server.HELPER, HELPER_PATH)
        paths = set(re.findall(r"/[\w./-]*telcoin-ui-helper[\w.-]*", sudoers_text()))
        self.assertIn(HELPER_PATH, paths)
        other = paths - {HELPER_PATH}
        self.assertEqual(other, set(), "sudoers names the helper by another path")

    def test_every_helper_call_matches_a_sudoers_line(self):
        rules, _ = split_transitional(sudoers_text())
        rules = helper_rules(rules)
        self.exercise_every_helper_call()
        calls = self.helper_calls()
        self.assertTrue(calls)
        for argv in calls:
            with self.subTest(argv=argv):
                self.assertEqual(argv[:3], ["sudo", "-n", HELPER_PATH],
                                 "helper calls go through sudo -n with the full path")
                self.assertTrue(sudo_allows(argv, rules),
                                "no sudoers line (outside TRANSITIONAL) allows %r" % argv)

    def test_every_subcommand_in_the_source_is_exercised(self):
        # Ties the call check above to the source: a new helper call in
        # server.py fails here until exercise_every_helper_call drives it.
        self.exercise_every_helper_call()
        called = {argv[3] for argv in self.helper_calls()}
        self.assertEqual(server_subcommands() - called, set())
        self.assertEqual(called - server_subcommands(), set())

    def test_every_source_subcommand_has_a_sudoers_line(self):
        rules, _ = split_transitional(sudoers_text())
        whitelisted = {r.split()[0] for r in helper_rules(rules)}
        self.assertEqual(server_subcommands() - whitelisted, set())

    def test_node_subcommands_carry_no_role(self):
        self.exercise_every_helper_call()
        seen = set()
        for argv in self.helper_calls():
            sub = argv[3]
            if sub in NODE_SUBCOMMAND_ARITY:
                seen.add(sub)
                with self.subTest(argv=argv):
                    self.assertEqual(len(argv) - 4, NODE_SUBCOMMAND_ARITY[sub])
        self.assertEqual(seen, set(NODE_SUBCOMMAND_ARITY))

    def test_every_sudoers_subcommand_is_dispatched_by_the_helper(self):
        dispatch = helper_dispatch()
        self.assertIn("helper-version", dispatch)
        for rule in helper_rules(sudoers_text()):
            with self.subTest(rule=rule):
                self.assertIn(rule.split()[0], dispatch)

    def test_helper_version_matches_the_server(self):
        m = re.search(r"^HELPER_API=(\d+)$", read(HELPER_SH), re.M)
        self.assertIsNotNone(m)
        self.assertEqual(int(m.group(1)), server.HELPER_API_REQUIRED)

    def test_env_keep_covers_every_variable_the_server_sets(self):
        keep = env_keep_vars()
        with mock.patch.dict(os.environ, {}, clear=True):
            env, err = server._setup_env(FULL_SETUP, want_passphrase=True)
        self.assertIsNone(err)
        set_vars = {k for k in env if k.startswith("TN_")}
        self.assertIn("TN_SETUP_RPC_DOMAIN", set_vars)
        self.assertEqual(set_vars - keep, set())
        # Every TN_* the source assigns (TN_CADDY_PASSWORD included).
        assigned = set(re.findall(r'env\["(TN_[A-Z_]+)"\]', read(SERVER_PY)))
        self.assertEqual(assigned - keep, set())
        for gone in ("TN_SETUP_RPC_PUBLIC", "TN_SETUP_INSTANCE"):
            self.assertNotIn(gone, set_vars | assigned | keep)

    def test_helper_reads_every_setup_variable(self):
        helper = read(HELPER_SH)
        with mock.patch.dict(os.environ, {}, clear=True):
            env, _ = server._setup_env(FULL_SETUP, want_passphrase=True)
        for var in sorted(k for k in env if k.startswith("TN_SETUP_")):
            with self.subTest(var=var):
                self.assertIn("${" + var + ":-", helper)

    def test_installer_steps_follow_the_safe_order(self):
        text = read(INSTALLER)
        marks = [(int(m.group(1)), m.start())
                 for m in re.finditer(r"^# ---- (\d+)\. ", text, re.M)]
        self.assertEqual([n for n, _ in marks], list(range(1, 13)))
        bounds = [pos for _, pos in marks] + [len(text)]
        steps = {n: text[bounds[i]:bounds[i + 1]] for i, (n, _) in enumerate(marks)}
        anchors = {
            1: ["$EUID -ne 0", "WAS_ACTIVE="],
            2: ["pip3 install flask"],
            3: ["useradd --system"],
            4: ['bash -n "${SRC_DIR}/telcoin-ui-helper.sh"'],
            5: ['mktemp "${SUDOERS_TMP_TEMPLATE}"', 'visudo -cf "${SUDOERS_TMP}"'],
            6: ['"${HELPER_DST}.new"', 'mv -f "${HELPER_DST}.new" "${HELPER_DST}"'],
            7: ['"${UPDATE_DIR}/update-node.sh"'],
            8: ['cp "${SRC_DIR}/server.py"', "chown -R"],
            9: ["LOGROTATE_CONF="],
            10: ["systemctl daemon-reload"],
            11: ['mv -f "${SUDOERS_TMP}" "${SUDOERS_FILE}"'],
            12: ["systemctl restart telcoin-ui"],
        }
        for n, needles in anchors.items():
            for needle in needles:
                with self.subTest(step=n, needle=needle):
                    self.assertIn(needle, steps[n])
        self.assertEqual(text.count('mv -f "${SUDOERS_TMP}" "${SUDOERS_FILE}"'), 1,
                         "the whitelist is swapped in once, at step 11")
        self.assertEqual(text.count("visudo -cf"), 1)


# ---------------------------------------------------------------------------
# Setup environment
# ---------------------------------------------------------------------------

class SetupEnvTest(ServerTestCase):

    def env_for(self, **changes):
        data = dict(FULL_SETUP, **changes)
        for k in [k for k, v in changes.items() if v is None]:
            data.pop(k)
        with mock.patch.dict(os.environ, {}, clear=True):
            return server._setup_env(data, want_passphrase=True)

    def test_domain_is_normalised(self):
        env, err = self.env_for(rpc_domain="  Node7.Example.COM. ")
        self.assertIsNone(err)
        self.assertEqual(env["TN_SETUP_RPC_DOMAIN"], "node7.example.com")

    def test_domain_without_rpc_public_still_requests_public_rpc(self):
        env, err = self.env_for(rpc_public=None)
        self.assertIsNone(err)
        self.assertEqual(env["TN_SETUP_RPC_DOMAIN"], "node7.example.com")

    def test_rpc_public_without_domain_is_refused(self):
        for domain in (None, "", "   "):
            with self.subTest(domain=domain):
                env, err = self.env_for(rpc_domain=domain)
                self.assertIsNone(env)
                self.assertEqual(err, server.RPC_PUBLIC_NEEDS_HOST)

    def test_invalid_domain_is_refused(self):
        for domain in ("localhost", "1.2.3.4", "a..b", "-a.example.com", "a_b.example.com",
                       "x" * 64 + ".com", "https://node7.example.com", "node7.example.com:443"):
            with self.subTest(domain=domain):
                env, err = self.env_for(rpc_domain=domain)
                self.assertIsNone(env)
                self.assertTrue(err.startswith("That public RPC hostname is not valid: "), err)

    def test_explicit_private_rpc_drops_a_leftover_domain(self):
        env, err = self.env_for(rpc_public=False, rpc_domain="node7.example.com")
        self.assertIsNone(err)
        self.assertEqual(env["TN_SETUP_RPC_DOMAIN"], "")
        env, err = self.env_for(rpc_public=False, rpc_domain="not a host")
        self.assertIsNone(err)

    def test_private_rpc_sets_an_empty_domain(self):
        env, err = self.env_for(rpc_public=None, rpc_domain=None)
        self.assertIsNone(err)
        self.assertEqual(env["TN_SETUP_RPC_DOMAIN"], "")

    def test_retired_variables_are_never_set(self):
        env, err = self.env_for(instance="2")
        self.assertIsNone(err)
        self.assertNotIn("TN_SETUP_RPC_PUBLIC", env)
        self.assertNotIn("TN_SETUP_INSTANCE", env)

    def test_passphrase_required_for_keygen_only(self):
        data = dict(FULL_SETUP)
        data.pop("passphrase")
        env, err = server._setup_env(data, want_passphrase=True)
        self.assertEqual(err, "passphrase required")
        env, err = server._setup_env(data, want_passphrase=False)
        self.assertIsNone(err)
        self.assertNotIn("TN_BLS_PASSPHRASE", env)

    def test_routes_refuse_before_any_helper_call(self):
        for phase in ("keygen", "finalize"):
            for body in (dict(FULL_SETUP, rpc_domain=""),
                         dict(FULL_SETUP, rpc_domain="1.2.3.4")):
                with self.subTest(phase=phase, body=body["rpc_domain"]):
                    self.calls.clear()
                    resp = self.client.post("/api/setup/observer/" + phase, json=body)
                    self.assertEqual(resp.status_code, 400)
                    self.assertTrue(resp.get_json()["error"])
                    self.assertEqual(self.helper_calls(), [])
                    self.assertFalse(server._setup_running["active"])

    def test_routes_send_the_domain_in_the_environment(self):
        for phase in ("keygen", "finalize"):
            with self.subTest(phase=phase):
                self.procs.clear()
                resp = self.client.post("/api/setup/validator/" + phase,
                                        json=dict(FULL_SETUP, rpc_domain="Node7.Example.com"),
                                        buffered=True)
                self.assertEqual(resp.status_code, 200)
                proc = self.procs[-1]
                self.assertEqual(proc.args, ["sudo", "-n", HELPER_PATH, "setup-" + phase])
                self.assertEqual(proc.env["TN_SETUP_RPC_DOMAIN"], "node7.example.com")
                self.assertEqual(proc.env.get("TN_BLS_PASSPHRASE") is not None,
                                 phase == "keygen")
                self.assertFalse(server._setup_running["active"],
                                 "the setup guard is released when the stream closes")


# ---------------------------------------------------------------------------
# Public RPC enable
# ---------------------------------------------------------------------------

class RpcEnableTest(ServerTestCase):
    D = "node7.example.com"
    IP = "203.0.113.10"
    MOVE = "dashboard.node7.example.com"

    def enable(self, body):
        self.procs.clear()
        resp = self.client.post("/api/rpc/enable", json=body, buffered=True)
        return resp, (self.procs[-1].args if self.procs else None)

    def test_four_argv_shapes(self):
        base = ["sudo", "-n", HELPER_PATH, "rpc-enable"]
        cases = [
            ({"domain": self.D}, [self.D]),
            ({"domain": self.D, "public_ip": self.IP}, [self.D, self.IP]),
            ({"domain": self.D, "move_dashboard_to": self.MOVE}, [self.D, "-", self.MOVE]),
            ({"domain": self.D, "public_ip": self.IP, "move_dashboard_to": self.MOVE},
             [self.D, self.IP, self.MOVE]),
        ]
        for body, tail in cases:
            with self.subTest(body=body):
                resp, argv = self.enable(body)
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(argv, base + tail)

    def test_hostnames_are_normalised(self):
        resp, argv = self.enable({"domain": " NODE7.Example.com. ",
                                  "move_dashboard_to": "Dashboard.NODE7.example.com."})
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(argv[4:], [self.D, "-", self.MOVE])

    def test_refusals_happen_before_the_helper(self):
        cases = [
            ({"domain": "localhost"}, 'That public RPC hostname is not valid: "localhost".'),
            ({"domain": "1.2.3.4"}, 'That public RPC hostname is not valid: "1.2.3.4".'),
            ({"domain": ""}, "Enter a public RPC hostname, such as node7.example.com."),
            ({"domain": "a_b.example.com"}, "That public RPC hostname is not valid"),
            ({"domain": self.D, "public_ip": "203.0.113.10; rm"}, "invalid public IP"),
            ({"domain": self.D, "move_dashboard_to": "dashboard"},
             'That new dashboard hostname is not valid: "dashboard".'),
            ({"domain": self.D, "move_dashboard_to": "10.0.0.1"},
             "That new dashboard hostname is not valid"),
            ({"domain": self.D, "move_dashboard_to": "NODE7.example.com."},
             "The dashboard needs a hostname other than the RPC hostname"),
        ]
        for body, message in cases:
            with self.subTest(body=body):
                self.calls.clear()
                resp, argv = self.enable(body)
                self.assertEqual(resp.status_code, 400)
                self.assertIn(message, resp.get_json()["error"])
                self.assertIsNone(argv)
                self.assertEqual(self.helper_calls(), [])

    def test_dns_checks_use_the_strict_rule(self):
        for route, what in (("/api/caddy/dns-check", "dashboard hostname"),
                            ("/api/rpc/dns-check", "public RPC hostname")):
            with self.subTest(route=route):
                self.calls.clear()
                resp = self.client.post(route, json={"domain": "localhost"})
                self.assertEqual(resp.status_code, 400)
                self.assertTrue(resp.get_json()["error"].startswith(
                    f'That {what} is not valid: "localhost". '), resp.get_json()["error"])
                self.assertEqual(self.helper_calls(), [])
                resp = self.client.post(route, json={"domain": "Node7.Example.com."})
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(self.helper_calls()[-1][4], self.D)

    def test_caddy_enable_uses_the_strict_rule(self):
        body = {"domain": "1.2.3.4", "username": "admin", "password": "long enough"}
        resp = self.client.post("/api/caddy/enable", json=body)
        self.assertEqual(resp.status_code, 400)
        self.assertIn('That dashboard hostname is not valid: "1.2.3.4".', resp.get_json()["error"])
        self.assertEqual(self.helper_calls(), [])


# ---------------------------------------------------------------------------
# Config edits: the fields and values the helper's config-set accepts
# ---------------------------------------------------------------------------

def helper_config_patterns():
    """{field: regex text} from the `case "$field"` in the helper's
    cmd_config_set, one entry per label."""
    m = re.search(r"^cmd_config_set\(\) \{\n(.*?)^\}", read(HELPER_SH), re.S | re.M)
    if not m:
        raise AssertionError("cmd_config_set not found in telcoin-ui-helper.sh")
    out = {}
    for labels, block in re.findall(r"^\s+([a-z_|]+)\)\n(.*?);;", m.group(1), re.S | re.M):
        rx = re.search(r"=~ (\S+)", block)
        for label in labels.split("|"):
            out[label] = rx.group(1) if rx else None
    return out


# The same rows as the config-set section of ui/tests/helper_test.sh.
CONFIG_GOOD = [
    ("primary_listener", "/ip4/0.0.0.0/udp/49590/quic-v1"),
    ("worker_listener", "/ip6/::/udp/49594/quic-v1"),
    ("metrics", "127.0.0.1:9101"),
    ("metrics", "off"),
    ("verbosity", "-vvvvv"),
    ("docker_image", "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri"),
    ("bootstrap_peers", "none"),
    ("bootstrap_peers", "/home/ubuntu/peers.yaml"),
    ("state_export", "off"),
    ("state_export", "unlimited"),
    ("state_export", "1"),
    ("state_export", "999999"),
    ("allow_private_forward_targets", "true"),
    ("allow_private_forward_targets", "false"),
]
CONFIG_BAD = [
    ("metrics", "on"),
    ("metrics", "OFF"),
    ("metrics", "127.0.0.1"),
    ("verbosity", "-vvvvvv"),
    ("docker_image", "adiri"),
    ("bootstrap_peers", "peers.yaml"),
    ("bootstrap_peers", "None"),
    ("bootstrap_peers", "/tmp/peers file.yaml"),
    ("bootstrap_peers", "/tmp/$(id).yaml"),
    ("bootstrap_peers", ""),
    ("state_export", "0"),
    ("state_export", "01"),
    ("state_export", "1000000"),
    ("state_export", "-1"),
    ("state_export", "Unlimited"),
    ("allow_private_forward_targets", "yes"),
    ("allow_private_forward_targets", "1"),
    ("allow_private_forward_targets", "TRUE"),
]


class ConfigSetTest(ServerTestCase):

    def set_field(self, field, value):
        self.calls.clear()
        return self.client.get("/api/config/observer/set",
                               query_string={"field": field, "value": value}, buffered=True)

    def test_fields_and_patterns_match_the_helper(self):
        helper = helper_config_patterns()
        self.assertEqual(set(helper), set(server.CONFIG_FIELDS))
        for field in server.CONFIG_FIELDS:
            with self.subTest(field=field):
                self.assertEqual(server.CONFIG_VALUE_RE[field].pattern, helper[field])

    def test_accepted_values_reach_the_helper_unchanged(self):
        for field, value in CONFIG_GOOD:
            with self.subTest(field=field, value=value):
                resp = self.set_field(field, value)
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(self.helper_calls(),
                                 [["sudo", "-n", HELPER_PATH, "config-set", field, value]])

    def test_refused_values_never_reach_the_helper(self):
        for field, value in CONFIG_BAD:
            with self.subTest(field=field, value=value):
                resp = self.set_field(field, value)
                self.assertEqual(resp.status_code, 400)
                self.assertEqual(resp.get_json(), {"error": "invalid value for field"})
                self.assertEqual(self.helper_calls(), [])

    def test_unknown_fields_are_refused(self):
        for field in ("not_a_field", "Metrics", "hostname", ""):
            with self.subTest(field=field):
                resp = self.set_field(field, "off")
                self.assertEqual(resp.status_code, 400)
                self.assertEqual(resp.get_json(), {"error": "field not editable"})
                self.assertEqual(self.helper_calls(), [])

    def test_a_trailing_newline_fails_as_in_bash(self):
        # The route strips its input; config_value_ok itself must still refuse
        # what the helper's [[ =~ ]] refuses.
        for field, value in CONFIG_GOOD:
            with self.subTest(field=field, value=value):
                self.assertTrue(server.config_value_ok(field, value))
                self.assertFalse(server.config_value_ok(field, value + "\n"))


# ---------------------------------------------------------------------------
# Action streams
# ---------------------------------------------------------------------------

ARGV = ["sudo", "-n", HELPER_PATH, "update-apply"]


def ev(event, **kw):
    return json.dumps(dict({"event": event}, **kw))


class StreamTest(ServerTestCase):

    def run_stream(self, lines=(), rc=0, stderr_text="", **script):
        self.popen_script = dict(script, lines=list(lines), rc=rc, stderr_text=stderr_text)
        return self.events(server._update_stream(list(ARGV)))

    def assert_framing(self, events):
        names = [e["event"] for e in events]
        self.assertEqual(names.count("done"), 1, names)
        self.assertEqual(names.count("closed"), 1, names)
        self.assertEqual(names[-2:], ["done", "closed"], names)
        self.assertEqual(os.listdir(self.tmp.name), [], "stderr temp file removed")

    def test_child_done_passes_through(self):
        events = self.run_stream([ev("step", msg="one"), ev("log", msg="two"),
                                  ev("done", ok=True, msg="Updated")])
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["step", "log", "done", "closed"])
        self.assertEqual(events[2], {"event": "done", "ok": True, "msg": "Updated"})

    def test_missing_done_with_failure(self):
        events = self.run_stream([ev("step", msg="one")], rc=1,
                                 stderr_text="\x1b[31m[ERROR]\x1b[0m first\n\nsecond\n")
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["step", "error", "done", "closed"])
        self.assertEqual(events[1]["msg"], "output: [ERROR] first | second")
        done = events[2]
        self.assertEqual({k: done[k] for k in ("ok", "synthesized", "rc")},
                         {"ok": False, "synthesized": True, "rc": 1})
        self.assertIn("exit code 1", done["msg"])

    def test_missing_done_with_success(self):
        events = self.run_stream([ev("step", msg="one")], rc=0, stderr_text="noise\n")
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["step", "done", "closed"])
        self.assertEqual({k: events[1][k] for k in ("ok", "synthesized", "rc")},
                         {"ok": True, "synthesized": True, "rc": 0})

    def test_failure_tail_comes_before_the_child_done(self):
        events = self.run_stream([ev("done", ok=False, msg="apply failed")], rc=2,
                                 stderr_text="docker: no space left on device\n")
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["error", "done", "closed"])
        self.assertIn("no space left", events[0]["msg"])
        self.assertNotIn("synthesized", events[1])

    def test_stray_lines_become_log_events(self):
        events = self.run_stream([
            "Status: Downloaded newer image for adiri:v0.15.0-adiri",
            "\x1b[1;32mgreen\x1b[0m text\x1b]0;title\x07",
            '{"not_an_event": 1}',
            "[1, 2]",
            "   ",
            "\x1b[0m",
            DONE_OK,
        ])
        self.assert_framing(events)
        logs = [e for e in events if e["event"] == "log"]
        self.assertEqual([e["msg"] for e in logs],
                         ["Status: Downloaded newer image for adiri:v0.15.0-adiri",
                          "green text", '{"not_an_event": 1}', "[1, 2]"])

    def test_exactly_one_done_and_server_owned_closed(self):
        events = self.run_stream([ev("step", msg="one"), ev("closed"),
                                  ev("done", ok=True, msg="first"),
                                  ev("log", msg="late"),
                                  ev("done", ok=False, msg="second")])
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["step", "log", "done", "closed"])
        self.assertEqual(events[2]["msg"], "first")

    def test_child_killed_by_signal(self):
        events = self.run_stream([ev("step", msg="one")], hang=True)
        self.assert_framing(events)
        self.assertTrue(self.procs[-1].terminated)
        self.assertEqual(events[-2]["rc"], -15)
        self.assertIn("signal 15", events[-2]["msg"])

    def test_start_failure_still_ends_the_stream(self):
        self.popen_script = {"start_error": FileNotFoundError(2, "No such file", "sudo")}
        events = self.events(server._update_stream(list(ARGV)))
        self.assert_framing(events)
        self.assertEqual([e["event"] for e in events], ["error", "done", "closed"])
        self.assertEqual(events[1]["rc"], 127)
        self.assertFalse(events[1]["ok"])

    def test_client_disconnect_mid_stream(self):
        closed = []
        for hang in (False, True):
            with self.subTest(hang=hang):
                self.popen_script = {"lines": [ev("step", msg="one"), ev("step", msg="two"),
                                               DONE_OK], "rc": 0, "hang": hang}
                resp = server._update_stream(list(ARGV), on_close=lambda: closed.append(1))
                gen = resp.response
                self.assertIn('"step"', next(gen))
                closed.clear()
                resp.close()            # what the WSGI server does when the client goes
                with self.assertRaises(StopIteration):
                    next(gen)           # nothing more is yielded after the close
                proc = self.procs[-1]
                self.assertTrue(proc.stdout.closed)
                self.assertEqual(proc.terminated, hang,
                                 "a child still running after the grace period is terminated")
                self.assertEqual(closed, [1], "on_close runs once")
                self.assertEqual(os.listdir(self.tmp.name), [])

    def test_on_close_runs_even_if_the_stream_never_started(self):
        closed = []
        resp = server._update_stream(list(ARGV), on_close=lambda: closed.append(1))
        resp.close()
        self.assertEqual(closed, [1])
        self.assertEqual(self.procs, [], "no child is started for an unread response")

    def test_child_gets_utf8_with_replacement_and_a_stderr_file(self):
        self.run_stream([DONE_OK])
        kw = self.procs[-1].kwargs
        self.assertEqual((kw.get("encoding"), kw.get("errors"), kw.get("text")),
                         ("utf-8", "replace", True))

    def test_routes_keep_their_method_and_framing(self):
        cases = [
            ("get", "/api/update/prepare/observer?ref=v0.15.0-adiri", None),
            ("get", "/api/update/apply/observer", None),
            ("get", "/api/config/observer/set?field=verbosity&value=-vv", None),
            ("post", "/api/setup/observer/keygen", FULL_SETUP),
            ("post", "/api/setup/observer/finalize", FULL_SETUP),
            ("post", "/api/caddy/enable", {"domain": "dashboard.example.com",
                                           "username": "admin", "password": "long enough"}),
            ("post", "/api/caddy/disable", None),
            ("post", "/api/rpc/enable", {"domain": "node7.example.com"}),
            ("post", "/api/rpc/disable", None),
        ]
        self.popen_script = {"lines": ["stray"], "rc": 3, "stderr_text": "why\n"}
        for method, url, body in cases:
            with self.subTest(url=url):
                kwargs = {"json": body} if body is not None else {}
                resp = getattr(self.client, method)(url, buffered=True, **kwargs)
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(resp.mimetype, "text/event-stream")
                events = self.stream_events(resp.data)
                self.assertEqual([e["event"] for e in events],
                                 ["log", "error", "done", "closed"])
                self.assertTrue(events[2]["synthesized"])
        self.assertFalse(server._setup_running["active"])


class RealChildStreamTest(ServerTestCase):
    """The same generator over a real child process (this Python), so the
    Popen arguments, the stderr file and the decoding are the real ones."""

    def setUp(self):
        super().setUp()
        real = types.SimpleNamespace(**{k: getattr(subprocess, k) for k in dir(subprocess)
                                        if not k.startswith("__")})
        self.patch(server, "subprocess", real)

    def stream(self, code):
        return self.events(server._update_stream([sys.executable, "-c", code]))

    def test_real_child_without_done(self):
        code = (
            "import sys\n"
            "sys.stdout.write('{\"event\":\"step\",\"msg\":\"one\"}\\n')\n"
            "sys.stdout.flush()\n"
            "sys.stdout.buffer.write(b'bad byte \\xff here\\n')\n"
            "sys.stdout.flush()\n"
            "sys.stderr.write('\\x1b[31mfailed:\\x1b[0m disk full\\n')\n"
            "sys.exit(4)\n"
        )
        events = self.stream(code)
        self.assertEqual([e["event"] for e in events], ["step", "log", "error", "done", "closed"])
        self.assertEqual(events[1]["msg"], "bad byte � here")
        self.assertEqual(events[2]["msg"], "output: failed: disk full")
        self.assertEqual((events[3]["rc"], events[3]["synthesized"]), (4, True))
        self.assertEqual(os.listdir(self.tmp.name), [])

    def test_real_child_with_done(self):
        code = "print('{\"event\":\"done\",\"ok\":true,\"msg\":\"fine\"}')"
        events = self.stream(code)
        self.assertEqual(events, [{"event": "done", "ok": True, "msg": "fine"},
                                  {"event": "closed"}])

    def test_missing_program(self):
        events = self.events(server._update_stream(
            [os.path.join(self.tmp.name, "no-such-program")]))
        self.assertEqual([e["event"] for e in events], ["error", "done", "closed"])
        self.assertEqual(events[1]["rc"], 127)


# ---------------------------------------------------------------------------
# Parsers and probes
# ---------------------------------------------------------------------------

class ParseJsonTailTest(unittest.TestCase):

    def test_cases(self):
        cases = [
            (None, None),
            ("", None),
            ("   \n  ", None),
            ('{"a": 1}', {"a": 1}),
            ('warning: slow disk\n{"a": 1}', {"a": 1}),
            ('{"a": 1}\n{"b": 2}', {"b": 2}),
            ('{"a": 1}\ntrailing log line', {"a": 1}),
            ('{"a": 1}\r\n', {"a": 1}),
            ('  {"a": 1}  ', {"a": 1}),
            ('{"a": 1}\n{"b": ', {"a": 1}),
            ("[1, 2]", None),
            ('"text"', None),
            ("42", None),
            ('{"a": 1', None),
        ]
        for text, want in cases:
            with self.subTest(text=text):
                self.assertEqual(server._parse_json_tail(text), want)


class HostnameRuleTest(unittest.TestCase):
    LONG_OK = ".".join(["a" * 63, "b" * 63, "c" * 63, "d" * 61])   # 253 characters

    def test_valid(self):
        self.assertEqual(len(self.LONG_OK), 253)
        for h in ("node7.adiri.telcoin.network", "a.b", "1.2.3.a", "xn--bcher-kva.example",
                  "a-b.c-d.example", "a" * 63 + ".com", self.LONG_OK):
            with self.subTest(h=h):
                self.assertTrue(server.valid_hostname(h))

    def test_invalid(self):
        for h in ("localhost", "1.2.3.4", "1.2.3.4.5", "a..b", "a.b.", ".a.b", "-a.b",
                  "a-.b", "a_b.com", "a" * 64 + ".com", self.LONG_OK + "d", "",
                  "http://a.b", "a.b:443", "a b.c", "a.b\n", None, 7):
            with self.subTest(h=h):
                self.assertFalse(server.valid_hostname(h))

    def test_normalise(self):
        self.assertEqual(server.norm_host("  NODE7.Example.COM.  "), "node7.example.com")
        self.assertEqual(server.norm_host("a.b.."), "a.b.")
        self.assertFalse(server.valid_hostname(server.norm_host("a.b..")))
        self.assertEqual(server.norm_host(None), "")

    def test_same_host(self):
        self.assertTrue(server.same_host("A.b.", "a.B"))
        self.assertFalse(server.same_host("", ""))
        self.assertFalse(server.same_host("a.b", "a.c"))


LSCPU_8C16T = "# The following is the parsable format\n# Core,Socket\n" + "".join(
    "%d,0\n%d,0\n" % (c, c) for c in range(8))

CPUINFO_2S2C2T = "".join(
    "processor\t: %d\nvendor_id\t: GenuineIntel\nphysical id\t: %d\ncore id\t\t: %d\n\n"
    % (n, n // 4, (n // 2) % 2) for n in range(8))

CPUINFO_ARM = "".join("processor\t: %d\nBogoMIPS\t: 50.00\n\n" % n for n in range(4))


class PhysicalCoresTest(ServerTestCase):

    def cpuinfo(self, text):
        path = os.path.join(self.tmp.name, "cpuinfo")
        with open(path, "w") as f:
            f.write(text)
        self.patch(server, "CPUINFO_PATH", path)

    def test_lscpu_pairs(self):
        self.host_replies = {"lscpu": (0, LSCPU_8C16T.strip(), ""), "nproc": (0, "16", "")}
        self.assertEqual(server.physical_cores(), 8)
        self.assertEqual(self.calls[0], ["lscpu", "--parse=CORE,SOCKET"])

    def test_lscpu_two_sockets_reuse_core_ids(self):
        self.host_replies = {"lscpu": (0, "0,0\n1,0\n0,1\n1,1", "")}
        self.assertEqual(server.physical_cores(), 4)

    def test_cpuinfo_pairs_when_lscpu_is_missing(self):
        self.cpuinfo(CPUINFO_2S2C2T)
        self.assertEqual(server.physical_cores(), 4)

    def test_lscpu_without_rows_falls_through(self):
        self.host_replies = {"lscpu": (0, "# Core,Socket", "")}
        self.cpuinfo(CPUINFO_2S2C2T.rstrip("\n"))   # no blank line at the end
        self.assertEqual(server.physical_cores(), 4)

    def test_sysctl_when_cpuinfo_has_no_core_ids(self):
        self.cpuinfo(CPUINFO_ARM)
        self.host_replies = {"sysctl": (0, "10", "")}
        self.assertEqual(server.physical_cores(), 10)
        self.assertIn(["sysctl", "-n", "hw.physicalcpu"], self.calls)

    def test_order_when_every_source_answers(self):
        self.cpuinfo(CPUINFO_2S2C2T)
        self.host_replies = {"lscpu": (0, LSCPU_8C16T.strip(), ""), "sysctl": (0, "10", ""),
                             "nproc": (0, "16", "")}
        self.assertEqual(server.physical_cores(), 8)     # lscpu first
        del self.host_replies["lscpu"]
        self.assertEqual(server.physical_cores(), 4)     # then /proc/cpuinfo
        self.cpuinfo(CPUINFO_ARM)
        self.assertEqual(server.physical_cores(), 10)    # then sysctl
        del self.host_replies["sysctl"]
        self.assertEqual(server.physical_cores(), 16)    # then the logical count

    def test_logical_count_last(self):
        self.host_replies = {"nproc": (0, "16", "")}
        self.assertEqual(server.physical_cores(), 16)
        self.host_replies = {}
        self.patch(server.os, "cpu_count", lambda: 6)
        self.assertEqual(server.physical_cores(), 6)
        self.assertEqual(server.logical_cpus(), 6)

    def test_system_and_preflight_report_both_counts(self):
        self.host_replies = {"lscpu": (0, LSCPU_8C16T.strip(), ""), "nproc": (0, "16", "")}
        system = self.client.get("/api/system").get_json()
        self.assertEqual((system["cpu_cores"], system["cpu_threads"]), ("8", 16))
        pre = self.client.get("/api/setup/preflight").get_json()
        self.assertEqual((pre["cpu_physical"], pre["cpu_threads"]), (8, 16))
        self.assertEqual(pre["hardware"]["cpu"], 8)
        validator = [t for t in pre["hardware"]["tiers"] if t["role"] == "validator"][0]
        self.assertNotIn("cpu", validator["gaps"], "8 physical cores meet the validator tier")


# ---------------------------------------------------------------------------
# /api/nodes, /api/rpc/status, constants
# ---------------------------------------------------------------------------

class NodesAndStatusTest(ServerTestCase):

    def nodes_json(self, public=False):
        headers = {"X-TN-Dashboard-Public": "1"} if public else {}
        return self.client.get("/api/nodes", headers=headers).get_json()

    def test_operator_path_reports_helper_and_role(self):
        self.nodes = scripts_nodes("validator", role_source="local",
                                   role_checked_at=1790000000, role_address="0x" + "ab" * 20)
        data = self.nodes_json()
        self.assertEqual(data["helper"], {"ok": True, "api": 2, "required": 2, "error": ""})
        self.assertEqual(data["role_source"], "local")
        self.assertEqual(data["role_checked_at"], 1790000000)
        self.assertEqual(data["role_address"], "0x" + "ab" * 20)
        self.assertEqual(data["role"], "validator")

    def test_public_path_reports_neither(self):
        self.nodes = scripts_nodes("validator", role_source="local",
                                   role_checked_at=1790000000)
        data = self.nodes_json(public=True)
        for key in ("helper", "role_source", "role_checked_at", "role_address"):
            self.assertNotIn(key, data)
        self.assertEqual(self.helper_calls(), [], "no helper-version call on the public path")

    def test_role_fields_null_without_a_node(self):
        self.nodes = {t: {"mode": None} for t in server.NODE_TYPES}
        data = self.nodes_json()
        self.assertIsNone(data["role_source"])
        self.assertIsNone(data["role_checked_at"])
        self.assertIsNone(data["role_address"])

    def test_detector_without_a_role_answer_leaves_the_fields_out(self):
        self.nodes = scripts_nodes("observer")      # like ui/dev/serve.py's detector
        data = self.nodes_json()
        self.assertNotIn("role_source", data)
        self.assertIn("helper", data)

    def test_helper_status_cache(self):
        self.assertTrue(server.helper_status()["ok"])
        server.helper_status()
        self.assertEqual(len(self.helper_calls()), 1, "a good answer is cached")

        server._helper_cache.update({"expires": 0.0, "data": None})
        self.helper_replies["helper-version"] = (1, "", "sudo: a password is required")
        bad = server.helper_status()
        self.assertEqual(bad, {"ok": False, "api": None, "required": 2,
                               "error": "sudo: a password is required"})
        self.helper_replies["helper-version"] = (0, "2\n", "")
        self.assertEqual(server.helper_status(), bad, "a failed probe is cached too")
        self.assertEqual(len(self.helper_calls()), 2,
                         "a denied sudo is not repeated on every poll")
        server._helper_cache.update({"expires": 0.0})      # the minute is over
        self.assertTrue(server.helper_status()["ok"])
        self.assertEqual(len(self.helper_calls()), 3)

    def test_helper_status_old_api(self):
        self.helper_replies["helper-version"] = (0, "1", "")
        st = server.helper_status()
        self.assertEqual((st["ok"], st["api"]), (False, 1))
        self.assertIn("API 1", st["error"])
        server._helper_cache.update({"expires": 0.0, "data": None})
        self.helper_replies["helper-version"] = (0, "two", "")
        st = server.helper_status()
        self.assertEqual((st["ok"], st["api"]), (False, None))

    def test_helper_status_newer_api(self):
        self.helper_replies["helper-version"] = (0, "3", "")
        st = server.helper_status()
        self.assertEqual(st, {"ok": True, "api": 3, "required": 2, "error": ""})

    def test_rpc_status_meta_domain_and_pass_through(self):
        full = {"installed": True, "running": True, "enabled": True,
                "domain": "node7.example.com", "advertised_http": "https://node7.example.com",
                "advertised_ws": "", "ws_listening": False, "block_stale": True}
        self.helper_replies["rpc-status"] = (0, "warning: x\n" + json.dumps(full), "")
        data = self.client.get("/api/rpc/status").get_json()
        self.assertEqual(data["meta_domain"], "node7.example.com")
        for key in ("advertised_http", "advertised_ws", "ws_listening", "block_stale"):
            self.assertEqual(data[key], full[key])

        self.helper_replies["rpc-status"] = (0, json.dumps({"installed": True}), "")
        data = self.client.get("/api/rpc/status").get_json()
        for key in ("advertised_http", "advertised_ws", "ws_listening", "block_stale"):
            self.assertNotIn(key, data)

        self.helper_replies["rpc-status"] = (1, "", "boom")
        server.clear_meta_cache()
        self.helper_replies["meta-cat"] = (1, "", "no meta")
        data = self.client.get("/api/rpc/status").get_json()
        self.assertEqual((data["installed"], data["error"], data["meta_domain"]),
                         (False, "boom", ""))

    def test_status_readers_take_the_last_json_object(self):
        self.helper_replies["caddy-status"] = (0, 'note\n{"installed": true, "domain": "d.e"}', "")
        self.assertEqual(self.client.get("/api/caddy/status").get_json()["domain"], "d.e")
        self.helper_replies["update-check"] = (0, 'log line\n{"latest_ref": "v9"}', "")
        self.assertEqual(self.client.get("/api/update/status/observer").get_json(),
                         {"latest_ref": "v9"})

    def test_endpoint_constants(self):
        self.assertEqual(server.NETWORK_PUBLIC_RPC[2017], ["https://rpc.adiri.tel"])
        self.assertFalse(hasattr(server, "NETWORK_PUBLIC_WS"))
        self.assertNotIn("scan.telcoin.network", read(SERVER_PY))

    def test_jaeger_service_preference(self):
        rs = server.resolve_service
        self.assertEqual(rs(["telcoin-observer-A", "telcoin", "telcoin-B"]), "telcoin")
        self.assertEqual(rs(["telcoin-validator-Z", "telcoin-QCZPqMY2zfp", "jaeger-all-in-one"]),
                         "telcoin-QCZPqMY2zfp")
        # A legacy name that sorts first still loses to a current one.
        self.assertEqual(rs(["telcoin-zKq3", "telcoin-observer-A"]), "telcoin-zKq3")
        self.assertEqual(rs(["telcoin-validator-Z", "telcoin-observer-A"]), "telcoin-observer-A")
        self.assertIsNone(rs(["jaeger-all-in-one", "telcoinx"]))
        self.assertIsNone(rs([]))


# ---------------------------------------------------------------------------
# Refs that reach git or update-node.sh never start with "-"
# ---------------------------------------------------------------------------

class RefValidationTest(ServerTestCase):

    def test_update_prepare_refuses_a_leading_dash(self):
        for ref in ("-v0.15.0", "--help", "-", "", "v0.15.0 adiri", "v0.15.0;id"):
            with self.subTest(ref=ref):
                resp = self.client.get("/api/update/prepare/observer", query_string={"ref": ref})
                self.assertEqual(resp.status_code, 400)
                self.assertEqual(resp.get_json(), {"error": "invalid ref"})
        self.assertEqual(self.helper_calls(), [], "a refused ref never reaches the helper")

    def test_update_prepare_accepts_ordinary_refs(self):
        for ref in ("v0.15.0-adiri", "main", "feature/epoch-wait", "0.15.0", "_x", "v1.2-"):
            with self.subTest(ref=ref):
                self.calls.clear()
                resp = self.client.get("/api/update/prepare/observer", query_string={"ref": ref},
                                       buffered=True)
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(self.helper_calls(),
                                 [["sudo", "-n", HELPER_PATH, "update-prepare", ref]])

    def test_setup_build_ref_refuses_a_leading_dash(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            env, err = server._setup_env(dict(FULL_SETUP, install_method="source",
                                              build_ref="-v0.15.0"), want_passphrase=True)
            self.assertIsNone(env)
            self.assertEqual(err, "invalid build ref")
            env, err = server._setup_env(dict(FULL_SETUP, install_method="source",
                                              build_ref="v0.15.0-adiri"), want_passphrase=True)
            self.assertIsNone(err)
            self.assertEqual(env["TN_SETUP_BUILD_REF"], "v0.15.0-adiri")


if __name__ == "__main__":
    unittest.main()
