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
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

from flask import Flask, Response, jsonify, request, send_file, send_from_directory

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================

app = Flask(__name__)

# Web UI version -- its own independent line (starts at 1.0.0). This is the
# single constant update-scripts.sh greps to decide whether the UI is stale.
UI_VERSION = "1.7.3"

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

# Default instance number per node type (observer 5 -> 8541, validator 1 -> 8545).
DEFAULT_INSTANCE = {"observer": 5, "validator": 1}


def service_name(t):
    return f"telcoin-{t}"


def service_file(t):
    return f"/etc/systemd/system/telcoin-{t}.service"


def log_file(t):
    """Default node log path. parse_service_file() may override via StandardOutput."""
    return f"{DEFAULT_LOG_DIR}/telcoin-{t}.log"


def meta_file(t):
    return f"{DEFAULT_CONFIG_DIR}/{t}/.node-meta"


def config_dir(t):
    return f"{DEFAULT_CONFIG_DIR}/{t}"


def data_dir(t):
    """Node data dir -- from .node-meta DATA_DIR if set, else the default."""
    meta = read_meta(t)
    return meta.get("DATA_DIR") or f"{DEFAULT_DATA_DIR}/{t}"


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


def read_meta(t):
    """Parse /etc/telcoin/<type>/.node-meta (KEY=VALUE lines). {} if missing."""
    out = {}
    path = meta_file(t)
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    except (OSError, IOError):
        pass
    return out


def rpc_port(instance):
    """RPC port from instance number: 8545 - (instance - 1)."""
    try:
        return 8545 - (int(instance) - 1)
    except (TypeError, ValueError):
        return 8545


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
        "rpc_port": str(rpc_port(DEFAULT_INSTANCE.get(t, 1))),
        "metrics": "",
        "primary_listener": "",
        "worker_listener": "",
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
    # below find --instance / --metrics regardless of install method.
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

    # --instance N
    mi = re.search(r"--instance\s+(\d+)", searchable)
    if mi:
        cfg["instance"] = mi.group(1)
        cfg["rpc_port"] = str(rpc_port(mi.group(1)))

    # --metrics host:port  (may be quoted)
    mm = re.search(r"--metrics\s+\"?([^\s\"\\]+)", searchable)
    if mm:
        cfg["metrics"] = mm.group(1)

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

    method = detect_install_method(t)
    out = {"ref": "", "kind": method or ""}
    if method == "source":
        # -c safe.directory: the source checkout is root-owned but we run as the
        # unprivileged telcoin-ui user, so a bare git call refuses with "dubious
        # ownership". Scope the exception to this one read-only describe.
        rc, o, _ = run(
            ["git", "-c", "safe.directory=" + TN_SOURCE_DIR,
             "-C", TN_SOURCE_DIR, "describe", "--tags", "--always", "--dirty"]
        )
        if rc == 0 and o:
            out["ref"] = o
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


# Adiri testnet runs as EVM chain id 2017. Mainnet has not launched; new installs
# always record NETWORK in .node-meta, so this chain-id fallback only ever needs
# to cover legacy testnet nodes whose meta predates the NETWORK field.
CHAIN_ID_NETWORK = {2017: "testnet"}


