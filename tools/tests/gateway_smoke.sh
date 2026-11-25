#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/gateway_smoke.sh -- the real worker-gateway image, started with
# the argument line lib/gateway.sh renders, against stub servers on loopback
#
#   bash tools/tests/gateway_smoke.sh <image-ref> [--keep]
#
# Not a fixture test: it needs docker and the image, so its name does not end
# in _test.sh and tools/tests/run.sh never picks it up. It never pulls.
#
# What it does: starts gateway_smoke_stubs.py (a worker JSON-RPC stub, the
# node's GET /health/workers with a switchable accepting_transactions, and a
# query JSON-RPC stub for --redirect-queries) on free 127.0.0.1 ports in
# 18000-19999; sources lib/common.sh (which sources lib/gateway.sh) on a temp
# TN_ROOT_PREFIX; sets GW_V_* as gw_validate_inputs resolves them for
# --mode same-host --front caddy; takes the argument line from gw_render_args;
# checks that its docker run options are the ExecStart= line of gw_unit_text
# (container name and -d aside); runs the container as l2smoke-gw and checks
# health, readiness, routing, the edge refusals, per-client rate limiting
# behind a trusted proxy, the metrics, and a clean docker stop.
#
# Cleanup (EXIT trap): the l2smoke-gw container, the stub process, the temp
# tree. --keep leaves all three (the stop check is skipped) and prints how to
# remove them.
#
# Exit status: 0 every check passed; 1 a check failed; 2 usage; 77 docker,
# the image, python3 or curl is not available here (nothing was started).
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -u

SMOKE_NAME="l2smoke-gw"
SMOKE_IMAGE=""
SMOKE_KEEP=0
SMOKE_STUB_PID=""
# Per-client limit at the gateway's defaults (facts: --rate-limit-per-ip 100/s,
# --rate-limit-per-ip-burst 0 = twice the rate). The burst must exceed what that
# bucket can admit while it runs, so a working limiter is certain to refuse.
SMOKE_RATE=100
SMOKE_BUCKET=200
SMOKE_BURST_N=600
SMOKE_BURST_THREADS=8
SMOKE_OTHER_N=50
# A signed legacy transaction (the EIP-155 example, chain 1).
SMOKE_RAW_TX="0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
SMOKE_ADDR="0x3535353535353535353535353535353535353535"

smoke_usage() {
    printf 'usage: bash tools/tests/gateway_smoke.sh <image-ref> [--keep]\n'
}

for smoke_a in "$@"; do
    case "$smoke_a" in
        --keep) SMOKE_KEEP=1 ;;
        -h|--help) smoke_usage; exit 0 ;;
        -*) smoke_usage >&2; exit 2 ;;
        *)
            if [[ -n "$SMOKE_IMAGE" ]]; then smoke_usage >&2; exit 2; fi
            SMOKE_IMAGE="$smoke_a"
            ;;
    esac
done
if [[ -z "$SMOKE_IMAGE" ]]; then smoke_usage >&2; exit 2; fi

smoke_unavailable() {
    printf 'gateway_smoke: not run (exit 77): %s\n' "$1"
    exit 77
}
command -v docker >/dev/null 2>&1 || smoke_unavailable "docker is not installed"
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    || smoke_unavailable "the docker daemon is not reachable"
docker image inspect "$SMOKE_IMAGE" >/dev/null 2>&1 \
    || smoke_unavailable "image ${SMOKE_IMAGE} is not on this host (the smoke never pulls)"
command -v python3 >/dev/null 2>&1 || smoke_unavailable "python3 is not installed"
command -v curl >/dev/null 2>&1 || smoke_unavailable "curl is not installed"

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_STUBS="${SMOKE_DIR}/gateway_smoke_stubs.py"
# shellcheck source=tools/tests/lib.sh
. "${SMOKE_DIR}/lib.sh"
ST="${TN_TEST_TMP}/stubs"
mkdir -p "$ST" "${TN_TEST_TMP}/root"
export TN_ROOT_PREFIX="${TN_TEST_TMP}/root"

eval "$(tn_test_source_common)"

