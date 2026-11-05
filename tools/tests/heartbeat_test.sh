#!/usr/bin/env bash
# tools/tests/heartbeat_test.sh -- lib/tn-heartbeat.sh, the private-alerts runner.
#
# Library mode: the file is sourced (no side effects) and its helpers are checked
# directly: hb_header_number on nested, fixture-shaped, error and unbalanced
# answers; hb_target_normalize on the provider rules; hb_state_get on valid,
# invalid and symlinked state files.
#
# Runner mode: `bash lib/tn-heartbeat.sh` with STATE_DIRECTORY,
# CREDENTIALS_DIRECTORY, TN_HB_NOW, TN_HB_MONO and TN_HB_SERVICE_STATE pointing
# at a private tree and two stand-ins first on PATH. systemctl prints the SVC_*
# fields the test sets; the service-state file (what the unit's root
# ExecStartPre= writes) is absent unless a case writes it.
# curl never runs for real: a push (-K FILE) is recorded from the url line of
# its config file and its options to $T/pushes and fails per host when
# $T/fail/<host> says so; an RPC call answers from $T/rpc/<method>; the health
# endpoint answers from $T/health. Every argv is logged so the test can show
# that no target URL ever reaches a command line.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
RUNNER="$TN_TEST_REPO/lib/tn-heartbeat.sh"
SH="${BASH:-bash}"
mkdir -p "$T/bin" "$T/state" "$T/cred" "$T/rpc" "$T/fail" "$T/lib" "$T/svc"
SVC_FILE="$T/svc/heartbeat-service"

# --- library mode -----------------------------------------------------------

out="$("$SH" -c 'set -euo pipefail; source "$1"; printf "sourced %s\n" "$HEARTBEAT_VERSION"' _ "$RUNNER" 2>&1)"
rc=$?
check_rc "sourcing under set -euo pipefail succeeds" 0 "$rc"
check "sourcing runs nothing but the definitions" "sourced 2.1.0" "$out"

# shellcheck source=lib/tn-heartbeat.sh
source "$RUNNER"

hdr_json() {
    # A tn_latestConsensusHeader answer: the sub_dag (with a nested
    # latest_execution_block.number and braces inside strings) comes first,
    # the header's own number after it.
    printf '{"jsonrpc":"2.0","id":1,"result":{"sub_dag":{"leader":{"author":"Auth1x","latest_execution_block":{"number":%s,"hash":"0x{}"}},"headers":[{"author":"Auth1x","epoch":42,"round":12,"latest_execution_block":{"number":%s,"hash":"0x}}"}}],"note":"\\"number\\":7","commit_timestamp":1762257600},"number":%s,"parent_hash":"0x00"}}' \
        "$(( $1 + 9 ))" "$(( $1 + 8 ))" "$1"
}

n="$(hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"sub_dag":{"latest_execution_block":{"number":999}},"number":12}}')"
check "header: a nested latest_execution_block.number first, the top-level one taken" "12" "$n"
n="$(hb_header_number "$(hdr_json 5123)")"
check "header: a fixture-shaped answer" "5123" "$n"
n="$(hb_header_number '{"jsonrpc":"2.0","id":1,"result" : { "number" : 42 , "sub_dag" : {} } }')"
check "header: whitespace around the key and value" "42" "$n"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"sub_dag":{"latest_execution_block":{"number":999}}}}' >/dev/null
check_rc "header: no number at depth 2 is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"number":5,"message":"x"}}' >/dev/null
check_rc "header: an error answer is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"number":5}' >/dev/null
check_rc "header: a missing closing brace is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"number":5}}}' >/dev/null
check_rc "header: an extra closing brace is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"note":"{","number":5}}' >/dev/null
check_rc "header: a brace in a string still counts the real braces" 0 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"number":"5"}}' >/dev/null
check_rc "header: a string number is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":[{"number":5}]}' >/dev/null
check_rc "header: a result that is an array is unreadable" 1 "$?"
hb_header_number '' >/dev/null
check_rc "header: an empty answer is unreadable" 1 "$?"
hb_header_number '{"jsonrpc":"2.0","id":1,"result":{"number":12.5}}' >/dev/null
check_rc "header: a number that is not a whole number is unreadable" 1 "$?"

# norm KIND URL [ALLOW] -- "ok <url>" or "err <HB_ERR>".
norm() {
    if hb_target_normalize "$@" >/dev/null; then
        printf 'ok %s\n' "$HB_URL"
    else
        printf 'err %s\n' "$HB_ERR"
    fi
}
check "kuma: the UI form loses its query" "ok https://kuma.example.org/api/push/AbCd1234" \
    "$(norm kuma 'https://kuma.example.org/api/push/AbCd1234?status=up&msg=OK&ping=')"
check "kuma: a fragment goes too" "ok https://kuma.example.org/api/push/AbCd1234" \
    "$(norm kuma 'https://kuma.example.org/api/push/AbCd1234#status')"
check "kuma: a trailing slash goes" "ok https://kuma.example.org/kuma/api/push/tok_-9" \
    "$(norm kuma 'https://kuma.example.org/kuma/api/push/tok_-9/')"
check "kuma: a token shorter than 4 is refused" "err kuma: not an /api/push/<token> URL" \
    "$(norm kuma 'https://kuma.example.org/api/push/abc')"
check "kuma: no push path is refused" "err kuma: not an /api/push/<token> URL" \
    "$(norm kuma 'https://kuma.example.org/dashboard/3')"
check "healthchecks: /fail goes" "ok https://hc-ping.com/uuid-1" "$(norm healthchecks 'https://hc-ping.com/uuid-1/fail')"
check "healthchecks: /start/ goes" "ok https://hc-ping.com/uuid-1" "$(norm healthchecks 'https://hc-ping.com/uuid-1/start/')"
check "healthchecks: a query is refused" "err healthchecks: a query string or fragment is not allowed" \
    "$(norm healthchecks 'https://hc-ping.com/uuid-1?rid=1')"
