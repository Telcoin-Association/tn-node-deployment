#!/usr/bin/env python3
"""
Telcoin Network Node Manager -- Flask backend.

Read/observe + service-control web UI for Telcoin Network nodes. Runs on the
node itself, binds to 127.0.0.1:8080, and is reached over an SSH tunnel.

This server does NOT replace the bash scripts (setup-*.sh, check-node.sh,
edit-config.sh, ...). The scripts remain the source of truth. The UI reads the
same files / logs / RPC the scripts read and shells out to `systemctl` for
start/stop/restart only. Status parsing is re-implemented in Python here so it
does not depend on scraping check-node.sh text output -- but the probes mirror
exactly what check-node.sh does (same RPC methods, same file paths).

Every route returns JSON even on error: a missing log file yields an empty
array, a missing service file yields installed:false -- never a 500.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from datetime import datetime, timezone

from flask import Flask, Response, jsonify, request, send_file, send_from_directory

# Diagnostics. _log always writes to stderr (-> journald: `journalctl -u
# telcoin-ui`); _dbg only when TN_UI_DEBUG is set (verbose request/response
# dumps). Used to trace the external-node on-chain contract-call pipeline.
TN_UI_DEBUG = os.environ.get("TN_UI_DEBUG", "").lower() in ("1", "true", "yes", "on")


def _log(msg):
    print(f"[tn-ui] {msg}", file=sys.stderr, flush=True)


def _dbg(msg):
    if TN_UI_DEBUG:
        print(f"[tn-ui-debug] {msg}", file=sys.stderr, flush=True)

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================

app = Flask(__name__)

# Silence Werkzeug's per-request access log. The dashboard polls several endpoints
# every ~15s while open, so an always-on dashboard writes ~1 access line/sec to the
# journal (`journalctl -u telcoin-ui`) -- pure HTTP noise that dominated the journal
# (~97% of its lines). WARNING keeps real warnings/errors; our own _log/_dbg
# diagnostics and Flask exception tracebacks are unaffected. Behaviour is identical.
import logging
logging.getLogger("werkzeug").setLevel(logging.WARNING)

# Web UI version -- its own independent line (starts at 1.0.0). This is the
# single constant update-scripts.sh greps to decide whether the UI is stale.
UI_VERSION = "1.7.67"

NODE_TYPES = ("observer", "validator")

# Where the management scripts live (used only to print the manual setup
# command in the wizard -- the UI never auto-runs setup in v1).
SCRIPTS_DIR = os.path.expanduser("~/telcoin-node-scripts")

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# Default layout, mirroring lib/common.sh in the deployment repo.
DEFAULT_LOG_DIR = "/var/log/telcoin"
DEFAULT_CONFIG_DIR = "/etc/telcoin"
DEFAULT_DATA_DIR = "/var/lib/telcoin"
DEFAULT_INSTALL_DIR = "/opt/telcoin"
TN_SOURCE_DIR = "/opt/telcoin-source"

# Legacy per-type instance number, retained only for the (now vestigial) "instance"
# config field the UI still renders. The node no longer takes --instance and the RPC
# port comes from .node-meta (reth default 8545), so this no longer maps to a port.
DEFAULT_INSTANCE = {"observer": 5, "validator": 1}


def resolve_service_unit(t):
    """Resolve the systemd unit BASE name for the installed node, mirroring
    lib/fallback.sh's tn_resolve_service. New single-identity installs use one
    unit (telcoin.service) regardless of node type; legacy installs keep their
    per-role unit. Probe in priority order:
        /etc/systemd/system/telcoin.service          -> "telcoin"   (new)
        else telcoin-<validator|observer>.service    -> that base   (legacy)
        else                                         -> "telcoin-<t>" (default
            for the requested type, so existence probes on a not-installed node
            still resolve to the conventional per-type path).
    Validator is preferred over observer if a host improbably has both."""
    sysd = "/etc/systemd/system"
    if os.path.exists(f"{sysd}/telcoin.service"):
        return "telcoin"
    for role in ("validator", "observer"):
        if os.path.exists(f"{sysd}/telcoin-{role}.service"):
            return f"telcoin-{role}"
    return f"telcoin-{t}"


def unified_install():
    """True when a new single-identity install is present (the unified
    telcoin.service exists). Such a host runs ONE node whose type lives in
    /etc/telcoin/.node-meta, not in the unit name."""
    return os.path.exists("/etc/systemd/system/telcoin.service")


def resolve_node_type():
    """The default-view HINT observer|validator for a unified install, mirroring
    lib/fallback.sh's tn_resolve_node_type. NODE_TYPE is a non-authoritative
    presentation hint, NOT a role: the protocol decides a node's role dynamically
    from on-chain committee membership each epoch, and the UI promotes/demotes the
    view from tn_isValidator (detect_nodes' on-chain remap). The hint is read from
    the unified /etc/telcoin/.node-meta NODE_TYPE (via the root helper, the only
    channel to the mode-0600 file); on older/legacy metadata the per-role
    .node-meta answers; a missing hint resolves to the plain 'observer' full-node
    view -- never validator, since on-chain status is what promotes a node."""
    for t in NODE_TYPES:
        nt = read_meta(t).get("NODE_TYPE", "").strip()
        if nt in NODE_TYPES:
            return nt
    return "observer"


def service_name(t):
    return resolve_service_unit(t)


def service_file(t):
    return f"/etc/systemd/system/{resolve_service_unit(t)}.service"


def log_file(t):
    """Default node log path. parse_service_file() may override via StandardOutput."""
    return f"{DEFAULT_LOG_DIR}/telcoin-{t}.log"


def config_dir(t):
    """Node config dir -- /etc/telcoin for a unified install (.node-meta lives
    there), else the legacy per-type dir."""
    if os.path.exists(f"{DEFAULT_CONFIG_DIR}/.node-meta"):
        return DEFAULT_CONFIG_DIR
    return f"{DEFAULT_CONFIG_DIR}/{t}"


def data_dir(t):
    """Node data dir -- from .node-meta DATA_DIR if set, else the default
    (unified /var/lib/telcoin, or the legacy per-type dir)."""
    meta = read_meta(t)
    if meta.get("DATA_DIR"):
        return meta["DATA_DIR"]
    if os.path.exists(f"{DEFAULT_CONFIG_DIR}/.node-meta"):
        return DEFAULT_DATA_DIR
    return f"{DEFAULT_DATA_DIR}/{t}"


def node_id(t):
    """The node's libp2p peer ID (12D3KooW...) parsed from node-info.yaml.
    '' when the file is missing or carries no peer ID."""
    info = os.path.join(data_dir(t), "node-info.yaml")
    try:
        with open(info, "r") as f:
            text = f.read()
    except (OSError, IOError):
        return ""
    m = re.search(r"/p2p/(12D3KooW[1-9A-HJ-NP-Za-km-z]+)", text)
    if m:
        return m.group(1)
    m = re.search(r"\b(12D3KooW[1-9A-HJ-NP-Za-km-z]+)\b", text)
    return m.group(1) if m else ""


def read_build_info():
    """Parse /etc/telcoin/build-info (KEY=VALUE lines) written by the setup
    scripts after a source build. None when the file is absent."""
    out = {}
    try:
        with open("/etc/telcoin/build-info", "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    except (OSError, IOError):
        return None
    return out


# =============================================================================
# LOW-LEVEL HELPERS
# =============================================================================

def run(cmd, timeout=10):
    """
    Run a command (list form) and return (rc, stdout, stderr). Never raises:
    a timeout or missing binary comes back as a non-zero rc with the error in
    stderr, so callers can treat everything uniformly.
    """
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except FileNotFoundError:
        return 127, "", "not found"
    except Exception as e:  # pragma: no cover - defensive
        return 1, "", str(e)


def valid_type(t):
    return t in NODE_TYPES


def bad_type():
    return jsonify({"error": "invalid node_type"}), 400


# .node-meta is root-owned mode 0600; the unprivileged UI user cannot open it
# directly (that silently yielded {} -> data_dir() etc. fell back to defaults,
# so a custom data dir read the wrong disk). Read it through the root helper
# instead -- the same privileged path addons-status already uses. Cached briefly
# since the file only changes on install/remove/settings and read_meta() is
# called several times per request; clear_meta_cache() drops it after a mutation.
_meta_cache = {}          # t -> (expires_monotonic, dict)
_META_TTL = 15.0


def clear_meta_cache():
    _meta_cache.clear()


def read_meta(t):
    """Parse /etc/telcoin/<type>/.node-meta (KEY=VALUE lines) via the root helper.
    {} if missing/unreadable."""
    if t not in NODE_TYPES:
        return {}
    now = time.monotonic()
    cached = _meta_cache.get(t)
    if cached and cached[0] > now:
        return cached[1]
    out = {}
    rc, text, _ = run(["sudo", "-n", HELPER, "meta-cat", t], timeout=10)
    if rc == 0 and text:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    _meta_cache[t] = (now + _META_TTL, out)
    return out


def parse_service_file(t):
    """
    Parse the systemd unit (and, for source installs, the wrapper script the
    unit ExecStart points at) into a config dict. Tolerant of both the docker
    form (flags + `-e "..."` on the ExecStart line) and the source form
    (Environment= lines in the unit, flags inside the wrapper .sh).

    Returns a dict with: installed, instance, rpc_port, metrics, primary_listener,
    worker_listener, http, log_path.
    """
    cfg = {
        "installed": False,
        "instance": str(DEFAULT_INSTANCE.get(t, 1)),
        "rpc_port": "8545",
        "metrics": "",
        "primary_listener": "",
        "worker_listener": "",
        "verbosity": "",
        "http": False,
        "log_path": log_file(t),
    }

    path = service_file(t)
    if not os.path.exists(path):
        return cfg
    cfg["installed"] = True

    try:
        with open(path, "r") as f:
            unit = f.read()
    except (OSError, IOError):
        return cfg

    # For source installs the actual node flags live in a wrapper script that
    # ExecStart=... points to. Pull the wrapper contents in so the same regexes
    # below find --metrics regardless of install method.
    searchable = unit
    m = re.search(r"^ExecStart=(\S+\.sh)\s*$", unit, re.MULTILINE)
    if m and os.path.exists(m.group(1)):
        try:
            with open(m.group(1), "r") as wf:
                searchable += "\n" + wf.read()
        except (OSError, IOError):
            pass

    # Log path: StandardOutput=append:/path
    mlog = re.search(r"^StandardOutput=append:(\S+)", unit, re.MULTILINE)
    if mlog:
        cfg["log_path"] = mlog.group(1)

    # RPC port: the node no longer takes an --instance flag, so the port is the
    # authoritative RPC_PORT from .node-meta (both setup scripts persist it --
    # unified installs serve 8545, legacy observer installs still serve 8541; the
    # helper's meta-cat resolves whichever .node-meta is present). Falls back to
    # the reth default 8545 set above.
    meta = read_meta(t)
    if meta.get("RPC_PORT"):
        cfg["rpc_port"] = meta["RPC_PORT"]

    # --metrics host:port  (may be quoted)
    mm = re.search(r"--metrics\s+\"?([^\s\"\\]+)", searchable)
    if mm:
        cfg["metrics"] = mm.group(1)

    # Verbosity flag: a standalone -v .. -vvvvv token (bounded so --validator and
    # other --v* flags never match). Mirrors edit-config.sh's detection.
    mvb = re.search(r"(?<!\S)(-v{1,5})(?!\S)", searchable)
    if mvb:
        cfg["verbosity"] = mvb.group(1)

    # Listeners appear as Environment="PRIMARY_LISTENER_MULTIADDR=..." (source)
    # or -e "PRIMARY_LISTENER_MULTIADDR=..." (docker). Match the value up to the
    # closing quote / whitespace either way.
    mp = re.search(r"PRIMARY_LISTENER_MULTIADDR=([^\"\s\\]+)", searchable)
    if mp:
        cfg["primary_listener"] = mp.group(1)
    mw = re.search(r"WORKER_LISTENER_MULTIADDR=([^\"\s\\]+)", searchable)
    if mw:
        cfg["worker_listener"] = mw.group(1)

    cfg["http"] = "--http" in searchable
    return cfg


# =============================================================================
# NODE DETECTION  (scripts-installed systemd unit  vs  external docker container)
#
# Every route decides "is this node installed, and may I manage it?" from this
# one short-TTL-cached detector instead of bare os.path.exists(service_file).
# A scripts node (systemd unit present) always wins and behaves exactly as
# before (mode="scripts"). Only when NEITHER type has a unit do we ask the root
# helper whether a dev-team docker container is running (mode="external"); such
# nodes are read-only -- the UI monitors them but every management action is
# refused. mode=None means not installed.
# =============================================================================

_detect_cache = {"ts": 0.0, "data": None}  # ~10s TTL
_DETECT_TTL = 10


def _docker_detect():
    """Names of running Telcoin Network docker containers, via the root helper.
    [] when none are found or the helper/sudo/docker is unavailable."""
    rc, out, _ = run(["sudo", "-n", HELPER, "docker-detect"], timeout=10)
    if rc != 0 or not out:
        return []
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def _docker_inspect(name):
    """Parsed `docker inspect` object (first array element) for a container, via
    the helper. None on any failure / bad JSON."""
    rc, out, _ = run(["sudo", "-n", HELPER, "docker-status", name], timeout=10)
    if rc != 0 or not out:
        return None
    try:
        data = json.loads(out)
    except (ValueError, json.JSONDecodeError):
        return None
    if isinstance(data, list):
        return data[0] if (data and isinstance(data[0], dict)) else None
    return data if isinstance(data, dict) else None


# docker stats samples take ~1s, so cache the parsed sample per container for the
# dashboard refresh cycle (mirrors the detect cache TTL).
_docker_stats_cache = {}  # name -> (ts, dict)
_DOCKER_STATS_TTL = 10


def _docker_stats(name):
    """Parsed `docker stats --no-stream` for a container, via the helper, cached
    ~10s. {cpu_percent, mem_usage, net_io, block_io}; None on any failure."""
    if not name:
        return None
    now = time.time()
    cached = _docker_stats_cache.get(name)
    if cached and now - cached[0] < _DOCKER_STATS_TTL:
        return cached[1]
    rc, out, _ = run(["sudo", "-n", HELPER, "docker-stats", name], timeout=15)
    if rc != 0 or not out:
        return None
    parts = out.splitlines()[0].split("\t")
    cpu = None
    if parts and parts[0]:
        m = re.search(r"([0-9.]+)", parts[0])
        if m:
            try:
                cpu = round(float(m.group(1)), 1)
            except ValueError:
                cpu = None
    data = {
        "cpu_percent": cpu,
        "mem_usage": parts[1].strip() if len(parts) > 1 else None,
        "net_io": parts[2].strip() if len(parts) > 2 else None,
        "block_io": parts[3].strip() if len(parts) > 3 else None,
    }
    _docker_stats_cache[name] = (now, data)
    return data


def _docker_log_size(name):
    """Size in bytes of the container's json-file log, via the helper. None on
    any failure."""
    if not name:
        return None
    rc, out, _ = run(["sudo", "-n", HELPER, "docker-log-size", name], timeout=10)
    if rc != 0 or not out.strip().isdigit():
        return None
    return int(out.strip())


def _cmd_join(cmd):
    """A container's Config.Cmd (list or string) as one searchable string."""
    if isinstance(cmd, list):
        return " ".join(str(x) for x in cmd)
    return str(cmd or "")


def _cmd_http_port(cmd):
    """--http.port N from a container Cmd (the port INSIDE the container). 8545
    when absent/unparseable."""
    m = re.search(r"--http\.port[=\s]+(\d+)", _cmd_join(cmd))
    if m:
        try:
            return int(m.group(1))
        except ValueError:
            pass
    return 8545


def _resolve_rpc_port(insp, internal_port):
    """The port the UI (a host process) must hit to reach the container's RPC.
    With host networking the container shares the host stack, so the internal
    --http.port is reachable directly. With bridge networking + a published port,
    the UI must use the HOST port the internal one is mapped to (which can differ
    from --http.port). Falls back to the internal port when there's no mapping."""
    ports = (insp.get("NetworkSettings") or {}).get("Ports") or {}
    binding = ports.get(f"{internal_port}/tcp")
    if isinstance(binding, list) and binding:
        hp = (binding[0] or {}).get("HostPort")
        if hp and str(hp).isdigit():
            return int(hp)
    return internal_port


def _docker_node_type(name):
    """Classify an external container as 'validator' or 'observer' from the
    helper's docker-node-info output (a non-empty proof_of_possession in
    node-info.yaml -> validator). None when it can't be determined; callers
    default to observer. Node type is config-derived, not from --validator
    flags (team deployments don't pass them)."""
    if not name:
        return None
    rc, out, _ = run(["sudo", "-n", HELPER, "docker-node-info", name], timeout=10)
    if rc != 0 or not out:
        return None
    m = re.search(r"(?m)^node_type:\s*(validator|observer)\s*$", out)
    return m.group(1) if m else None


def detect_nodes():
    """{type: {mode, status, container, image, rpc_port, node_info_path,
    inspect}} for both node types, short-TTL cached. mode is "scripts",
    "external", or None. `inspect` is the cached docker inspect dict for an
    external node (reused by status/identity within the TTL), absent otherwise."""
    now = time.time()
    cached = _detect_cache["data"]
    if cached is not None and now - _detect_cache["ts"] < _DETECT_TTL:
        return cached

    out = {t: {"mode": None, "status": "not installed", "container": None,
               "image": None, "rpc_port": None, "node_info_path": None}
           for t in NODE_TYPES}

    scripts = {}
    # A new single-identity install has ONE unit (telcoin.service) for whichever
    # single node type the host runs; the historical loop over both types would
    # otherwise mark BOTH as installed (service_file() resolves to the same unit
    # for either type). Attribute the unified unit to exactly one type slot,
    # resolved from .node-meta NODE_TYPE. Legacy installs keep their per-type
    # unit and the original per-type detection below.
    if unified_install():
        t = resolve_node_type()
        cfg = parse_service_file(t)
        try:
            port = int(cfg["rpc_port"])
        except (TypeError, ValueError):
            port = 8545
        out[t] = {"mode": "scripts", "status": service_status(t),
                  "container": None, "image": None, "rpc_port": port,
                  "node_info_path": None}
        scripts[t] = True
    else:
        for t in NODE_TYPES:
            if os.path.exists(service_file(t)):
                cfg = parse_service_file(t)
                try:
                    port = int(cfg["rpc_port"])
                except (TypeError, ValueError):
                    port = 8545
                out[t] = {"mode": "scripts", "status": service_status(t),
                          "container": None, "image": None, "rpc_port": port,
                          "node_info_path": None}
                scripts[t] = True

    # Container names already owned by a scripts-deployed systemd service. A
    # scripts node can itself run as a docker container; that container must
    # NEVER be re-detected as a separate "external" node (regardless of how it
    # would classify), since systemd already manages it. New installs name the
    # container `telcoin`; legacy installs name it telcoin-<type>.
    managed_names = {f"telcoin-{t}" for t in NODE_TYPES if scripts.get(t)}
    if unified_install():
        managed_names.add("telcoin")

    # Probe docker only for types that have NO systemd unit.
    if not all(scripts.get(t) for t in NODE_TYPES):
        for name in _docker_detect():
            if name in managed_names:
                _dbg(f"detect_nodes: skipping {name!r} -- managed by systemd")
                continue
            insp = _docker_inspect(name)
            if not insp:
                continue
            config = insp.get("Config") or {}
            cmd = config.get("Cmd") or []
            # Type is decided by config (proof_of_possession in node-info.yaml),
            # not the docker command line.
            t = _docker_node_type(name) or "observer"
            if scripts.get(t) or out[t]["mode"] == "external":
                continue  # never override a scripts node / first container wins
            st = insp.get("State") or {}
            binds = (insp.get("HostConfig") or {}).get("Binds") or []
            node_info_path = binds[0].split(":", 1)[0] if binds else None
            internal_port = _cmd_http_port(cmd)
            rpc_port = _resolve_rpc_port(insp, internal_port)
            _dbg(f"detect_nodes: external {t} container={name!r} "
                 f"internal_http_port={internal_port} rpc_port={rpc_port} "
                 f"netmode={(insp.get('HostConfig') or {}).get('NetworkMode')!r}")
            out[t] = {
                "mode": "external",
                "status": "active" if st.get("Running") is True else "inactive",
                "container": name,
                "image": config.get("Image"),
                "rpc_port": rpc_port,
                "node_info_path": node_info_path,
                "inspect": insp,
            }

    # ---- On-chain role remap (bidirectional) --------------------------------
    # telcoin-network decides a node's ROLE dynamically from on-chain committee
    # membership each epoch, not from the static NODE_TYPE hint. So present the
    # single installed (scripts-managed) node under the slot its on-chain status
    # dictates, in EITHER direction:
    #   tn_isValidator True  -> validator slot (the validator dashboard)
    #   tn_isValidator False -> observer slot  (the plain full-node view) -- this
    #     also demotes a legacy setup-validator install that never staked
    #   None (RPC down / not synced) -> leave it in its NODE_TYPE hint slot and
    #     never flap; a demotion requires a definitive synced False, not unknown.
    # Runs AFTER docker detection so managed_names already shielded the legacy
    # container from external re-detect. The single telcoin.service/.node-meta
    # resolves to the same node for either type slot, so re-attributing is purely
    # presentational (no other change needed). The clobber guard keeps a genuinely
    # separate node in the OTHER slot (shouldn't exist on a single-node host) from
    # being overwritten. External (read-only docker) nodes keep their config-
    # derived slot and are not remapped.
    src = next((t for t in NODE_TYPES
                if (out.get(t) or {}).get("mode") == "scripts"), None)
    if src is not None:
        is_val = onchain_is_validator(src, out[src])
        dst = ("validator" if is_val is True
               else "observer" if is_val is False else None)
        if dst is not None and dst != src:
            other = out.get(dst) or {}
            # Only remap into an empty slot or one already pointing at this same
            # single install (mode None/scripts) -- never clobber a separate node.
            if other.get("mode") in (None, "scripts"):
                remapped = dict(out[src])
                # "staked" badges the surprising observer-deployed-now-validator
                # case (true only when promoting INTO the validator slot).
                remapped["staked"] = (is_val is True)
                out[dst] = remapped
                out[src] = {"mode": None, "status": "not installed",
                            "container": None, "image": None,
                            "rpc_port": None, "node_info_path": None}
                _log(f"detect_nodes: on-chain tn_isValidator={is_val} -> "
                     f"presenting the {src} install under the {dst} slot")

    _detect_cache["ts"] = now
    _detect_cache["data"] = out
    return out


def detect_type(t):
    """detect_nodes() entry for one type (never raises)."""
    return detect_nodes().get(t, {"mode": None})


def is_external(t):
    return detect_type(t).get("mode") == "external"


def _external_block(t):
    """A 403 JSON response when t is an external (read-only) node, else None.
    Mutation routes call this so a management action is refused server-side even
    if the UI's read-only gating were bypassed."""
    if is_external(t):
        return jsonify({"ok": False, "error": "read-only (external node)"}), 403
    return None


# =============================================================================
# PUBLIC (read-only) ACCESS GUARD
#
# The dashboard is reachable two ways: directly over the SSH tunnel
# (127.0.0.1:8080 -- trusted, full management), and -- when install-caddy is
# enabled -- publicly via the Caddy reverse proxy. Caddy stamps an unforgeable
# X-TN-Dashboard-Public header on every proxied request (it deletes any
# client-supplied value then sets its own), which the SSH path never carries.
# Public requests are READ-ONLY: every write route is refused 403 here, server-
# side, so management is impossible over the public path even if the UI's gating
# were bypassed. Management requires the SSH tunnel.
# =============================================================================

def is_public_request():
    return bool(request.headers.get("X-TN-Dashboard-Public"))


def _is_write_request():
    """True for requests that mutate node/host state. POST/PUT/DELETE/PATCH are
    always writes; a few GET routes are SSE 'action' streams (config-set, update
    prepare/apply) and count as writes too.

    If you add a mutating GET route, add its path here AND classify it in
    test_public_readonly.py -- that test walks app.url_map and fails until every
    route is declared read or write, so a new write cannot silently leak onto
    the public (read-only) path."""
    if request.method in ("GET", "HEAD", "OPTIONS"):
        p = request.path
        return (p.endswith("/set")
                or p.startswith("/api/update/prepare/")
                or p.startswith("/api/update/apply/"))
    return True


@app.before_request
def _enforce_public_readonly():
    if is_public_request() and _is_write_request():
        return jsonify({
            "ok": False,
            "error": "read-only (public access) -- connect via the SSH tunnel "
                     "for management",
        }), 403


def _iso_uptime_seconds(iso):
    """Seconds since a docker RFC3339 StartedAt (e.g. 2024-05-01T12:00:00.123Z).
    None for an unset/never-started timestamp (0001-01-01...) or a bad value."""
    if not iso:
        return None
    m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", iso.strip())
    if not m:
        return None
    try:
        dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc)
    except ValueError:
        return None
    if dt.year < 1971:  # docker's zero-value StartedAt
        return None
    secs = int(time.time() - dt.timestamp())
    return secs if secs >= 0 else 0


