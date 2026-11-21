#!/usr/bin/env python3
"""V-HW-UI H3: GET /api/setup/preflight with hostile ?network= values.

    python3 -I h3_params.py UI_DIR OUT_JSON

Imports UI_DIR/server.py (the current tree, or the 01664cc one), stubs the
slow probes (run -> "not found", urlopen raises, host_has_tpm -> None) and
sends every query string below through the Flask test client, with the token
and a local Host. For each: status, the `network` field, whether the raw
value (or its first 40 characters) appears in the body, and the key sets
(top level, hardware, one tier). Then the auth checks: no token, a foreign
Host, the public header, for this route and for /api/setup/defaults.
Writes OUT_JSON; prints a table. Exit 1 on a 5xx, a reflected value, or a
network field other than testnet/mainnet (when present).
"""

import json
import os
import sys
import urllib.request
from unittest import mock

UI_DIR, OUT = sys.argv[1], sys.argv[2]
sys.path.insert(0, UI_DIR)
import server  # noqa: E402

try:
    import test_support  # noqa: E402
    test_support.local_client(server)
except ImportError:
    server.UI_TOKEN = "ab" * 32
TOKEN = server.UI_TOKEN
GOOD = {"X-TN-UI-Token": TOKEN, "Host": "127.0.0.1:8080"}

BIG = "a" * 10240
CASES = [
    ("absent", "", None),
    ("empty", "network=", ""),
    ("testnet", "network=testnet", "testnet"),
    ("mainnet", "network=mainnet", "mainnet"),
    ("adiri", "network=adiri", "adiri"),
    ("devnet", "network=devnet", "devnet"),
    ("MAINNET", "network=MAINNET", "MAINNET"),
    ("spaces", "network=%20mainnet%20", " mainnet "),
    ("plus-spaces", "network=+mainnet+", " mainnet "),
    ("nbsp", "network=%C2%A0mainnet", " mainnet"),
    ("tab", "network=mainnet%09", "mainnet\t"),
    ("dup m,t", "network=mainnet&network=testnet", "mainnet"),
    ("dup t,m", "network=testnet&network=mainnet", "testnet"),
    ("10kB", "network=" + BIG, BIG),
    ("quotes", "network=%22mainnet%27", "\"mainnet'"),
    ("angle", "network=%3Cscript%3Ealert(1)%3C%2Fscript%3E", "<script>alert(1)</script>"),
    ("img", "network=%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E", "<img src=x onerror=alert(1)>"),
    ("newline", "network=mainnet%0Aevil", "mainnet\nevil"),
    ("trail-LF", "network=mainnet%0A", "mainnet\n"),
    ("null", "network=mainnet%00", "mainnet\x00"),
    ("null-mid", "network=main%00net", "main\x00net"),
    ("bad-utf8", "network=%FF%FE", None),
    ("bad-utf8-2", "network=%C3%28mainnet", None),
    ("rtl", "network=%E2%80%AEtennuam", "‮tennuam"),
    ("json", "network=%7B%22a%22%3A1%7D", '{"a":1}'),
    ("other key", "net=mainnet", None),
    ("semicolon", "network=mainnet;network=testnet", "mainnet;network=testnet"),
]


def keyset(reply):
    hw = reply.get("hardware") or {}
    tiers = hw.get("tiers") or [{}]
    return {"top": sorted(reply), "hardware": sorted(hw), "tier": sorted(tiers[0]),
            "disk": sorted(hw.get("disk") or {}),
            "validator_recommended": sorted(hw.get("validator_recommended") or {})}


def main():
    client = server.app.test_client()
    rec = {"cases": [], "auth": []}
    bad = []
    with mock.patch.object(server, "run", lambda cmd, timeout=10: (127, "", "not found")), \
            mock.patch.object(urllib.request, "urlopen", mock.Mock(side_effect=OSError("off"))), \
            mock.patch.object(server, "host_has_tpm", lambda *a, **k: None):
        for name, qs, raw in CASES:
            r = client.get("/api/setup/preflight" + ("?" + qs if qs else ""), headers=GOOD)
            body = r.get_data(as_text=True)
            reply = r.get_json(silent=True) or {}
            net = (reply.get("hardware") or {}).get("network", "<absent>")
            refl = False
            # A value that strips to a known name is answered with that name
            # (network_rule strips); anything else must not appear in the body.
            if raw and raw.strip() not in ("testnet", "mainnet", "adiri", "devnet", "MAINNET"):
                probe = raw[:40]
                refl = len(probe) >= 3 and probe in body
            row = {"name": name, "qs": qs[:60], "status": r.status_code, "network": net,
                   "reflected": refl, "bytes": len(body), "keys": keyset(reply)}
            rec["cases"].append(row)
            if r.status_code >= 500 or refl or (net != "<absent>" and net not in ("testnet", "mainnet")):
                bad.append(name)
            print(f"{name:12} {r.status_code} network={net:9} reflected={refl} bytes={len(body)}")
        for route in ("/api/setup/preflight?network=mainnet", "/api/setup/defaults?network=mainnet"):
            for label, hdrs in (
                    ("token+local", GOOD),
                    ("no token", {"Host": "127.0.0.1:8080", "X-TN-UI-Token": ""}),
                    ("wrong token", {"Host": "127.0.0.1:8080", "X-TN-UI-Token": "cd" * 32}),
                    ("foreign Host", {"Host": "evil.example:8080", "X-TN-UI-Token": TOKEN}),
                    ("public", dict(GOOD, **{"X-TN-Dashboard-Public": "1"})),
                    ("cross-site", dict(GOOD, **{"Sec-Fetch-Site": "cross-site", "Origin": "http://evil.example"}))):
                r = client.get(route, headers=hdrs)
                rec["auth"].append({"route": route.split("?")[0], "headers": label, "status": r.status_code})
                print(f"auth {route.split('?')[0]:22} {label:12} -> {r.status_code}")
    rec["bad"] = bad
    with open(OUT, "w") as f:
        json.dump(rec, f, indent=1)
    print("bad cases: " + (", ".join(bad) or "none"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