check "healthchecks: a fragment is refused (its /fail ping would reach the up URL)" \
    "err healthchecks: a query string or fragment is not allowed" "$(norm healthchecks 'https://hc-ping.com/uuid-1#x')"
check "healthchecks: a fragment after /fail is refused too" \
    "err healthchecks: a query string or fragment is not allowed" "$(norm healthchecks 'https://hc-ping.com/uuid-1/fail#x')"
check "webhook: kept as given" "ok https://hooks.example.net/hook/x?a=1" "$(norm webhook 'https://hooks.example.net/hook/x?a=1')"
check "a quote is refused" "err url holds a quote, backslash, space or control character" \
    "$(norm webhook 'https://hooks.example.net/a"b')"
check "a backslash is refused" "err url holds a quote, backslash, space or control character" \
    "$(norm webhook 'https://hooks.example.net/a\b')"
check "a space is refused" "err url holds a quote, backslash, space or control character" \
    "$(norm webhook 'https://hooks.example.net/a b')"
check "http on a public host without allow is refused" "err http needs --allow-http (the token travels in clear text)" \
    "$(norm kuma 'http://kuma.example.org/api/push/abcd')"
check "http on a public host with allow" "ok http://kuma.example.org/api/push/abcd" \
    "$(norm kuma 'http://kuma.example.org/api/push/abcd' 1)"
check "http on 127.0.0.1" "ok http://127.0.0.1:18080/api/push/vmtest1" "$(norm kuma 'http://127.0.0.1:18080/api/push/vmtest1')"
check "http on [::1]" "ok http://[::1]:8080/hook" "$(norm webhook 'http://[::1]:8080/hook')"
check "http on localhost" "ok http://localhost/hook" "$(norm webhook 'http://localhost/hook')"
check "http with loopback userinfo on a public host is refused" "err http needs --allow-http (the token travels in clear text)" \
    "$(norm webhook 'http://127.0.0.1@hooks.example.net/hook')"
check "another scheme is refused" "err url must start with https://" "$(norm webhook 'ftp://hooks.example.net/x')"
check "no host is refused" "err url has no host" "$(norm webhook 'https:///x')"
u512="https://hooks.example.net/$(printf '%0486d' 0)"
check "512 characters pass" "512" "$(hb_target_normalize webhook "$u512" | tr -d '\n' | wc -c | tr -d ' ')"
check "513 characters are refused" "err url longer than 512 characters" "$(norm webhook "${u512}0")"
check "an empty url is refused" "err empty url" "$(norm webhook '')"
check "a bad kind is refused" "err unknown provider 'slack' (kuma, healthchecks or webhook)" "$(norm slack 'https://x.example/y')"
check "a kind that looks like a URL is not echoed" "err unknown provider (kuma, healthchecks or webhook)" \
    "$(norm 'https://x.example/SECRETkind' 'y')"
check "url host: port kept, userinfo dropped" "kuma.example.org:8443" "$(hb_url_host 'https://u:SECRETpw@kuma.example.org:8443/api/push/x')"
check "url host: IPv6 brackets kept" "[::1]:8080" "$(hb_url_host 'http://[::1]:8080/hook')"
check "url host: only the characters a push record allows" "host.example.org:8443" \
    "$(hb_url_host 'https://ho%st!.example.org:8443/x')"
check "hex: chain id" "2017" "$(hb_hex2dec 0x7e1)"
hb_hex2dec 0xffffffffffffffff >/dev/null
check_rc "hex: above the 64-bit range is refused" 1 "$?"
check "json string escaping" '"a\"b\\c"' "$(hb_json_str 'a"b\c')"
check "clean: filtered and cut" "x(touch y) _" "$(hb_clean 'x$(touch y) é@_')"

printf 'version=2.1.0\nlast_status=up\nlast_block=\npush_1=kuma ok 200 kuma.example.org\n' > "$T/lib/st"
check "state get: a value" "up" "$(hb_state_get "$T/lib/st" last_status)"
v="$(hb_state_get "$T/lib/st" last_block)"
check_rc "state get: an empty value is present" 0 "$?"
hb_state_get "$T/lib/st" mono >/dev/null
check_rc "state get: an absent key" 1 "$?"
hb_state_get "$T/lib/st" bogus >/dev/null
check_rc "state get: an unknown key" 1 "$?"
printf 'last_status=up\nlast_reason=$(touch %s/lib/sentinel)\n' "$T" > "$T/lib/st2"
hb_state_get "$T/lib/st2" last_status >/dev/null
check_rc "state get: an invalid value makes the whole file invalid" 1 "$?"
printf 'last_status=up\nlast_status=down\n' > "$T/lib/st3"
hb_state_get "$T/lib/st3" last_status >/dev/null
check_rc "state get: a repeated key makes the file invalid" 1 "$?"
ln -s "$T/lib/st" "$T/lib/st4"
hb_state_get "$T/lib/st4" last_status >/dev/null
check_rc "state get: a symlink is not followed" 1 "$?"
check "state get: nothing ran" "absent" "$([[ -e "$T/lib/sentinel" ]] && echo present || echo absent)"

# --- runner mode: stand-ins ------------------------------------------------

cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
# systemctl stand-in: logs its argv and prints the SVC_* fields.
printf '%s\n' "$*" >> "$HBT/systemctl.log"
if [ -n "${TN_BLS_PASSPHRASE+x}" ]; then
    printf 'systemctl\n' >> "$HBT/env-leak"