# =============================================================================
# INSTALL / PASSPHRASE / VERSION DETECTION
#
# .node-meta is the source of truth when present, but it is missing/empty on
# nodes set up before the meta feature. These helpers fall back to deriving the
# answer from live system state (the unit file, on-disk key files, the source
# checkout) so the UI is correct regardless of meta presence.
# =============================================================================

def docker_image_ref(t):
    """Full docker image (registry/path:tag) from meta DOCKER_IMAGE, else grep
    the unit file. '' if neither has one."""
    meta = read_meta(t)
    img = meta.get("DOCKER_IMAGE", "").strip()
    if img:
        return img
    path = service_file(t)
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                unit = f.read()
            m = re.search(r"(us-docker[^\s\"]+|gcr\.io[^\s\"]+|ghcr\.io[^\s\"]+)", unit)
            if m:
                return m.group(1)
        except (OSError, IOError):
            pass
    return ""


def detect_install_method(t):
    """meta INSTALL_METHOD first; else infer from the unit ExecStart:
    a docker image -> 'docker'; a wrapper '.sh' -> 'source'; a bare binary
    -> 'existing'. '' when the node is not installed."""
    meta = read_meta(t)
    val = meta.get("INSTALL_METHOD", "").strip()
    if val:
        return val
    path = service_file(t)
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r") as f:
            unit = f.read()
    except (OSError, IOError):
        return ""
    m = re.search(r"^ExecStart=(.*)$", unit, re.MULTILINE)
    execline = m.group(1).strip() if m else ""
    if re.search(r"(us-docker|gcr\.io|ghcr\.io|/docker\b|\bdocker\s+run)", execline):
        return "docker"
    mw = re.search(r"^ExecStart=(\S+\.sh)\s*$", unit, re.MULTILINE)
    if mw and os.path.exists(mw.group(1)):
        return "source"
    if execline:
        return "existing"
    return ""


def detect_passphrase_method(t):
    """meta PASSPHRASE_METHOD first; else infer: a sealed TPM keypair
    (bls-tpm.pub/.priv) under /etc/telcoin/<type>/ -> 'tpm'; a
    LoadCredential=bls-passphrase line in the unit -> 'loadcredential'."""
    meta = read_meta(t)
    val = meta.get("PASSPHRASE_METHOD", "").strip()
    if val:
        return val
    cdir = config_dir(t)
    if (os.path.exists(os.path.join(cdir, "bls-tpm.pub")) or
            os.path.exists(os.path.join(cdir, "bls-tpm.priv"))):
        return "tpm"
    path = service_file(t)
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                if "LoadCredential=bls-passphrase" in f.read():
                    return "loadcredential"
        except (OSError, IOError):
            pass
    return ""


# Node version is not collected anywhere by the scripts; derive it on demand.
# Briefly cached because the source path shells out to git on every call.
_version_cache = {}  # t -> (timestamp, dict)


def node_version(t):
    """{'ref', 'kind'} for the node's running build. source -> git describe of
    /opt/telcoin-source; docker -> the image tag; existing -> binary --version."""
    now = time.time()
    cached = _version_cache.get(t)
    if cached and now - cached[0] < 30:
        return cached[1]

    # External (docker) nodes: prefer the version reported by the node (tn_info /
    # node-info.yaml); fall back to the container image tag.
    det = detect_type(t)
    if det.get("mode") == "external":
        out = {"ref": "", "kind": ""}
        ver = (node_identity(t, det) or {}).get("version")
        if ver:
            out["ref"], out["kind"] = ver, "node"
        else:
            img = det.get("image") or ""
            if ":" in img:
                out["ref"], out["kind"] = img.split(":")[-1], "docker image tag"
        _version_cache[t] = (now, out)
        return out

    method = detect_install_method(t)
    out = {"ref": "", "kind": method or ""}
    if method == "source":
        # Prefer the version marker written at install/apply time -- it names the
        # RUNNING binary. `git describe` of the source checkout is only the
        # fallback (older installs without a marker): it diverges from the running
        # binary after a prepare or a rolled-back apply, since the checkout moves
        # but the installed binary does not.
        ref = ""
        try:
            with open(os.path.join(DEFAULT_INSTALL_DIR, "telcoin-network.version")) as f:
                ref = f.read().strip()
        except (OSError, IOError):
            ref = ""
        if not ref:
            # -c safe.directory: the source checkout is root-owned but we run as
            # the unprivileged telcoin-ui user, so a bare git call refuses with
            # "dubious ownership". Scope it to this one read-only describe.
            rc, o, _ = run(
                ["git", "-c", "safe.directory=" + TN_SOURCE_DIR,
                 "-C", TN_SOURCE_DIR, "describe", "--tags", "--always", "--dirty"]
            )
            if rc == 0 and o:
                ref = o
        out["ref"] = ref
    elif method == "docker":
        img = docker_image_ref(t)
        if img:
            out["ref"] = img.split(":")[-1]
    else:
        binpath = os.path.join(DEFAULT_INSTALL_DIR, "telcoin-network")
        if os.path.exists(binpath):
            rc, o, _ = run([binpath, "--version"])
            if rc == 0 and o:
                out["ref"] = o.splitlines()[0].strip()

    _version_cache[t] = (now, out)
    return out


# Known networks keyed by EVM chain id. `slug` selects the public status page
# (status-page/<slug>) and the public-RPC map below; `name` is the display label.
# Adding a network here makes the whole UI (identity, network panel, status-page
# link) work on it -- nothing else is hardcoded to testnet.
NETWORKS = {
    2017: {"name": "Adiri Testnet", "slug": "testnet"},
    32285: {"name": "Adiri Devnet", "slug": "devnet"},
}

# Public consensus-block RPC endpoints per chain id, tried in order (first
# success wins). Testnet has a load balancer (single endpoint); devnet has no LB
# so all five node endpoints are listed as fallbacks. A chain id omitted here
# degrades the "Network Block"/"Consensus Lag" compare cards to "—".
NETWORK_PUBLIC_RPC = {
    2017:  ["https://rpc.telcoin.network"],
    32285: [
        "https://node1.devnet.telcoin.network",
        "https://node2.devnet.telcoin.network",
        "https://node3.devnet.telcoin.network",
        "https://node4.devnet.telcoin.network",
        "https://node5.devnet.telcoin.network",
    ],
}


def resolve_network(chain_id, t=None):
    """(slug, name, configured) for a live chain id. The chain id is
    authoritative; an unknown id falls back to .node-meta NETWORK (legacy nodes)
    with configured=False. configured=True means we have a known status page /
    network identity for it."""
    if chain_id is not None and chain_id in NETWORKS:
        m = NETWORKS[chain_id]
        return m["slug"], m["name"], True
    slug = read_meta(t).get("NETWORK", "").strip() if t is not None else ""
    if slug:
        for m in NETWORKS.values():
            if m["slug"] == slug:
                return slug, m["name"], True
        return slug, slug.capitalize(), False
    return "", "", False


def block_age(port):
    """Human 'X ago' for the latest execution block timestamp, or None."""
    res = local_rpc(port, "eth_getBlockByNumber", ["latest", False])
    if isinstance(res, dict):
        ts = hex_to_dec(res.get("timestamp"))
        if ts:
            return fmt_age(int(time.time()) - ts)
    return None


def log_error_count(log_path, window=3600):
    """Count ERROR/WARN log lines whose leading ISO-8601 timestamp falls within
    the last `window` seconds. 0 when the file is missing or has no timestamped
    error lines (lines without a parseable timestamp are skipped, not counted)."""
    if not log_path or not os.path.exists(log_path):
        return 0
    try:
        with open(log_path, "rb") as f:
            try:
                f.seek(-500000, os.SEEK_END)
            except OSError:
                f.seek(0)
            tail = f.read().decode("utf-8", "replace")
    except (OSError, IOError):
        return 0

    cutoff = time.time() - window
    count = 0
    for line in tail.splitlines():
        if "ERROR" not in line and "WARN" not in line:
            continue
        m = re.match(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})", line)
        if not m:
            continue
        try:
            dt = datetime.strptime(
                m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S"
            ).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if dt.timestamp() >= cutoff:
            count += 1
    return count


def fmt_bytes(n):
    """Bytes -> human ('12.3 MB'). None/garbage -> None."""
    try:
        n = float(n)
    except (TypeError, ValueError):
        return None
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{int(n)} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return None


# Quoted log message value, allowing escaped quotes/backslashes inside
# (message="... PeerId(\"...\") ..."). A [^"]* pattern would stop at the first
# \" -- this consumes \\. escape pairs so the whole value is captured.
_MSG_RE = re.compile(r'message="((?:\\.|[^"\\])*)"')


