#!/usr/bin/env python3
"""V-HW-UI H2: the 24 hardware constants, four ways.

    python3 -I h2_constants.py REPO SPEC_MD

  A. lib/common.sh, parsed with the spec 3.2 regex
     readonly (HW_(TESTNET|MAINNET)_[A-Z_]+)=([0-9]+)
  B. ui/server.py HW_TIERS and HW_VALIDATOR_RECOMMENDED (imported), named the
     same way (HW_<NET>_<ROLE>_<MIN|REC>_<CPU|RAM_GB|DISK_GB>)
  C. the spec 3.2 table (parsed from SPEC_MD)
  D. the spec 3.1 document tables (parsed from SPEC_MD): cores, GB RAM, storage
Also prints _hw_ram_floor_kb / _hw_disk_floor_kb for the tier sizes, for
h2_floors.sh to check against the shell. Exit 1 on any mismatch.
"""

import re
import sys

REPO, SPEC = sys.argv[1], sys.argv[2]
sys.path.insert(0, REPO + "/ui")
import server  # noqa: E402

bad = []

# A. the library
lib = open(REPO + "/lib/common.sh").read()
a_pairs = re.findall(r"readonly (HW_(?:TESTNET|MAINNET)_[A-Z_]+)=([0-9]+)", lib)
A = {}
for k, v in a_pairs:
    if k in A:
        bad.append(f"A: {k} assigned twice")
    A[k] = int(v)
all_hw = re.findall(r"\bHW_[A-Z_]+=", lib)
print(f"A lib/common.sh: {len(A)} constants by the spec regex; {len(all_hw)} HW_*= assignments in all")

# B. the server
ROLE = {"node": "NODE", "rpc": "RPC", "validator": "VAL"}
B = {}
for net, tiers in server.HW_TIERS.items():
    for role, _label, cpu, ram, disk in tiers:
        p = f"HW_{net.upper()}_{ROLE[role]}_MIN_"
        B[p + "CPU"], B[p + "RAM_GB"], B[p + "DISK_GB"] = cpu, ram, disk
for net, r in server.HW_VALIDATOR_RECOMMENDED.items():
    p = f"HW_{net.upper()}_VAL_REC_"
    B[p + "CPU"], B[p + "RAM_GB"], B[p + "DISK_GB"] = r["cpu"], r["ram_gb"], r["disk_gb"]
print(f"B ui/server.py: {len(B)} values; nets {sorted(server.HW_TIERS)}; ecc "
      f"{ {k: v['ecc'] for k, v in server.HW_VALIDATOR_RECOMMENDED.items()} }")
labels = {net: [t[1] for t in tiers] for net, tiers in server.HW_TIERS.items()}
for net, ls in labels.items():
    if ls != ["Full node (follower)", "Public RPC node", "Validator (minimum)"]:
        bad.append(f"B: {net} labels {ls} differ from the shell's role labels")

spec = open(SPEC).read()
s32 = spec[spec.index("### 3.2"):spec.index("### 3.3")]
s31 = spec[spec.index("### 3.1"):spec.index("### 3.2")]

# C. spec 3.2
C = {}
for row in re.findall(r"\| `HW_<NET>_([A-Z]+_(?:MIN|REC))_CPU` / `_RAM_GB` / `_DISK_GB` \| ([0-9 /]+) \| ([0-9 /]+) \|", s32):
    stem, tvals, mvals = row
    for net, vals in (("TESTNET", tvals), ("MAINNET", mvals)):
        cpu, ram, disk = [int(x) for x in vals.split("/")]
        p = f"HW_{net}_{stem}_"
        C[p + "CPU"], C[p + "RAM_GB"], C[p + "DISK_GB"] = cpu, ram, disk
print(f"C spec 3.2: {len(C)} values")