fi
[ "${SVC_FAIL:-0}" = 1 ] && exit 1
[ "${SVC_EMPTY:-0}" = 1 ] && exit 0
printf 'LoadState=%s\n' "${SVC_LOAD:-loaded}"
[ "${SVC_LOAD:-loaded}" = not-found ] && { printf 'ActiveState=inactive\nSubState=dead\nNRestarts=0\n'; exit 0; }
printf 'ActiveState=%s\nSubState=%s\nNRestarts=%s\nActiveEnterTimestampMonotonic=%s\nStateChangeTimestampMonotonic=%s\n' \
    "${SVC_ACTIVE:-active}" "${SVC_SUB:-running}" "${SVC_NRESTARTS:-0}" "${SVC_AET:-0}" "${SVC_SCT:-0}"
STUB

cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
# curl stand-in: never calls the real curl. Logs its argv, then answers a push
# (-K), the health endpoint or a JSON-RPC call from files under $HBT.
d="$HBT"
printf '%s\n' "$*" >> "$d/argv.log"
if [ -n "${TN_BLS_PASSPHRASE+x}" ]; then
    printf 'curl\n' >> "$d/env-leak"
fi
kfile="" url="" data="" wfmt="" out="" get=0 hdr="" ue=""
while [ $# -gt 0 ]; do
    case "$1" in
        -K) kfile="$2"; shift ;;
        --url) url="$2"; shift ;;
        -G) get=1 ;;
        --data|--data-raw|--data-binary) data="$2"; shift ;;
        --data-urlencode) ue="${ue:+$ue&}$2"; shift ;;
        -H) hdr="$2"; shift ;;
        -w) wfmt="$2"; shift ;;
        -o) out="$2"; shift ;;
        -X|-A|--proto|--connect-timeout|--max-time|--max-filesize) shift ;;
        -q|-sS) ;;
        -*) printf 'unknown option %s\n' "$1" >> "$d/stub-errors" ;;
        *) url="$1" ;;
    esac
    shift
done
# emit BODY CODE -- the body (unless -o) and the -w text.
emit() {
    [ -n "$out" ] || printf '%s' "$1"
    w="$(printf '%s' "$wfmt" | sed -e "s/%{http_code}/$2/g" -e 's/%{time_total}/0.012345/g')"
    printf '%b' "$w"
}
# answer FILE DEFAULT_BODY -- "rc N", "code N" or "body TEXT" from FILE.
answer() {
    if [ -f "$1" ]; then
        read -r kind val < "$1"
        case "$kind" in
            rc) emit "" 000; exit "$val" ;;
            code) emit "" "$val"; exit 0 ;;
            body) emit "$val" 200; exit 0 ;;
        esac
    fi
    emit "$2" 200
    exit 0
}
if [ -n "$kfile" ]; then
    url="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$kfile")"
    host="$(printf '%s' "$url" | sed -e 's|^[a-z]*://||' -e 's|[/?#].*||' -e 's|.*@||')"
    m=GET
    [ "$get" = 1 ] || [ -z "$data" ] || m=POST
    printf '%s %s|%s|%s|%s\n' "$m" "$url" "$ue" "$data" "$hdr" >> "$d/pushes"
    answer "$d/fail/$host" '{"ok":true}'
fi
case "$url" in
    */health/network)
        [ -f "$d/health" ] || exit 7
        answer "$d/health" ""
        ;;
esac
m="$(printf '%s' "$data" | sed -n 's/.*"method":"\([A-Za-z_]*\)".*/\1/p')"
printf '%s\n' "$m" >> "$d/rpc.log"
if [ -f "$d/rpc/$m.fail" ]; then
    answer "$d/rpc/$m.fail" ""
fi
[ -f "$d/rpc/$m" ] || { emit "" 000; exit 7; }
emit "$(cat "$d/rpc/$m")" 200
STUB
chmod 0755 "$T/bin/systemctl" "$T/bin/curl"

export ALERTS_SERVICE=telcoin ALERTS_RPC_URL=http://127.0.0.1:8545 ALERTS_NETWORK=testnet \
    ALERTS_CHAIN_ID=2017 ALERTS_LABEL=node-1 ALERTS_HEALTH_PORT=43174 ALERTS_INTERVAL=60 \
    ALERTS_STALL_AFTER=180 ALERTS_INACTIVE_AFTER=900 ALERTS_RESTART_GRACE=120

KUMA='kuma https://kuma.example.org/api/push/SECRETkuma1'
HOOK='webhook https://hooks.example.net/hook/SECRETweb2'
HC='healthchecks https://hc-ping.com/SECREThc3/fail'
ALL_TEXT=""
HEADER=5123