def _extract_message(line):
    r"""Full message= value from a log line, or None. Unescapes \" and \\ so the
    displayed text reads naturally (other backslash sequences left as-is)."""
    m = _MSG_RE.search(line)
    if not m:
        return None
    return re.sub(r'\\(["\\])', r'\1', m.group(1))


def log_stats(log_path, window=3600):
    """Single-pass log scan -> error/warn counts in the last `window` seconds,
    the most recent ERROR line (time + truncated message), and the log file
    size. Uses re.search (not match) so timestamps anywhere on the line parse --
    the node format prefixes lines with `ts=<iso>`. Safe defaults when missing."""
    out = {
        "error_count": 0,
        "warn_count": 0,
        "last_error": None,
        "recent_events": [],
        "log_size": None,
        "log_size_human": None,
    }
    if not log_path or not os.path.exists(log_path):
        return out
    try:
        out["log_size"] = os.path.getsize(log_path)
        out["log_size_human"] = fmt_bytes(out["log_size"])
    except OSError:
        pass
    try:
        with open(log_path, "rb") as f:
            try:
                f.seek(-1000000, os.SEEK_END)
            except OSError:
                f.seek(0)
            tail = f.read().decode("utf-8", "replace")
    except (OSError, IOError):
        return out

    cutoff = time.time() - window
    last_error_line = None
    events = []  # all ERROR/WARN events in the tail (for the Recent Log Events table)
    ts_re = re.compile(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})")
    for line in tail.splitlines():
        is_err = "ERROR" in line or "level=error" in line
        is_warn = "WARN" in line or "level=warn" in line
        if not is_err and not is_warn:
            continue
        ts = None
        m = ts_re.search(line)
        if m:
            try:
                ts = datetime.strptime(
                    m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S"
                ).replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                ts = None
        in_window = ts is not None and ts >= cutoff
        if is_err:
            if in_window:
                out["error_count"] += 1
            last_error_line = line  # ends as the most recent ERROR in the tail
        elif is_warn and in_window:
            out["warn_count"] += 1

        # Recent-events row (regardless of window; we keep only the last few).
        tgt = re.search(r"\btarget=(\S+)", line)
        emsg = _extract_message(line)
        events.append({
            "time": m.group(2) if m else "",
            "level": "error" if is_err else "warn",
            "target": tgt.group(1) if tgt else "",
            "msg": emsg if emsg is not None else line.strip(),
        })

    out["recent_events"] = list(reversed(events[-5:]))  # last 5, most recent first

    if last_error_line:
        tm = re.search(r"ts=(\S+)", last_error_line)
        time_str = tm.group(1) if tm else ""
        if not time_str:
            mm = ts_re.search(last_error_line)
            time_str = (mm.group(1) + " " + mm.group(2)) if mm else ""
        msg = _extract_message(last_error_line)
        if msg is None:
            msg = last_error_line.strip()
        if len(msg) > 140:
            msg = msg[:140] + "…"
        out["last_error"] = {"time": time_str, "msg": msg}

    return out


# =============================================================================
# RPC PROBES  (mirror check-node.sh: eth_chainId / eth_blockNumber /
#              tn_latestConsensusHeader)
# =============================================================================

def local_rpc(port, method, params=None, timeout=6):
    """
    JSON-RPC POST to http://127.0.0.1:<port>. Returns the parsed `result`
    (or the whole response dict if no `result`), None on any failure. Uses only
    the stdlib so the install footprint stays at just Flask.
    """
    payload = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
        if isinstance(data, dict) and "error" in data:
            return None
        if isinstance(data, dict) and "result" in data:
            return data["result"]
        return data
    except Exception:
        return None


def local_rpc_full(port, method, params=None, timeout=6):
    """Like local_rpc but returns the WHOLE parsed response dict (so callers can
    read error.code -- notably -32601 "method not found" to flag a feature the
    node's version doesn't support). None only on transport failure."""
    payload = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def rpc_unsupported(resp):
    """True when an RPC response dict carries a -32601 (method not found) error."""
    return (isinstance(resp, dict) and isinstance(resp.get("error"), dict)
            and resp["error"].get("code") == -32601)


def hex_to_dec(h):
    """'0x1234' -> int. None on garbage."""
    if not isinstance(h, str):
        return None
    h = h.strip()
    if h.startswith("0x"):
        h = h[2:]
    if not h or not re.fullmatch(r"[0-9a-fA-F]+", h):
        return None
    try:
        return int(h, 16)
    except ValueError:
        return None


# Bitcoin/IPFS base58 alphabet (no 0 O I l). node-info.yaml and tn_info report the
# BLS public key in THIS encoding, but tn_isValidator(blsPubkey: bytes) on the
# ConsensusRegistry wants the raw 96 bytes as 0x-hex and rejects anything whose
# length != 96. So we base58-decode -> 96 bytes -> 0x-hex before the on-chain call.
_B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
_B58_INDEX = {c: i for i, c in enumerate(_B58_ALPHABET)}


