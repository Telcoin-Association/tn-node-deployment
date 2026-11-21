#!/usr/bin/env python3
"""V-HW-UI parity harness, server side.

    python3 -I h1_server.py UI_DIR HOSTS_TSV RUN_DIR [OUT_NAME]

Reads the fixtures h1_shell.sh wrote (RUN_DIR/fx/<id>/) and, for every host,
imports UI_DIR/server.py as the ui tests do (test_support.local_client) and
feeds it the same machine: `run` answers lscpu / nproc / sysctl from the
fixtures (every other command is "not found"), CPUINFO_PATH and /proc/meminfo
point at the fixtures, shutil.disk_usage answers from the df fixture (or raises
OSError), os.cpu_count answers None (the shell's getconf stub fails),
DEFAULT_DATA_DIR is the host's data dir. Then it calls hardware_profile(net)
and GET /api/setup/preflight?network=net through the Flask test client for
testnet, mainnet, devnet, adiri and none (no argument / no parameter).

Writes RUN_DIR/<OUT_NAME or server>.tsv (host net tierset role verdict dims
spec), RUN_DIR/<OUT_NAME>-meta.tsv and RUN_DIR/<OUT_NAME>-json/<id>.<net>.json
(the route's whole reply). Exits 1 when the route and the direct call differ
or the route is not 200.
"""

import builtins
import collections
import json
import os
import shutil
import sys
import urllib.request
from unittest import mock

UI_DIR, HOSTS, RUN = sys.argv[1], sys.argv[2], sys.argv[3]
NAME = sys.argv[4] if len(sys.argv) > 4 else "server"
sys.path.insert(0, UI_DIR)
import server  # noqa: E402

try:
    import test_support  # noqa: E402
    test_support.local_client(server)
except ImportError:  # an old tree without test_support: set the token by hand
    server.UI_TOKEN = "ab" * 32

TOKEN = getattr(server, "UI_TOKEN", "ab" * 32)
HDRS = {"X-TN-UI-Token": TOKEN, "Host": "127.0.0.1:8080"}
Usage = collections.namedtuple("Usage", "total used free")
REAL_OPEN = builtins.open
NETS = ("testnet", "mainnet", "devnet", "adiri", "none")


def hosts():
    with REAL_OPEN(HOSTS) as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            yield line.rstrip("\n").split("\t")[0]


def read(path):
    with REAL_OPEN(path) as f:
        return f.read()


def machine(fx):
    """The patches that make server.py see the fixture host in `fx`."""
    df_log = []

    def fake_run(cmd, timeout=10):
        name = cmd[0]
        if name in ("lscpu", "nproc"):
            p = os.path.join(fx, name)
            return (0, read(p).strip(), "") if os.path.exists(p) else (1, "", "")
        if name == "sysctl" and list(cmd[1:]) == ["-n", "hw.physicalcpu"]:
            p = os.path.join(fx, "sysctl")
            return (0, read(p).strip(), "") if os.path.exists(p) else (1, "", "")
        return 127, "", "not found"

    def fake_open(path, *a, **k):
        if path == "/proc/meminfo":
            path = os.path.join(fx, "meminfo")
        return REAL_OPEN(path, *a, **k)

    def fake_usage(path):
        df_log.append(path)
        p = os.path.join(fx, "df")
        if not os.path.exists(p):
            raise OSError(2, "fake: cannot stat", path)
        t, u, a, _pct = read(p).split()
        return Usage(int(t) * 1024, int(u) * 1024, int(a) * 1024)

    def no_net(*_a, **_k):
        raise OSError("no network in the harness")

    patches = [
        mock.patch.object(server, "run", fake_run),
        mock.patch.object(server, "CPUINFO_PATH", os.path.join(fx, "cpuinfo")),
        mock.patch.object(server, "open", fake_open, create=True),
        mock.patch.object(shutil, "disk_usage", fake_usage),
        mock.patch.object(shutil, "which", lambda *_a, **_k: None),
        mock.patch.object(os, "cpu_count", lambda: None),
        mock.patch.object(server, "DEFAULT_DATA_DIR", read(os.path.join(fx, "datadir")).strip()),
        mock.patch.object(urllib.request, "urlopen", no_net),
    ]
    if hasattr(server, "host_has_tpm"):
        patches.append(mock.patch.object(server, "host_has_tpm", lambda *_a, **_k: None))
    return patches, df_log


def disk_label(gb):
    return f"{gb // 1000} TB" if gb >= 1000 and gb % 1000 == 0 else f"{gb} GB"


def main():
    client = server.app.test_client()
    jdir = os.path.join(RUN, NAME + "-json")
    os.mkdir(jdir)
    rows = ["host\tnet\ttierset\trole\tverdict\tdims\tspec"]
    meta = ["host\tnet\tstatus\tsame_as_direct\tcpu\tram_kb\tdisk_total_kb\tdisk_path\tcpu_physical\tcpu_threads\tdf_paths"]
    bad = 0
    for hid in hosts():
        fx = os.path.join(RUN, "fx", hid)
        patches, df_log = machine(fx)
        for p in patches:
            p.start()
        try:
            for net in NETS:
                arg = None if net == "none" else net
                try:
                    direct = server.hardware_profile(arg) if arg is not None else server.hardware_profile()
                except TypeError:  # an old server: hardware_profile() takes no argument
                    direct = server.hardware_profile()
                del df_log[:]
                url = "/api/setup/preflight" + ("" if arg is None else "?network=" + arg)
                r = client.get(url, headers=HDRS)
                reply = r.get_json(silent=True) or {}
                with REAL_OPEN(os.path.join(jdir, f"{hid}.{net}.json"), "w") as f:
                    json.dump(reply, f, indent=1, sort_keys=True)
                hw = reply.get("hardware") or {}
                same = hw == direct
                if r.status_code != 200 or not same:
                    bad += 1
                ts = hw.get("network", "-")
                for t in hw.get("tiers", []):
                    if t["ok"]:
                        v = "pass"
                    elif t["gaps"]:
                        v = "below"
                    else:
                        v = "unknown"
                    spec = (f"{t['min_cpu']} cores ({2 * t['min_cpu']} vCPU) / {t['min_ram_gb']} GB / "
                            f"{disk_label(t['min_disk_gb'])}")
                    rows.append("\t".join([hid, net, ts, t["role"], v, ",".join(t["gaps"]) or "-", spec]))
                d = hw.get("disk") or {}
                meta.append("\t".join(str(x) for x in [
                    hid, net, r.status_code, same, hw.get("cpu"), hw.get("ram_kb"),
                    d.get("total_kb"), d.get("path"), reply.get("cpu_physical"),
                    reply.get("cpu_threads"), ",".join(df_log) or "-"]))
        finally:
            for p in reversed(patches):
                p.stop()
    with REAL_OPEN(os.path.join(RUN, NAME + ".tsv"), "w") as f:
        f.write("\n".join(rows) + "\n")
    with REAL_OPEN(os.path.join(RUN, NAME + "-meta.tsv"), "w") as f:
        f.write("\n".join(meta) + "\n")
    print(f"h1_server.py: {len(rows) - 1} rows, {bad} route/direct mismatches or non-200")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
