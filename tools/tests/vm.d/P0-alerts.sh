#!/usr/bin/env bash
# =============================================================================
# tools/tests/vm.d/P0-alerts.sh -- private alerts end to end under systemd
#
# A fake node: telcoin.service runs a python3 JSON-RPC stand-in on
# 127.0.0.1:8545 (eth_chainId 0x7e1, a tn_latestConsensusHeader answer with a
# nested number before the header's own, tn_nodeMode CvvActive, eth_blockNumber,
# tn_getCurrentEpochInfo), its start script carries --http --http.addr 127.0.0.1
# --http.port 8545, and .node-meta says NETWORK=testnet, OWNERSHIP_LAYOUT=2. A
# python3 listener on 127.0.0.1:18080 logs the method and path of every push.
#
# setup-alerts.sh --json --enable --targets-stdin (a Kuma push URL and a webhook)
# must leave the timer active and a state file written by the dynamic user (uid
# 61184-65519) saying up, with the Kuma push accepted; the listener must have
# seen the Kuma GET and the webhook POST, and the journal must not hold the URLs.
# The unit's root ExecStartPre= must have written /run/telcoin/heartbeat-service
# (root 0644), the node service's state the dynamic user cannot ask the bus for.
# With the node stopped, a heartbeat run says "service telcoin inactive (dead)".
# setup-alerts.sh --json --disable must leave no unit, runner, config dir,
# state or service-state file. On exit everything this file made is removed and the files it replaced
# are put back.
#
# Skips without python3, without systemd as the init system, or while
# setup-alerts.sh is not in the tree.
# =============================================================================

set -u
# shellcheck source=tools/tests/vm.d/vm_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm_lib.sh"

SA="$VM_REPO/setup-alerts.sh"
if [[ ! -f "$SA" ]]; then
    skip "private alerts end to end" "setup-alerts.sh not in the tree yet"
    finish
fi
PY="$(command -v python3 2>/dev/null)" || PY=""
if [[ -z "$PY" ]]; then
    skip "private alerts end to end" "python3 not installed on this VM"
    finish
fi
if [[ ! -d /run/systemd/system ]] || ! command -v curl >/dev/null 2>&1; then
    skip "private alerts end to end" "systemd is not the init system here, or curl is missing"
    finish
fi

T="$TN_TEST_TMP"
D=/usr/local/libexec/tn-vmtest-alerts
UNIT_D=/etc/systemd/system
STATE=/var/lib/private/telcoin-heartbeat/state
LISTENER_PID=""

# Files this assertion replaces: saved here, put back on exit.
SAVED=(/etc/telcoin/.node-meta /usr/local/libexec/telcoin/tn-start "$UNIT_D/telcoin.service")
mkdir -p "$T/saved"
i=0
for f in "${SAVED[@]}"; do
    if [[ -e "$f" ]]; then cp -p "$f" "$T/saved/$i"; fi
    i=$((i + 1))
done

vm_cleanup() {
    local f i=0
    bash "$SA" --json --disable >/dev/null 2>&1 < /dev/null || true
    systemctl disable --now telcoin-heartbeat.timer >/dev/null 2>&1 || true
    systemctl stop telcoin-heartbeat.service telcoin.service >/dev/null 2>&1 || true
    rm -f "$UNIT_D/telcoin-heartbeat.service" "$UNIT_D/telcoin-heartbeat.timer" \
        /usr/local/libexec/telcoin/tn-heartbeat
    rm -rf /etc/telcoin/alerts /var/lib/private/telcoin-heartbeat
    rm -f /var/lib/telcoin-heartbeat /run/telcoin/heartbeat-service /run/telcoin/heartbeat-service.tmp
    if [[ -n "$LISTENER_PID" ]]; then kill "$LISTENER_PID" 2>/dev/null || true; fi
    for f in "${SAVED[@]}"; do
        if [[ -e "$T/saved/$i" ]]; then cp -p "$T/saved/$i" "$f"; else rm -f "$f"; fi
        i=$((i + 1))
    done
    rm -rf "$D"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed telcoin.service telcoin-heartbeat.service >/dev/null 2>&1 || true
    tn_test_cleanup
}
trap vm_cleanup EXIT

