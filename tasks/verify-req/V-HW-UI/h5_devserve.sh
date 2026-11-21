#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-HW-UI/h5_devserve.sh -- ui/dev/serve.py with the new reply.
#
#   bash h5_devserve.sh REPO OUT_DIR      (inside python:3.10-slim, PYTHONPATH set
#                                          to the ui requirements)
#
# Starts the dev server for the scenarios fresh and legacy, asks
# /api/setup/preflight with ?network=testnet, mainnet and none, and saves each
# reply's hardware part to OUT_DIR/<scenario>.<net>.json. OUT_DIR must not exist.
# =============================================================================
set -u
REPO="$1"
OUT="$2"
mkdir "$OUT" || exit 2
port=8099
for sc in fresh legacy; do
    python3 "$REPO/ui/dev/serve.py" --port "$port" --scenario "$sc" > "$OUT/$sc.log" 2>&1 &
    pid=$!
    tok=""
    i=0
    while [[ $i -lt 50 && -z "$tok" ]]; do
        sleep 0.2
        tok="$(sed -n 's/.*#t=\([0-9a-f]*\).*/\1/p' "$OUT/$sc.log" | head -n 1)"
        i=$((i + 1))
    done
    for net in testnet mainnet none; do
        q="?network=$net"
        if [[ "$net" == "none" ]]; then q=""; fi
        python3 - "$port" "$tok" "$q" > "$OUT/$sc.$net.json" 2>&1 <<'EOF'
import json, sys, urllib.request
port, tok, q = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(f"http://127.0.0.1:{port}/api/setup/preflight{q}",
                             headers={"X-TN-UI-Token": tok, "Host": f"127.0.0.1:{port}"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.load(r)
    print(json.dumps({"status": r.status, "hardware": d.get("hardware"),
                      "cpu_physical": d.get("cpu_physical"), "cpu_threads": d.get("cpu_threads")}, sort_keys=True))
except Exception as e:
    print(json.dumps({"error": repr(e)}))
EOF
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    port=$((port + 1))
done