def _b58decode(s):
    """Decode a base58 string (Bitcoin alphabet) to bytes. None on any invalid
    character. Leading '1's decode to leading zero bytes, per the standard. Pure
    stdlib -- requirements.txt stays flask-only."""
    if not isinstance(s, str) or s == "":
        return None
    num = 0
    for ch in s:
        v = _B58_INDEX.get(ch)
        if v is None:
            return None
        num = num * 58 + v
    body = num.to_bytes((num.bit_length() + 7) // 8, "big") if num else b""
    pad = 0
    for ch in s:
        if ch == "1":
            pad += 1
        else:
            break
    return b"\x00" * pad + body


def bls_pubkey_to_hex(b58):
    """A base58-encoded BLS public key -> '0x'+hex of the raw 96 bytes, or None if
    it does not decode to exactly 96 bytes (the length the ConsensusRegistry
    enforces). Tolerant of an already-0x-hex 96-byte input (passes it through)."""
    if not b58 or not isinstance(b58, str):
        return None
    s = b58.strip()
    if s[:2].lower() == "0x":
        h = s[2:]
        return "0x" + h.lower() if re.fullmatch(r"[0-9a-fA-F]{192}", h) else None
    raw = _b58decode(s)
    if raw is None or len(raw) != 96:
        if raw is not None:
            _dbg(f"bls_pubkey_to_hex: decoded {len(raw)} bytes, expected 96")
        return None
    return "0x" + raw.hex()


def fmt_age(seconds):
    """Seconds elapsed -> human 'X ago' string, matching check-node.sh fmt_age."""
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return None
    if s < 0:
        return "in the future"
    if s < 60:
        return f"{s}s ago"
    if s < 3600:
        return f"{s // 60}m ago"
    return f"{s // 3600}h ago"


def consensus_info(port):
    """
    Query tn_latestConsensusHeader and extract block / epoch / age + the
    network's latest execution block (for the sync comparison). Returns
    (consensus_dict, cons_exec_block, unsupported) where cons_exec_block may be
    None and `unsupported` is True only when the node returned -32601 (the method
    is absent on this node's version).
    """
    out = {"block": None, "epoch": None, "age": None}
    resp = local_rpc_full(port, "tn_latestConsensusHeader")
    result = resp.get("result") if isinstance(resp, dict) else None
    if not isinstance(result, dict):
        return out, None, rpc_unsupported(resp)
    sub = result.get("sub_dag") or {}
    headers = sub.get("headers") or []
    out["block"] = str(result.get("number")) if result.get("number") is not None else None
    if headers:
        epoch = headers[0].get("epoch")
        if epoch is not None:
            out["epoch"] = str(epoch)
    ts = sub.get("commit_timestamp")
    if ts:
        out["age"] = fmt_age(int(time.time()) - int(ts))
    # Highest execution block referenced by any header in the commit.
    exec_blocks = [
        (h.get("latest_execution_block") or {}).get("number", 0) for h in headers
    ]
    cons_exec = max(exec_blocks) if exec_blocks else None
    return out, cons_exec, False


# =============================================================================
# NODE IDENTITY  (tn_info, with a node-info.yaml fallback)
#
# The validator dashboard and Node Details rows want the node's identity (name,
# BLS key, execution address, advertised addresses). tn_info is the live source,
# but older node versions lack it (-32601) and external docker nodes may too --
# so we fall back to node-info.yaml, parsed with stdlib regex (no PyYAML; the
# install footprint stays at just Flask).
# =============================================================================

def node_id_from_text(text):
    """libp2p peer id (12D3KooW...) from node-info.yaml text. '' when absent."""
    if not text:
        return ""
    m = re.search(r"/p2p/(12D3KooW[1-9A-HJ-NP-Za-km-z]+)", text)
    if m:
        return m.group(1)
    m = re.search(r"\b(12D3KooW[1-9A-HJ-NP-Za-km-z]+)\b", text)
    return m.group(1) if m else ""


def parse_node_info_yaml(text):
    """Regex-parse node-info.yaml into the identity fields /api/validator
    consumes. Top-level name / bls_public_key / execution_address; the two
    nested network_address values are primary then worker (document order,
    mirroring external_addrs)."""
    out = {"name": None, "bls_public_key": None, "execution_address": None,
           "primary_external_address": None, "worker_external_address": None}
    if not text:
        return out

    def top(key):
        # Allow leading indentation: node-info.yaml may nest these keys (mirrors
        # check-node.sh's `^[[:space:]]*<key>:` grep).
        m = re.search(r"(?m)^[ \t]*%s\s*:\s*[\"']?([^\"'\n]+?)[\"']?\s*$"
                      % re.escape(key), text)
        return m.group(1).strip() if m else None

    out["name"] = top("name")
    out["bls_public_key"] = top("bls_public_key")
    out["execution_address"] = top("execution_address")
    addrs = re.findall(r"(?m)network_address\s*:\s*[\"']?(\S+?)[\"']?\s*$", text)
    if len(addrs) >= 1:
        out["primary_external_address"] = addrs[0]
    if len(addrs) >= 2:
        out["worker_external_address"] = addrs[1]
    return out


def read_node_info_text(t, det=None):
    """Raw node-info.yaml text for a node. External -> via the root helper (the
    file lives in the container's host bind mount); scripts -> data_dir/node-
    info.yaml. '' when unavailable."""
    det = det or detect_type(t)
    if det.get("mode") == "external":
        name = det.get("container")
        if not name:
            return ""
        rc, out, _ = run(["sudo", "-n", HELPER, "docker-node-info", name], timeout=10)
        return out if rc == 0 else ""
    info = os.path.join(data_dir(t), "node-info.yaml")
    try:
        with open(info, "r") as f:
            return f.read()
    except (OSError, IOError):
        return ""


def network_config_path(t, det=None):
    """Path to the node's network-config (YAML) in its data dir. For external
    nodes that's the container's host bind path; for scripts nodes the data dir."""
    det = det or detect_type(t)
    if det.get("mode") == "external":
        base = det.get("node_info_path")
    else:
        base = data_dir(t)
    return os.path.join(base, "network-config") if base else ""


def advertised_node_name(t, det=None):
    """The node's advertised name -- the `hostname` field in network-config (what
    the UI calls 'Advertised Node Name'). '' when unset or unreadable."""
    path = network_config_path(t, det)
    if not path:
        return ""
    try:
        with open(path, "r") as f:
            text = f.read()
    except (OSError, IOError):
        return ""
    m = re.search(r'(?m)^hostname:\s*["\']?(.*?)["\']?\s*$', text)
    return m.group(1).strip() if m else ""


LOGROTATE_CONF = "/etc/logrotate.d/telcoin"


def logrotate_size():
    """Current node-log rotation trigger size from the telcoin logrotate config
    (e.g. '1G'). '' when not configured/readable."""
    try:
        with open(LOGROTATE_CONF, "r") as f:
            text = f.read()
    except (OSError, IOError):
        return ""
    m = re.search(r"(?m)^\s*size\s+(\S+)", text)
    return m.group(1) if m else ""


def node_identity(t, det=None):
    """Identity dict (bls key, execution address, advertised addresses, name,
    version, authority id) for a node, plus `unsupported`. Tries tn_info; on
    -32601 or any failure falls back to node-info.yaml. `unsupported` is True
    only when tn_info itself returned -32601 (so the UI can say 'unavailable on
    this version')."""
    det = det or detect_type(t)
    port = det.get("rpc_port") or 8545
    out = {"bls_public_key": None, "execution_address": None,
           "primary_external_address": None, "worker_external_address": None,
           "name": None, "version": None, "authority_id": None,
           "unsupported": False}

    resp = local_rpc_full(port, "tn_info")
    info = resp.get("result") if isinstance(resp, dict) else None
    if isinstance(info, dict):
        out.update({
            "bls_public_key": info.get("bls_public_key"),
            "execution_address": info.get("execution_address"),
            "primary_external_address": info.get("primary_external_address"),
            "worker_external_address": info.get("worker_external_address"),
            "name": info.get("name"),
            "version": info.get("version"),
            "authority_id": info.get("authority_id"),
        })
    elif rpc_unsupported(resp):
        out["unsupported"] = True

    # Backfill any field tn_info did not provide from node-info.yaml. Critically
    # this covers execution_address: tn_info on external/older nodes often omits
    # it, and without it the on-chain getValidator/getRewards/balanceOf calls
    # can't run (the Validator Status card would read "unavailable"). We do NOT
    # return early on a successful-but-partial tn_info anymore.
    needed = ("name", "bls_public_key", "execution_address",
              "primary_external_address", "worker_external_address")
    if any(not out.get(k) for k in needed):
        parsed = parse_node_info_yaml(read_node_info_text(t, det))
        for k in needed:
            if not out.get(k):
                out[k] = parsed.get(k)
    return out


# tn_isValidator(blsPubkey) result cache: t -> (expires_monotonic, bool|None).
# detect_nodes() calls this once per detect cycle for an observer-typed node; the
# 30s TTL keeps the extra RPC cheap and stops a flapping tip from toggling the tab.
_isval_cache = {}
_ISVAL_TTL = 30.0


def onchain_is_validator(t, det=None):
    """True only when the node is fully synced AND the ConsensusRegistry reports
    its BLS key as a validator (tn_isValidator). False when synced-but-not-a-
    validator. None when we cannot tell -- RPC down, not synced, no usable 96-byte
    key, or the node's version lacks tn_isValidator. Gating on synced honors
    'after the node is synced' and avoids a stale tip momentarily mis-typing the
    node. Cached ~30s (its own TTL, independent of detect_nodes' cache)."""
    now = time.monotonic()
    cached = _isval_cache.get(t)
    if cached and cached[0] > now:
        return cached[1]

    result = None
    try:
        det = det or detect_type(t)
        port = det.get("rpc_port") or 8545
        # Synced? Reuse the status-page computation: local exec block within 2 of
        # the network's consensus-referenced exec tip.
        block_number = hex_to_dec(local_rpc(port, "eth_blockNumber"))
        _consensus, cons_exec, _unsup = consensus_info(port)
        synced = (block_number is not None and cons_exec is not None
                  and block_number >= cons_exec - 2)
        if synced:
            hexkey = bls_pubkey_to_hex((node_identity(t, det) or {}).get("bls_public_key"))
            if hexkey:
                rpc = local_rpc(port, "tn_isValidator", [hexkey])
                if rpc is True:
                    result = True
                elif rpc is False:
                    result = False
            else:
                _dbg(f"onchain_is_validator: no usable BLS key for {t}")
    except Exception as e:  # pragma: no cover - defensive
        _log(f"onchain_is_validator({t}) error: {e}")
        result = None

    _isval_cache[t] = (now + _ISVAL_TTL, result)
    return result


# =============================================================================
# CONSENSUS REGISTRY  (validator-only on-chain reads via eth_call)
#
# The validator dashboard surfaces on-chain state (registration, committee,
# stake, rewards, ConsensusNFT) that the JSON-RPC node API does not carry. The
# browser reaches the UI over an SSH tunnel and cannot hit the node RPC, so each
# eth_call is made here server-side and returned decoded. Every call is wrapped
# independently: a single failure yields null for that one field, never a whole-
# page error. Mirrors check_validator_onchain_status() in lib/common.sh.
# =============================================================================

# ConsensusRegistry precompile (lib/common.sh:855).
CONSENSUS_REGISTRY = "0x07e17e17e17e17e17e17e17e17e17e17e17e17e1"

# Function selectors (keccak256(signature)[:4]).
REGISTRY_SELECTORS = {
    "getCurrentEpoch": "0xb97dd9e2",
    "getNextCommitteeSize": "0xeb8535c2",
    "getValidator": "0x1904bb2e",
    "getRewards": "0x79ee54f7",
    "getBalanceBreakdown": "0x15b5709a",
    "getCurrentStakeConfig": "0x7d06fdf8",
    "balanceOf": "0x70a08231",
}


def eth_call_registry(port, selector, address=None):
    """eth_call the ConsensusRegistry with `selector` (+ optional left-padded
    address arg). Returns the result hex string, or None on any failure. The
    address is right-aligned in a 32-byte word, left-padded with zeros (the
    same ABI encoding lib/common.sh builds by hand).

    The address is sanitised first: surrounding whitespace stripped, an optional
    0x/0X prefix removed, then validated as exactly 40 hex chars and lowercased.
    Without this a stray character (e.g. a trailing space invisible in the UI, or
    a checksummed 0X) corrupts the 32-byte word and the call silently fails."""
    data = selector
    if address:
        addr = str(address).strip()
        if addr[:2].lower() == "0x":
            addr = addr[2:].strip()
        if not re.fullmatch(r"[0-9a-fA-F]{40}", addr):
            _log(f"eth_call_registry: invalid address {address!r} for {selector} "
                 f"-> skipping call")
            return None
        data = selector + addr.lower().rjust(64, "0")

    resp = local_rpc_full(port, "eth_call",
                          [{"to": CONSENSUS_REGISTRY, "data": data}, "latest"])
    _dbg(f"eth_call_registry port={port} sel={selector} data={data} resp={resp}")
    if isinstance(resp, dict) and isinstance(resp.get("error"), dict):
        _log(f"eth_call_registry {selector} port={port} returned error "
             f"{resp['error']} (data={data})")
        return None
    res = resp.get("result") if isinstance(resp, dict) else None
    return res if isinstance(res, str) else None


def _words(hexstr):
    """Split an ABI-encoded hex result into a list of int words (one per 32-byte
    slice). [] for None/garbage; a trailing partial word is ignored."""
    if not isinstance(hexstr, str):
        return []
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    words = []
    for i in range(0, len(h), 64):
        chunk = h[i:i + 64]
        if len(chunk) < 64:
            break
        try:
            words.append(int(chunk, 16))
        except ValueError:
            break
    return words


def wei_to_tel(wei):
    """Wei (int) -> float TEL (wei / 1e18). None on garbage."""
    try:
        return int(wei) / 10**18
    except (TypeError, ValueError):
        return None


# =============================================================================
# LOG-DERIVED METRICS  (peers -- no consensus-header RPC equivalent)
# =============================================================================

def peer_counts(t, log_path):
    """
    Parse peers.primary / peers.worker from the most recent
    "peer metrics heartbeat" log lines (connected_count=N), per the brief.
    There is no consensus-header RPC equivalent for peers.

    Reality of the node's output: the primary and worker networks each emit an
    UNLABELLED heartbeat (both `target=tn::network`, no primary/worker tag) as a
    pair every ~30s, and the order within the pair is not stable. We therefore
    take the connected_count from the two most recent heartbeats and assign the
    larger to `primary` and the smaller to `worker` -- both figures are real and
    current; the labelling is nominal but stable across refreshes (no flicker).
    Returns '0'/'0' if no heartbeats are present.
    """
    peers = {"primary": "0", "worker": "0"}
    if not log_path or not os.path.exists(log_path):
        return peers
    try:
        # Only scan the tail of the file; heartbeats are frequent.
        with open(log_path, "rb") as f:
            try:
                f.seek(-200000, os.SEEK_END)
            except OSError:
                f.seek(0)
            tail = f.read().decode("utf-8", "replace")
    except (OSError, IOError):
        return peers

    counts = []
    for line in tail.splitlines():
        if "peer metrics heartbeat" not in line:
            continue
        m = re.search(r"connected_count=(\d+)", line)
        if m:
            counts.append(int(m.group(1)))

    if not counts:
        return peers
    recent = counts[-2:]  # most recent pair (one per network)
    hi, lo = max(recent), min(recent)
    peers["primary"] = str(hi)
    peers["worker"] = str(lo) if len(recent) > 1 else "0"
    return peers


def peer_counts_rpc(port):
    """Peer counts for nodes whose log file isn't accessible (external docker
    nodes). net_peerCount returns a single TOTAL (not split by primary/worker),
    so we surface it as the primary count with worker unknown. `split` is False
    so the UI can show the total in Primary Peers and "—" for Worker Peers.
    Returns the same shape as peer_counts() with primary=None on RPC failure."""
    total = hex_to_dec(local_rpc(port, "net_peerCount"))
    return {
        "primary": str(total) if total is not None else None,
        "worker": None,
        "total": total,
        "split": False,
    }


# =============================================================================
# SYSTEM PROBES
# =============================================================================

def service_status(t):
    """active / inactive / not installed."""
    if not os.path.exists(service_file(t)):
        return "not installed"
    rc, out, _ = run(["systemctl", "is-active", service_name(t)])
    return "active" if out == "active" else "inactive"


def service_uptime(t):
    """ActiveEnterTimestamp string, or '' if not running / unknown."""
    rc, out, _ = run(
        ["systemctl", "show", service_name(t), "--property=ActiveEnterTimestamp"]
    )
    if out and "=" in out:
        return out.split("=", 1)[1].strip()
    return ""


def service_uptime_seconds(t):
    """Seconds the unit has been active. Derived from the monotonic enter
    timestamp vs /proc/uptime, so it sidesteps wall-clock timezone parsing.
    None when not running / unknown."""
    rc, out, _ = run(
        ["systemctl", "show", service_name(t),
         "--property=ActiveEnterTimestampMonotonic"]
    )
    if not out or "=" not in out:
        return None
    try:
        mono_us = int(out.split("=", 1)[1].strip())
    except ValueError:
        return None
    if mono_us <= 0:
        return None
    try:
        with open("/proc/uptime") as f:
            boot_secs = float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    secs = int(boot_secs - mono_us / 1_000_000)
    return secs if secs >= 0 else 0


def fmt_uptime(secs):
    """Seconds -> 'Xd Yh Zm' (drops leading zero units; always shows minutes)."""
    if secs is None:
        return ""
    d, r = divmod(int(secs), 86400)
    h, r = divmod(r, 3600)
    m, _ = divmod(r, 60)
    parts = []
    if d:
        parts.append(f"{d}d")
    if h:
        parts.append(f"{h}h")
    if m or not parts:
        parts.append(f"{m}m")
    return " ".join(parts)


def service_restart_count(t):
    """Service starts since the current install (not since boot). Counts journal
    'Started telcoin-<t>.service' lines since the build/install timestamp. The
    unit journal is root-only, so this goes through the helper. None when the
    helper/sudo is unavailable (UI then shows '—')."""
    rc, out, _ = run(["sudo", "-n", HELPER, "restart-count", t], timeout=25)
    if rc == 0 and out.strip().isdigit():
        return int(out.strip())
    return None


def _node_pid(t):
    """PID of the running node process. Prefer the actual telcoin-network
    process (so docker installs measure the container's process, not the
    `docker run` client), falling back to the unit's MainPID. None if down."""
    rc, o, _ = run(["pgrep", "-x", "telcoin-network"])
    if rc == 0 and o:
        try:
            return int(o.splitlines()[0].strip())
        except (ValueError, IndexError):
            pass
    rc, out, _ = run(
        ["systemctl", "show", service_name(t), "--property=MainPID"]
    )
    if out and "=" in out:
        try:
            pid = int(out.split("=", 1)[1].strip())
            if pid > 0:
                return pid
        except ValueError:
            pass
    return None


def _proc_cpu_ticks(pid):
    """utime+stime (clock ticks) for a pid from /proc/<pid>/stat. The comm field
    can contain spaces/parens, so slice after the last ')'. None on failure."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            data = f.read()
    except (OSError, IOError):
        return None
    rp = data.rfind(")")
    if rp < 0:
        return None
    fields = data[rp + 2:].split()
    try:
        # After ')', field[0]=state (stat field 3); utime=field 14 -> index 11,
        # stime=field 15 -> index 12.
        return int(fields[11]) + int(fields[12])
    except (IndexError, ValueError):
        return None


def service_cpu_percent(t):
    """Instantaneous CPU% of the node process as a share of total capacity
    (100 == all cores saturated). Samples /proc/<pid>/stat twice. None if down."""
    pid = _node_pid(t)
    if pid is None:
        return None
    t0 = _proc_cpu_ticks(pid)
    if t0 is None:
        return None
    interval = 0.2
    time.sleep(interval)
    t1 = _proc_cpu_ticks(pid)
    if t1 is None:
        return None
    try:
        clk = os.sysconf("SC_CLK_TCK")
    except (ValueError, OSError):
        clk = 100
    ncpu = os.cpu_count() or 1
    pct = (t1 - t0) / clk / interval / ncpu * 100
    if pct < 0:
        pct = 0.0
    return round(pct, 1)


def disk_for(path):
    """df against the mount holding `path`. {used,total,percent}."""
    info = {"used": None, "total": None, "percent": None}
    rc, out, _ = run(["df", "-h", "--output=used,size,pcent", path])
    if rc != 0 or not out:
        # Fall back to root if the node path does not exist yet.
        rc, out, _ = run(["df", "-h", "--output=used,size,pcent", "/"])
        if rc != 0 or not out:
            return info
    lines = out.splitlines()
    if len(lines) >= 2:
        parts = lines[-1].split()
        if len(parts) >= 3:
            info["used"] = parts[0]
            info["total"] = parts[1]
            info["percent"] = parts[2].rstrip("%")
    return info


def mem_info():
    """MemTotal/MemAvailable from /proc/meminfo -> {used_gb,total_gb,percent}."""
    info = {"used_gb": None, "total_gb": None, "percent": None}
    try:
        vals = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                vals[k.strip()] = v.strip()
        total_kb = int(vals["MemTotal"].split()[0])
        avail_kb = int(vals.get("MemAvailable", "0").split()[0])
        used_kb = total_kb - avail_kb
        info["total_gb"] = round(total_kb / 1024 / 1024, 1)
        info["used_gb"] = round(used_kb / 1024 / 1024, 1)
        info["percent"] = int(round(used_kb / total_kb * 100)) if total_kb else 0
    except (OSError, KeyError, ValueError, IndexError):
        pass
    return info


def primary_iface():
    """Primary network interface from the default route (`ip route` -> dev <if>),
    e.g. 'eno1'. '' when there's no default route."""
    rc, out, _ = run(["ip", "route"])
    if rc != 0 or not out:
        return ""
    for line in out.splitlines():
        if line.startswith("default"):
            m = re.search(r"\bdev\s+(\S+)", line)
            if m:
                return m.group(1)
    return ""


def _iface_bytes(iface):
    """(rx_bytes, tx_bytes) for iface from /proc/net/dev. None on failure.
    Columns after 'iface:': rx bytes=0 .. multicast=7, tx bytes=8."""
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                name, sep, rest = line.partition(":")
                if not sep or name.strip() != iface:
                    continue
                fields = rest.split()
                return int(fields[0]), int(fields[8])
    except (OSError, ValueError, IndexError):
        return None
    return None


def network_traffic():
    """Per-interface traffic for the primary NIC, using only /proc + ip. Samples
    /proc/net/dev twice 1s apart for current rates, plus cumulative since-boot
    totals. Built-in tools only -- no external deps. Human-formatted strings."""
    iface = primary_iface()
    out = {"iface": iface, "rx_rate": None, "tx_rate": None,
           "rx_total": None, "tx_total": None}
    if not iface:
        return out
    s0 = _iface_bytes(iface)
    if s0 is None:
        return out
    time.sleep(1.0)
    s1 = _iface_bytes(iface)
    if s1 is None:
        return out
    rx_rate = max(0, s1[0] - s0[0])  # bytes over ~1s == bytes/s
    tx_rate = max(0, s1[1] - s0[1])
    out["rx_rate"] = (fmt_bytes(rx_rate) or "0 B") + "/s"
    out["tx_rate"] = (fmt_bytes(tx_rate) or "0 B") + "/s"
    # Raw bytes/s too, so the UI can plot a correctly-scaled sparkline instead of
    # re-parsing the human strings (which mix KB/MB units onto one axis).
    out["rx_rate_bytes"] = rx_rate
    out["tx_rate_bytes"] = tx_rate
    out["rx_total"] = fmt_bytes(s1[0]) or "—"
    out["tx_total"] = fmt_bytes(s1[1]) or "—"
    return out


# Public Artifact Registry tag list for the testnet docker image (same source
# update-node.sh uses), plus the image base / fallback the CLI setup defaults to.
GAR_TAGS_URL = "https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/tags/list"
GAR_IMAGE_BASE = "us-docker.pkg.dev/telcoin-network/tn-public/adiri"
DEFAULT_DOCKER_IMAGE = GAR_IMAGE_BASE + ":v0.11.0-adiri"  # fallback only when the registry is unreachable


def detect_public_ip():
    """Best-effort public IP via api.ipify.org (mirrors the setup scripts).
    '' on failure."""
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=6) as r:
            ip = r.read().decode().strip()
    except Exception:
        return ""
    return ip if re.match(r"^[0-9a-fA-F.:]+$", ip) else ""


def detect_internal_ip():
    """Primary internal/NIC IP -- mirrors common.sh detect_internal_ip
    (hostname -I first field, else the default-route src). '' on failure."""
    rc, out, _ = run(["hostname", "-I"])
    if rc == 0 and out.split():
        return out.split()[0]
    rc, out, _ = run(["ip", "route", "get", "1.1.1.1"])
    if rc == 0 and out:
        m = re.search(r"\bsrc\s+(\S+)", out)
        if m:
            return m.group(1)
    return ""


def internal_ip():
    """Primary internal IP for the Node Details panel, via the root helper
    (`hostname -I | awk '{print $1}'`). Falls back to the in-process probe if the
    helper/sudo is unavailable. '' when neither resolves one."""
    rc, out, _ = run(["sudo", "-n", HELPER, "internal-ip"], timeout=10)
    ip = out.strip() if rc == 0 else ""
    return ip or detect_internal_ip()


def latest_docker_image():
    """Latest published testnet (-adiri) docker image ref from the public
    Artifact Registry, e.g. us-docker.pkg.dev/.../adiri:v0.9.3-adiri. Falls back
    to DEFAULT_DOCKER_IMAGE when the registry is unreachable."""
    try:
        req = urllib.request.Request(GAR_TAGS_URL, headers={"User-Agent": "telcoin-ui"})
        with urllib.request.urlopen(req, timeout=6) as r:
            data = json.loads(r.read().decode())
    except Exception:
        return DEFAULT_DOCKER_IMAGE
    parsed = []
    tags = (data.get("tags") or []) if isinstance(data, dict) else []
    for t in tags:
        m = re.match(r"^v(\d+)\.(\d+)\.(\d+)(?:-(.+))?$", t)
        if m and "adiri" in (m.group(4) or ""):
            parsed.append(((int(m.group(1)), int(m.group(2)), int(m.group(3))), t))
    if parsed:
        parsed.sort()
        return GAR_IMAGE_BASE + ":" + parsed[-1][1]
    return DEFAULT_DOCKER_IMAGE


# Source-build refs are GIT tags (what `cargo build` checks out), which are a
# DIFFERENT, more up-to-date set than the docker registry tags -- e.g. GitHub may
# carry v0.10.0-adiri while the registry still lags on v0.9.x. So the wizard's
# source "latest release" must come from git, not the registry.
TN_SOURCE_REPO = "https://github.com/Telcoin-Association/telcoin-network.git"
_source_tag_cache = {"ts": 0.0, "data": None}


def latest_source_tag():
    """Latest clean `vX.Y.Z-adiri` source-build git tag from GitHub (via
    `git ls-remote --tags`, no clone needed) -- the source-of-truth for source
    builds, matching the CLI menu. Highest semver wins; patch-suffixed tags
    (…-adiri-foo) are ignored. Cached 5 min. '' on failure."""
    now = time.time()
    c = _source_tag_cache
    if c["data"] is not None and now - c["ts"] < 300:
        return c["data"]
    rc, out, _ = run(["git", "ls-remote", "--tags", TN_SOURCE_REPO], timeout=20)
    best_key, best_tag = None, ""
    if rc == 0 and out:
        for line in out.splitlines():
            m = re.search(r"refs/tags/(v(\d+)\.(\d+)\.(\d+)-adiri)$", line)
            if not m:
                continue
            key = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
            if best_key is None or key > best_key:
                best_key, best_tag = key, m.group(1)
    if best_tag:
        c["ts"], c["data"] = now, best_tag
    return best_tag


def system_info():
    """Host facts for the System view."""
    hostname = ""
    rc, out, _ = run(["hostname"])
    if rc == 0:
        hostname = out

    uptime = ""
    rc, out, _ = run(["uptime", "-p"])
    if rc == 0 and out:
        uptime = out

    cpu_cores = ""
    rc, out, _ = run(["nproc"])
    if rc == 0 and out:
        cpu_cores = out

    distro = ""
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    distro = line.split("=", 1)[1].strip().strip('"')
                    break
    except (OSError, IOError):
        pass

    kernel = ""
    rc, out, _ = run(["uname", "-r"])
    if rc == 0:
        kernel = out

    return {
        "hostname": hostname,
        "uptime": uptime,
        "cpu_cores": cpu_cores,
        "distro": distro,
        "kernel": kernel,
        "disk": disk_for("/"),
        "memory": mem_info(),
        # Host-global node-log rotation size (shown/edited under the System tab).
        "log_rotate_size": logrotate_size(),
    }


