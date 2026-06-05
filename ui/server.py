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
import time
import urllib.request

from flask import Flask, Response, jsonify, request, send_from_directory

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================

app = Flask(__name__)

# Web UI version -- its own independent line (starts at 1.0.0). This is the
# single constant update-scripts.sh greps to decide whether the UI is stale.
UI_VERSION = "1.0.2"

NODE_TYPES = ("observer", "validator")

# Where the management scripts live (used only to print the manual setup
# command in the wizard -- the UI never auto-runs setup in v1).
SCRIPTS_DIR = os.path.expanduser("~/telcoin-node-scripts")

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# Default layout, mirroring lib/common.sh in the deployment repo.
DEFAULT_LOG_DIR = "/var/log/telcoin"
DEFAULT_CONFIG_DIR = "/etc/telcoin"
DEFAULT_DATA_DIR = "/var/lib/telcoin"

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
    return jsonify(out)


@app.route("/api/status/<node_type>")
def api_status(node_type):
    if not valid_type(node_type):
        return bad_type()
    t = node_type

    if not os.path.exists(service_file(t)):
        return jsonify({"installed": False, "node_type": t, "status": "not installed"})

    meta = read_meta(t)
    cfg = parse_service_file(t)
    port = int(cfg["rpc_port"])
    status = service_status(t)

    # Local execution liveness + block.
    rpc_ok = local_rpc(port, "eth_chainId") is not None
    block_number = None
    if rpc_ok:
        block_number = hex_to_dec(local_rpc(port, "eth_blockNumber"))

    # Consensus header (block / epoch / age) + the network's exec tip for sync.
    consensus, cons_exec = consensus_info(port)

    # Synced when the local exec block has reached the network's exec tip
    # (small tolerance for the gap between commit and local execution).
    synced = False
    if block_number is not None and cons_exec is not None:
        synced = block_number >= cons_exec - 2

    return jsonify({
        "installed": True,
        "node_type": t,
        "status": status,
        "uptime": service_uptime(t),
        "rpc_ok": rpc_ok,
        "rpc_port": port,
        "block_number": block_number,
        "synced": synced,
        "tracing_enabled": tracing_enabled(t),
        "peers": peer_counts(t, cfg["log_path"]),
        "consensus": consensus,
        "disk": disk_for(data_dir(t)),
        "memory": mem_info(),
        "install_method": meta.get("INSTALL_METHOD", ""),
        "passphrase_method": meta.get("PASSPHRASE_METHOD", ""),
        "docker_image": meta.get("DOCKER_IMAGE", ""),
    })


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


# =============================================================================
# ROUTES -- config
# =============================================================================

@app.route("/api/config/<node_type>")
def api_config(node_type):
    if not valid_type(node_type):
        return bad_type()
    if not os.path.exists(service_file(node_type)):
        return jsonify({"installed": False, "node_type": node_type})

    cfg = parse_service_file(node_type)
    meta = read_meta(node_type)
    return jsonify({
        "installed": True,
        "instance": cfg["instance"],
        "rpc_port": cfg["rpc_port"],
        "metrics": cfg["metrics"],
        "primary_listener": cfg["primary_listener"],
        "worker_listener": cfg["worker_listener"],
        "install_method": meta.get("INSTALL_METHOD", ""),
        "passphrase_method": meta.get("PASSPHRASE_METHOD", ""),
        "docker_image": meta.get("DOCKER_IMAGE", ""),
    })


# =============================================================================
# ROUTES -- system
# =============================================================================

@app.route("/api/system")
def api_system():
    return jsonify(system_info())


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

    obs_reg = "telcoin-observer" in services
    val_reg = "telcoin-validator" in services
    if selected in NODE_TYPES:
        service_registered = ("telcoin-" + selected) in services
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

    data = jaeger_get(
        f"/api/traces?service=telcoin-{node_type}&limit={limit}"
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

    data = jaeger_get(
        f"/api/traces?service=telcoin-{node_type}&limit=100&lookback=1h"
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
# MAIN
# =============================================================================

if __name__ == "__main__":
    # 127.0.0.1 only -- never 0.0.0.0. Access is via SSH tunnel.
    app.run(host="127.0.0.1", port=8080, debug=False, threaded=True)