# --- the fake node -----------------------------------------------------------------
install -d -o root -g root -m 0755 "$D" /etc/telcoin /usr/local/libexec/telcoin
cat > "$D/rpc.py" <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# The sub_dag (with latest_execution_block.number) comes before the header's own
# number, as the node serialises it.
ANSWERS = {
    "eth_chainId": "0x7e1",
    "tn_latestConsensusHeader": {
        "sub_dag": {"leader": {"round": 7}, "latest_execution_block": {"number": 99}},
        "number": 1234,
    },
    "tn_nodeMode": "CvvActive",
    "eth_blockNumber": "0x12d687",
    "tn_getCurrentEpochInfo": {"epoch": 42, "epochDuration": 21600},
}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            req = {}
        method = req.get("method")
        if method in ANSWERS:
            body = {"jsonrpc": "2.0", "id": req.get("id", 1), "result": ANSWERS[method]}
        else:
            body = {"jsonrpc": "2.0", "id": req.get("id", 1),
                    "error": {"code": -32601, "message": "method not found"}}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 8545), Handler).serve_forever()
PYEOF
cat > "$D/listener.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def _answer(self):
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
        data = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._answer()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        self.rfile.read(n)
        self._answer()

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
PYEOF
chmod 0644 "$D/rpc.py" "$D/listener.py"
printf '[Unit]\nDescription=Fake Telcoin node for P0-alerts\n\n[Service]\nExecStart=%s -I %s/rpc.py\n' \
    "$PY" "$D" > "$UNIT_D/telcoin.service"
printf '#!/bin/bash\nset -euo pipefail\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin --http --http.addr 127.0.0.1 --http.port 8545\n' \
    > /usr/local/libexec/telcoin/tn-start
chmod 0755 /usr/local/libexec/telcoin/tn-start
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nDATA_DIR=/var/lib/telcoin\n' > /etc/telcoin/.node-meta
chmod 0600 /etc/telcoin/.node-meta
systemctl daemon-reload
systemctl start telcoin.service
"$PY" -I "$D/listener.py" "$T/pushes" > /dev/null 2>&1 &
LISTENER_PID=$!
up=no
for _ in $(seq 1 40); do
    if curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' http://127.0.0.1:8545 \
        && curl -s -o /dev/null http://127.0.0.1:18080/ready; then
        up=yes
        break
    fi
    sleep 0.25
done
check "the fake node and the listener answer" "yes" "$up"
: > "$T/pushes"

# --- enable -------------------------------------------------------------------------
out="$(printf 'kuma http://127.0.0.1:18080/api/push/vmtest1\nwebhook http://127.0.0.1:18080/hook\n' \
    | timeout 300 bash "$SA" --json --enable --targets-stdin --interval 30 2> "$T/enable.err")"
rc=$?
check_rc "setup-alerts.sh --json --enable" 0 "$rc" || { printf '%s\n' "$out"; tail -n 40 "$T/enable.err"; } | sed 's/^/    /'
check "enable: the done event is ok" "yes" "$(grep '"event":"done"' <<< "$out" | grep -q '"ok":true' && echo yes)"
check "enable: the timer is active" "active" "$(systemctl is-active telcoin-heartbeat.timer 2>/dev/null)"
check "enable: the state says up" "up" "$(sed -n 's/^last_status=//p' "$STATE" 2>/dev/null)"
check "enable: the Kuma push was accepted" "yes" "$(grep -qE '^push_1=kuma ok 200 ' "$STATE" 2>/dev/null && echo yes)"
check "enable: the webhook push was accepted" "yes" "$(grep -qE '^push_2=webhook ok 200 ' "$STATE" 2>/dev/null && echo yes)"
check "enable: the listener saw the Kuma GET" "yes" "$(grep -q '^GET /api/push/vmtest1?' "$T/pushes" && echo yes)"
check "enable: the listener saw the webhook POST" "yes" "$(grep -qx 'POST /hook' "$T/pushes" && echo yes)"
uid="$(stat -c %u "$STATE" 2>/dev/null)" || uid=""
check "enable: the state file belongs to the dynamic user" "yes" \
    "$([[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 61184 && uid <= 65519 )) && echo yes)"
check "enable: targets root:root 0600" "0:0 600" "$(stat -c '%u:%g %a' /etc/telcoin/alerts/targets 2>/dev/null)"
check "enable: .node-meta says ENABLE_ALERTS=true" "ENABLE_ALERTS=true" "$(grep '^ENABLE_ALERTS=' /etc/telcoin/.node-meta)"
SVC_STATE=/run/telcoin/heartbeat-service
check "enable: the service-state file is a regular file" "yes" \
    "$([[ -f "$SVC_STATE" && ! -L "$SVC_STATE" ]] && echo yes || echo no)"
