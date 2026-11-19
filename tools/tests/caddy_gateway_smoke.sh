#!/usr/bin/env bash
# =============================================================================
# tools/tests/caddy_gateway_smoke.sh -- install-caddy.sh's worker-gateway site
# checked by a real Caddy (needs docker and the Caddy image; NOT named *_test.sh, so
# tools/tests/run.sh never picks it up):
#   1. `caddy validate --adapter caddyfile` on Caddyfiles written by
#      caddy_write_managed: the gateway block alone, and dashboard + gateway (the
#      combinations the script can produce; it refuses tn-rpc next to tn-gateway);
#   2. the gateway block served over plain HTTP on a loopback port, with two python3
#      stub upstreams (the gateway's main listener and its probe listener), for the
#      routing, the 405s, the CORS preflight, the 2 MB body cap and X-Forwarded-For.
#
#   bash tools/tests/caddy_gateway_smoke.sh
#   TN_SMOKE_CADDY_IMAGE=caddy:2 bash tools/tests/caddy_gateway_smoke.sh
#
# Exit 0 all checks passed, 1 a check failed, 77 docker or the Caddy image is not
# available (the image is never pulled here). Containers are named l2caddy-*, use
# the host network, listen on 127.0.0.1 only (ports 18000-19999), and are removed on
# every exit.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
IMG="${TN_SMOKE_CADDY_IMAGE:-caddy:2.8.4}"
CNAME="l2caddy-smoke"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP  docker is not available"
    exit 77
fi
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "SKIP  image ${IMG} is not present locally (docker pull ${IMG})"
    exit 77
fi
command -v python3 >/dev/null 2>&1 || { echo "SKIP  python3 is not available"; exit 77; }

STUB_PIDS=""
smoke_cleanup() {
    local p
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    for p in $STUB_PIDS; do kill "$p" 2>/dev/null || true; done
    tn_test_cleanup
}

export TN_ROOT_PREFIX="$T/root"
export TN_CADDY_RUN_PARENT="$T/run"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export TN_BACKUP_DIR="$T/backups"
RP="$TN_ROOT_PREFIX"
mkdir -p "$RP/etc/caddy" "$RP/etc/telcoin" "$T/run" "$T/bin" "$T/c" "$T/py" "$T/v1" "$T/v2" "$T/srv"

# The fake caddy only lets caddy_write_managed's own validate step pass; the real
# Caddy runs in the container below.
cat > "$T/bin/caddy" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    version) echo "v2.8.4 h1:stub" ;;
    validate) exit 0 ;;
esac
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin/caddy" "$T/bin/systemctl"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

grep -v '^main "\$@"$' "${TN_TEST_REPO}/install-caddy.sh" > "$T/c/install-caddy.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/c/lib"
# shellcheck source=/dev/null
source "$T/c/install-caddy.sh"
set +e
trap smoke_cleanup EXIT

tn_write_root_file() { [[ -L "$1" || -d "$1" ]] && return 1; cat > "$1"; }
sleep() { :; }
CF="$RP/etc/caddy/Caddyfile"
docker rm -f "$CNAME" >/dev/null 2>&1 || true

echo "image: ${IMG} ($(docker run --rm --name l2caddy-version --network none "$IMG" caddy version 2>&1 | head -n1))"

# --- 1. caddy validate on what caddy_write_managed writes ------------------------------
real_validate() {   # <dir holding Caddyfile> <name>
    local out rc
    out="$(docker run --rm --name "l2caddy-validate-$2" --network none -v "$1:/srv/tn:ro" "$IMG" \
        caddy validate --adapter caddyfile --config /srv/tn/Caddyfile 2>&1)"
    rc=$?
    check_rc "caddy validate: $2" 0 "$rc"
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out" | sed 's/^/      | /'
    else
        printf '%s\n' "$out" | grep -E '"level":"(warn|error)"|Valid configuration' | sed 's/^/      | /'
    fi
}
GW_HOST="gw.smoke.example.org"
( write_gateway_block "$GW_HOST" 8655 8656 "$T/gw.block" ) >"$T/out" 2>&1
check_rc "write_gateway_block rc 0" 0 $?
HASH="$(docker run --rm --name l2caddy-hash --network none "$IMG" caddy hash-password --plaintext 'smoke-only-password-1234' 2>/dev/null | tail -n1)"
check "real bcrypt hash for the dashboard block" yes "$(case "$HASH" in '$2'*) echo yes ;; *) echo "no: $HASH" ;; esac)"
( write_dashboard_block dash.smoke.example.org admin "$HASH" "$T/dash.block" ) >"$T/out" 2>&1
check_rc "write_dashboard_block rc 0" 0 $?

( caddy_write_managed "" "" "$T/gw.block" ) >"$T/out" 2>&1
check_rc "caddy_write_managed (gateway alone) rc 0" 0 $?
cp "$CF" "$T/v1/Caddyfile"
check "gateway alone: one gateway fence pair" 2 "$(grep -cxF -e "$TN_CADDY_GW_BEGIN" -e "$TN_CADDY_GW_END" "$T/v1/Caddyfile")"
real_validate "$T/v1" gateway-alone