# shellcheck disable=SC2329  # run by the EXIT trap
smoke_cleanup() {
    if [[ "$SMOKE_KEEP" == 1 ]]; then
        printf '\n--keep: left the gateway container, the stubs and the temp tree. Remove them with:\n'
        printf '  docker rm -f %s\n' "$SMOKE_NAME"
        if [[ -n "$SMOKE_STUB_PID" ]]; then printf '  kill %s\n' "$SMOKE_STUB_PID"; fi
        printf '  rm -rf %s\n' "$TN_TEST_TMP"
        return 0
    fi
    docker rm -f "$SMOKE_NAME" >/dev/null 2>&1
    if [[ -n "$SMOKE_STUB_PID" ]]; then
        kill "$SMOKE_STUB_PID" 2>/dev/null
        wait "$SMOKE_STUB_PID" 2>/dev/null
    fi
    tn_test_cleanup
}
trap smoke_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# smoke_get URL [curl options...] -- print the HTTP status (000: no answer);
# the body lands in $ST/resp.
smoke_get() {
    local url="$1"
    shift
    curl -sS --noproxy '*' --max-time 10 -o "$ST/resp" -w '%{http_code}' "$@" "$url" \
        2>"$ST/curl.err" || true
}
# smoke_rpc BODY [X-Forwarded-For] -- POST BODY to the gateway's main listener.
smoke_rpc() {
    local xff=()
    if [[ -n "${2:-}" ]]; then xff=(-H "X-Forwarded-For: $2"); fi
    smoke_get "${GW_URL}/" -H 'Content-Type: application/json' ${xff[@]+"${xff[@]}"} --data-binary "$1"
}
# smoke_call ID METHOD PARAMS -- one JSON-RPC call object.
smoke_call() {
    printf '{"jsonrpc":"2.0","id":"%s","method":"%s","params":%s}' "$1" "$2" "$3"
}
smoke_code()   { sed -n 's/.*"code": *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$ST/resp"; }
smoke_result() { sed -n 's/.*"result": *"\([^"]*\)".*/\1/p' "$ST/resp"; }
# smoke_seen STUB ID -- how many calls with that id the stub logged.
smoke_seen() {
    local n
    n="$(grep -c "^id=$2 " "$ST/$1.log" 2>/dev/null)"
    printf '%s\n' "${n:-0}"
}
smoke_line() { grep -m 1 "^id=$2 " "$ST/$1.log" 2>/dev/null || true; }
smoke_yes() { if "$@"; then printf 'yes\n'; else printf 'no\n'; fi; }
# smoke_msum NAME LABEL -- sum of the samples of metric NAME whose labels hold LABEL.
smoke_msum() {
    awk -v m="$1{" -v l="$2" 'substr($0, 1, length(m)) == m && index($0, l) { s += $NF }
        END { printf "%d\n", s + 0 }' "$ST/metrics"
}
# smoke_kv KEY -- a value from the burst client's key=value line.
smoke_kv() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<< " $SMOKE_BURST_OUT"; }

# --- stubs --------------------------------------------------------------------
printf 'false\n' > "$ST/accepting"
python3 -I "$SMOKE_STUBS" serve "$ST" > "$ST/stubs.out" 2>&1 &
SMOKE_STUB_PID=$!
smoke_i=0
while [[ ! -f "$ST/ports" && $smoke_i -lt 50 ]]; do
    sleep 0.2
    smoke_i=$((smoke_i + 1))
done
if [[ ! -f "$ST/ports" ]]; then
    check "stub servers bound their ports" "ports file" "none after 10 s: $(cat "$ST/stubs.out" 2>/dev/null)"
    finish
fi
smoke_port() { sed -n "s/^$1=//p" "$ST/ports"; }
P_WORKER="$(smoke_port WORKER)"
P_HEALTH="$(smoke_port HEALTH)"
P_QUERY="$(smoke_port QUERY)"
P_LISTEN="$(smoke_port LISTEN)"
P_PROBE="$(smoke_port PROBE)"
P_METRICS="$(smoke_port METRICS)"
GW_URL="http://127.0.0.1:${P_LISTEN}"
PROBE_URL="http://127.0.0.1:${P_PROBE}"
printf 'info: ports worker=%s health=%s query=%s listen=%s probe=%s metrics=%s\n' \
    "$P_WORKER" "$P_HEALTH" "$P_QUERY" "$P_LISTEN" "$P_PROBE" "$P_METRICS"