# D. spec 3.1
D = {}
parts = s31.split("Mainnet:")
for net, text in (("TESTNET", parts[0]), ("MAINNET", parts[1])):
    rows = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 3 and cells[0] not in ("Role", "---"):
            rows[cells[0]] = cells[1:]

    def cores_ram(cell, where):
        m = re.fullmatch(r"(\d+) cores \((\d+) vCPU\), (\d+) GB (ECC )?RAM", cell)
        if not m:
            bad.append(f"D: {net} {where}: cannot read {cell!r}")
            return 0, 0, False
        if int(m.group(2)) != 2 * int(m.group(1)):
            bad.append(f"D: {net} {where}: vCPU {m.group(2)} is not twice {m.group(1)} cores")
        return int(m.group(1)), int(m.group(3)), bool(m.group(4))

    def gb(cell):
        m = re.match(r"(\d+) (GB|TB)", cell)
        return int(m.group(1)) * (1000 if m.group(2) == "TB" else 1)

    for key, stem in (("Observer, follower", "NODE"), ("Observer, public RPC", "RPC"), ("Validator", "VAL")):
        cpu, ram, ecc = cores_ram(rows[key][0], key + " min")
        D[f"HW_{net}_{stem}_MIN_CPU"], D[f"HW_{net}_{stem}_MIN_RAM_GB"] = cpu, ram
        if stem == "VAL":
            rc, rr, recc = cores_ram(rows[key][1], key + " rec")
            D[f"HW_{net}_VAL_REC_CPU"], D[f"HW_{net}_VAL_REC_RAM_GB"] = rc, rr
            want_ecc = server.HW_VALIDATOR_RECOMMENDED[net.lower()]["ecc"]
            if recc != want_ecc or ecc != want_ecc:
                bad.append(f"D: {net} validator ECC in 3.1 min={ecc} rec={recc}; server ecc={want_ecc}")
        else:
            cores_ram(rows[key][1], key + " rec")
    if net == "TESTNET":
        st = rows["Storage, every role"]
        for stem in ("NODE", "RPC", "VAL"):
            D[f"HW_{net}_{stem}_MIN_DISK_GB"] = gb(st[0])
        D[f"HW_{net}_VAL_REC_DISK_GB"] = gb(st[1])
    else:
        sv, so = rows["Storage, validator"], rows["Storage, observer"]
        D[f"HW_{net}_VAL_MIN_DISK_GB"] = gb(sv[0])
        D[f"HW_{net}_VAL_REC_DISK_GB"] = int(sv[1].split()[0]) * 1000 if sv[1].endswith("TB") else gb(sv[1])
        D[f"HW_{net}_NODE_MIN_DISK_GB"] = D[f"HW_{net}_RPC_MIN_DISK_GB"] = gb(so[0])
print(f"D spec 3.1: {len(D)} values")

names = sorted(set(A) | set(B) | set(C) | set(D))
print(f"\n{'name':30} {'lib':>5} {'srv':>5} {'3.2':>5} {'3.1':>5}")
for n in names:
    vals = [A.get(n), B.get(n), C.get(n), D.get(n)]
    flag = "" if len(set(vals)) == 1 and None not in vals else "   <-- MISMATCH"
    if flag:
        bad.append(f"{n}: lib={vals[0]} server={vals[1]} 3.2={vals[2]} 3.1={vals[3]}")
    print(f"{n:30} " + " ".join(f"{str(v):>5}" for v in vals) + flag)
if len(names) != 24:
    bad.append(f"{len(names)} names, expected 24")

print("\nserver floors (kB): RAM " + ", ".join(f"{g}={server._hw_ram_floor_kb(g)}" for g in (8, 16, 32, 64))
      + "; disk " + ", ".join(f"{g}={server._hw_disk_floor_kb(g)}" for g in (350, 500, 2000, 4000)))
print("FLOORS " + " ".join(f"ram:{g}:{server._hw_ram_floor_kb(g)}" for g in (8, 16, 32, 64)) + " "
      + " ".join(f"disk:{g}:{server._hw_disk_floor_kb(g)}" for g in (350, 500, 2000, 4000)))
print("\nmismatches: " + (str(len(bad)) + "\n  " + "\n  ".join(bad) if bad else "0"))
sys.exit(1 if bad else 0)