( caddy_write_managed "$T/dash.block" "" "$T/gw.block" ) >"$T/out" 2>&1
check_rc "caddy_write_managed (dashboard + gateway) rc 0" 0 $?
cp "$CF" "$T/v2/Caddyfile"
check "dashboard + gateway: both fences" 4 "$(grep -cxF -e "$TN_CADDY_GW_BEGIN" -e "$TN_CADDY_GW_END" -e "$DASH_BEGIN" -e "$DASH_END" "$T/v2/Caddyfile")"
real_validate "$T/v2" dashboard-gateway

# --- 2. the gateway block served over plain HTTP ---------------------------------------
PORTS="$(python3 - <<'PY'
import random, socket
got = []
while len(got) < 3:
    p = random.randint(18000, 19999)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        if p not in got:
            got.append(p)
    except OSError:
        pass
    finally:
        s.close()
print(" ".join(str(p) for p in got))
PY
)"
read -r CPORT MPORT PPORT <<EOF
$PORTS
EOF
echo "ports: caddy ${CPORT}, main stub ${MPORT}, probe stub ${PPORT}; client source 127.0.0.2"

cat > "$T/py/stub.py" <<'PY'
import http.server, json, sys
role, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if len(body) != n:
            return
        rec = {"role": role, "method": self.command, "path": self.path,
               "xff": self.headers.get("X-Forwarded-For"), "len": n}
        with open(log, "a") as f:
            f.write(json.dumps(rec) + "\n")
        out = json.dumps(rec).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)
    do_GET = do_POST = do_HEAD = do_PUT = do_DELETE = do_OPTIONS = do_PATCH = handle_any
    def log_message(self, *a):
        pass
class S(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
S(("127.0.0.1", port), H).serve_forever()
PY
# req.py PORT METHOD PATH [--wait] [--body=N] [Name:Value ...] -> one JSON object
cat > "$T/py/req.py" <<'PY'
import http.client, json, sys, time
sys.unraisablehook = lambda *a: None   # a refused connection while waiting is expected
port, method, path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
body, hdrs, wait = None, {}, False
for a in sys.argv[4:]:
    if a.startswith("--body="):
        body = b"x" * int(a[7:])
    elif a == "--wait":
        wait = True
    else:
        k, v = a.split(":", 1)
        hdrs[k.strip()] = v.strip()
if method == "POST" and body is None:
    body = b'{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
    hdrs.setdefault("Content-Type", "application/json")
def once():
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=15, source_address=("127.0.0.2", 0))
    senderr = ""
    try:
        c.request(method, path, body=body, headers=hdrs)
    except OSError as e:
        senderr = type(e).__name__
    try:
        r = c.getresponse()
        data = r.read()
        return {"status": r.status, "allow": r.getheader("Allow"),
                "acao": r.getheader("Access-Control-Allow-Origin"),
                "body": data.decode("utf-8", "replace")[:200], "senderr": senderr}
    except Exception as e:
        return {"status": "ERR", "err": type(e).__name__ + ": " + str(e), "senderr": senderr}
res = once()
deadline = time.time() + 20
while wait and res.get("status") == "ERR" and time.time() < deadline:
    time.sleep(0.25)
    res = once()
print(json.dumps(res))
PY
field() { python3 -c 'import json,sys; v=json.loads(sys.argv[2]).get(sys.argv[1]); print("" if v is None else v)' "$1" "$2"; }
req() { python3 "$T/py/req.py" "$CPORT" "$@"; }
last_rec() { tail -n1 "$1" 2>/dev/null; }
lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

MLOG="$T/main.log" PLOG="$T/probe.log"
python3 "$T/py/stub.py" main "$MPORT" "$MLOG" >"$T/main.err" 2>&1 &
STUB_PIDS="$STUB_PIDS $!"
python3 "$T/py/stub.py" probe "$PPORT" "$PLOG" >"$T/probe.err" 2>&1 &
STUB_PIDS="$STUB_PIDS $!"

# Derived test variant: ONLY the site-address line of the generated block is
# replaced (`<host> {` -> `http://127.0.0.1:<port> {`), so plain HTTP works without
# a certificate. Everything inside the braces is the generated text, byte for byte.
( write_gateway_block "$GW_HOST" "$MPORT" "$PPORT" "$T/gw-test.block" ) >"$T/out" 2>&1
check_rc "write_gateway_block (stub ports) rc 0" 0 $?
awk -v site="${GW_HOST} {" -v repl="http://127.0.0.1:${CPORT} {" '$0==site {print repl; next} {print}' \
    "$T/gw-test.block" > "$T/srv/block"
check "test variant differs in the site line only" 2 "$(diff "$T/gw-test.block" "$T/srv/block" | grep -c '^[<>]')"
{
    printf '{\n\tadmin off\n\tauto_https off\n\tdefault_bind 127.0.0.1\n}\n\n'
    cat "$T/srv/block"
} > "$T/srv/Caddyfile"
docker run -d --name "$CNAME" --network host -v "$T/srv:/srv/tn:ro" "$IMG" \
    caddy run --adapter caddyfile --config /srv/tn/Caddyfile >"$T/docker.out" 2>&1