# --- the argument line and the unit, from lib/gateway.sh ----------------------
# What gw_validate_inputs resolves for --mode same-host --front caddy
# --network devnet with test ports (no --trusted-proxies: caddy gives 127.0.0.1/32).
# shellcheck disable=SC2034  # read by lib/gateway.sh
{
    GW_V_MODE="same-host" GW_V_NETWORK="devnet" GW_V_IMAGE="$SMOKE_IMAGE"
    GW_V_DOMAIN="gw.l2smoke.invalid" GW_V_FRONT="caddy" GW_V_UPSTREAM=""
    GW_V_UPSTREAM_HOST="127.0.0.1" GW_V_RPC_PORT="$P_WORKER" GW_V_HEALTH_PORT="$P_HEALTH"
    GW_V_REDIRECT="http://127.0.0.1:${P_QUERY}" GW_V_LISTEN_PORT="$P_LISTEN"
    GW_V_PROBE_PORT="$P_PROBE" GW_V_METRICS_PORT="$P_METRICS" GW_V_TRUSTED_PROXIES="127.0.0.1/32"
    GW_V_RATE_LIMIT_SUBMISSIONS="300"
}
GW_ARGS_LINE="$(gw_render_args)"
printf 'info: gw_render_args: %s\n' "$GW_ARGS_LINE"
check "gw_render_args: the contract 3.3 line for same-host, front caddy" \
    "--listen-addr 127.0.0.1:${P_LISTEN} --probe-addr 127.0.0.1:${P_PROBE} --metrics 127.0.0.1:${P_METRICS} --upstream-rpc-url http://127.0.0.1:${P_WORKER} --upstream-readiness-url http://127.0.0.1:${P_HEALTH}/health/workers --worker-id 0 --redirect-queries http://127.0.0.1:${P_QUERY} --rate-limit-submissions 300 --trusted-proxies 127.0.0.1/32" \
    "$GW_ARGS_LINE"
SMOKE_OPTS=(--network=host --user 1101:1101 --read-only --cap-drop ALL
            --security-opt no-new-privileges --pull=never --stop-timeout 60)
SMOKE_UNIT_EXEC="$(grep '^ExecStart=' <<< "$(gw_unit_text)")"
# shellcheck disable=SC2154  # TN_GATEWAY_CONTAINER comes from lib/common.sh
check "smoke docker run options = gw_unit_text ExecStart (name and -d aside)" \
    "$SMOKE_UNIT_EXEC" \
    "ExecStart=$(command -v docker) run --rm --name ${TN_GATEWAY_CONTAINER} ${SMOKE_OPTS[*]} ${SMOKE_IMAGE} ${GW_ARGS_LINE}"

# --- start --------------------------------------------------------------------
read -r -a SMOKE_ARGV <<< "$GW_ARGS_LINE"
docker rm -f "$SMOKE_NAME" >/dev/null 2>&1
docker run --rm -d --name "$SMOKE_NAME" "${SMOKE_OPTS[@]}" "$SMOKE_IMAGE" "${SMOKE_ARGV[@]}" \
    > "$ST/run.out" 2>&1
check_rc "docker run -d starts the gateway" 0 $?
sleep 3
check "container running after 3 s" "true" \
    "$(docker inspect -f '{{.State.Running}}' "$SMOKE_NAME" 2>&1)"
check "/health 200 on the probe listener" 200 "$(smoke_get "${PROBE_URL}/health")"
check "/health 200 on the main listener" 200 "$(smoke_get "${GW_URL}/health")"
check "the gateway polls the health stub" yes \
    "$(smoke_yes grep -q '^poll ' "$ST/health.log")"

# --- worker not accepting -----------------------------------------------------
check "/ready 503 while the worker is not accepting" 503 "$(smoke_get "${PROBE_URL}/ready")"
smoke_c="$(smoke_rpc "$(smoke_call sub-notready eth_sendRawTransaction "[\"${SMOKE_RAW_TX}\"]")")"
check "submission while not ready: HTTP 503, JSON-RPC -32000" "503 -32000" "$smoke_c $(smoke_code)"
check "submission while not ready reaches neither stub" "worker=0 query=0" \
    "worker=$(smoke_seen worker sub-notready) query=$(smoke_seen query sub-notready)"