# =============================================================================
# ROUTES -- static
# =============================================================================

@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "index.html")


# =============================================================================
# ROUTES -- node detection & status
# =============================================================================

@app.route("/api/nodes")
def api_nodes():
    # ?fresh=1 forces a re-detection (bypassing the ~10s detect cache) -- used
    # right after a setup finalize so the just-installed node shows immediately
    # instead of the operator having to wait out the cache / manually refresh.
    if request.args.get("fresh"):
        _detect_cache["data"] = None
        clear_meta_cache()
    det = detect_nodes()
    out = {}
    for t in NODE_TYPES:
        d = det.get(t, {})
        mode = d.get("mode")
        out[t] = {
            "installed": mode is not None,
            "status": d.get("status") if mode is not None else "not installed",
            "mode": mode,                 # "scripts" | "external" | None
            "container": d.get("container"),
            "image": d.get("image"),
            # True when an observer-deployed node was re-attributed here because it
            # is a staked, on-chain validator (detect_nodes remap) -- drives an
            # optional "staked" badge in the selector.
            "staked": bool(d.get("staked")),
        }
    # ---- Derived single-node view (on-chain role is the authority) ----------
    # telcoin-network derives a node's role dynamically from on-chain committee
    # membership, so the UI presents ONE node whose role is the populated slot
    # after detect_nodes' bidirectional remap: "validator" when tn_isValidator is
    # true, else the plain "observer" (full-node) view. `role` is None only on a
    # fresh host with nothing installed (the UI then keeps its own default). The
    # `node` summary carries the same facts the per-type slots expose plus the
    # actual resolved systemd unit name, so the frontend can drive the active node
    # without a second call. The per-type slots above are kept unchanged for
    # backward compatibility.
    role = next((t for t in ("validator", "observer")
                 if det.get(t, {}).get("mode") is not None), None)
    out["role"] = role
    if role is not None:
        node = dict(out[role])
        node["role"] = role
        node["type"] = role                    # presentation slot (equals role here)
        node["service"] = service_name(role)   # resolved unit (telcoin / telcoin-<t>)
        out["node"] = node
    else:
        out["node"] = None
    # Read-only when reached over the public Caddy path (vs the SSH tunnel). The
    # UI uses this to hide every management control and show a read-only banner.
    out["public_readonly"] = is_public_request()
    # Never cache node detection -- after a remove/install the UI must see the
    # change immediately (the empty-state switch keys off this).
    resp = jsonify(out)
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/status/<node_type>")
def api_status(node_type):
    if not valid_type(node_type):
        return bad_type()
    t = node_type
    det = detect_type(t)
    mode = det.get("mode")

    if mode is None:
        r = jsonify({"installed": False, "node_type": t, "status": "not installed"})
        r.headers["Cache-Control"] = "no-store"
        return r

    external = mode == "external"
    if external:
        port = det.get("rpc_port") or 8545
        log_path = None  # external logs come from `docker logs`, not a file
        data_path = det.get("node_info_path")
    else:
        cfg = parse_service_file(t)
        port = int(cfg["rpc_port"])
        log_path = cfg["log_path"]
        data_path = data_dir(t)

    # Local execution liveness + block. eth_chainId doubles as the liveness
    # probe and the source of the network's chain id (previously discarded).
    chain_id_raw = local_rpc(port, "eth_chainId")
    rpc_ok = chain_id_raw is not None
    chain_id = hex_to_dec(chain_id_raw) if chain_id_raw else None
    block_number = None
    blk_age = None
    if rpc_ok:
        block_number = hex_to_dec(local_rpc(port, "eth_blockNumber"))
        blk_age = block_age(port)

    # Consensus header (block / epoch / age) + the network's exec tip for sync.
    consensus, cons_exec, cons_unsupported = consensus_info(port)

    # Synced when the local exec block has reached the network's exec tip
    # (small tolerance for the gap between commit and local execution).
    synced = False
    if block_number is not None and cons_exec is not None:
        synced = block_number >= cons_exec - 2

    # On-chain validator role for display (cached ~30s). Computed only for the
    # validator tab -- the detect_nodes() remap already decides which tab shows, so
    # there is no need to probe an observer here. None when undeterminable.
    is_validator_onchain = onchain_is_validator(t, det) if t == "validator" else None

    # Dynamic network identity from the live chain id.
    slug, net_name, net_configured = resolve_network(chain_id, t)

    # Network consensus block + epoch (public RPC tn_latestConsensusHeader) + lag.
    # Lag is local - network: positive => local ahead, negative => local behind.
    net_block = network_consensus_block(chain_id)
    net_epoch = network_consensus_epoch(chain_id)
    local_cons_block = None
    if consensus.get("block") is not None:
        try:
            local_cons_block = int(consensus["block"])
        except (TypeError, ValueError):
            local_cons_block = None
    consensus_lag = None
    if net_block is not None and local_cons_block is not None:
        consensus_lag = local_cons_block - net_block

    # Uptime / restart count / status: from the docker inspect for external
    # nodes (StartedAt, RestartCount, State.Running), from systemd otherwise.
    if external:
        insp = det.get("inspect") or {}
        st = insp.get("State") or {}
        started = st.get("StartedAt") or ""
        up_secs = _iso_uptime_seconds(started)
        restart_count = insp.get("RestartCount")
        status = "active" if st.get("Running") is True else "inactive"
        uptime_str = started
        node_id_val = node_id_from_text(read_node_info_text(t, det))
        install_method = "external (docker)"
        passphrase_method = ""
        docker_image = det.get("image") or ""
        config_file = ""
        tracing_on = False
        # CPU from `docker stats` (cached this refresh cycle); host pgrep won't
        # resolve a containerised process. Log size from the container LogPath.
        stats = _docker_stats(det.get("container"))
        cpu_percent = stats.get("cpu_percent") if stats else None
        log_size_override = _docker_log_size(det.get("container"))
    else:
        status = service_status(t)
        up_secs = service_uptime_seconds(t)
        restart_count = service_restart_count(t)
        uptime_str = service_uptime(t)
        node_id_val = node_id(t)
        install_method = detect_install_method(t)
        passphrase_method = detect_passphrase_method(t)
        docker_image = docker_image_ref(t)
        config_file = service_file(t)
        tracing_on = tracing_enabled(t)
        cpu_percent = service_cpu_percent(t)
        log_size_override = None

    logs = log_stats(log_path)
    if log_size_override is not None:
        logs["log_size"] = log_size_override
        logs["log_size_human"] = fmt_bytes(log_size_override)

    # Peers: scripts nodes parse the log heartbeats (split primary/worker);
    # external nodes have no log file, so use net_peerCount (a single total).
    peers = peer_counts_rpc(port) if external else peer_counts(t, log_path)

    resp = jsonify({
        "installed": True,
        "node_type": t,
        # Actual resolved systemd unit base name (telcoin for a unified install,
        # telcoin-<type> for a legacy one) -- the UI shows this verbatim instead
        # of assuming telcoin-<type>.
        "service": service_name(t),
        "mode": mode,
        "container": det.get("container"),
        "image": det.get("image"),
        "readonly": external,
        "status": status,
        "uptime": uptime_str,
        "uptime_seconds": up_secs,
        "uptime_human": fmt_uptime(up_secs),
        "restart_count": restart_count,
        "last_restart": uptime_str,
        "cpu_percent": cpu_percent,
        "rpc_ok": rpc_ok,
        "rpc_port": port,
        "node_id": node_id_val,
        "advertised_name": advertised_node_name(t, det),
        "internal_ip": internal_ip(),
        # Connectivity/identity for the dashboard: declared region + the
        # advertised public endpoint (PUBLIC_IP from .node-meta, full multiaddr
        # from external_addrs so the UI can show ip:port). Empty -> tile shows "—".
        "region": read_meta(t).get("REGION", ""),
        "public_ip": read_meta(t).get("PUBLIC_IP", ""),
        "external_primary": external_addrs(t)[0],
        "data_dir": data_path,
        "config_file": config_file,
        "block_number": block_number,
        "synced": synced,
        "is_validator_onchain": is_validator_onchain,
        "chain_id": chain_id,
        "network": net_name,
        "network_slug": slug,
        "network_configured": net_configured,
        "consensus_unsupported": cons_unsupported,
        "block_age": blk_age,
        "log_error_count_1h": logs["error_count"],
        "log_warn_count_1h": logs["warn_count"],
        "last_error": logs["last_error"],
        "recent_log_events": logs["recent_events"],
        "log_size": logs["log_size"],
        "log_size_human": logs["log_size_human"],
        "tracing_enabled": tracing_on,
        "peers": peers,
        "consensus": consensus,
        "network_consensus_block": net_block,
        "network_epoch": net_epoch,
        "consensus_lag": consensus_lag,
        "disk": disk_for(data_path or "/"),
        "memory": mem_info(),
        "install_method": install_method,
        "passphrase_method": passphrase_method,
        "docker_image": docker_image,
    })
    # Never cache status -- every dashboard refresh must re-read live values
    # (log size, blocks, CPU, ...), not a value frozen at page load.
    resp.headers["Cache-Control"] = "no-store"
    return resp


# =============================================================================
# ROUTES -- validator-only on-chain dashboard
#
# Shared metrics (CPU, mem, disk, logs, peers, traffic, jaeger, version) keep
# coming from /api/status. This endpoint adds only the validator-specific
# consensus/contract data. Every field defaults to None and is filled by an
# independently-guarded probe, so any single RPC/contract failure degrades just
# that card to "—" -- the response is always HTTP 200 with valid JSON.
# =============================================================================

@app.route("/api/validator/<node_type>")
def api_validator(node_type):
    if not valid_type(node_type):
        return bad_type()
    t = node_type

    det = detect_type(t)
    mode = det.get("mode")

    out = {
        "installed": mode is not None,
        "node_type": t,
        "mode": mode,
        "readonly": mode == "external",
        # identity (tn_info / node-info.yaml fallback)
        "bls_public_key": None, "execution_address": None,
        "primary_external_address": None, "worker_external_address": None,
        "name": None, "version": None, "authority_id": None,
        "identity_unsupported": False,
        # consensus header (reused consensus_info)
        "block": None, "epoch": None, "age": None,
        "consensus_unsupported": False,
        # contract: epoch / committee sizing
        "current_epoch": None, "next_committee_size": None,
        # committee membership (tn_epochRecord)
        "in_committee": None, "in_next_committee": None,
        # validator record (getValidator)
        "activation_epoch": None, "exit_epoch": None, "status": None,
        "is_retired": None, "stake_version": None,
        # stake / rewards
        "rewards_tel": None, "balance_breakdown": None, "stake_config": None,
        "nft_held": None,
    }

    if not out["installed"]:
        r = jsonify(out)
        r.headers["Cache-Control"] = "no-store"
        return r

    port = det.get("rpc_port") or 8545
    if mode == "scripts":
        try:
            port = int(parse_service_file(t)["rpc_port"])
        except (TypeError, ValueError):
            port = 8545

    _dbg(f"/api/validator {t}: mode={mode} container={det.get('container')!r} "
         f"rpc_port={port}")

    # --- identity: tn_info, falling back to node-info.yaml (covers external
    #     nodes and older versions that lack tn_info -> -32601) ---
    try:
        ident = node_identity(t, det)
        for k in ("bls_public_key", "execution_address",
                  "primary_external_address", "worker_external_address",
                  "name", "version", "authority_id"):
            out[k] = ident.get(k)
        out["identity_unsupported"] = ident.get("unsupported", False)
    except Exception:
        pass

    # --- consensus header: block / epoch / age (reused) ---
    try:
        consensus, _, cons_unsupported = consensus_info(port)
        out["block"] = consensus.get("block")
        out["epoch"] = consensus.get("epoch")
        out["age"] = consensus.get("age")
        out["consensus_unsupported"] = cons_unsupported
    except Exception:
        pass

    # --- committee membership via tn_epochRecord(epoch) ---
    # Returns [EpochRecord, EpochCertificate]; the record carries committee[] and
    # next_committee[] (lists of BLS pubkeys -- same serialised form as
    # node-info.yaml / tn_info, so a direct string compare). The CURRENT epoch's
    # record is still empty while that epoch is in progress, so when its
    # committee[] is empty we fall back to the previous epoch's record
    # (current_epoch - 1), which is finalised.
    def _epoch_record(ep):
        rec = local_rpc(port, "tn_epochRecord", [int(ep)])
        if isinstance(rec, list) and rec and isinstance(rec[0], dict):
            return rec[0]
        if isinstance(rec, dict):
            return rec
        return None

    try:
        if out["epoch"] is not None and out["bls_public_key"] is not None:
            epoch = int(out["epoch"])
            record = _epoch_record(epoch)
            committee = (record or {}).get("committee") or []
            # In-progress current epoch has an empty committee -> use the prior,
            # finalised epoch's record instead.
            if not committee and epoch > 0:
                prev = _epoch_record(epoch - 1)
                if prev is not None and (prev.get("committee") or []):
                    record = prev
                    committee = record.get("committee") or []
            if record is not None:
                next_committee = record.get("next_committee") or []
                bls = out["bls_public_key"]
                out["in_committee"] = bls in committee
                out["in_next_committee"] = bls in next_committee
                _dbg(f"/api/validator {t}: committee epoch={epoch} "
                     f"used_committee={len(committee)} next={len(next_committee)} "
                     f"in_committee={out['in_committee']} "
                     f"in_next={out['in_next_committee']}")
    except Exception as e:
        _log(f"/api/validator {t}: committee membership check failed: {e}")

    # --- getCurrentEpoch() ---
    try:
        w = _words(eth_call_registry(port, REGISTRY_SELECTORS["getCurrentEpoch"]))
        if w:
            out["current_epoch"] = w[0]
    except Exception:
        pass

    # --- getNextCommitteeSize() ---
    try:
        w = _words(eth_call_registry(port, REGISTRY_SELECTORS["getNextCommitteeSize"]))
        if w:
            out["next_committee_size"] = w[0]
    except Exception:
        pass

    addr = out["execution_address"]
    _dbg(f"/api/validator {t}: execution_address={addr!r} epoch={out['epoch']!r} "
         f"bls={out['bls_public_key']!r}")

    # --- getValidator(address) -> ValidatorInfo struct (returned INLINE) ---
    # The struct carries no dynamic fields (blsPubkey is not part of it), so
    # there is NO leading offset word -- every field sits at a fixed word index:
    #   w0 validatorAddress, w1 activationEpoch, w2 exitEpoch, w3 currentStatus,
    #   w4 isRetired, w5 stakeVersion, w6 region
    # (The older layout decoded in lib/common.sh assumed a leading blsPubkey
    # offset pointer + an 8-word struct; the live contract returns 7 words.)
    try:
        if addr:
            raw = eth_call_registry(port, REGISTRY_SELECTORS["getValidator"], addr)
            _dbg(f"/api/validator {t}: getValidator raw={raw!r}")
            w = _words(raw)
            if len(w) >= 6:
                out["activation_epoch"] = w[1]
                out["exit_epoch"] = w[2]
                out["status"] = w[3]
                out["is_retired"] = bool(w[4])
                out["stake_version"] = w[5]
            elif mode == "external":
                # Visible without TN_UI_DEBUG so a still-failing external node
                # surfaces the reason in the journal.
                _log(f"/api/validator {t} (external): getValidator returned no "
                     f"usable data (addr={addr!r} port={port} raw={raw!r})")
        else:
            _log(f"/api/validator {t}: no execution_address available -> on-chain "
                 f"validator calls skipped (mode={mode})")
    except Exception as e:
        _log(f"/api/validator {t}: getValidator failed: {e}")

    # --- getRewards(address) -> claimable rewards (wei) ---
    try:
        if addr:
            w = _words(eth_call_registry(port, REGISTRY_SELECTORS["getRewards"], addr))
            if w:
                out["rewards_tel"] = wei_to_tel(w[0])
    except Exception:
        pass

    # --- getBalanceBreakdown(address) -> (total, stake, rewards) wei ---
    try:
        if addr:
            w = _words(eth_call_registry(port, REGISTRY_SELECTORS["getBalanceBreakdown"], addr))
            if len(w) >= 3:
                out["balance_breakdown"] = {
                    "total": wei_to_tel(w[0]),
                    "stake": wei_to_tel(w[1]),
                    "rewards": wei_to_tel(w[2]),
                }
    except Exception:
        pass

    # --- getCurrentStakeConfig() -> (stakeAmount, minWithdraw, epochIssuance,
    #     epochDuration). Amounts are wei -> TEL; epochDuration is seconds. ---
    try:
        w = _words(eth_call_registry(port, REGISTRY_SELECTORS["getCurrentStakeConfig"]))
        if len(w) >= 4:
            out["stake_config"] = {
                "stake_amount": wei_to_tel(w[0]),
                "min_withdraw": wei_to_tel(w[1]),
                "epoch_issuance": wei_to_tel(w[2]),
                "epoch_duration": w[3],
            }
    except Exception:
        pass

    # --- balanceOf(address) -> ConsensusNFT held when > 0 ---
    try:
        if addr:
            w = _words(eth_call_registry(port, REGISTRY_SELECTORS["balanceOf"], addr))
            if w:
                out["nft_held"] = w[0] > 0
    except Exception:
        pass

    r = jsonify(out)
    r.headers["Cache-Control"] = "no-store"
    return r