# targets LINE... -- the targets credential.
targets() {
    printf '%s\n' "$@" > "$T/cred/targets"
}
# rpc METHOD JSON -- the answer METHOD gives.
rpc() {
    printf '%s\n' "$2" > "$T/rpc/$1"
}
rpc_result() {
    rpc "$1" "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":$2}"
}
# node_ok -- a healthy CvvActive node, active for an hour.
node_ok() {
    rm -f "$T/rpc/"* "$T/fail/"*
    rpc_result eth_chainId '"0x7e1"'
    rpc tn_latestConsensusHeader "$(hdr_json "$HEADER")"
    rpc_result tn_nodeMode '"CvvActive"'
    rpc_result eth_blockNumber '"0x12d687"'
    rpc_result tn_getCurrentEpochInfo '{"epoch":42,"epochDuration":21600}'
    printf 'code 200\n' > "$T/health"
    SVC_LOAD=loaded SVC_ACTIVE=active SVC_SUB=running SVC_NRESTARTS=0
    SVC_AET=$(( (MONO - 3600) * 1000000 ))
    SVC_SCT="$SVC_AET"
    SVC_EMPTY=0
}
# fresh -- no state, the clock at its start, a healthy node, two targets.
fresh() {
    rm -f "$T/state/state" "$T/state/.state.tmp."*
    NOW=1762257600
    MONO=10000
    HEADER=5123
    node_ok
    targets "$KUMA" "$HOOK"
}
# tick [SECONDS] -- advance both clocks (default 60).
tick() {
    NOW=$(( NOW + ${1:-60} ))
    MONO=$(( MONO + ${1:-60} ))
}
# advance -- tick and let the consensus header move on.
advance() {
    tick "${1:-60}"
    HEADER=$(( HEADER + 1 ))
    rpc tn_latestConsensusHeader "$(hdr_json "$HEADER")"
}
# run_hb -- one run; RC, OUT, ERR, STATE, PUSH1, PUSH2, RPCS. $T/argv.log holds
# the curl argv of this run only; earlier runs move to $T/argv.all.
run_hb() {
    RC=0
    : > "$T/pushes"
    : > "$T/rpc.log"
    if [[ -f "$T/argv.log" ]]; then
        cat "$T/argv.log" >> "$T/argv.all"
    fi
    : > "$T/argv.log"
    env HBT="$T" PATH="$T/bin:$PATH" STATE_DIRECTORY="$T/state" CREDENTIALS_DIRECTORY="$T/cred" \
        TN_HB_NOW="$NOW" TN_HB_MONO="$MONO" TN_HB_SERVICE_STATE="$SVC_FILE" \
        SVC_LOAD="$SVC_LOAD" SVC_ACTIVE="$SVC_ACTIVE" \
        SVC_SUB="$SVC_SUB" SVC_NRESTARTS="$SVC_NRESTARTS" SVC_AET="$SVC_AET" SVC_SCT="$SVC_SCT" \
        SVC_EMPTY="$SVC_EMPTY" "$SH" "$RUNNER" > "$T/out" 2> "$T/err" || RC=$?
    OUT="$(cat "$T/out")"
    ERR="$(cat "$T/err")"
    STATE="$(cat "$T/state/state" 2>/dev/null)"
    PUSH1="$(sed -n 1p "$T/pushes")"
    PUSH2="$(sed -n 2p "$T/pushes")"
    RPCS="$(tr '\n' ' ' < "$T/rpc.log")"
    ALL_TEXT="${ALL_TEXT}${OUT}${ERR}${STATE}"
}
# st KEY -- KEY from the state file the run wrote, through the library reader.
st() {
    hb_state_get "$T/state/state" "$1"
}
UP_MSG="CvvActive block 1234567 epoch 42"

# --- all up, then the same again --------------------------------------------

fresh
run_hb
check_rc "all up: exit 0" 0 "$RC"
check "all up: no stderr" "" "$ERR"
check "all up: the journal lines" "<5>status none -> up: ${UP_MSG}
<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "all up: kuma push" "GET https://kuma.example.org/api/push/SECRETkuma1|status=up&msg=${UP_MSG}&ping=12||" "$PUSH1"
check "all up: the exact webhook JSON" \
    "POST https://hooks.example.net/hook/SECRETweb2||{\"status\":\"up\",\"reason\":\"${UP_MSG}\",\"node\":\"node-1\",\"network\":\"testnet\",\"mode\":\"CvvActive\",\"block\":1234567,\"epoch\":42,\"ts\":1762257600,\"changed\":true}|Content-Type: application/json" \
    "$PUSH2"
check "all up: the RPC calls" "eth_chainId tn_latestConsensusHeader tn_nodeMode eth_blockNumber tn_getCurrentEpochInfo " "$RPCS"
check "all up: state written" "version=2.1.0
last_run=1762257600
mono=10000
last_status=up
status_since=10000
last_reason=${UP_MSG}
last_mode=CvvActive
last_block=1234567
last_epoch=42
last_header=5123
header_since=10000
inactive_since=
started=10000
svc_since=6400
svc_restarts=0
push_total=2
push_ok=2
push_1=kuma ok 200 kuma.example.org
push_2=webhook ok 200 hooks.example.net" "$STATE"
check "all up: state file mode 0600" "600" "$(stat -c %a "$T/state/state")"
check "all up: no temp file left" "none" \
    "$(set -- "$T/state/".state.tmp.*; if [[ -e "$1" ]]; then echo "$1"; else echo none; fi)"
check_has "all up: the systemctl query" \
    "show --no-pager -p LoadState -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestampMonotonic -p StateChangeTimestampMonotonic telcoin.service" \
    "$(cat "$T/systemctl.log")"
argv="$(cat "$T/argv.log")"
pline="$(grep -e '--proto' "$T/argv.log" | head -1)"
check "all up: the push argv" \
    "-q -sS --proto =http,https --connect-timeout 5 --max-time 10 --max-filesize 65536 -A tn-heartbeat/2.1.0 -w \n%{http_code} -G --data-urlencode status=up --data-urlencode msg=${UP_MSG} --data-urlencode ping=12" \
    "${pline% -K *}"