smoke_c="$(smoke_rpc "$(smoke_call bn-notready eth_blockNumber '[]')")"
check "eth_blockNumber while not ready: answered by the query stub" "200 query-stub" \
    "$smoke_c $(smoke_result)"
check "eth_blockNumber while not ready: query stub logged it, worker did not" "query=1 worker=0" \
    "query=$(smoke_seen query bn-notready) worker=$(smoke_seen worker bn-notready)"

# --- worker accepting ---------------------------------------------------------
printf 'true\n' > "$ST/accepting"
smoke_t0=$SECONDS
while :; do
    smoke_c="$(smoke_get "${PROBE_URL}/ready")"
    if [[ "$smoke_c" == 200 || $((SECONDS - smoke_t0)) -ge 15 ]]; then break; fi
    sleep 1
done
printf 'info: /ready answered %s after %ss\n' "$smoke_c" "$((SECONDS - smoke_t0))"
check "/ready 200 within 15 s of the worker accepting" 200 "$smoke_c"
check "/ready/any 200" 200 "$(smoke_get "${PROBE_URL}/ready/any")"

smoke_c="$(smoke_rpc "$(smoke_call sub-ready eth_sendRawTransaction "[\"${SMOKE_RAW_TX}\"]")" 203.0.113.9)"
check "submission when ready: HTTP 200" 200 "$smoke_c"
check "submission reaches the worker stub, not the query stub" "worker=1 query=0" \
    "worker=$(smoke_seen worker sub-ready) query=$(smoke_seen query sub-ready)"
smoke_l="$(smoke_line worker sub-ready)"
printf 'info: worker stub saw: %s\n' "$smoke_l"
check "the submission carries X-Forwarded-For with the client 203.0.113.9" yes \
    "$(smoke_yes grep -Eq ' xff=([^ ]*,)?203\.0\.113\.9(,[^ ]*)? ' <<< "$smoke_l")"
for smoke_m in eth_blockNumber tn_nodeMode; do
    smoke_c="$(smoke_rpc "$(smoke_call "q-${smoke_m}" "$smoke_m" '[]')")"
    check "${smoke_m}: answered by the query stub" "200 query-stub" "$smoke_c $(smoke_result)"
    check "${smoke_m}: never reaches the worker stub" "query=1 worker=0" \
        "query=$(smoke_seen query "q-${smoke_m}") worker=$(smoke_seen worker "q-${smoke_m}")"
done
check "the query stub sees X-TN-Gateway-Redirect: 1" yes \
    "$(smoke_yes grep -q ' xtgr=1$' <<< "$(smoke_line query q-eth_blockNumber)")"
smoke_c="$(smoke_rpc "$(smoke_call nonce eth_getTransactionCount "[\"${SMOKE_ADDR}\",\"pending\"]")")"
check "eth_getTransactionCount pending: answered by the worker stub" "200 0x5" "$smoke_c $(smoke_result)"
check "eth_getTransactionCount pending: worker stub only" "worker=1 query=0" \
    "worker=$(smoke_seen worker nonce) query=$(smoke_seen query nonce)"

# --- edge refusals ------------------------------------------------------------
check "GET / answers 405" 405 "$(smoke_get "${GW_URL}/")"
check "a WebSocket upgrade answers 405" 405 "$(smoke_get "${GW_URL}/" -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
{
    printf '{"jsonrpc":"2.0","id":"big","method":"eth_call","params":["'
    head -c 1100000 /dev/zero | tr '\0' 'a'
    printf '"]}'
} > "$ST/big.json"
smoke_c="$(smoke_get "${GW_URL}/" -H 'Content-Type: application/json' -H 'Expect:' --data-binary "@${ST}/big.json")"
check "a body over 1 MiB answers 413" 413 "$smoke_c"
check "the oversized body reaches neither stub" "worker=0 query=0" \
    "worker=$(smoke_seen worker big) query=$(smoke_seen query big)"
smoke_c="$(smoke_rpc "[$(smoke_call mb-sub eth_sendRawTransaction "[\"${SMOKE_RAW_TX}\"]"),$(smoke_call mb-read eth_blockNumber '[]')]")"
check "a batch mixing a submission and a read: HTTP 200" 200 "$smoke_c"
check "the mixed batch goes whole to the query stub" "query=2 worker=0" \
    "query=$(( $(smoke_seen query mb-sub) + $(smoke_seen query mb-read) )) worker=$(( $(smoke_seen worker mb-sub) + $(smoke_seen worker mb-read) ))"