check_rc "caddy run (gateway block over HTTP) started" 0 $?

R="$(req GET /health --wait)"
if [[ "$(field status "$R")" == "ERR" ]]; then
    echo "      | caddy did not answer: $R"
    docker logs "$CNAME" 2>&1 | tail -n 20 | sed 's/^/      | /'
fi
check "GET /health -> probe stub (200)" 200 "$(field status "$R")"
check "GET /health: answered by the probe stub" "probe GET /health" "$(R2="$(last_rec "$PLOG")"; echo "$(field role "$R2") $(field method "$R2") $(field path "$R2")")"
for p in /ready /ready/any; do
    R="$(req GET "$p")"
    check "GET ${p} -> probe stub (200)" 200 "$(field status "$R")"
    check "GET ${p}: answered by the probe stub" "probe GET ${p}" "$(R2="$(last_rec "$PLOG")"; echo "$(field role "$R2") $(field method "$R2") $(field path "$R2")")"
done
R="$(req HEAD /ready)"
check "HEAD /ready -> probe stub (200)" "200 probe HEAD /ready" "$(field status "$R") $(R2="$(last_rec "$PLOG")"; echo "$(field role "$R2") $(field method "$R2") $(field path "$R2")")"
check "no probe reached the main stub" 0 "$(lines "$MLOG")"

R="$(req POST /)"
check "POST / -> main stub (200)" 200 "$(field status "$R")"
R2="$(last_rec "$MLOG")"
check "POST /: main stub saw POST /" "main POST /" "$(field role "$R2") $(field method "$R2") $(field path "$R2")"
check "POST /: CORS header on the answer" "*" "$(field acao "$R")"
XFF="$(field xff "$R2")"
echo "      X-Forwarded-For seen by the main stub (no client header): '${XFF}'"
check "X-Forwarded-For ends with the client's address" 127.0.0.2 "$(printf '%s' "$XFF" | awk -F', *' '{print $NF}')"
R="$(req POST /health)"
check "POST /health -> main stub (POST to any path is JSON-RPC)" "200 main POST /health" "$(field status "$R") $(R2="$(last_rec "$MLOG")"; echo "$(field role "$R2") $(field method "$R2") $(field path "$R2")")"

R="$(req POST / 'X-Forwarded-For: 203.0.113.9')"
check "POST with a client X-Forwarded-For -> main stub (200)" 200 "$(field status "$R")"
XFF="$(field xff "$(last_rec "$MLOG")")"
echo "      X-Forwarded-For seen by the main stub (client sent 203.0.113.9): '${XFF}'"
check "spoof: last X-Forwarded-For entry is the client's address" 127.0.0.2 "$(printf '%s' "$XFF" | awk -F', *' '{print $NF}')"
check "spoof: 203.0.113.9 is not the last entry" no "$(case "$XFF" in *203.0.113.9) echo yes ;; *) echo no ;; esac)"

m0="$(lines "$MLOG")" p0="$(lines "$PLOG")"
for spec in "GET /" "GET /anything" "PUT /" "DELETE /health" "PATCH /ready"; do
    # shellcheck disable=SC2086 # "<METHOD> <PATH>" splits into two arguments
    R="$(req ${spec})"
    check "${spec} -> 405" 405 "$(field status "$R")"
    check "${spec}: Allow header" "POST, OPTIONS" "$(field allow "$R")"
done
R="$(req GET / 'Connection: Upgrade' 'Upgrade: websocket' 'Sec-WebSocket-Version: 13' 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
check "WebSocket upgrade on / -> 405" 405 "$(field status "$R")"
check "WebSocket upgrade: Allow header" "POST, OPTIONS" "$(field allow "$R")"
R="$(req GET /health 'Connection: Upgrade' 'Upgrade: websocket' 'Sec-WebSocket-Version: 13' 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
check "WebSocket upgrade on /health -> 405 (not the probe)" 405 "$(field status "$R")"
R="$(req OPTIONS / 'Origin: https://wallet.example.org' 'Access-Control-Request-Method: POST' 'Access-Control-Request-Headers: content-type')"
check "OPTIONS preflight -> 200" 200 "$(field status "$R")"
check "OPTIONS preflight: Access-Control-Allow-Origin" "*" "$(field acao "$R")"
check "no 405 case and no preflight reached a stub" "${m0} ${p0}" "$(lines "$MLOG") $(lines "$PLOG")"

R="$(req POST / --body=3145728)"
echo "      3 MB POST: $R"
check "POST over 2 MB -> 413" 413 "$(field status "$R")"
check "POST over 2 MB: the main stub never got the whole body" 0 "$(grep -c '"len": 3145728' "$MLOG")"
R="$(req POST / --body=1048576)"
check "POST of 1 MB -> main stub (200)" "200 1048576" "$(field status "$R") $(field len "$(last_rec "$MLOG")")"

docker logs "$CNAME" 2>&1 | grep -E '"level":"error"' | head -n 5 | sed 's/^/      caddy log | /'
finish