check "all up: the URL comes from a process substitution" "ok" \
    "$(printf '%s\n' "${pline##* -K }" | grep -Eq '^/(dev|proc/self)/fd/[0-9]+$' && echo ok)"
check_has "all up: the RPC argv" \
    "-q -sS --connect-timeout 2 --max-time 5 --max-filesize 8388608 -X POST -H Content-Type: application/json --data {\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1} -w \n%{http_code}\n%{time_total} --url http://127.0.0.1:8545" \
    "$argv"
check "all up: the stand-in saw no unknown option" "" "$(cat "$T/stub-errors" 2>/dev/null)"

advance
run_hb
check_rc "second run: exit 0" 0 "$RC"
check "second run: no status line without a change" \
    "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "second run: webhook changed false" '"changed":false' "$(printf '%s\n' "$PUSH2" | grep -o '"changed":[a-z]*')"
check "second run: counters" "4 4" "$(st push_total) $(st push_ok)"
check "second run: header tracked" "5124 10060" "$(st last_header) $(st header_since)"

# --- service states ----------------------------------------------------------

fresh
run_hb
tick
SVC_ACTIVE=inactive SVC_SUB=dead
run_hb
check_rc "inactive: exit 0 (the push went through)" 0 "$RC"
check "inactive: status change and reason" "<5>status up -> down: service telcoin inactive (dead)
<4>down: service telcoin inactive (dead) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "inactive: kuma down push" "GET https://kuma.example.org/api/push/SECRETkuma1|status=down&msg=service telcoin inactive (dead)&ping=12||" "$PUSH1"
check "inactive: state" "down service telcoin inactive (dead) 10060" "$(st last_status) $(st last_reason) $(st status_since)"
SVC_ACTIVE=failed SVC_SUB=failed
tick
run_hb
check_has "failed: down" "<4>down: service telcoin inactive (failed) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
SVC_ACTIVE=activating SVC_SUB=auto-restart
tick
run_hb
check_has "auto-restart: down" "<4>down: service telcoin inactive (auto-restart) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
run_hb
tick
SVC_ACTIVE=activating SVC_SUB=start-pre SVC_SCT=$(( (MONO - 30) * 1000000 ))
run_hb
check "activating inside the grace: up, RPC not asked" \
    "<6>up: service telcoin restarting (activating, 30s) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200|" \
    "${OUT}|${RPCS}"
check "activating: kuma push carries no ping" "GET https://kuma.example.org/api/push/SECRETkuma1|status=up&msg=service telcoin restarting (activating, 30s)||" "$PUSH1"
check "activating: webhook fields unknown" \
    "{\"status\":\"up\",\"reason\":\"service telcoin restarting (activating, 30s)\",\"node\":\"node-1\",\"network\":\"testnet\",\"mode\":\"unknown\",\"block\":null,\"epoch\":null,\"ts\":1762257660,\"changed\":false}" \
    "$(printf '%s\n' "$PUSH2" | cut -d'|' -f3)"
tick
SVC_SCT=$(( (MONO - 120) * 1000000 ))
run_hb
check_has "activating after the grace: down" "<4>down: service telcoin activating for 120s | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
tick
SVC_ACTIVE=deactivating SVC_SUB=stop-sigterm SVC_SCT=$(( (MONO - 5) * 1000000 ))
run_hb
check_has "deactivating inside the grace: up" "<6>up: service telcoin restarting (deactivating, 5s) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
run_hb
advance
SVC_NRESTARTS=1
run_hb
check_has "NRestarts rose: down" "<4>down: service telcoin restarted after a failure (NRestarts 1) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "NRestarts stored" "1" "$(st svc_restarts)"
advance
run_hb
check_has "NRestarts unchanged: up again" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
SVC_LOAD=not-found
run_hb
check_has "not-found: down" "<4>down: service telcoin not found | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
SVC_EMPTY=1
run_hb
check_has "systemctl prints nothing: the RPC checks decide" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
rm -f "$T/rpc/eth_chainId"
tick
run_hb
check_has "systemctl prints nothing: no grace for a dead RPC" "<4>down: rpc 127.0.0.1:8545 not answering (refused) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# --- the service-state file (the unit's root ExecStartPre=) ---------------------
#
# A dynamic user cannot reach the system bus, so the unit writes the node
# service's systemctl show to /run/telcoin/heartbeat-service as root before each
# run. The runner reads it when it is a regular file, not a symlink, and asks
# systemctl only when it is absent or unusable. The stand-in is set to say the
# opposite of the file, so each case shows which source decided.

# svc_file ACTIVE SUB [EXTRA_LINE] -- the file as the pre-step writes it.
svc_file() {
    {
        printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nNRestarts=0\n' "$1" "$2"
        printf 'ActiveEnterTimestampMonotonic=%s\nStateChangeTimestampMonotonic=%s\n' "$SVC_AET" "$SVC_SCT"
        if [[ -n "${3:-}" ]]; then
            printf '%s\n' "$3"
        fi
    } > "$SVC_FILE"
}
# svc_calls -- how many times the systemctl stand-in has run so far.
svc_calls() {
    if [[ -f "$T/systemctl.log" ]]; then
        wc -l < "$T/systemctl.log" | tr -d ' '
    else
        echo 0
    fi
}
UP_LINE="<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200"
DEAD_LINE="<4>down: service telcoin inactive (dead) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200"

fresh
svc_file active running
SVC_ACTIVE=inactive SVC_SUB=dead
c0="$(svc_calls)"
run_hb
check_has "state file: active in the file wins over the stand-in" "$UP_LINE" "$OUT"
check "state file: systemctl not called" "$c0" "$(svc_calls)"
check "state file: svc_since from the file" "6400" "$(st svc_since)"

tick
svc_file inactive dead
SVC_ACTIVE=active SVC_SUB=running
c0="$(svc_calls)"
run_hb
check "state file: inactive (dead) in the file is down" "<5>status up -> down: service telcoin inactive (dead)
${DEAD_LINE}" "$OUT"
check "state file: the down reason recorded" "down service telcoin inactive (dead)" "$(st last_status) $(st last_reason)"
check "state file: still no systemctl call" "$c0" "$(svc_calls)"

fresh
run_hb
tick
svc_file inactive dead
mv "$SVC_FILE" "$T/svc/real"
ln -s "$T/svc/real" "$SVC_FILE"
c0="$(svc_calls)"
run_hb
check_has "state file a symlink: ignored, systemctl decides (up)" "$UP_LINE" "$OUT"
check "state file a symlink: systemctl called once" "$(( c0 + 1 ))" "$(svc_calls)"
rm -f "$SVC_FILE" "$T/svc/real"

tick
SVC_ACTIVE=inactive SVC_SUB=dead
c0="$(svc_calls)"
run_hb
check_has "state file absent: systemctl decides (down)" "$DEAD_LINE" "$OUT"
check "state file absent: systemctl called once" "$(( c0 + 1 ))" "$(svc_calls)"

fresh
run_hb
tick
: > "$SVC_FILE"
SVC_ACTIVE=inactive SVC_SUB=dead
c0="$(svc_calls)"
run_hb
check_has "state file empty: systemctl decides" "$DEAD_LINE" "$OUT"
check "state file empty: systemctl called once" "$(( c0 + 1 ))" "$(svc_calls)"

fresh
run_hb
advance
svc_file active running "Bogus=inactive"
printf 'ActiveStateX=failed\nX=$(touch %s/svc/sentinel)\n' "$T" >> "$SVC_FILE"
SVC_ACTIVE=inactive SVC_SUB=dead
c0="$(svc_calls)"
run_hb
check_has "state file with unknown keys: those lines ignored, up" "$UP_LINE" "$OUT"
check "state file with unknown keys: systemctl not called" "$c0" "$(svc_calls)"
check "state file with unknown keys: nothing ran" "absent" "$([[ -e "$T/svc/sentinel" ]] && echo present || echo absent)"
rm -f "$SVC_FILE"

# --- RPC ------------------------------------------------------------------------

fresh
rm -f "$T/rpc/eth_chainId"
run_hb
check "rpc refused: down, later steps skipped" \
    "<5>status none -> down: rpc 127.0.0.1:8545 not answering (refused)
<4>down: rpc 127.0.0.1:8545 not answering (refused) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200|eth_chainId " \
    "${OUT}|${RPCS}"
check "rpc refused: kuma without ping" "GET https://kuma.example.org/api/push/SECRETkuma1|status=down&msg=rpc 127.0.0.1:8545 not answering (refused)||" "$PUSH1"
check "rpc refused: the exact webhook JSON" \
    "{\"status\":\"down\",\"reason\":\"rpc 127.0.0.1:8545 not answering (refused)\",\"node\":\"node-1\",\"network\":\"testnet\",\"mode\":\"unknown\",\"block\":null,\"epoch\":null,\"ts\":1762257600,\"changed\":true}" \
    "$(printf '%s\n' "$PUSH2" | cut -d'|' -f3)"
check "rpc refused: state fields unknown" "unknown||" "$(st last_mode)|$(st last_block)|$(st last_epoch)"
SVC_AET=$(( (MONO - 10) * 1000000 ))
tick
run_hb
check_has "rpc not up 70s after the start: up (grace)" "<6>up: starting: rpc not answering yet | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
tick 60
run_hb
check_has "rpc not up 130s after the start: down" "<4>down: rpc 127.0.0.1:8545 not answering (refused) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
printf 'code 500\n' > "$T/rpc/eth_chainId.fail"
rpc_result eth_chainId '"0x7e1"'
tick
run_hb
check_has "rpc http 500" "<4>down: rpc 127.0.0.1:8545 not answering (http 500) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
printf 'rc 28\n' > "$T/rpc/eth_chainId.fail"
tick
run_hb
check_has "rpc timeout" "<4>down: rpc 127.0.0.1:8545 not answering (timeout) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
rm -f "$T/rpc/eth_chainId.fail"
rpc_result eth_chainId '"zz"'
tick
run_hb
check_has "rpc malformed" "<4>down: rpc 127.0.0.1:8545 not answering (malformed) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# The starting grace ends at ALERTS_RESTART_GRACE (120 s) after the unit became active.
fresh
rm -f "$T/rpc/eth_chainId"
SVC_AET=$(( (MONO - 119) * 1000000 ))
run_hb
check_has "rpc not up 119s after the start: up (grace)" "<6>up: starting: rpc not answering yet | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
tick 1
run_hb
check_has "rpc not up 120s after the start: down" "<4>down: rpc 127.0.0.1:8545 not answering (refused) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
rpc_result eth_chainId '"0x1"'
run_hb
check_has "wrong chain: down" "<4>down: wrong chain: rpc reports 1, expected 2017 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "wrong chain: the other fields still read" "CvvActive 1234567 42" "$(st last_mode) $(st last_block) $(st last_epoch)"
advance
ALERTS_CHAIN_ID='' run_hb
check_has "no chain id configured: the check is skipped" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# --- consensus stall ------------------------------------------------------------

fresh
run_hb
tick 179
run_hb
check_has "stall: 179s at one header is up" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
tick 1
run_hb
check "stall: 180s is down" "<5>status up -> down: consensus stalled at header 5123 for 180s
<4>down: consensus stalled at header 5123 for 180s | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
tick 20
run_hb
check "stall: 200s still down, no second status line" \
    "<4>down: consensus stalled at header 5123 for 200s | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
rpc tn_latestConsensusHeader '{"jsonrpc":"2.0","id":1,"result":{"number":5'
tick 20
run_hb
check_has "stall: an unreadable header keeps the last one" "<4>down: consensus stalled at header 5123 for 220s | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
advance
run_hb
check "stall: the header moved, up again" "<5>status down -> up: ${UP_MSG}
<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
rpc_result tn_latestConsensusHeader 'null'
run_hb
tick 180
run_hb
check_has "header unreadable from the start" "<4>down: consensus header unreadable for 180s | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

fresh
rpc tn_latestConsensusHeader '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}'
run_hb
tick 600
run_hb
check_has "header method missing (-32601): check skipped" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# A restart of the node restarts the stall window: the header is measured from
# the run that saw the new activation.
fresh
run_hb
tick 170
SVC_AET=$(( (MONO - 5) * 1000000 ))
run_hb
check "stall: a restart restarts the window" "up $MONO" "$(st last_status) $(st header_since)"
tick 60
run_hb
check "stall: 60s after the restart (230s at one header) still up" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# --- CvvInactive ------------------------------------------------------------------

fresh
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
check_has "inactive mode: up at first" "<5>status none -> up: CvvInactive block 1234567 epoch 42" "$OUT"
check "inactive mode: window starts" "10000" "$(st inactive_since)"
advance 899
run_hb
check_has "inactive mode: 899s is up" "<6>up: CvvInactive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
advance 1
run_hb
check_has "inactive mode: 900s is down" "<4>down: CvvInactive for 900s: committee member not voting | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "inactive mode: webhook mode" '"mode":"CvvInactive"' "$(printf '%s\n' "$PUSH2" | grep -o '"mode":"[A-Za-z]*"')"
advance
SVC_AET=$(( (MONO - 5) * 1000000 ))
run_hb
check_has "inactive mode: a restart resets the window" "<6>up: CvvInactive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "inactive mode: window restarted" "$MONO $MONO" "$(st inactive_since) $(st started)"
rpc_result tn_nodeMode '"CvvActive"'
advance
run_hb
check "active again: window cleared" "" "$(st inactive_since)"

# An unreadable mode leaves the window as it was.
fresh
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
advance 450
rm -f "$T/rpc/tn_nodeMode"
run_hb
check "mode unreadable: up without the mode" "<6>up: block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "mode unreadable: the window kept" "unknown 10000" "$(st last_mode) $(st inactive_since)"
advance 450
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
check_has "mode unreadable: 900s from the first CvvInactive is down" \
    "<4>down: CvvInactive for 900s: committee member not voting | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# Observer clears the window, so a later CvvInactive starts a fresh one.
fresh
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
advance 600
rpc_result tn_nodeMode '"Observer"'
run_hb
check "observer: the up message" "<6>up: Observer block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "observer: webhook mode" '"mode":"Observer"' "$(printf '%s\n' "$PUSH2" | grep -o '"mode":"[A-Za-z]*"')"
check "observer: the window cleared" "Observer|" "$(st last_mode)|$(st inactive_since)"
advance 600
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
check "inactive after observer: a fresh window" "$MONO" "$(st inactive_since)"
check "inactive after observer: up" "<6>up: CvvInactive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# --- reboot -----------------------------------------------------------------------------

fresh
rpc_result tn_nodeMode '"CvvInactive"'
run_hb
advance 600
run_hb
check "before the reboot: trackers" "10600 10000 10000 10000" \
    "$(st header_since) $(st started) $(st status_since) $(st inactive_since)"
SVC_EMPTY=1
MONO=50
NOW=$(( NOW + 120 ))
run_hb
check "reboot: every tracker restarts from this run" "50 50 50 50" \
    "$(st header_since) $(st started) $(st status_since) $(st inactive_since)"
check "reboot: still up, no status line" "<6>up: CvvInactive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"

# --- health -----------------------------------------------------------------------------

fresh
printf 'code 503\n' > "$T/health"
run_hb
check_has "health 503: down" "<4>down: health 503: node reports the network unreachable | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
rm -f "$T/health"
advance
run_hb
check_has "health refused: skipped" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
printf 'code 500\n' > "$T/health"
advance
run_hb
check_has "health 500: noted" "<6>up: ${UP_MSG} (health 500) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
printf 'rc 28\n' > "$T/health"
advance
run_hb
check_has "health timeout: noted" "<6>up: ${UP_MSG} (health timeout) | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check_has "health: the query" "-q -sS --connect-timeout 2 --max-time 5 --max-filesize 65536 -o /dev/null -w %{http_code} --url http://127.0.0.1:43174/health/network" "$(cat "$T/argv.log")"

# --- state file -----------------------------------------------------------------------------

fresh
printf 'version=2.1.0\nlast_status=down\nlast_reason=$(touch %s/sentinel)\n' "$T" > "$T/state/state"
run_hb
check_rc "corrupt state: exit 0" 0 "$RC"
check "corrupt state: logged once, then a fresh run" "<4>state file invalid; starting fresh
<5>status none -> up: ${UP_MSG}
<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net ok 200" "$OUT"
check "corrupt state: the value never ran" "absent" "$([[ -e "$T/sentinel" ]] && echo present || echo absent)"
check "corrupt state: replaced by a valid file" "up 2" "$(st last_status) $(st push_total)"

fresh
printf 'last_status=up\nnode_secret=1\n' > "$T/state/state"
run_hb
check_has "unknown key: invalid" "<4>state file invalid; starting fresh" "$OUT"

fresh
printf 'last_status=down\nmono=1\n' > "$T/elsewhere"
ln -s "$T/elsewhere" "$T/state/state"
run_hb
check_has "symlinked state: treated as absent" "<5>status none -> up: ${UP_MSG}" "$OUT"
check "symlinked state: the link was replaced by a file" "file" "$([[ -L "$T/state/state" ]] && echo link || echo file)"
check "symlinked state: its target untouched" "last_status=down
mono=1" "$(cat "$T/elsewhere")"

# --- pushes -----------------------------------------------------------------------------

fresh
printf 'rc 28\n' > "$T/fail/hooks.example.net"
run_hb
check_rc "one of two targets failing: exit 0" 0 "$RC"
check_has "one failing: the log line" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net fail 000 timeout" "$OUT"
check_lacks "one failing: no every-target line" "every target failed" "$OUT"
check "one failing: state records" "kuma ok 200 kuma.example.org|webhook fail 000 timeout hooks.example.net|2 1" \
    "$(st push_1)|$(st push_2)|$(st push_total) $(st push_ok)"

printf 'code 500\n' > "$T/fail/kuma.example.org"
printf 'rc 7\n' > "$T/fail/hooks.example.net"
advance
run_hb
check_rc "every target failing: exit 1" 1 "$RC"
check "every target failing: the log lines" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org fail 500 http, 2 webhook@hooks.example.net fail 000 refused
<4>every target failed" "$OUT"
check "every target failing: state still written" "4 1 kuma fail 500 http kuma.example.org" \
    "$(st push_total) $(st push_ok) $(st push_1)"

printf 'body {"ok":false,"msg":"Monitor not found or not active."}\n' > "$T/fail/kuma.example.org"
printf 'rc 60\n' > "$T/fail/hooks.example.net"
advance
run_hb
check_has "kuma ok:false body and a TLS failure" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org fail 200 body, 2 webhook@hooks.example.net fail 000 tls" "$OUT"
printf 'rc 63\n' > "$T/fail/kuma.example.org"
printf 'rc 6\n' > "$T/fail/hooks.example.net"
advance
run_hb
check_has "too large and dns" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org fail 000 too-large, 2 webhook@hooks.example.net fail 000 dns" "$OUT"
printf 'rc 52\n' > "$T/fail/kuma.example.org"
rm -f "$T/fail/hooks.example.net"
advance
run_hb
check_has "another curl failure" "<6>up: ${UP_MSG} | 1 kuma@kuma.example.org fail 000 curl-52, 2 webhook@hooks.example.net ok 200" "$OUT"
check "state records the curl-N reason" "kuma fail 000 curl-52 kuma.example.org" "$(st push_1)"

fresh
targets "$HC"
run_hb
check "healthchecks up: the ping URL and body" "POST https://hc-ping.com/SECREThc3||up: ${UP_MSG}|" "$PUSH1"
check_has "healthchecks up: log" "<6>up: ${UP_MSG} | 1 healthchecks@hc-ping.com ok 200" "$OUT"
SVC_ACTIVE=inactive SVC_SUB=dead
tick
run_hb
check "healthchecks down: the /fail URL and body" "POST https://hc-ping.com/SECREThc3/fail||down: service telcoin inactive (dead)|" "$PUSH1"

# --- message length and filtering ----------------------------------------------------------------

fresh
long="$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)"
long="${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}${long}"
SVC_ACTIVE=failed SVC_SUB="\$(touch ${T}/sentinel2);@${long}"
run_hb
reason="$(st last_reason)"
check_rc "long sub-state: the state stays valid" 0 "$?"
check "long sub-state: the reason is cut to 200" "200" "${#reason}"
check_lacks "long sub-state: filtered" '$' "$reason"
check "long sub-state: nothing ran" "absent" "$([[ -e "$T/sentinel2" ]] && echo present || echo absent)"
line="$(printf '%s\n' "$OUT" | grep '^<4>down: ')"
check "long sub-state: the log line carries the cut reason" "<4>down: ${reason} |" "${line%% 1 kuma@*}"

# --- configuration errors ----------------------------------------------------------------

fresh
rm -f "$T/cred/targets"
run_hb
check_rc "no credential: exit 2" 2 "$RC"
check "no credential: the message" "<3>config: no targets credential" "$OUT"
check "no credential: no state written, nothing pushed" "absent|" \
    "$([[ -e "$T/state/state" ]] && echo present || echo absent)|$(cat "$T/pushes")"

: > "$T/cred/targets"
run_hb
check "empty targets: exit 2" "2 <3>config: targets credential is empty" "$RC $OUT"

targets "$KUMA" "$HOOK" "$KUMA" "$HOOK" "$KUMA" "$HOOK"
run_hb
check "six targets: exit 2" "2 <3>config: targets credential holds more than 5 lines" "$RC $OUT"

targets "$KUMA" "kuma https://kuma.example.org/status/SECRETbad4"
run_hb
check "a bad line: exit 2, no URL in the message" "2 <3>config: targets line 2 invalid: kuma: not an /api/push/<token> URL" "$RC $OUT"
check "a bad line: nothing pushed" "" "$(cat "$T/pushes")"

targets "kuma http://kuma.example.org/api/push/SECRETkuma1"
run_hb
check_rc "http on a public host in the credential (enable allowed it)" 0 "$RC"
rm -f "$T/state/state"

targets "$KUMA"
ALERTS_INTERVAL=10 run_hb
check "interval below 30: exit 2" "2 <3>config: ALERTS_INTERVAL invalid" "$RC $OUT"
ALERTS_RPC_URL='https://127.0.0.1:8545' run_hb
check "rpc url not http: exit 2" "2 <3>config: ALERTS_RPC_URL invalid" "$RC $OUT"
ALERTS_LABEL='-bad' run_hb
check "label starting with -: exit 2" "2 <3>config: ALERTS_LABEL invalid" "$RC $OUT"
ALERTS_SERVICE='' run_hb
check "no service: exit 2" "2 <3>config: ALERTS_SERVICE invalid" "$RC $OUT"
ALERTS_RESTART_GRACE=5 run_hb
check "grace below 30: exit 2" "2 <3>config: ALERTS_RESTART_GRACE invalid" "$RC $OUT"
check "config errors: no state written" "absent" "$([[ -e "$T/state/state" ]] && echo present || echo absent)"

# --- the BLS passphrase variable ---------------------------------------------------

# The stand-ins note an inherited TN_BLS_PASSPHRASE in $T/env-leak; the runner
# drops it before it starts anything.
fresh
TN_BLS_PASSPHRASE=x HBT="$T" "$T/bin/curl" -q --url http://127.0.0.1:1/x >/dev/null 2>&1
check "passphrase: the stand-in notices an inherited variable" "curl" "$(cat "$T/env-leak" 2>/dev/null)"
rm -f "$T/env-leak"
TN_BLS_PASSPHRASE=x run_hb
check_rc "passphrase in the environment: exit 0" 0 "$RC"
check "passphrase: no command the runner starts inherits it" "absent" \
    "$([[ -e "$T/env-leak" ]] && echo present || echo absent)"

# --- secrets -----------------------------------------------------------------------------

check_lacks "no token in any stdout, stderr or state" "SECRET" "$ALL_TEXT"
all_argv="$(cat "$T/argv.all" "$T/argv.log" "$T/systemctl.log")"
check_lacks "no token on any curl or systemctl command line" "SECRET" "$all_argv"
check_lacks "no -L on any curl" " -L " "$all_argv"
check_lacks "no -f on any curl" " -f " "$all_argv"

finish