# =============================================================================
# ROUTES -- service control
# =============================================================================

@app.route("/api/service/<node_type>/<action>", methods=["POST"])
def api_service(node_type, action):
    if not valid_type(node_type):
        return bad_type()
    if action not in ("start", "stop", "restart"):
        return jsonify({"ok": False, "status": "", "error": "invalid action"}), 400
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    if not os.path.exists(service_file(node_type)):
        return jsonify({"ok": False, "status": "not installed",
                        "error": "service not installed"}), 404

    # Use the exact binary path the sudoers whitelist grants (/bin/systemctl).
    # Bare `sudo systemctl` would resolve via secure_path to /usr/bin/systemctl
    # and fail to match the rule on usrmerge systems.
    rc, out, err = run(
        ["sudo", "/bin/systemctl", action, service_name(node_type)], timeout=30
    )
    # Give systemd a moment to settle before re-reading state.
    time.sleep(1.5)
    status = service_status(node_type)
    ok = rc == 0
    return jsonify({"ok": ok, "status": status, "error": "" if ok else (err or out)})


# =============================================================================
# ROUTES -- logs
# =============================================================================

@app.route("/api/logs/<node_type>")
def api_logs(node_type):
    if not valid_type(node_type):
        return bad_type()
    try:
        lines = int(request.args.get("lines", 100))
    except ValueError:
        lines = 100
    lines = max(1, min(lines, 1000))

    det = detect_type(node_type)
    if det.get("mode") == "external":
        name = det.get("container")
        if not name:
            return jsonify({"lines": []})
        rc, out, _ = run(["sudo", "-n", HELPER, "docker-logs", name, str(lines)],
                         timeout=20)
        if rc != 0:
            return jsonify({"lines": []})
        return jsonify({"lines": out.splitlines() if out else []})

    path = parse_service_file(node_type)["log_path"]
    if not path or not os.path.exists(path):
        return jsonify({"lines": []})

    rc, out, _ = run(["tail", "-n", str(lines), path], timeout=10)
    if rc != 0:
        return jsonify({"lines": []})
    return jsonify({"lines": out.splitlines() if out else []})


@app.route("/api/logs/<node_type>/stream")
def api_logs_stream(node_type):
    if not valid_type(node_type):
        return bad_type()

    # External (docker) nodes have no tailable log file; live streaming is not
    # offered (the UI hides the Live button -- this is the matching notice).
    if is_external(node_type):
        def notice():
            yield "data: (live tail not available for external nodes)\n\n"
        return Response(notice(), mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache",
                                 "X-Accel-Buffering": "no"})

    path = parse_service_file(node_type)["log_path"]

    def generate():
        if not path or not os.path.exists(path):
            yield "data: (log file not found)\n\n"
            return
        proc = subprocess.Popen(
            ["tail", "-n", "0", "-F", path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            for line in iter(proc.stdout.readline, ""):
                yield f"data: {line.rstrip()}\n\n"
        except GeneratorExit:
            # Client disconnected -- tear down the tail subprocess.
            pass
        finally:
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                proc.kill()

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"})


@app.route("/api/logs/<node_type>/download")
def api_logs_download(node_type):
    """Download the complete log as telcoin-<type>.log. External nodes stream the
    full container log via the helper; scripts nodes send the on-disk file."""
    if not valid_type(node_type):
        return bad_type()
    det = detect_type(node_type)
    if det.get("mode") == "external":
        name = det.get("container")
        body = ""
        if name:
            rc, out, _ = run(["sudo", "-n", HELPER, "docker-logs-full", name],
                             timeout=60)
            if rc == 0:
                body = out
        return Response(
            body, mimetype="text/plain",
            headers={"Content-Disposition":
                     f'attachment; filename="telcoin-{node_type}.log"'})
    path = parse_service_file(node_type)["log_path"]
    if not path or not os.path.exists(path):
        return jsonify({"error": "log file not found"}), 404
    return send_file(path, mimetype="text/plain", as_attachment=True,
                     download_name=f"telcoin-{node_type}.log")


@app.route("/api/logs/<node_type>/clear", methods=["POST"])
def api_logs_clear(node_type):
    """Truncate (not delete) the node's log file via the root helper, so the
    running service keeps its open file handle."""
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    rc, out, err = run(["sudo", "-n", HELPER, "log-clear", node_type], timeout=15)
    ok = rc == 0 and out.strip() == "ok"
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "clear failed")})


# =============================================================================
# ROUTES -- config
# =============================================================================

def external_addrs(t):
    """(external_primary, external_worker) advertised to peers. From .node-meta
    when present (EXTERNAL_PRIMARY_ADDR/EXTERNAL_WORKER_ADDR); otherwise grep the
    advertised multiaddrs out of node-info.yaml for nodes built before meta
    carried them. ('', '') when neither source has them."""
    meta = read_meta(t)
    primary = meta.get("EXTERNAL_PRIMARY_ADDR", "").strip()
    worker = meta.get("EXTERNAL_WORKER_ADDR", "").strip()
    if primary or worker:
        return primary, worker

    info = os.path.join(data_dir(t), "node-info.yaml")
    if not os.path.exists(info):
        return primary, worker
    try:
        with open(info, "r") as f:
            text = f.read()
    except (OSError, IOError):
        return primary, worker

    # node-info.yaml lists the advertised multiaddrs; primary appears before
    # worker. Pick out non-loopback multiaddrs in document order and assign the
    # first to primary, the second to worker.
    addrs = re.findall(r'(/(?:ip4|ip6|dns\d?)/[^\s"\']+)', text)
    addrs = [a for a in addrs if "/127.0.0.1/" not in a and "/0.0.0.0/" not in a]
    if not primary and len(addrs) >= 1:
        primary = addrs[0]
    if not worker and len(addrs) >= 2:
        worker = addrs[1]
    return primary, worker


@app.route("/api/config/<node_type>")
def api_config(node_type):
    if not valid_type(node_type):
        return bad_type()
    det = detect_type(node_type)
    mode = det.get("mode")
    if mode is None:
        return jsonify({"installed": False, "node_type": node_type})

    # External (docker) nodes are read-only: values come from node-info.yaml +
    # the docker inspect, and the UI renders them without editable controls.
    if mode == "external":
        ident = node_identity(node_type, det)
        return jsonify({
            "installed": True,
            "readonly": True,
            "instance": "",
            "rpc_port": str(det.get("rpc_port") or ""),
            "metrics": "",
            "primary_listener": "",
            "worker_listener": "",
            "external_primary": ident.get("primary_external_address") or "",
            "external_worker": ident.get("worker_external_address") or "",
            "install_method": "external (docker)",
            "passphrase_method": "",
            "docker_image": det.get("image") or "",
            "version": ident.get("version") or "",
            "advertised_name": advertised_node_name(node_type, det),
        })

    cfg = parse_service_file(node_type)
    ext_primary, ext_worker = external_addrs(node_type)
    return jsonify({
        "installed": True,
        "instance": cfg["instance"],
        "rpc_port": cfg["rpc_port"],
        "metrics": cfg["metrics"],
        "primary_listener": cfg["primary_listener"],
        "worker_listener": cfg["worker_listener"],
        "verbosity": cfg["verbosity"],
        "external_primary": ext_primary,
        "external_worker": ext_worker,
        "install_method": detect_install_method(node_type),
        "passphrase_method": detect_passphrase_method(node_type),
        "docker_image": docker_image_ref(node_type),
        "version": node_version(node_type).get("ref", ""),
        "advertised_name": advertised_node_name(node_type),
        "log_rotate_size": logrotate_size(),
    })


# Editable config field allowlist + per-field value validation, mirroring
# edit-config.sh's --json mode and the helper's config-set guard. We reject bad
# input with a clean 400 before ever shelling out; the helper and the script
# re-validate (defence in depth -- the server is the unprivileged caller).
CONFIG_FIELDS = (
    "primary_listener", "worker_listener", "instance",
    "metrics", "verbosity", "docker_image",
)
_MULTIADDR_RE = re.compile(r"^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$")
_METRICS_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}:\d{1,5}$")
_VERBOSITY_RE = re.compile(r"^-v{1,5}$")
_IMAGE_CHARS_RE = re.compile(r"^[A-Za-z0-9._/:@-]+$")


def config_value_ok(field, value):
    if field in ("primary_listener", "worker_listener"):
        return bool(_MULTIADDR_RE.match(value))
    if field == "instance":
        return value in ("1", "2", "3", "4", "5", "6", "7", "8", "9")
    if field == "metrics":
        return bool(_METRICS_RE.match(value))
    if field == "verbosity":
        return bool(_VERBOSITY_RE.match(value))
    if field == "docker_image":
        return bool(_IMAGE_CHARS_RE.match(value)) and ":" in value
    return False


@app.route("/api/config/<node_type>/set")
def api_config_set(node_type):
    # GET (not POST) so the browser can stream the restart+verify progress with
    # EventSource. The field/value are query params, validated here and again in
    # the helper + edit-config.sh. Reuses the same SSE plumbing as updates.
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    field = (request.args.get("field") or "").strip()
    value = (request.args.get("value") or "").strip()
    if field not in CONFIG_FIELDS:
        return jsonify({"error": "field not editable"}), 400
    if not config_value_ok(field, value):
        return jsonify({"error": "invalid value for field"}), 400
    return _update_stream(["sudo", "-n", HELPER, "config-set", node_type, field, value])


# Advertised node name ("Advertised Node Name" in the UI) = the network-config
# hostname. Lives in a different file than the unit/wrapper edit-config.sh edits,
# so it has its own route + helper subcommand. Conservative charset.
_NODE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


@app.route("/api/config/<node_type>/hostname", methods=["POST"])
def api_set_hostname(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    data = request.get_json(silent=True) or {}
    name = str(data.get("name") or "").strip()
    if not _NODE_NAME_RE.match(name):
        return jsonify({"ok": False,
                        "error": "invalid name (letters, digits, . _ - ; start "
                                 "alphanumeric; max 64 chars)"}), 400
    # The helper writes network-config + .node-meta and restarts the node so it
    # reads the new name.
    rc, out, err = run(["sudo", "-n", HELPER, "set-hostname", node_type, name],
                       timeout=30)
    ok = rc == 0 and out.strip().splitlines()[-1:] == ["ok"]
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "set failed")})


# Node-log rotation size (one global logrotate config for both node types).
_LOGROTATE_SIZE_RE = re.compile(r"^[0-9]+[KMG]$")


@app.route("/api/config/<node_type>/logrotate", methods=["POST"])
def api_set_logrotate(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)  # external docker logs aren't on disk here
    if blocked:
        return blocked
    data = request.get_json(silent=True) or {}
    size = str(data.get("size") or "").strip().upper()
    if not _LOGROTATE_SIZE_RE.match(size):
        return jsonify({"ok": False, "error": "invalid size -- use e.g. 500M or 1G"}), 400
    rc, out, err = run(["sudo", "-n", HELPER, "set-logrotate", size], timeout=15)
    ok = rc == 0 and out.strip().splitlines()[-1:] == ["ok"]
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "set failed")})


# Delete rotated node logs (telcoin-*.log.N / .gz), never the live file. One
# host-global action like logrotate itself. Public path is refused upstream by
# _enforce_public_readonly (POST); external nodes have no on-disk logs here.
@app.route("/api/config/<node_type>/clear-rotated", methods=["POST"])
def api_clear_rotated(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    rc, out, err = run(["sudo", "-n", HELPER, "clear-rotated"], timeout=15)
    last = out.strip().splitlines()[-1:] if out else []
    ok = rc == 0 and bool(last) and last[0].startswith("removed ")
    removed = int(last[0].split()[1]) if ok and last[0].split()[1:] else 0
    return jsonify({"ok": ok, "removed": removed,
                    "error": "" if ok else (err or out or "clear failed")})


# =============================================================================
# ROUTES -- firewall (node ports only) + node removal
#
# Both go through the root-owned helper's --json subcommands. The firewall
# surface is deliberately limited to the three node ports (the helper + script
# refuse anything else); SSH/policy stay CLI-only so the UI can't lock anyone
# out. Removal is destructive and requires a server-side typed "DELETE" confirm.
# =============================================================================

# Only these may be toggled (mirrors the helper + firewall-setup.sh allowlist).
FIREWALL_PORTS = ("49590/udp", "49594/udp", "43174/tcp")


@app.route("/api/firewall")
def api_firewall():
    rc, out, err = run(["sudo", "-n", HELPER, "firewall-status"], timeout=20)
    if rc == 0 and out:
        try:
            return jsonify(json.loads(out.splitlines()[-1]))
        except (ValueError, json.JSONDecodeError):
            pass
    # Helper/sudo/ufw unavailable -- degrade gracefully (no 500).
    return jsonify({
        "installed": False, "active": False, "default_incoming": "",
        "ssh_port": "", "ports": {p: False for p in FIREWALL_PORTS},
        "caddy_managed": False, "desired": [], "unexpected": [],
        "error": err or out or "firewall status unavailable",
    })


@app.route("/api/firewall/port", methods=["POST"])
def api_firewall_port():
    data = request.get_json(silent=True) or {}
    port = str(data.get("port") or "").strip()
    proto = str(data.get("proto") or "").strip()
    state = str(data.get("state") or "").strip()
    spec = f"{port}/{proto}"
    if spec not in FIREWALL_PORTS:
        return jsonify({"ok": False, "error": "port not permitted"}), 400
    if state not in ("on", "off"):
        return jsonify({"ok": False, "error": "state must be on|off"}), 400
    # Firewall management is for scripts-managed nodes. On a host whose only node
    # is an externally-deployed (read-only) container, refuse port toggles.
    det = detect_nodes()
    if not any(det.get(t, {}).get("mode") == "scripts" for t in NODE_TYPES):
        return jsonify({"ok": False, "error": "read-only (external node)"}), 403
    rc, out, err = run(["sudo", "-n", HELPER, "firewall-port", spec, state], timeout=30)
    if rc == 0 and out:
        try:
            d = json.loads(out.splitlines()[-1])
            return jsonify({"ok": bool(d.get("ok")), "error": "" if d.get("ok") else d.get("msg", "")})
        except (ValueError, json.JSONDecodeError):
            pass
    return jsonify({"ok": False, "error": err or out or "firewall update failed"})


# Node removal is intentionally NOT exposed in the UI: it is irreversible
# (validator keys), so it runs on the server via remove-node.sh (which also
# removes the UI itself). The dashboard's System tab just points operators there.


# =============================================================================
# ROUTES -- setup (phased, full install in the UI)
#
# Two phases via the helper's setup-keygen / setup-finalize, which run
# setup-<type>.sh --json --phase=...  Config travels in TN_SETUP_* env vars and
# the BLS passphrase in TN_BLS_PASSPHRASE (env only -- never argv, never the URL,
# kept in-process here). These are POST + streamed (not EventSource) precisely so
# the passphrase never lands in a query string or access log. The frontend reads
# the streamed body with fetch().
# =============================================================================

_ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
_BUILD_REF_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
_PUBLIC_IP_RE = re.compile(r"^[0-9a-fA-F.:]+$")
_SVC_NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]{0,31}$")  # mirrors validate_service_name
_DATA_DIR_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")  # absolute path, safe charset