# --- client identity behind the trusted proxy ---------------------------------
SMOKE_BURST_OUT="$(python3 -I "$SMOKE_STUBS" burst "${GW_URL}/" 198.51.100.7 "$SMOKE_BURST_N" \
    198.51.100.8 "$SMOKE_OTHER_N" "$SMOKE_BURST_THREADS" "$SMOKE_RATE" "$SMOKE_BUCKET" 2>&1)"
printf 'info: burst: %s\n' "$SMOKE_BURST_OUT"
check "burst: ${SMOKE_BURST_N} calls outrun a ${SMOKE_BUCKET}-token, ${SMOKE_RATE}/s bucket (certain)" 1 "$(smoke_kv certain)"
check "burst: 198.51.100.7 gets 429 answers" yes "$(smoke_yes test "$(smoke_kv a429)" -gt 0)"
check "burst: 198.51.100.7 admitted no more than the bucket allows" yes \
    "$(smoke_yes test "$(smoke_kv a200)" -le "$(smoke_kv bound)")"
check "burst: 198.51.100.7 got only 200 or 429" 0 "$(smoke_kv aother)"
check "198.51.100.8 in the same second: never throttled" "b200=${SMOKE_OTHER_N} b429=0 bother=0 same_second=1" \
    "b200=$(smoke_kv b200) b429=$(smoke_kv b429) bother=$(smoke_kv bother) same_second=$(smoke_kv same_second)"

# --- metrics ------------------------------------------------------------------
check "the metrics listener answers 200" 200 "$(smoke_get "http://127.0.0.1:${P_METRICS}/metrics")"
cp "$ST/resp" "$ST/metrics"
check "tn_worker_gateway_upstream_ready is 1" 1 "$(smoke_msum tn_worker_gateway_upstream_ready '')"
check "tn_worker_gateway_routed_requests_total route=worker is non-zero" yes \
    "$(smoke_yes test "$(smoke_msum tn_worker_gateway_routed_requests_total 'route="worker"')" -gt 0)"
check "tn_worker_gateway_routed_requests_total route=query is non-zero" yes \
    "$(smoke_yes test "$(smoke_msum tn_worker_gateway_routed_requests_total 'route="query"')" -gt 0)"
check "tn_worker_gateway_rejections_total reason=rate_limited is non-zero" yes \
    "$(smoke_yes test "$(smoke_msum tn_worker_gateway_rejections_total 'reason="rate_limited"')" -gt 0)"
printf 'info: metrics: %s\n' "$(grep -E '^tn_worker_gateway_(upstream_ready|routed_requests_total|rejections_total|mixed_batches_total)' "$ST/metrics" | tr '\n' ' ')"

# --- stop ---------------------------------------------------------------------
docker logs "$SMOKE_NAME" > "$ST/gw.log" 2>&1
if [[ "$SMOKE_KEEP" == 1 ]]; then
    skip "docker stop -t 60 exits cleanly" "--keep leaves the container running"
else
    docker wait "$SMOKE_NAME" > "$ST/wait.out" 2>&1 &
    smoke_wait_pid=$!
    sleep 1
    smoke_t0=$SECONDS
    docker stop -t 60 "$SMOKE_NAME" > "$ST/stop.out" 2>&1
    smoke_rc=$?
    smoke_dt=$((SECONDS - smoke_t0))
    wait "$smoke_wait_pid"
    printf 'info: docker stop took %ss\n' "$smoke_dt"
    check_rc "docker stop -t 60 succeeds" 0 "$smoke_rc"
    check "docker stop returns before the 60 s kill" yes "$(smoke_yes test "$smoke_dt" -lt 60)"
    check "the container exits with status 0" 0 "$(tr -d '[:space:]' < "$ST/wait.out")"
fi

printf 'info: gateway WARN/ERROR lines: %s\n' "$(grep -c -E ' (WARN|ERROR) ' "$ST/gw.log")"
if [[ $FAILS -ne 0 ]]; then
    printf '\n-- gateway log (last 30 lines)\n'
    tail -n 30 "$ST/gw.log"
fi
finish