def detect_network(t, chain_id=None):
    """'testnet' / 'mainnet' / ''. meta NETWORK first; else map the live RPC
    chain id (covers nodes set up before .node-meta carried NETWORK)."""
    net = read_meta(t).get("NETWORK", "").strip()
    if net:
        return net
    if chain_id is not None:
        return CHAIN_ID_NETWORK.get(chain_id, "")
    return ""


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
    (consensus_dict, cons_exec_block) where cons_exec_block may be None.
    """
    out = {"block": None, "epoch": None, "age": None}
    result = local_rpc(port, "tn_latestConsensusHeader")
    if not isinstance(result, dict):
        return out, None
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
    return out, cons_exec


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
    out["rx_total"] = fmt_bytes(s1[0]) or "—"
    out["tx_total"] = fmt_bytes(s1[1]) or "—"
    return out


# Public Artifact Registry tag list for the testnet docker image (same source
# update-node.sh uses), plus the image base / fallback the CLI setup defaults to.
GAR_TAGS_URL = "https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/tags/list"
GAR_IMAGE_BASE = "us-docker.pkg.dev/telcoin-network/tn-public/adiri"
DEFAULT_DOCKER_IMAGE = GAR_IMAGE_BASE + ":v0.9.2-adiri"


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
    out = {}
    for t in NODE_TYPES:
        installed = os.path.exists(service_file(t))
        out[t] = {
            "installed": installed,
            "status": service_status(t) if installed else "not installed",
        }
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

    if not os.path.exists(service_file(t)):
        r = jsonify({"installed": False, "node_type": t, "status": "not installed"})
        r.headers["Cache-Control"] = "no-store"
        return r

    meta = read_meta(t)
    cfg = parse_service_file(t)
    port = int(cfg["rpc_port"])
    status = service_status(t)

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
    consensus, cons_exec = consensus_info(port)

    # Synced when the local exec block has reached the network's exec tip
    # (small tolerance for the gap between commit and local execution).
    synced = False
    if block_number is not None and cons_exec is not None:
        synced = block_number >= cons_exec - 2

    # Network consensus block (public RPC tn_latestConsensusHeader) + lag.
    # Lag is local - network: positive => local ahead, negative => local behind.
    net_block = network_consensus_block()
    local_cons_block = None
    if consensus.get("block") is not None:
        try:
            local_cons_block = int(consensus["block"])
        except (TypeError, ValueError):
            local_cons_block = None
    consensus_lag = None
    if net_block is not None and local_cons_block is not None:
        consensus_lag = local_cons_block - net_block

    up_secs = service_uptime_seconds(t)
    logs = log_stats(cfg["log_path"])

    resp = jsonify({
        "installed": True,
        "node_type": t,
        "status": status,
        "uptime": service_uptime(t),
        "uptime_seconds": up_secs,
        "uptime_human": fmt_uptime(up_secs),
        "restart_count": service_restart_count(t),
        "last_restart": service_uptime(t),
        "cpu_percent": service_cpu_percent(t),
        "rpc_ok": rpc_ok,
        "rpc_port": port,
        "node_id": node_id(t),
        "data_dir": data_dir(t),
        "config_file": service_file(t),
        "block_number": block_number,
        "synced": synced,
        "chain_id": chain_id,
        "network": detect_network(t, chain_id),
        "block_age": blk_age,
        "log_error_count_1h": logs["error_count"],
        "log_warn_count_1h": logs["warn_count"],
        "last_error": logs["last_error"],
        "recent_log_events": logs["recent_events"],
        "log_size": logs["log_size"],
        "log_size_human": logs["log_size_human"],
        "tracing_enabled": tracing_enabled(t),
        "peers": peer_counts(t, cfg["log_path"]),
        "consensus": consensus,
        "network_consensus_block": net_block,
        "consensus_lag": consensus_lag,
        "disk": disk_for(data_dir(t)),
        "memory": mem_info(),
        "install_method": detect_install_method(t),
        "passphrase_method": detect_passphrase_method(t),
        "docker_image": docker_image_ref(t),
    })
    # Never cache status -- every dashboard refresh must re-read live values
    # (log size, blocks, CPU, ...), not a value frozen at page load.
    resp.headers["Cache-Control"] = "no-store"
    return resp


# =============================================================================
# ROUTES -- service control
# =============================================================================

@app.route("/api/service/<node_type>/<action>", methods=["POST"])
def api_service(node_type, action):
    if not valid_type(node_type):
        return bad_type()
    if action not in ("start", "stop", "restart"):
        return jsonify({"ok": False, "status": "", "error": "invalid action"}), 400
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
    """Download the complete log file from disk as telcoin-<type>.log."""
    if not valid_type(node_type):
        return bad_type()
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
    if not os.path.exists(service_file(node_type)):
        return jsonify({"installed": False, "node_type": node_type})

    cfg = parse_service_file(node_type)
    ext_primary, ext_worker = external_addrs(node_type)
    return jsonify({
        "installed": True,
        "instance": cfg["instance"],
        "rpc_port": cfg["rpc_port"],
        "metrics": cfg["metrics"],
        "primary_listener": cfg["primary_listener"],
        "worker_listener": cfg["worker_listener"],
        "external_primary": ext_primary,
        "external_worker": ext_worker,
        "install_method": detect_install_method(node_type),
        "passphrase_method": detect_passphrase_method(node_type),
        "docker_image": docker_image_ref(node_type),
        "version": node_version(node_type).get("ref", ""),
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
    field = (request.args.get("field") or "").strip()
    value = (request.args.get("value") or "").strip()
    if field not in CONFIG_FIELDS:
        return jsonify({"error": "field not editable"}), 400
    if not config_value_ok(field, value):
        return jsonify({"error": "invalid value for field"}), 400
    return _update_stream(["sudo", "-n", HELPER, "config-set", node_type, field, value])


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
    rc, out, err = run(["sudo", "-n", HELPER, "firewall-port", spec, state], timeout=30)
    if rc == 0 and out:
        try:
            d = json.loads(out.splitlines()[-1])
            return jsonify({"ok": bool(d.get("ok")), "error": "" if d.get("ok") else d.get("msg", "")})
        except (ValueError, json.JSONDecodeError):
            pass
    return jsonify({"ok": False, "error": err or out or "firewall update failed"})


@app.route("/api/node/remove/<node_type>")
def api_node_remove(node_type):
    # Destructive, and SSE so the operator watches each teardown step -- which
    # means GET (EventSource is GET-only), like the update/config streams. The
    # browser must echo back confirm == "DELETE" (the same typed confirmation
    # the CLI requires) before we will call the helper; the helper passes --yes.
    if not valid_type(node_type):
        return bad_type()
    scope = (request.args.get("scope") or "").strip()
    confirm = request.args.get("confirm") or ""
    remove_ui = (request.args.get("ui") == "true")
    if scope not in ("service", "data", "keys"):
        return jsonify({"error": "invalid scope"}), 400
    if confirm != "DELETE":
        return jsonify({"error": 'confirmation required (type "DELETE")'}), 400
    argv = ["sudo", "-n", HELPER, "node-remove", node_type, scope]
    if remove_ui:
        argv.append("ui")  # also uninstall the Node Manager UI (detached, root)
    return _update_stream(argv)


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
        "service_user": "telcoin",
        "service_group": "telcoin",
    })
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/setup/<node_type>/keygen", methods=["POST"])
def api_setup_keygen(node_type):
    if not valid_type(node_type):
        return bad_type()
    data = request.get_json(silent=True) or {}
    env, err = _setup_env(data, want_passphrase=True)
    if err:
        return jsonify({"error": err}), 400
    return _update_stream(["sudo", "-n", HELPER, "setup-keygen", node_type], env=env, capture_stderr=True)


@app.route("/api/setup/<node_type>/finalize", methods=["POST"])
def api_setup_finalize(node_type):
    if not valid_type(node_type):
        return bad_type()
    data = request.get_json(silent=True) or {}
    env, err = _setup_env(data, want_passphrase=False)
    if err:
        return jsonify({"error": err}), 400
    return _update_stream(["sudo", "-n", HELPER, "setup-finalize", node_type], env=env, capture_stderr=True)


# =============================================================================
# ROUTES -- system
# =============================================================================

@app.route("/api/system")
def api_system():
    return jsonify(system_info())


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


def _update_stream(argv, env=None, capture_stderr=False):
    """SSE generator that streams a --json subprocess (via the helper) line by
    line. Each JSON line the script emits becomes one SSE event. Mirrors the
    /api/logs/<type>/stream teardown pattern. `env`, when given, fully replaces
    the child environment (used by Setup to pass TN_SETUP_*/TN_BLS_PASSPHRASE).
    `capture_stderr` tees the script's human-readable stderr (print_*/build/
    keytool noise) to a temp file and, on a non-zero exit, surfaces its tail as
    a final error event -- so a failing step shows WHY instead of just a code."""
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
    ref = (request.args.get("ref") or "").strip()
    if not REF_RE.match(ref):
        return jsonify({"error": "invalid ref"}), 400
    return _update_stream(["sudo", "-n", HELPER, "update-prepare", node_type, ref])


@app.route("/api/update/apply/<node_type>")
def api_update_apply(node_type):
    if not valid_type(node_type):
        return bad_type()
    return _update_stream(["sudo", "-n", HELPER, "update-apply", node_type])


@app.route("/api/update/discard/<node_type>", methods=["POST"])
def api_update_discard(node_type):
    if not valid_type(node_type):
        return bad_type()
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
    The node registers its OTLP service name as `telcoin-<t>` plus a node-identity
    suffix (e.g. telcoin-observer-QCZPqMY2zfp), so an exact-name query never
    matches. Return the registered service that is `telcoin-<t>` exactly or a
    `telcoin-<t>-...` prefix, else None when the node has not registered yet.
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
# NETWORK STATUS  (public Adiri Testnet Uptime Kuma status page)
#
# Pulls the same data the public status page shows -- monitor config + live
# heartbeats -- from two no-auth endpoints, and folds them into one response the
# dashboard renders. Cached 60s so the dashboard's polling never hammers the
# external API. Always degrades to available:false (never a 500) when the status
# page is unreachable.
# =============================================================================

STATUS_PAGE_CONFIG = "https://status.telscan.xyz/api/status-page/testnet"
STATUS_PAGE_HEARTBEAT = "https://status.telscan.xyz/api/status-page/heartbeat/testnet"

# Validator monitors in display order (id -> fallback name if config omits it).
NETWORK_MONITORS = [
    (2, "V1 (Los Angeles)"),
    (6, "V2 (Sydney)"),
    (10, "V3 (Montreal)"),
    (14, "V4 (Netherlands)"),
    (18, "V5 (London)"),
]
CONSENSUS_MONITOR_ID = 48

# Public RPC for the network's latest consensus block (tn_latestConsensusHeader).
TN_PUBLIC_RPC = "https://rpc.telcoin.network"

_network_cache = {"ts": 0.0, "data": None}  # 60s TTL
_netcons_cache = {"ts": 0.0, "data": None}  # 60s TTL (network consensus block #)


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


def network_consensus_block():
    """Network consensus block number from the public RPC
    (tn_latestConsensusHeader -> result.number), cached 60s. Returns the int
    block, or None on failure/timeout (with a short stale-cache grace window)."""
    now = time.time()
    cached = _netcons_cache["data"]
    if cached is not None and now - _netcons_cache["ts"] < 60:
        return cached

    block = None
    payload = json.dumps({
        "jsonrpc": "2.0", "method": "tn_latestConsensusHeader",
        "params": [], "id": 1,
    }).encode()
    try:
        req = urllib.request.Request(
            TN_PUBLIC_RPC, data=payload,
            headers={"Content-Type": "application/json", "User-Agent": "telcoin-ui"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode())
        result = data.get("result") if isinstance(data, dict) else None
        if isinstance(result, dict):
            block = _to_int_block(result.get("number"))
    except Exception:
        block = None

    if block is None:
        # Failure/timeout: serve a recent stale value within a grace window, else None.
        if cached is not None and now - _netcons_cache["ts"] < 300:
            return cached
        return None

    _netcons_cache["ts"] = now
    _netcons_cache["data"] = block
    return block


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


def _monitor_names(cfg):
    """Map monitor id -> name from the status-page config (publicGroupList)."""
    names = {}
    if not isinstance(cfg, dict):
        return names
    for group in cfg.get("publicGroupList") or []:
        for m in group.get("monitorList") or []:
            mid, nm = m.get("id"), m.get("name")
            if isinstance(mid, int) and nm:
                names[mid] = nm
    return names


def _build_network_status():
    """Fetch config + heartbeats and fold them into the dashboard payload.
    Returns None when the status page is unreachable (both fetches failed)."""
    cfg = _http_get_json(STATUS_PAGE_CONFIG)
    hb = _http_get_json(STATUS_PAGE_HEARTBEAT)
    if cfg is None and hb is None:
        return None

    title = "Adiri Testnet Network Status"
    if isinstance(cfg, dict):
        c = cfg.get("config") or {}
        if c.get("title"):
            title = c["title"]

    names = _monitor_names(cfg)
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
    for mid, fallback in NETWORK_MONITORS:
        last = latest(mid)
        st = last.get("status") if last else None
        monitors.append({
            "id": mid,
            "name": names.get(mid, fallback),
            "status": st if st is not None else 0,
            "ping": (last or {}).get("ping"),
            "uptime": uptime_pct(mid),
        })
        if st is not None:
            statuses.append(st)

    cons_last = latest(CONSENSUS_MONITOR_ID)
    cons_status = cons_last.get("status") if cons_last else 0
    consensus = {
        "name": names.get(CONSENSUS_MONITOR_ID, "Consensus Block Progress"),
        "status": cons_status if cons_status is not None else 0,
        "last_seen": (cons_last or {}).get("time"),
        "ping": (cons_last or {}).get("ping"),
        "uptime": uptime_pct(CONSENSUS_MONITOR_ID),
    }
    if cons_last is not None and cons_last.get("status") is not None:
        statuses.append(cons_last.get("status"))

    if not statuses:
        overall = "down"
    elif all(s == 1 for s in statuses):
        overall = "up"
    elif all(s != 1 for s in statuses):
        overall = "down"
    else:
        overall = "degraded"

    # Most recent heartbeat time across all monitors, else now.
    last_updated = consensus.get("last_seen")
    for m in NETWORK_MONITORS:
        lb = latest(m[0])
        if lb and lb.get("time") and (not last_updated or lb["time"] > last_updated):
            last_updated = lb["time"]
    if not last_updated:
        last_updated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    return {
        "title": title,
        "overall": overall,
        "monitors": monitors,
        "consensus_block": consensus,
        "last_updated": last_updated,
    }


@app.route("/api/network/status")
def api_network_status():
    now = time.time()
    cached = _network_cache["data"]
    if cached is not None and now - _network_cache["ts"] < 60:
        return jsonify(cached)

    data = _build_network_status()
    if data is None:
        # Unreachable -- degrade, never 500. Do not cache the failure (so we
        # retry on the next poll), but serve a stale-but-recent cache if we have
        # one within a short grace window.
        if cached is not None and now - _network_cache["ts"] < 300:
            return jsonify(cached)
        return jsonify({
            "title": "Adiri Testnet Network Status",
            "overall": "unknown",
            "available": False,
            "monitors": [],
            "consensus_block": None,
            "last_updated": None,
        })

    data["available"] = True
    _network_cache["ts"] = now
    _network_cache["data"] = data
    return jsonify(data)


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    # 127.0.0.1 only -- never 0.0.0.0. Access is via SSH tunnel.
    app.run(host="127.0.0.1", port=8080, debug=False, threaded=True)