def _setup_env(data, want_passphrase):
    """Validate a setup config dict and build the child env (TN_SETUP_* [+
    TN_BLS_PASSPHRASE]). Returns (env, None) or (None, error_message)."""
    network = str(data.get("network") or "testnet").strip()
    method = str(data.get("install_method") or "").strip()
    passm = str(data.get("passphrase_method") or "loadcredential").strip()
    address = str(data.get("address") or "").strip()
    build_ref = str(data.get("build_ref") or "").strip()
    image = str(data.get("docker_image") or "").strip()
    instance = str(data.get("instance") or "").strip()
    ext_primary = str(data.get("external_primary") or "").strip()
    ext_worker = str(data.get("external_worker") or "").strip()
    lis_primary = str(data.get("listener_primary") or "").strip()
    lis_worker = str(data.get("listener_worker") or "").strip()
    public_ip = str(data.get("public_ip") or "").strip()
    rpc_public = "true" if data.get("rpc_public") else "false"
    service_user = str(data.get("service_user") or "").strip()
    service_group = str(data.get("service_group") or "").strip()
    advertised_name = str(data.get("advertised_name") or "").strip()
    data_dir = str(data.get("data_dir") or "").strip()

    if network not in ("testnet", "adiri"):
        return None, "invalid network"
    if method not in ("source", "docker", "existing", ""):
        return None, "invalid install method"
    if passm not in ("loadcredential", "tpm"):
        return None, "invalid passphrase method"
    if address and not _ADDRESS_RE.match(address):
        return None, "invalid address"
    if build_ref and not _BUILD_REF_RE.match(build_ref):
        return None, "invalid build ref"
    if image and not (_IMAGE_CHARS_RE.match(image) and ":" in image):
        return None, "invalid docker image"
    if instance and instance not in tuple("123456789"):
        return None, "invalid instance"
    for m in (ext_primary, ext_worker, lis_primary, lis_worker):
        if m and not _MULTIADDR_RE.match(m):
            return None, "invalid multiaddr"
    if public_ip and not _PUBLIC_IP_RE.match(public_ip):
        return None, "invalid public ip"
    if service_user and not _SVC_NAME_RE.match(service_user):
        return None, "invalid service user"
    if service_group and not _SVC_NAME_RE.match(service_group):
        return None, "invalid service group"
    if advertised_name and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", advertised_name):
        return None, "invalid advertised name"
    if data_dir and (not _DATA_DIR_RE.match(data_dir) or ".." in data_dir):
        return None, "invalid data directory (must be an absolute path)"
    if method == "source" and not build_ref:
        return None, "build_ref required for source install"

    env = os.environ.copy()
    env["TN_SETUP_NETWORK"] = network
    env["TN_SETUP_INSTALL_METHOD"] = method
    env["TN_SETUP_PASSPHRASE_METHOD"] = passm
    env["TN_SETUP_ADDRESS"] = address
    env["TN_SETUP_BUILD_REF"] = build_ref
    env["TN_SETUP_DOCKER_IMAGE"] = image
    env["TN_SETUP_INSTANCE"] = instance
    env["TN_SETUP_EXT_PRIMARY"] = ext_primary
    env["TN_SETUP_EXT_WORKER"] = ext_worker
    env["TN_SETUP_LIS_PRIMARY"] = lis_primary
    env["TN_SETUP_LIS_WORKER"] = lis_worker
    env["TN_SETUP_PUBLIC_IP"] = public_ip
    env["TN_SETUP_RPC_PUBLIC"] = rpc_public
    env["TN_SETUP_SERVICE_USER"] = service_user
    env["TN_SETUP_SERVICE_GROUP"] = service_group
    env["TN_SETUP_ADVERTISED_NAME"] = advertised_name
    env["TN_SETUP_DATA_DIR"] = data_dir

    if want_passphrase:
        passphrase = data.get("passphrase")
        if not passphrase:
            return None, "passphrase required"
        env["TN_BLS_PASSPHRASE"] = str(passphrase)

    return env, None


@app.route("/api/setup/defaults")
def api_setup_defaults():
    """Auto-detected defaults to prefill the setup wizard (matching what the CLI
    detects/uses): public IP, internal IP, latest docker image, service user/group."""
    resp = jsonify({
        "public_ip": detect_public_ip(),
        "internal_ip": detect_internal_ip(),
        "docker_image": latest_docker_image(),
        "source_ref": latest_source_tag(),
        "service_user": "telcoin",
        "service_group": "telcoin",
    })
    resp.headers["Cache-Control"] = "no-store"
    return resp


# Single-flight guard: only one setup phase (keygen/finalize) may run at a time.
# Concurrent runs (double-clicks, multiple tabs) collide on shared resources --
# notably groupadd/useradd locking /etc/group ("cannot lock ... try again later").
_setup_lock = threading.Lock()
_setup_running = {"active": False}


def _begin_setup():
    """Reserve the setup slot. Returns True if acquired, False if one is running."""
    with _setup_lock:
        if _setup_running["active"]:
            return False
        _setup_running["active"] = True
        return True


def _end_setup():
    with _setup_lock:
        _setup_running["active"] = False


@app.route("/api/setup/<node_type>/keygen", methods=["POST"])
def api_setup_keygen(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    data = request.get_json(silent=True) or {}
    env, err = _setup_env(data, want_passphrase=True)
    if err:
        return jsonify({"error": err}), 400
    if not _begin_setup():
        return jsonify({"error": "a node setup is already running -- wait for it to finish"}), 409
    return _update_stream(["sudo", "-n", HELPER, "setup-keygen", node_type],
                          env=env, capture_stderr=True, on_close=_end_setup)


@app.route("/api/setup/<node_type>/finalize", methods=["POST"])
def api_setup_finalize(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    data = request.get_json(silent=True) or {}
    env, err = _setup_env(data, want_passphrase=False)
    if err:
        return jsonify({"error": err}), 400
    if not _begin_setup():
        return jsonify({"error": "a node setup is already running -- wait for it to finish"}), 409
    return _update_stream(["sudo", "-n", HELPER, "setup-finalize", node_type],
                          env=env, capture_stderr=True, on_close=_end_setup)


# =============================================================================
# ROUTES -- external dashboard access (Caddy)
#
# Expose the Node Manager UI at https://<domain> behind Caddy (Let's Encrypt TLS
# + basic_auth). dns-check/enable/disable are management actions: they run via
# the root helper and -- being POSTs -- are refused on the public (read-only)
# path by the before_request guard, so external access can only be configured
# from the SSH tunnel. The password travels in TN_CADDY_PASSWORD (env only,
# never argv/URL). status is a read (GET) and stays available either way.
# =============================================================================

_CADDY_DOMAIN_RE = re.compile(r"^[A-Za-z0-9.-]+$")
_CADDY_USER_RE = re.compile(r"^[A-Za-z0-9._-]{2,32}$")
# Optional inbound-public-IP override (multi-IP / 1:1-NAT nodes). Loose char-class --
# mirrors the setup-path guard; install-caddy.sh re-validates semantically via
# validate_public_ip and falls back to the egress IP on failure. Empty = no override.
_CADDY_PUBLIC_IP_RE = re.compile(r"^[0-9a-fA-F.:]+$")


@app.route("/api/caddy/status")
def api_caddy_status():
    rc, out, err = run(["sudo", "-n", HELPER, "caddy-status"], timeout=10)
    try:
        data = json.loads(out) if out else {}
    except Exception:
        data = {}
    if not data:
        data = {"installed": False, "running": False, "enabled": False,
                "domain": "", "username": ""}
        if rc != 0:
            data["error"] = err or "status unavailable"
    data["ok"] = True
    resp = jsonify(data)
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/caddy/dns-check", methods=["POST"])
def api_caddy_dns_check():
    data = request.get_json(silent=True) or {}
    domain = (data.get("domain") or "").strip()
    if not _CADDY_DOMAIN_RE.match(domain):
        return jsonify({"ok": False, "error": "invalid domain"}), 400
    public_ip = (data.get("public_ip") or "").strip()
    if public_ip and not _CADDY_PUBLIC_IP_RE.match(public_ip):
        return jsonify({"ok": False, "error": "invalid public IP"}), 400
    cmd = ["sudo", "-n", HELPER, "caddy-dns-check", domain]
    if public_ip:
        cmd.append(public_ip)
    rc, out, err = run(cmd, timeout=20)
    try:
        res = json.loads(out) if out else {}
    except Exception:
        res = {}
    if not res:
        return jsonify({"ok": False, "error": err or "dns check failed"}), 200
    res["ok"] = True
    return jsonify(res)


@app.route("/api/caddy/enable", methods=["POST"])
def api_caddy_enable():
    data = request.get_json(silent=True) or {}
    domain = (data.get("domain") or "").strip()
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    public_ip = (data.get("public_ip") or "").strip()
    if not _CADDY_DOMAIN_RE.match(domain):
        return jsonify({"error": "invalid domain"}), 400
    if not _CADDY_USER_RE.match(username):
        return jsonify({"error": "invalid username (2-32 chars: letters, digits, . _ -)"}), 400
    if len(password) < 8:
        return jsonify({"error": "password too short (min 8 chars)"}), 400
    if public_ip and not _CADDY_PUBLIC_IP_RE.match(public_ip):
        return jsonify({"error": "invalid public IP"}), 400
    env = os.environ.copy()
    env["TN_CADDY_PASSWORD"] = str(password)
    cmd = ["sudo", "-n", HELPER, "caddy-enable", domain, username]
    if public_ip:
        cmd.append(public_ip)
    return _update_stream(cmd, env=env, capture_stderr=True)


@app.route("/api/caddy/disable", methods=["POST"])
def api_caddy_disable():
    return _update_stream(["sudo", "-n", HELPER, "caddy-disable"],
                          env=os.environ.copy(), capture_stderr=True)


# =============================================================================
# ROUTES -- system
# =============================================================================

@app.route("/api/system")
def api_system():
    return jsonify(system_info())


@app.route("/api/addons/status")
def api_addons_status():
    """Read-only status of the testnet opt-in add-ons (health monitor / logging /
    VPN admin SSH) for the management-side System card. Management-only: refused on
    the public Caddy path even though it's a read. All enabling/disabling lives on
    the CLI (setup-observability.sh / setup-vpn.sh)."""
    if is_public_request():
        return jsonify({"ok": False, "error": "management only"}), 403
    t = (request.args.get("node_type") or "").strip()
    if not valid_type(t):
        return bad_type()
    rc, out, err = run(["sudo", "-n", HELPER, "addons-status", t], timeout=10)
    try:
        data = json.loads(out) if out else {}
    except Exception:
        data = {}
    if not data:
        return jsonify({"ok": False, "error": err or "unavailable"}), 200
    data["ok"] = True
    resp = jsonify(data)
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/netstat")
def api_netstat():
    """Primary-NIC traffic (rates + since-boot totals). Its own endpoint so the
    1s sample doesn't delay /api/status; the dashboard fetches it each refresh."""
    resp = jsonify(network_traffic())
    resp.headers["Cache-Control"] = "no-store"
    return resp


# =============================================================================
# ROUTES -- version & update
#
# The privileged work (registry/git queries, building, swapping the binary,
# restarting the service) is done by update-node.sh in a non-interactive
# --json mode, reached only through the root-owned telcoin-ui-helper (same
# no-wildcard sudoers pattern as the Jaeger/tracing commands). The server never
# runs update-node.sh or systemctl for updates directly.
# =============================================================================

# Allowed git ref / docker tag shape for the prepare endpoint. The helper
# re-validates, but reject obviously bad input before we ever shell out.
REF_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


@app.route("/api/version/<node_type>")
def api_version(node_type):
    if not valid_type(node_type):
        return bad_type()
    return jsonify(node_version(node_type))


@app.route("/api/build-info")
def api_build_info():
    """build_ref/branch/commit/built_at from /etc/telcoin/build-info (written by
    the setup scripts on a source build). {exists:false} when not present."""
    bi = read_build_info()
    if not bi:
        return jsonify({"exists": False})
    return jsonify({
        "exists": True,
        "build_ref": bi.get("build_ref", ""),
        "branch": bi.get("branch", ""),
        "commit": bi.get("commit", ""),
        "built_at": bi.get("built_at", ""),
    })


@app.route("/api/update/status/<node_type>")
def api_update_status(node_type):
    if not valid_type(node_type):
        return bad_type()
    rc, out, err = run(["sudo", "-n", HELPER, "update-check", node_type], timeout=30)
    if rc == 0 and out:
        try:
            return jsonify(json.loads(out))
        except (ValueError, json.JSONDecodeError):
            pass
    # Helper/sudo unavailable (e.g. dev box) -- degrade gracefully.
    return jsonify({
        "install_method": detect_install_method(node_type),
        "current_ref": node_version(node_type).get("ref", ""),
        "latest_ref": "",
        "update_available": False,
        "pending": None,
        "error": err or out or "update check unavailable",
    })


def _update_stream(argv, env=None, capture_stderr=False, on_close=None):
    """SSE generator that streams a --json subprocess (via the helper) line by
    line. Each JSON line the script emits becomes one SSE event. Mirrors the
    /api/logs/<type>/stream teardown pattern. `env`, when given, fully replaces
    the child environment (used by Setup to pass TN_SETUP_*/TN_BLS_PASSPHRASE).
    `capture_stderr` tees the script's human-readable stderr (print_*/build/
    keytool noise) to a temp file and, on a non-zero exit, surfaces its tail as
    a final error event -- so a failing step shows WHY instead of just a code.
    `on_close` is always invoked once the subprocess ends (used to release the
    single-flight setup guard)."""
    def generate():
        errfile = None
        stderr_dest = subprocess.DEVNULL
        if capture_stderr:
            fd, errpath = tempfile.mkstemp(prefix="tn-stream-", suffix=".log")
            errfile = errpath
            stderr_dest = os.fdopen(fd, "w")
        proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=stderr_dest, text=True, env=env,
        )
        if capture_stderr:
            stderr_dest.close()  # parent's copy; child keeps writing to the fd
        try:
            for line in iter(proc.stdout.readline, ""):
                line = line.rstrip()
                if line:
                    yield f"data: {line}\n\n"
        except GeneratorExit:
            pass
        finally:
            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    proc.kill()
            if on_close:
                try:
                    on_close()
                except Exception:
                    pass
        if errfile is not None:
            if proc.returncode not in (0, None):
                tail = ""
                try:
                    with open(errfile, "r", errors="replace") as f:
                        lines = [ln.rstrip() for ln in f if ln.strip()]
                    tail = " | ".join(lines[-12:])[:900]
                except Exception:
                    pass
                if tail:
                    yield "data: " + json.dumps({"event": "error", "msg": "output: " + tail}) + "\n\n"
            try:
                os.unlink(errfile)
            except Exception:
                pass
        yield 'data: {"event":"closed"}\n\n'

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"})


@app.route("/api/update/prepare/<node_type>")
def api_update_prepare(node_type):
    # GET (not POST) so the browser can consume it with EventSource; the ref is
    # a query param, validated here and again in the helper.
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    ref = (request.args.get("ref") or "").strip()
    if not REF_RE.match(ref):
        return jsonify({"error": "invalid ref"}), 400
    return _update_stream(["sudo", "-n", HELPER, "update-prepare", node_type, ref])


@app.route("/api/update/apply/<node_type>")
def api_update_apply(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    return _update_stream(["sudo", "-n", HELPER, "update-apply", node_type])


@app.route("/api/update/discard/<node_type>", methods=["POST"])
def api_update_discard(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    rc, out, err = run(["sudo", "-n", HELPER, "update-discard", node_type], timeout=30)
    ok = rc == 0
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "discard failed")})


# =============================================================================
# ROUTES -- setup preflight
# =============================================================================

@app.route("/api/setup/preflight")
def api_preflight():
    # systemd version (>= 247 required, mirrors the setup scripts).
    systemd = {"ok": False, "version": None, "required": 247}
    rc, out, _ = run(["systemctl", "--version"])
    if rc == 0 and out:
        m = re.search(r"systemd\s+(\d+)", out)
        if m:
            systemd["version"] = int(m.group(1))
            systemd["ok"] = systemd["version"] >= 247

    # Internet reachability.
    internet = {"ok": False}
    try:
        urllib.request.urlopen("https://github.com", timeout=5)
        internet["ok"] = True
    except Exception:
        internet["ok"] = False

    # Disk headroom on root.
    disk = {"ok": False, "percent": None}
    d = disk_for("/")
    if d.get("percent") is not None:
        try:
            pct = int(d["percent"])
            disk["percent"] = pct
            disk["ok"] = pct < 90
        except ValueError:
            pass

    # Docker (soft).
    docker = {"ok": False}
    if shutil.which("docker"):
        rc, _, _ = run(["docker", "info"], timeout=10)
        docker["ok"] = rc == 0

    # Rust toolchain (soft).
    rust = {"ok": bool(shutil.which("rustc"))}

    # TPM device (soft).
    tpm = {"ok": os.path.exists("/dev/tpm0") or os.path.exists("/dev/tpmrm0")}

    return jsonify({
        "systemd": systemd,
        "internet": internet,
        "disk": disk,
        "docker": docker,
        "rust": rust,
        "tpm": tpm,
    })


# =============================================================================
# Observability (Jaeger / tracing)
# =============================================================================
#
# The Telcoin Network binary has built-in OpenTelemetry tracing
# (--tracing-url + --node-name). Jaeger runs as a Docker container on the same
# host (UI :16686, OTLP :4317). All privileged operations -- managing the
# container, editing the tel-owned node wrapper script, restarting the node --
# go through one root-owned, arg-validated helper invoked via sudo. Direct
# reads (the world-readable wrapper, the Jaeger HTTP API on localhost) need no
# privilege and are done in-process.

HELPER = "/usr/local/sbin/telcoin-ui-helper"
JAEGER_BASE = "http://127.0.0.1:16686"
TRACING_URL = "http://127.0.0.1:4317"


def wrapper_path(t):
    """
    Path to the node's wrapper script (the one ExecStart points at). Resolved
    from the unit's ExecStart=<...>.sh line, falling back to the conventional
    /opt/telcoin/start-telcoin-<t>.sh.
    """
    path = service_file(t)
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                unit = f.read()
            m = re.search(r"^ExecStart=(\S+\.sh)\s*$", unit, re.MULTILINE)
            if m:
                return m.group(1)
        except (OSError, IOError):
            pass
    return f"/opt/telcoin/start-telcoin-{t}.sh"