check "enable: the service-state file is root:root 0644" "0:0 644" "$(stat -c '%u:%g %a' "$SVC_STATE" 2>/dev/null)"
check "enable: the service-state file says active" "ActiveState=active" "$(grep '^ActiveState=' "$SVC_STATE" 2>/dev/null)"
check "enable: no .tmp left beside it" "no" "$([[ -e "${SVC_STATE}.tmp" ]] && echo yes || echo no)"
check "enable: /run/telcoin is root 0755" "0:0 755" "$(stat -c '%u:%g %a' /run/telcoin 2>/dev/null)"
journal="$(journalctl -u telcoin-heartbeat.service --no-pager -o cat 2>/dev/null)"
check "enable: the journal has the run line" "yes" "$(grep -q 'kuma@127.0.0.1:18080 ok 200' <<< "$journal" && echo yes)"
check_lacks "enable: the journal holds no push URL" "/api/push/" "$journal"
check_lacks "enable: the journal holds no push token" "vmtest1" "$journal"
check_lacks "enable: the journal holds no webhook path" "18080/hook" "$journal"
check_lacks "enable: setup-alerts.sh printed no push token" "vmtest1" "$out$(cat "$T/enable.err")"

# --- the node stops: the next run says why ----------------------------------------
# The timer fired a run at the enable (OnBootSec is long past), so a run may still
# be in flight; its pre-step read the service while it ran. Stop the timer and
# let that run finish, so the explicit start below is a fresh run that sees the
# stopped node. (A run in flight when a node stops reports the starting grace
# once; the next run is down.)
systemctl stop telcoin-heartbeat.timer
i=0
while [[ "$(systemctl is-active telcoin-heartbeat.service 2>/dev/null)" == "activating" && $i -lt 150 ]]; do
    sleep 1; i=$((i + 1))
done
systemctl stop telcoin.service
timeout 200 systemctl start telcoin-heartbeat.service
check "node stopped: the run says the service is inactive" "service telcoin inactive (dead)" \
    "$(sed -n 's/^last_reason=//p' "$STATE" 2>/dev/null)"
check "node stopped: down" "down" "$(sed -n 's/^last_status=//p' "$STATE" 2>/dev/null)"
check "node stopped: the service-state file says inactive (dead)" "ActiveState=inactive SubState=dead" \
    "$(grep -E '^(ActiveState|SubState)=' "$SVC_STATE" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
check "node stopped: the Kuma push still reaches the monitor" "yes" "$(grep -q 'status=down' "$T/pushes" && echo yes)"

# --- disable -----------------------------------------------------------------------
out="$(timeout 120 bash "$SA" --json --disable < /dev/null 2> "$T/disable.err")"
rc=$?
check_rc "setup-alerts.sh --json --disable" 0 "$rc" || { printf '%s\n' "$out"; tail -n 20 "$T/disable.err"; } | sed 's/^/    /'
left=""
for f in "$UNIT_D/telcoin-heartbeat.service" "$UNIT_D/telcoin-heartbeat.timer" \
    /usr/local/libexec/telcoin/tn-heartbeat /etc/telcoin/alerts /var/lib/private/telcoin-heartbeat \
    /var/lib/telcoin-heartbeat "$SVC_STATE" "${SVC_STATE}.tmp"; do
    if [[ -e "$f" || -L "$f" ]]; then left="${left} ${f}"; fi
done
check "disable: no unit, runner, config dir or state left" "" "$left"
check "disable: the service-state file is gone" "no" "$([[ -e "$SVC_STATE" || -L "$SVC_STATE" ]] && echo yes || echo no)"
check "disable: /run/telcoin stays" "yes" "$([[ -d /run/telcoin ]] && echo yes || echo no)"
check "disable: the timer is gone" "no" "$(systemctl cat telcoin-heartbeat.timer >/dev/null 2>&1 && echo yes || echo no)"
check "disable: .node-meta says ENABLE_ALERTS=false" "ENABLE_ALERTS=false" "$(grep '^ENABLE_ALERTS=' /etc/telcoin/.node-meta)"

finish
