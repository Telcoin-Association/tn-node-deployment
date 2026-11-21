#!/usr/bin/env python3
"""V-HW-UI parity harness, comparison.

    python3 -I h1_compare.py RUN_DIR [SERVER_NAME] [--table]

Joins RUN_DIR/shell.tsv (h1_shell.sh) and RUN_DIR/<SERVER_NAME>.tsv
(h1_server.py, default "server") on (host, net, role) and prints:
  1. the parity table for testnet and mainnet (with --table: every row; without
     it: the count and the differing rows only),
  2. which tier set each side applied for devnet, adiri and no network,
  3. the shell's own consistency (rc 0, TN_HW_GAPS = the roles below),
  4. the measured path of each side (df argument vs disk_usage argument).
Exit 1 when a testnet/mainnet row differs.
"""

import collections
import os
import sys

RUN = sys.argv[1]
SNAME = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else "server"
TABLE = "--table" in sys.argv


def load(name):
    with open(os.path.join(RUN, name)) as f:
        lines = f.read().splitlines()
    head = lines[0].split("\t")
    return [dict(zip(head, ln.split("\t"))) for ln in lines[1:] if ln]


def short(p):
    return p.replace(RUN, "$RUN") if p else p


def verdict(r):
    return r["verdict"] + ("" if r["dims"] == "-" else "(" + r["dims"] + ")")


def main():
    sh = {(r["host"], r["net"], r["role"]): r for r in load("shell.tsv")}
    sv = {(r["host"], r["net"], r["role"]): r for r in load(SNAME + ".tsv")}
    hosts = list(collections.OrderedDict.fromkeys(k[0] for k in sh))
    diffs, rows = [], 0
    out = []
    out.append("== 1. parity, testnet and mainnet (host net role: shell | server)")
    for h in hosts:
        for net in ("testnet", "mainnet"):
            for role in ("node", "rpc", "validator"):
                a, b = sh.get((h, net, role)), sv.get((h, net, role))
                rows += 1
                if a is None or b is None:
                    diffs.append(f"{h} {net} {role}: missing on {'shell' if a is None else 'server'}")
                    continue
                va, vb = verdict(a), verdict(b)
                spec_ok = a["spec"] == "-" or a["spec"] == b["spec"]
                same = va == vb and a["tierset"] == b["tierset"] and spec_ok
                line = f"{h:11} {net:8} {role:10} {va:22} | {vb:22}" + ("" if same else "   <-- DIFF")
                if not spec_ok:
                    line += f" spec shell={a['spec']!r} server={b['spec']!r}"
                if TABLE:
                    out.append(line)
                if not same:
                    diffs.append(line)
    out.append(f"rows: {rows}; differing: {len(diffs)}")
    out.extend(diffs)

    out.append("")
    out.append("== 2. tier set applied (host-independent; shown for host big)")
    for net in ("testnet", "mainnet", "devnet", "adiri", "none"):
        a, b = sh[("big", net, "validator")], sv[("big", net, "validator")]
        out.append(f"network={net:8} shell={a['tierset']:8} server={b['tierset']}")
    mism = collections.Counter()
    for (h, net, role), a in sh.items():
        b = sv.get((h, net, role))
        if b and net in ("devnet", "adiri", "none") and verdict(a) != verdict(b):
            mism[net] += 1
    out.append("verdict rows differing per extra network value: " + (", ".join(f"{k}={v}" for k, v in sorted(mism.items())) or "none"))

    out.append("")
    out.append("== 3. shell consistency (rc, TN_HW_GAPS)")
    bad = 0
    for m in load("shell-meta.tsv"):
        below = [role for role in ("node", "rpc", "validator")
                 if sh[(m["host"], m["net"], role)]["verdict"] == "below"]
        want = ",".join(below) or "-"
        if m["rc"] != "0" or m["gaps"] != want:
            bad += 1
            out.append(f"{m['host']} {m['net']}: rc={m['rc']} gaps={m['gaps']} expected {want}")
    out.append(f"shell runs with rc!=0 or wrong TN_HW_GAPS: {bad}")

    out.append("")
    out.append("== 4. measured path and CPU kind (testnet run)")
    svm = {(m["host"], m["net"]): m for m in load(SNAME + "-meta.tsv")}
    for m in load("shell-meta.tsv"):
        if m["net"] != "testnet":
            continue
        s = svm.get((m["host"], "testnet"), {})
        sp = s.get("df_paths", "-").split(",")[0]
        flag = "" if sp == m["df_path"] else "   <-- path DIFF"
        if m["logical_note"] == "yes" or flag or m["host"] in ("dirmissing", "tnval"):
            out.append(f"{m['host']:11} shell df={short(m['df_path'])} logical_note={m['logical_note']} | "
                       f"server path={short(sp)} cpu={s.get('cpu')} cpu_physical={s.get('cpu_physical')} "
                       f"cpu_threads={s.get('cpu_threads')}{flag}")
    print("\n".join(out))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