def tracing_enabled(t):
    """True if the node wrapper already carries --tracing-url. Direct read."""
    path = wrapper_path(t)
    try:
        with open(path, "r") as f:
            return "--tracing-url" in f.read()
    except (OSError, IOError):
        return False


def jaeger_get(path, timeout=5):
    """
    GET JSON from the local Jaeger query API. Returns the parsed object, or None
    on any failure (Jaeger down, bad JSON, timeout). Stdlib only.
    """
    try:
        req = urllib.request.Request(JAEGER_BASE + path, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def jaeger_services():
    """List of registered service names from /api/services. [] if unreachable."""
    data = jaeger_get("/api/services")
    if isinstance(data, dict) and isinstance(data.get("data"), list):
        return [s for s in data["data"] if isinstance(s, str)]
    return []


def resolve_service(t, services=None):
    """
    The node registers its OTLP service name as `telcoin-<type>` plus a
    node-identity suffix (e.g. `telcoin-<type>-QCZPqMY2zfp`), so an exact-name
    query never matches. Return the registered service that is `telcoin-<t>`
    exactly or a `telcoin-<t>-...` prefix, else None when the node has not
    registered yet.
    Pass an already-fetched `services` list to avoid a second /api/services call.
    """
    base = f"telcoin-{t}"
    if services is None:
        services = jaeger_services()
    if base in services:
        return base
    for s in services:
        if s.startswith(base + "-"):
            return s
    return None


def _span_is_error(span):
    """Detect an error span from its tags (error / otel.status_code / http >=400)."""
    for tag in span.get("tags") or []:
        key = tag.get("key")
        val = tag.get("value")
        if key == "error" and val in (True, "true"):
            return True
        if key == "otel.status_code" and val == "ERROR":
            return True
        if key == "http.status_code":
            try:
                if int(val) >= 400:
                    return True
            except (TypeError, ValueError):
                pass
    return False


def simplify_trace(trace):
    """
    Reduce a raw Jaeger trace to {trace_id, operation, duration_ms, start_time,
    error}. The root span (empty `references`, else the earliest startTime)
    supplies operation + start; trace duration spans the whole tree
    (max span end - min span start), converted µs -> ms.
    """
    spans = trace.get("spans") or []
    if not spans:
        return None

    root = None
    for sp in spans:
        if not sp.get("references"):
            root = sp
            break
    if root is None:
        root = min(spans, key=lambda s: s.get("startTime", 0))

    starts = [s.get("startTime", 0) for s in spans]
    ends = [s.get("startTime", 0) + s.get("duration", 0) for s in spans]
    duration_us = (max(ends) - min(starts)) if spans else 0
    error = any(_span_is_error(s) for s in spans)

    return {
        "trace_id": trace.get("traceID"),
        "operation": root.get("operationName", ""),
        "duration_ms": round(duration_us / 1000, 1),
        "start_time": int(root.get("startTime", min(starts)) // 1000),  # epoch ms
        "error": error,
    }


@app.route("/api/jaeger/status")
def api_jaeger_status():
    selected = request.args.get("node_type")
    services = jaeger_services()
    api_reachable = jaeger_get("/api/services") is not None

    # container_running via the privileged helper; on a dev box without the
    # helper/sudo, fall back to "is the API answering?".
    rc, out, _ = run(["sudo", "-n", HELPER, "jaeger-status"])
    if rc == 0 and out in ("running", "stopped", "absent"):
        container_running = out == "running"
    else:
        container_running = api_reachable

    obs_reg = resolve_service("observer", services) is not None
    val_reg = resolve_service("validator", services) is not None
    if selected in NODE_TYPES:
        service_registered = resolve_service(selected, services) is not None
    else:
        service_registered = obs_reg or val_reg

    return jsonify({
        "container_running": container_running,
        "api_reachable": api_reachable,
        "service_registered": service_registered,
        "services": services,
        "tracing": {
            "observer": tracing_enabled("observer"),
            "validator": tracing_enabled("validator"),
        },
    })


@app.route("/api/jaeger/start", methods=["POST"])
def api_jaeger_start():
    rc, out, err = run(["sudo", "-n", HELPER, "jaeger-start"], timeout=60)
    ok = rc == 0
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "start failed")})


@app.route("/api/jaeger/stop", methods=["POST"])
def api_jaeger_stop():
    rc, out, err = run(["sudo", "-n", HELPER, "jaeger-stop"], timeout=60)
    ok = rc == 0
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "stop failed")})


@app.route("/api/tracing/enable/<node_type>", methods=["POST"])
def api_tracing_enable(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    # 30s: the helper edits the wrapper then restarts the node with --no-block,
    # so it returns once the restart job is queued (no wait on the node's stop
    # window) -- ample headroom for an enqueue-and-return.
    rc, out, err = run(["sudo", "-n", HELPER, "tracing-enable", node_type], timeout=30)
    ok = rc == 0
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "enable failed")})


@app.route("/api/tracing/disable/<node_type>", methods=["POST"])
def api_tracing_disable(node_type):
    if not valid_type(node_type):
        return bad_type()
    blocked = _external_block(node_type)
    if blocked:
        return blocked
    rc, out, err = run(["sudo", "-n", HELPER, "tracing-disable", node_type], timeout=30)
    ok = rc == 0
    return jsonify({"ok": ok, "error": "" if ok else (err or out or "disable failed")})


@app.route("/api/tracing/status/<node_type>")
def api_tracing_status(node_type):
    if not valid_type(node_type):
        return bad_type()
    return jsonify({"enabled": tracing_enabled(node_type)})


@app.route("/api/traces/<node_type>")
def api_traces(node_type):
    if not valid_type(node_type):
        return bad_type()
    try:
        limit = int(request.args.get("limit", 20))
    except ValueError:
        limit = 20
    limit = max(1, min(limit, 100))

    service = resolve_service(node_type)
    if service is None:
        return jsonify({"traces": []})
    data = jaeger_get(
        f"/api/traces?service={service}&limit={limit}"
    )
    traces = []
    if isinstance(data, dict) and isinstance(data.get("data"), list):
        for raw in data["data"]:
            simple = simplify_trace(raw)
            if simple:
                traces.append(simple)
    traces.sort(key=lambda x: x.get("start_time") or 0, reverse=True)
    return jsonify({"traces": traces})


@app.route("/api/traces/<node_type>/stats")
def api_traces_stats(node_type):
    if not valid_type(node_type):
        return bad_type()

    zero = {
        "total_traces_last_hour": 0,
        "avg_duration_ms": 0,
        "slowest_duration_ms": 0,
        "error_count": 0,
        "error_rate_percent": 0,
    }

    service = resolve_service(node_type)
    if service is None:
        return jsonify(zero)
    data = jaeger_get(
        f"/api/traces?service={service}&limit=100&lookback=1h"
    )
    if not (isinstance(data, dict) and isinstance(data.get("data"), list)):
        return jsonify(zero)

    simples = []
    for raw in data["data"]:
        s = simplify_trace(raw)
        if s:
            simples.append(s)

    if not simples:
        return jsonify(zero)

    durations = [s["duration_ms"] for s in simples]
    errors = sum(1 for s in simples if s["error"])
    total = len(simples)
    return jsonify({
        "total_traces_last_hour": total,
        "avg_duration_ms": round(sum(durations) / total, 1),
        "slowest_duration_ms": round(max(durations), 1),
        "error_count": errors,
        "error_rate_percent": round(errors / total * 100, 1),
    })


# =============================================================================
# NETWORK STATUS  (public Uptime Kuma status page, per network)
#
# Pulls the same data the public status page shows -- monitor config + live
# heartbeats -- from two no-auth endpoints (keyed by the active network slug),
# and folds them into one response the dashboard renders. Monitors are rendered
# DYNAMICALLY from the status page's publicGroupList (no fixed monitor ids), so
# the same code works on testnet and devnet. Cached 60s per slug so polling never
# hammers the external API. Degrades to available:false (never a 500) when the
# status page is unreachable, and configured:false for an unknown network.
# =============================================================================

# Network slugs we know a status page for (drawn from NETWORKS above).
KNOWN_SLUGS = {m["slug"] for m in NETWORKS.values()}

STATUS_PAGE_BASE = "https://status.telscan.xyz"


def status_page_config_url(slug):
    return f"{STATUS_PAGE_BASE}/api/status-page/{slug}"


def status_page_heartbeat_url(slug):
    return f"{STATUS_PAGE_BASE}/api/status-page/heartbeat/{slug}"


_network_cache = {}   # slug -> {"ts": float, "data": dict}
_netcons_cache = {}   # slug -> {"ts": float, "data": int}


def _to_int_block(num):
    """Coerce an RPC block 'number' (int, decimal str, or 0x-hex str) to int."""
    if isinstance(num, bool):
        return None
    if isinstance(num, int):
        return num
    if isinstance(num, str):
        s = num.strip()
        if s.startswith("0x"):
            return hex_to_dec(s)
        if s.isdigit():
            return int(s)
    return None


def _network_consensus(chain_id):
    """{'block':int|None, 'epoch':int|None} from the network's public RPC
    endpoint(s) (tn_latestConsensusHeader), cached 60s per chain id. Tries each
    endpoint in order with a short 3s timeout (so one down node never stalls the
    dashboard) and returns the first success. {} when the chain has no public RPC,
    or when every endpoint fails (with a short stale-cache grace)."""
    rpcs = NETWORK_PUBLIC_RPC.get(chain_id)
    if not rpcs:
        return {}
    now = time.time()
    entry = _netcons_cache.get(chain_id)
    cached = entry["data"] if entry else None
    if cached is not None and now - entry["ts"] < 60:
        return cached

    payload = json.dumps({
        "jsonrpc": "2.0", "method": "tn_latestConsensusHeader",
        "params": [], "id": 1,
    }).encode()
    out = None
    for rpc in rpcs:
        try:
            req = urllib.request.Request(
                rpc, data=payload,
                headers={"Content-Type": "application/json", "User-Agent": "telcoin-ui"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read().decode())
            result = data.get("result") if isinstance(data, dict) else None
            if isinstance(result, dict):
                block = _to_int_block(result.get("number"))
                epoch = None
                headers = (result.get("sub_dag") or {}).get("headers") or []
                if headers and headers[0].get("epoch") is not None:
                    epoch = headers[0].get("epoch")
                if block is not None:
                    out = {"block": block, "epoch": epoch}
                    break
        except Exception:
            continue

    if out is None:
        # Every endpoint failed: serve a recent stale value within a grace window.
        if cached is not None and now - entry["ts"] < 300:
            return cached
        return {}

    _netcons_cache[chain_id] = {"ts": now, "data": out}
    return out


def network_consensus_block(chain_id):
    """Network consensus block number (None when unavailable)."""
    return _network_consensus(chain_id).get("block")


def network_consensus_epoch(chain_id):
    """Network's current consensus epoch (None when unavailable). Lets a syncing
    node compare its local epoch against the network's."""
    return _network_consensus(chain_id).get("epoch")


def _http_get_json(url, timeout=6):
    """GET JSON from a public URL. None on any failure. Stdlib only."""
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "telcoin-ui"}, method="GET"
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def _ordered_monitors(cfg):
    """[(id, name), ...] in publicGroupList display order. [] when the config is
    missing or carries no monitors."""
    out = []
    if not isinstance(cfg, dict):
        return out
    for group in cfg.get("publicGroupList") or []:
        for m in group.get("monitorList") or []:
            mid, nm = m.get("id"), m.get("name")
            if isinstance(mid, int):
                out.append((mid, nm or f"Monitor {mid}"))
    return out


def _build_network_status(slug, title_default):
    """Fetch config + heartbeats for `slug` and fold them into the dashboard
    payload, rendering every monitor from the status page itself (no fixed ids).
    The consensus-block row is whichever monitor's name mentions 'consensus';
    the rest become tiles. Returns None when the status page is unreachable."""
    cfg = _http_get_json(status_page_config_url(slug))
    hb = _http_get_json(status_page_heartbeat_url(slug))
    if cfg is None and hb is None:
        return None

    title = title_default
    if isinstance(cfg, dict):
        c = cfg.get("config") or {}
        if c.get("title"):
            title = c["title"]

    hb_list = (hb or {}).get("heartbeatList") or {}

    def beats(mid):
        b = hb_list.get(str(mid))
        return b if isinstance(b, list) else []

    def latest(mid):
        b = beats(mid)
        return b[-1] if b else None

    def uptime_pct(mid):
        b = beats(mid)[-50:]  # last 50 heartbeats, per the brief
        if not b:
            return None
        up = sum(1 for x in b if x.get("status") == 1)
        return round(up / len(b) * 100, 2)

    statuses = []
    monitors = []
    consensus = None
    last_updated = None
    for mid, name in _ordered_monitors(cfg):
        last = latest(mid)
        st = last.get("status") if last else None
        if st is not None:
            statuses.append(st)
        lt = (last or {}).get("time")
        if lt and (not last_updated or lt > last_updated):
            last_updated = lt
        # The first monitor whose name mentions "consensus" is the dedicated
        # consensus-block progress row; everything else is a validator tile.
        if consensus is None and "consensus" in name.lower():
            consensus = {
                "name": name,
                "status": st if st is not None else 0,
                "last_seen": lt,
                "ping": (last or {}).get("ping"),
                "uptime": uptime_pct(mid),
            }
        else:
            monitors.append({
                "id": mid,
                "name": name,
                "status": st if st is not None else 0,
                "ping": (last or {}).get("ping"),
                "uptime": uptime_pct(mid),
            })

    if not statuses:
        overall = "down"
    elif all(s == 1 for s in statuses):
        overall = "up"
    elif all(s != 1 for s in statuses):
        overall = "down"
    else:
        overall = "degraded"

    if not last_updated:
        last_updated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    return {
        "title": title,
        "slug": slug,
        "overall": overall,
        "monitors": monitors,
        "consensus_block": consensus,
        "last_updated": last_updated,
    }


@app.route("/api/network/status")
def api_network_status():
    # The active network slug comes from the selected node's chain id; default to
    # testnet for the boot-time nav pill before a node's chain id is known.
    slug = (request.args.get("slug") or "testnet").strip()
    if slug not in KNOWN_SLUGS:
        return jsonify({
            "configured": False,
            "available": False,
            "slug": slug,
            "overall": "unknown",
            "monitors": [],
            "consensus_block": None,
            "last_updated": None,
        })

    name = next((m["name"] for m in NETWORKS.values() if m["slug"] == slug), slug)
    title_default = f"{name} Network Status"

    now = time.time()
    entry = _network_cache.get(slug)
    cached = entry["data"] if entry else None
    if cached is not None and now - entry["ts"] < 60:
        return jsonify(cached)

    data = _build_network_status(slug, title_default)
    if data is None:
        # Unreachable -- degrade, never 500. Do not cache the failure (so we
        # retry on the next poll), but serve a stale-but-recent cache if we have
        # one within a short grace window.
        if cached is not None and now - entry["ts"] < 300:
            return jsonify(cached)
        return jsonify({
            "configured": True,
            "available": False,
            "slug": slug,
            "title": title_default,
            "overall": "unknown",
            "monitors": [],
            "consensus_block": None,
            "last_updated": None,
        })

    data["configured"] = True
    data["available"] = True
    _network_cache[slug] = {"ts": now, "data": data}
    return jsonify(data)


# =============================================================================
# MAIN
# =============================================================================

# The bind address IS the trust boundary for the management path. This server
# has NO authentication of its own: the SSH-tunnel / loopback path is trusted
# purely because it is unreachable from off-host. Caddy (install-caddy.sh) is
# the ONLY intended public entrypoint, and it forces every proxied request
# read-only via the unforgeable X-TN-Dashboard-Public header. Exposing this
# port by ANY other means -- binding 0.0.0.0, a second reverse proxy that does
# not stamp that header, `docker -p 8080:8080`, or `ssh -g`/GatewayPorts --
# hands unauthenticated, full node control to whoever can reach it. Keep this
# on loopback; the guard below refuses to start otherwise.
BIND_HOST = "127.0.0.1"
BIND_PORT = 8080
_LOOPBACK_HOSTS = ("127.0.0.1", "::1")

if __name__ == "__main__":
    if BIND_HOST not in _LOOPBACK_HOSTS:
        _log(
            f"refusing to start: BIND_HOST={BIND_HOST!r} is not loopback "
            f"({' / '.join(_LOOPBACK_HOSTS)}). This UI has no auth of its own; "
            "binding off-loopback exposes unauthenticated full node management. "
            "Put a header-stamping reverse proxy (install-caddy.sh) in front "
            "instead -- see the comment above BIND_HOST."
        )
        sys.exit(1)
    app.run(host=BIND_HOST, port=BIND_PORT, debug=False, threaded=True)
