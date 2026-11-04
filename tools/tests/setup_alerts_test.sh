#!/usr/bin/env bash
# =============================================================================
# tools/tests/setup_alerts_test.sh -- setup-alerts.sh (#60) against a stubbed
# library:
#
#   --json       the done event of every action (enable, test, refresh, disable,
#                status), stdout JSON only, the exit codes 0, 1 and 3, the lock
#                each action takes (none for --status), the host baseline made
#                again after a change; on a node whose alerts are on, only the
#                --interval, --stall-after, --inactive-after and --label given
#                reach the library (--enable and --refresh), and a targets change
#                with them lists both applied items;
#   targets      --targets-stdin, TN_ALERT_TARGETS and --target reach
#                alerts_enable on its stdin, normalised (the real
#                alerts_targets_validate); --target warns once; two sources,
#                two actions, no action, an unknown argument, an option that does
#                not go with the action and a bad value are refused before
#                anything runs; TN_ALERT_TARGETS is unset before the library is
#                even sourced; a token never shows on stdout or stderr;
#   plain mode   --enable without a target source and without a terminal is
#                refused with the stdin hint; the menu asks for a target with the
#                URL hidden and echoes kind@host only;
#   library gap  a lib/ without alerts.sh and tn-heartbeat.sh exits 2 with one
#                message naming update-scripts.sh (addon_oldlib_test.sh runs the
#                old-library case).
#
#   bash tools/tests/setup_alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/setup_alerts_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/setup_alerts_test.sh
#
# The copy of setup-alerts.sh runs beside a lib/common.sh that sources the real
# lib/common.sh (and so the real lib/alerts.sh and lib/tn-heartbeat.sh), then
# replaces the update lock, the baseline refresh and the alerts_* actions with
# stand-ins that record their calls in $T/calls and return what SAT_RC,
# SAT_APPLIED and SAT_ISSUES say. An `id` stand-in answers SAT_UID (default 0).
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export SAT_DIR="$T"
mkdir -p "$T/sa/lib" "$T/bin" "$T/gap/lib" "$TN_ROOT_PREFIX/etc/telcoin" "$TN_ROOT_PREFIX/etc/systemd/system"
cp "$TN_TEST_REPO/setup-alerts.sh" "$T/sa/setup-alerts.sh"

# The stub library: the real one, then the stand-ins.
printf 'source %q\n' "$TN_TEST_REPO/lib/common.sh" > "$T/sa/lib/common.sh"
cat >> "$T/sa/lib/common.sh" <<'STUB'
_sat_log() { printf '%s\n' "$*" >> "$SAT_DIR/calls"; }
# What the library saw of TN_ALERT_TARGETS when it was sourced.
if [[ -n "${TN_ALERT_TARGETS+x}" ]]; then _sat_log "source: TN_ALERT_TARGETS set"; else _sat_log "source: TN_ALERT_TARGETS unset"; fi
addon_meta_lock() { _sat_log lock; TN_UPDATE_LOCK_KIND=test; return "${SAT_LOCK_RC:-0}"; }
addon_meta_write_begin() { _sat_log write_begin; TN_UPDATE_LOCK_KIND=test; return "${SAT_LOCK_RC:-0}"; }
tn_release_update_lock() { if [[ -n "${TN_UPDATE_LOCK_KIND:-}" ]]; then _sat_log release; fi; TN_UPDATE_LOCK_KIND=""; return 0; }
tn_host_baseline_refresh() { _sat_log "baseline fn=${1:-}"; return 0; }
_sat_env() {
    if [[ -n "${TN_ALERT_TARGETS+x}" ]]; then _sat_log "$1: TN_ALERT_TARGETS set"; fi
    if env | grep -q '^TN_ALERT_TARGETS='; then _sat_log "$1: TN_ALERT_TARGETS in env"; fi
    return 0
}
_sat_results() {
    ALERTS_RESULTS="1 kuma kuma.example.org ok 200
2 webhook hooks.example.net fail 000 timeout"
    ALERTS_NODE_STATUS=up
    ALERTS_NODE_REASON="CvvActive block 1234567 epoch 42"
}
alerts_enable() {
    _sat_env alerts_enable
    cat > "$SAT_DIR/enable.stdin"
    _sat_log "alerts_enable $1 $2 $3 fn=${4:-} label=${ALERTS_LABEL_REQ:-}"
    _alerts_say step "Enabling private alerts" "${4:-}"
    if [[ "${SAT_RC:-0}" -ne 0 ]]; then
        _alerts_say error "${SAT_ERR:-stand-in enable error}" "${4:-}"
        return "${SAT_RC}"
    fi
    if [[ "${SAT_APPLIED:-enabled}" != refreshed ]]; then _sat_results; fi
    ALERTS_APPLIED="${SAT_APPLIED:-enabled}"
    return 0
}
alerts_set_targets() {
    cat > "$SAT_DIR/set.stdin"
    _sat_log "alerts_set_targets fn=${1:-}"
    return "${SAT_RC:-0}"
}
alerts_test() {
    _sat_log "alerts_test fn=${1:-}"
    _sat_results
    _alerts_say ok "Target 1 kuma@kuma.example.org: accepted (200)" "${1:-}"
    return "${SAT_RC:-0}"
}
alerts_refresh() {
    _sat_log "alerts_refresh fn=${1:-} timing=${2:-}/${3:-}/${4:-} label=${ALERTS_LABEL_REQ:-}"
    if [[ "${SAT_RC:-0}" -ne 0 ]]; then _alerts_say error "The refresh stopped: stand-in. Run it again once that is fixed." "${1:-}"; fi
    return "${SAT_RC:-0}"
}
alerts_disable() {
    _sat_log "alerts_disable fn=${1:-}${2:+ $2}"
    return "${SAT_RC:-0}"
}
alerts_status() {
    _sat_log "alerts_status fn=${1:-}"
    ALERTS_ST_ENABLED="${SAT_ST_ENABLED-true}"
    ALERTS_ST_TIMER=active
    ALERTS_ST_LAST_RUN=1762257600
    ALERTS_ST_LAST_STATUS=up
    ALERTS_ST_LAST_REASON="CvvActive block 1234567 epoch 42"
    ALERTS_ST_RUNNER_VERSION=2.1.0
    ALERTS_RESULTS="1 kuma kuma.example.org ok 200"
    _alerts_say log "Private alerts: on" "${1:-}"
    return "${SAT_ISSUES:-0}"
}
STUB

# Stand-ins on PATH: id answers SAT_UID; systemctl and curl must never run.
printf '#!/bin/sh\necho "${SAT_UID:-0}"\n' > "$T/bin/id"
for c in systemctl curl; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >> "$SAT_DIR/calls"\nexit 0\n' "$c" > "$T/bin/$c"
done
chmod 0755 "$T/bin/"*

META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"
TIMER="$TN_ROOT_PREFIX/etc/systemd/system/telcoin-heartbeat.timer"
UNIT="$TN_ROOT_PREFIX/etc/systemd/system/telcoin-heartbeat.service"
TOK="sattoken0123456789"
KUMA="https://kuma.example.org/api/push/${TOK}?status=up&msg=OK&ping="
KUMA_N="https://kuma.example.org/api/push/${TOK}"
HOOK="https://hooks.example.net/hook/${TOK}x"

# reset_host [META_TEXT] -- a node with .node-meta and no alerts installed.
reset_host() {
    printf '%s\n' "${1:-NETWORK=testnet
OWNERSHIP_LAYOUT=2}" > "$META"
    rm -f "$TIMER" "$UNIT"
}

# run_sa ARGS... -- run the copy; stdin from SAT_STDIN (default /dev/null). Sets RC,
# OUT (stdout), ERR (stderr), CALLS and DONE (the last stdout line).
run_sa() {
    : > "$T/calls"
    rm -f "$T/enable.stdin" "$T/set.stdin"
    RC=0
    ( cd "$T/sa" && PATH="$T/bin:$PATH" bash ./setup-alerts.sh "$@" ) \
        >"$T/out" 2>"$T/err" <"${SAT_STDIN:-/dev/null}" || RC=$?
    OUT="$(cat "$T/out")"
    ERR="$(cat "$T/err")"
    CALLS="$(cat "$T/calls")"
    DONE="$(tail -n 1 "$T/out")"
}

# json_only NAME -- every stdout line is one JSON event, and exactly one is the done event.
json_only() {
    check "$1: stdout is JSON events only" "" \
        "$(grep -vE '^\{"event":"(step|log|ok|warn|error|done)",' "$T/out" || true)"
    check "$1: one done event, last" "1 yes" \
        "$(grep -c '"event":"done"' "$T/out") $(tail -n 1 "$T/out" | grep -q '^{"event":"done"' && echo yes)"
}

# no_token NAME -- the token appears nowhere in the output.
no_token() {
    check_lacks "$1: no token on stdout" "$TOK" "$OUT"
    check_lacks "$1: no token on stderr" "$TOK" "$ERR"
}

HAVE_PY=""
if command -v python3 >/dev/null 2>&1; then
    HAVE_PY=1
fi
# json_valid NAME -- every stdout line parses as JSON (python3), else a skip.
json_valid() {
    if [[ -z "$HAVE_PY" ]]; then
        skip "$1: stdout parses as JSON" "no python3"
        return 0
    fi
    check "$1: stdout parses as JSON" "ok" \
        "$(python3 -I -c 'import json,sys
for line in sys.stdin:
    json.loads(line)
print("ok")' < "$T/out" 2>&1)"
}

TARGETS_IN="$T/targets.in"
printf 'kuma %s\nwebhook %s\n' "$KUMA" "$HOOK" > "$TARGETS_IN"
NORM="kuma ${KUMA_N}
webhook ${HOOK}"
RESULTS_JSON='"node_status":"up","node_reason":"CvvActive block 1234567 epoch 42","targets":[{"n":1,"provider":"kuma","host":"kuma.example.org","result":"ok","code":200},{"n":2,"provider":"webhook","host":"hooks.example.net","result":"fail","code":0,"why":"timeout"}]'

# --- enable ------------------------------------------------------------------------------------
reset_host
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin
check_rc "enable: exit 0" 0 "$RC"
json_only "enable"
json_valid "enable"
check "enable: done event" \
    "{\"event\":\"done\",\"ok\":true,\"applied\":[\"alerts:enabled\"],\"network\":\"testnet\",\"interval\":60,${RESULTS_JSON},\"msg\":\"private alerts enabled\"}" \
    "$DONE"
check "enable: the calls, in order" "source: TN_ALERT_TARGETS unset
write_begin
alerts_enable 60 180 900 fn=addons_say label=
baseline fn=addons_say
release" "$CALLS"
check "enable: the targets reach alerts_enable on stdin, normalised" "$NORM" "$(cat "$T/enable.stdin" 2>/dev/null)"
check_has "enable: the step event" '{"event":"step","msg":"Enabling private alerts"}' "$OUT"
check_has "enable: the monitor advice" \
    "{\"event\":\"log\",\"msg\":\"Set the monitor's heartbeat interval to about 120 s with 1-2 retries: a node update or a restart you run yourself shows as a short down.\"}" "$OUT"
no_token "enable"

# --interval alone: stall and inactive follow it; --label reaches the library.
reset_host
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin --interval 600 --label node-7
check_rc "enable --interval 600: exit 0" 0 "$RC"
check_has "enable --interval 600: stall 3 x, inactive the stall" \
    "alerts_enable 600 1800 1800 fn=addons_say label=node-7" "$CALLS"
reset_host
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin --interval=30 --stall-after=120 --inactive-after 1000
check_has "enable: --flag=value forms, the given limits kept" \
    "alerts_enable 30 120 1000 fn=addons_say label=" "$CALLS"

# TN_ALERT_TARGETS: unset before the library is sourced, never in a child's environment.
reset_host
TN_ALERT_TARGETS="$(cat "$TARGETS_IN")" run_sa --json --enable
check_rc "enable from TN_ALERT_TARGETS: exit 0" 0 "$RC"
check_has "TN_ALERT_TARGETS: unset before the library is sourced" "source: TN_ALERT_TARGETS unset" "$CALLS"
check_lacks "TN_ALERT_TARGETS: not set when alerts_enable runs" "alerts_enable: TN_ALERT_TARGETS" "$CALLS"
check "TN_ALERT_TARGETS: the targets reach alerts_enable on stdin" "$NORM" "$(cat "$T/enable.stdin" 2>/dev/null)"
no_token "TN_ALERT_TARGETS"
# The variable is ignored (and still unset) by an action that takes no targets.
TN_ALERT_TARGETS="kuma $KUMA" run_sa --json --status
check_rc "TN_ALERT_TARGETS with --status: ignored, exit 0" 0 "$RC"
check_has "TN_ALERT_TARGETS with --status: unset all the same" "source: TN_ALERT_TARGETS unset" "$CALLS"

# --target: warns once, on stdout as a warn event.
reset_host
run_sa --json --enable --target "kuma=$KUMA" --target "webhook=$HOOK"
check_rc "enable --target: exit 0" 0 "$RC"
check "enable --target: one warning" "1" "$(grep -c '"event":"warn"' "$T/out")"
check_has "enable --target: the warning" \
    '{"event":"warn","msg":"--target puts the URL on the command line, where other local users can read it while this runs; pipe it in with --targets-stdin instead."}' "$OUT"
check "enable --target: the targets reach alerts_enable on stdin" "$NORM" "$(cat "$T/enable.stdin" 2>/dev/null)"
no_token "enable --target"

# A target the library refuses: the reason names kind@host, the run changes nothing.
reset_host
printf 'kuma https://kuma.example.org/status/%s\n' "$TOK" > "$T/bad.in"
SAT_STDIN="$T/bad.in" run_sa --json --enable --targets-stdin
check_rc "enable, bad kuma URL: exit 1" 1 "$RC"
check "enable, bad kuma URL: done" \
    '{"event":"done","ok":false,"msg":"Refused: line 1 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL. Nothing was changed."}' "$DONE"
check_lacks "enable, bad kuma URL: alerts_enable not run" "alerts_enable" "$CALLS"
no_token "enable, bad kuma URL"
# http to another host needs --allow-http.
printf 'webhook http://hooks.example.net/hook/%s\n' "$TOK" > "$T/http.in"
SAT_STDIN="$T/http.in" run_sa --json --enable --targets-stdin
check_rc "enable, http without --allow-http: exit 1" 1 "$RC"
check "enable, http without --allow-http: done" \
    '{"event":"done","ok":false,"msg":"Refused: line 1 (webhook@hooks.example.net): http needs --allow-http (the token travels in clear text). Nothing was changed."}' "$DONE"
no_token "enable, http without --allow-http"
SAT_STDIN="$T/http.in" run_sa --json --enable --targets-stdin --allow-http
check_rc "enable, http with --allow-http: exit 0" 0 "$RC"
check "enable, http with --allow-http: the target reaches alerts_enable" \
    "webhook http://hooks.example.net/hook/${TOK}" "$(cat "$T/enable.stdin" 2>/dev/null)"

# A failed enable: exit 1, done ok:false with the library's error, no baseline.
reset_host
SAT_STDIN="$TARGETS_IN" SAT_RC=1 SAT_ERR="No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again." \
    run_sa --json --enable --targets-stdin
check_rc "enable fails: exit 1" 1 "$RC"
json_only "enable fails"
check "enable fails: done" \
    '{"event":"done","ok":false,"msg":"No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again."}' "$DONE"
check_lacks "enable fails: no baseline" "baseline" "$CALLS"
check_has "enable fails: the lock released" "release" "$CALLS"
# ... and the targets file is still there: exit 3, the done message names it.
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin/alerts"
: > "$TN_ROOT_PREFIX/etc/telcoin/alerts/targets"
SAT_STDIN="$TARGETS_IN" SAT_RC=1 run_sa --json --enable --targets-stdin
check_rc "enable fails, targets file left: exit 3" 3 "$RC"
check "enable fails, targets file left: done" \
    "{\"event\":\"done\",\"ok\":false,\"msg\":\"private alerts were not enabled, and ${TN_ROOT_PREFIX}/etc/telcoin/alerts/targets, which holds the monitor URLs, could not be removed; delete it by hand: sudo shred -u ${TN_ROOT_PREFIX}/etc/telcoin/alerts/targets\"}" "$DONE"
rm -rf "$TN_ROOT_PREFIX/etc/telcoin/alerts"

# An enable on a node where alerts are on: no targets -> a refresh; targets -> a change.
reset_host "NETWORK=mainnet
ENABLE_ALERTS=true"
: > "$TIMER"
SAT_APPLIED=refreshed run_sa --json --enable --interval 120
check_rc "enable, already on, no targets: exit 0" 0 "$RC"
check "enable, already on, no targets: empty stdin" "" "$(cat "$T/enable.stdin" 2>/dev/null)"
check "enable, already on, no targets: done" \
    '{"event":"done","ok":true,"applied":["alerts:refreshed"],"network":"mainnet","interval":120,"node_status":null,"node_reason":null,"targets":[],"msg":"private alerts refreshed"}' "$DONE"
check_has "enable, already on, --interval: the interval and the thresholds it gives reach the library" \
    "alerts_enable 120 360 900 fn=addons_say label=" "$CALLS"
check_lacks "enable, already on, --interval: no warning that it is ignored" '"event":"warn"' "$OUT"
check_has "enable, already on, --interval: the monitor advice for the new interval" \
    "{\"event\":\"log\",\"msg\":\"Set the monitor's heartbeat interval to about 240 s with 1-2 retries: a node update or a restart you run yourself shows as a short down.\"}" "$OUT"
SAT_APPLIED=refreshed run_sa --json --enable
check_has "enable, already on, no value given: none reaches the library" \
    "alerts_enable    fn=addons_say label=" "$CALLS"
check_lacks "enable, already on, no value given: no advice" "Set the monitor's heartbeat interval" "$OUT"
SAT_APPLIED=refreshed run_sa --json --enable --stall-after 600 --label edge-5
check_has "enable, already on, a stall time alone: the interval and inactive time stay empty" \
    "alerts_enable  600  fn=addons_say label=edge-5" "$CALLS"
SAT_APPLIED=refreshed run_sa --json --enable --interval 90 --inactive-after 2000
check_has "enable, already on, an interval and an inactive time: the stall time follows the interval" \
    "alerts_enable 90 270 2000 fn=addons_say label=" "$CALLS"
SAT_STDIN="$TARGETS_IN" SAT_APPLIED=targets-changed run_sa --json --enable --targets-stdin
check_rc "enable, already on, targets: exit 0" 0 "$RC"
check "enable, already on, targets: done" \
    "{\"event\":\"done\",\"ok\":true,\"applied\":[\"alerts:targets-changed\"],\"network\":\"mainnet\",\"interval\":null,${RESULTS_JSON},\"msg\":\"private alerts targets changed\"}" "$DONE"
check_has "enable, already on, targets: no value reaches the library" "alerts_enable    fn=addons_say label=" "$CALLS"
SAT_STDIN="$TARGETS_IN" SAT_APPLIED="targets-changed refreshed" run_sa --json --enable --targets-stdin --interval 120 --label edge-5
check_rc "enable, already on, targets and values: exit 0" 0 "$RC"
json_valid "enable, already on, targets and values"
check "enable, already on, targets and values: both applied items" \
    "{\"event\":\"done\",\"ok\":true,\"applied\":[\"alerts:targets-changed\",\"alerts:refreshed\"],\"network\":\"mainnet\",\"interval\":120,${RESULTS_JSON},\"msg\":\"private alerts targets changed and refreshed\"}" "$DONE"
check_has "enable, already on, targets and values: the values and the label reach the library" \
    "alerts_enable 120 360 900 fn=addons_say label=edge-5" "$CALLS"
check "enable, already on, targets and values: the targets reach it on stdin" "$NORM" "$(cat "$T/enable.stdin" 2>/dev/null)"
SAT_STDIN="$TARGETS_IN" SAT_RC=1 run_sa --json --enable --targets-stdin
check_rc "enable, already on, targets refused and put back: exit 1" 1 "$RC"
check_lacks "enable, already on, targets put back: no baseline" "baseline" "$CALLS"
SAT_STDIN="$TARGETS_IN" SAT_RC=2 SAT_ERR="put-back failed" run_sa --json --enable --targets-stdin
check_rc "enable, already on, put-back failed: exit 3" 3 "$RC"
check "enable, already on, put-back failed: done" '{"event":"done","ok":false,"msg":"put-back failed"}' "$DONE"
check_has "enable, already on, put-back failed: baseline made again" "baseline fn=addons_say" "$CALLS"
SAT_RC=2 SAT_ERR="refresh stopped" run_sa --json --enable
check_rc "enable, already on, refresh stopped partway: exit 3" 3 "$RC"
check_has "enable, already on, refresh stopped partway: baseline made again" "baseline fn=addons_say" "$CALLS"
SAT_RC=1 SAT_ERR="Refused: the interval must be a whole number of seconds from 30 to 3600. Nothing was changed." \
    run_sa --json --enable --stall-after 99999
check_rc "enable, already on, a value refused: exit 1" 1 "$RC"
check "enable, already on, a value refused: done" \
    '{"event":"done","ok":false,"msg":"Refused: the interval must be a whole number of seconds from 30 to 3600. Nothing was changed."}' "$DONE"
check_lacks "enable, already on, a value refused: no baseline" "baseline" "$CALLS"
# The interval in the done event is the one alerts.env holds.
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin/alerts"
printf 'ALERTS_INTERVAL=90\n' > "$TN_ROOT_PREFIX/etc/telcoin/alerts/alerts.env"
SAT_APPLIED=refreshed run_sa --json --enable
check_has "enable, already on: the interval of alerts.env" "yes" \
    "$(printf '%s\n' "$DONE" | grep -q '"interval":90,' && echo yes)"
rm -rf "$TN_ROOT_PREFIX/etc/telcoin/alerts"

# --json --enable without a source on a node without alerts.
reset_host
run_sa --json --enable
check_rc "enable, no targets: exit 1" 1 "$RC"
check "enable, no targets: done" \
    "{\"event\":\"done\",\"ok\":false,\"msg\":\"--enable needs the targets: --targets-stdin (one '<kind> <url>' line each), TN_ALERT_TARGETS or --target kind=url. Nothing was changed.\"}" "$DONE"
# ENABLE_ALERTS set twice.
reset_host "NETWORK=testnet
ENABLE_ALERTS=false
ENABLE_ALERTS=true"
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin
check_rc "enable, ENABLE_ALERTS twice: exit 1" 1 "$RC"
check "enable, ENABLE_ALERTS twice: done" \
    '{"event":"done","ok":false,"msg":"ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."}' "$DONE"
check_lacks "enable, ENABLE_ALERTS twice: alerts_enable not run" "alerts_enable" "$CALLS"
# Not root: refused before the lock.
reset_host
SAT_STDIN="$TARGETS_IN" SAT_UID=1000 run_sa --json --enable --targets-stdin
check_rc "enable as a user: exit 1" 1 "$RC"
check "enable as a user: done" \
    '{"event":"done","ok":false,"msg":"Run setup-alerts.sh --enable as root (sudo). Nothing was changed."}' "$DONE"
check_lacks "enable as a user: no lock" "write_begin" "$CALLS"
# No node.
rm -f "$META"
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin
check_rc "enable, no .node-meta: exit 1" 1 "$RC"
check "enable, no .node-meta: done" \
    '{"event":"done","ok":false,"msg":"No Telcoin node was found on this host (no .node-meta under /etc/telcoin); run setup-node.sh first. Nothing was changed."}' "$DONE"
# The lock is held elsewhere.
reset_host
SAT_STDIN="$TARGETS_IN" SAT_LOCK_RC=1 run_sa --json --enable --targets-stdin
check_rc "enable, lock held: exit 1" 1 "$RC"
check_lacks "enable, lock held: alerts_enable not run" "alerts_enable" "$CALLS"
json_only "enable, lock held"

# --- test --------------------------------------------------------------------------------------
reset_host
: > "$UNIT"
run_sa --json --test
check_rc "test: exit 0" 0 "$RC"
json_only "test"
json_valid "test"
check "test: done" \
    "{\"event\":\"done\",\"ok\":true,\"applied\":[\"alerts:tested\"],\"network\":\"testnet\",${RESULTS_JSON},\"msg\":\"test heartbeat sent\"}" "$DONE"
check "test: the calls (the lock without the migration)" "source: TN_ALERT_TARGETS unset
lock
alerts_test fn=addons_say
release" "$CALLS"
check_has "test: the library's ok line becomes a log event" \
    '{"event":"log","msg":"Target 1 kuma@kuma.example.org: accepted (200)"}' "$OUT"
SAT_RC=1 run_sa --json --test
check_rc "test, every target failed: exit 1" 1 "$RC"
check "test, every target failed: done" \
    '{"event":"done","ok":false,"msg":"no target accepted the test heartbeat; check the URLs and this host'"'"'s network"}' "$DONE"
SAT_RC=2 run_sa --json --test
check_rc "test, no run recorded: exit 1" 1 "$RC"
check "test, no run recorded: done" \
    '{"event":"done","ok":false,"msg":"the heartbeat runner recorded no run; see what it said with: journalctl -u telcoin-heartbeat -n 20"}' "$DONE"
rm -f "$UNIT"
run_sa --json --test
check_rc "test, not set up: exit 1" 1 "$RC"
check "test, not set up: done" \
    '{"event":"done","ok":false,"msg":"Private alerts are not set up on this host; enable them first: sudo bash setup-alerts.sh --enable. Nothing was changed."}' "$DONE"
check_lacks "test, not set up: alerts_test not run" "alerts_test" "$CALLS"

# --- refresh -----------------------------------------------------------------------------------
reset_host "NETWORK=testnet
ENABLE_ALERTS=true"
: > "$TIMER"
run_sa --json --refresh --label edge-2
check_rc "refresh: exit 0" 0 "$RC"
check "refresh: done" \
    '{"event":"done","ok":true,"applied":["alerts:refreshed"],"network":"testnet","interval":null,"msg":"private alerts refreshed"}' "$DONE"
check "refresh: the calls" "source: TN_ALERT_TARGETS unset
write_begin
alerts_refresh fn=addons_say timing=// label=edge-2
baseline fn=addons_say
release" "$CALLS"
run_sa --json --refresh --interval 120
check_rc "refresh --interval: exit 0" 0 "$RC"
check_has "refresh --interval: the interval and the thresholds it gives reach the library" \
    "alerts_refresh fn=addons_say timing=120/360/900 label=" "$CALLS"
check "refresh --interval: done carries the new interval" \
    '{"event":"done","ok":true,"applied":["alerts:refreshed"],"network":"testnet","interval":120,"msg":"private alerts refreshed"}' "$DONE"
check_has "refresh --interval: the monitor advice" \
    "{\"event\":\"log\",\"msg\":\"Set the monitor's heartbeat interval to about 240 s with 1-2 retries: a node update or a restart you run yourself shows as a short down.\"}" "$OUT"
run_sa --json --refresh --stall-after=400
check_has "refresh --stall-after alone: the interval and inactive time stay empty" \
    "alerts_refresh fn=addons_say timing=/400/ label=" "$CALLS"
check_lacks "refresh without --interval: no advice" "Set the monitor's heartbeat interval" "$OUT"
SAT_RC=2 run_sa --json --refresh
check_rc "refresh stopped: exit 3" 3 "$RC"
check "refresh stopped: done carries the library's error" \
    '{"event":"done","ok":false,"msg":"The refresh stopped: stand-in. Run it again once that is fixed."}' "$DONE"
check_has "refresh stopped: baseline made again" "baseline fn=addons_say" "$CALLS"
SAT_RC=1 run_sa --json --refresh --inactive-after 100
check_rc "refresh, a value refused: exit 1" 1 "$RC"
check_lacks "refresh, a value refused: no baseline" "baseline" "$CALLS"
reset_host
run_sa --json --refresh
check_rc "refresh, alerts off: exit 0" 0 "$RC"
check "refresh, alerts off: done" \
    '{"event":"done","ok":true,"applied":[],"network":"testnet","msg":"private alerts are off; nothing to refresh"}' "$DONE"
check_lacks "refresh, alerts off: no baseline" "baseline" "$CALLS"

# --- disable -----------------------------------------------------------------------------------
reset_host
run_sa --json --disable
check_rc "disable: exit 0" 0 "$RC"
json_only "disable"
check "disable: done" \
    '{"event":"done","ok":true,"applied":["alerts:disabled"],"network":"testnet","msg":"private alerts disabled"}' "$DONE"
check "disable: the calls" "source: TN_ALERT_TARGETS unset
write_begin
alerts_disable fn=addons_say
baseline fn=addons_say
release" "$CALLS"
SAT_RC=1 run_sa --json --disable
check_rc "disable, targets file left: exit 3" 3 "$RC"
check "disable, targets file left: done" \
    "{\"event\":\"done\",\"ok\":false,\"msg\":\"private alerts were removed except ${TN_ROOT_PREFIX}/etc/telcoin/alerts/targets, which holds the monitor URLs; delete it by hand: sudo shred -u ${TN_ROOT_PREFIX}/etc/telcoin/alerts/targets\"}" "$DONE"

# --- status ------------------------------------------------------------------------------------
reset_host
SAT_ISSUES=2 run_sa --json --status
check_rc "status: exit 0" 0 "$RC"
json_only "status"
json_valid "status"
check "status: done" \
    '{"event":"done","ok":true,"applied":[],"network":"testnet","enabled":"true","timer":"active","last_run":1762257600,"last_status":"up","last_reason":"CvvActive block 1234567 epoch 42","runner_version":"2.1.0","issues":2,"targets":[{"n":1,"provider":"kuma","host":"kuma.example.org","result":"ok","code":200}],"msg":"private alerts status"}' "$DONE"
check "status: no lock" "source: TN_ALERT_TARGETS unset
alerts_status fn=addons_say" "$CALLS"
SAT_UID=1000 run_sa --json --status
check_rc "status as a user: exit 0, no root needed" 0 "$RC"
# .node-meta unreadable (a user's run): the library leaves ENABLED empty -> null.
SAT_ST_ENABLED="" SAT_UID=1000 run_sa --json --status
check "status, .node-meta unreadable: enabled is null" "yes" \
    "$(printf '%s\n' "$DONE" | grep -qF '"enabled":null,"timer":"active",' && echo yes)"
json_valid "status, .node-meta unreadable"
run_sa --status
check_rc "status, plain: exit 0" 0 "$RC"
check_has "status, plain: printed" "  ->  Private alerts: on" "$OUT"

# --- the command line --------------------------------------------------------------------------
reset_host
run_sa --json --status --disable
check_rc "two actions: exit 1" 1 "$RC"
check "two actions: done" \
    '{"event":"done","ok":false,"msg":"Give one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."}' "$DONE"
check "two actions: nothing run" "source: TN_ALERT_TARGETS unset" "$CALLS"
run_sa --enable --disable
check_rc "two actions, plain: exit 1" 1 "$RC"
run_sa --json
check_rc "no action with --json: exit 1" 1 "$RC"
check "no action with --json: done" \
    '{"event":"done","ok":false,"msg":"--json needs one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."}' "$DONE"
run_sa --json --status --bogus
check_rc "unknown argument: exit 1" 1 "$RC"
check "unknown argument: done" \
    '{"event":"done","ok":false,"msg":"Unknown argument: --bogus (see --help). Nothing was changed."}' "$DONE"
run_sa --json --enable "$KUMA"
check_rc "a stray URL: exit 1" 1 "$RC"
check "a stray URL: not shown" \
    '{"event":"done","ok":false,"msg":"Unknown argument (not shown, in case it holds a URL); see --help. Nothing was changed."}' "$DONE"
no_token "a stray URL"
SAT_STDIN="$TARGETS_IN" TN_ALERT_TARGETS="kuma $KUMA" run_sa --json --enable --targets-stdin
check_rc "two target sources (stdin, environment): exit 1" 1 "$RC"
check "two target sources: done" \
    '{"event":"done","ok":false,"msg":"Give the targets one way: --targets-stdin, --target or TN_ALERT_TARGETS. Nothing was changed."}' "$DONE"
check "two target sources: nothing run" "source: TN_ALERT_TARGETS unset" "$CALLS"
SAT_STDIN="$TARGETS_IN" run_sa --json --enable --targets-stdin --target "kuma=$KUMA"
check_rc "two target sources (stdin, --target): exit 1" 1 "$RC"
no_token "two target sources"
run_sa --json --status --interval 60
check_rc "--interval with --status: exit 1" 1 "$RC"
check "--interval with --status: done" \
    '{"event":"done","ok":false,"msg":"--interval goes with --enable or --refresh (the menu asks for the interval). Nothing was changed."}' "$DONE"
run_sa --json --test --stall-after 600
check_rc "--stall-after with --test: exit 1" 1 "$RC"
check_lacks "--stall-after with --test: nothing run" "alerts_" "$CALLS"
run_sa --json --disable --inactive-after 900
check_rc "--inactive-after with --disable: exit 1" 1 "$RC"
run_sa --json --disable --targets-stdin
check_rc "--targets-stdin with --disable: exit 1" 1 "$RC"
run_sa --json --test --label x1
check_rc "--label with --test: exit 1" 1 "$RC"
run_sa --json --status --allow-http
check_rc "--allow-http with --status: exit 1" 1 "$RC"
run_sa --json --enable --interval
check_rc "--interval without a value: exit 1" 1 "$RC"
check "--interval without a value: done" \
    '{"event":"done","ok":false,"msg":"--interval needs a value. Nothing was changed."}' "$DONE"
run_sa --json --enable --interval soon
check_rc "--interval not a number: exit 1" 1 "$RC"
run_sa --json --enable --label -bad
check_rc "--label starting with a dash: exit 1" 1 "$RC"
run_sa --json --enable --label "bad label"
check_rc "--label with a space: exit 1" 1 "$RC"
run_sa --json --enable --target kuma
check_rc "--target without kind=url: exit 1" 1 "$RC"
: > "$T/empty.in"
SAT_STDIN="$T/empty.in" run_sa --json --enable --targets-stdin
check_rc "--targets-stdin with nothing on stdin: exit 1" 1 "$RC"
check "--targets-stdin with nothing on stdin: done" \
    '{"event":"done","ok":false,"msg":"--targets-stdin: no targets on stdin. Nothing was changed."}' "$DONE"
run_sa --help
check_rc "--help: exit 0" 0 "$RC"
check_has "--help: the usage" "USAGE:" "$OUT"
check_has "--help: the values of a node whose alerts are on" \
    "On a node whose alerts are on, --enable and --refresh change only what the" "$OUT"
check "--help: the refresh with an interval" "yes" \
    "$(printf '%s\n' "$OUT" | grep -qF -- '--json --refresh --interval 120' && echo yes)"
check_lacks "--help: no comment marks" "# " "$(printf '%s\n' "$OUT" | head -n 3)"
check "--help: nothing run" "source: TN_ALERT_TARGETS unset" "$CALLS"

# --- plain mode --------------------------------------------------------------------------------
reset_host
run_sa --enable
check_rc "plain --enable, no terminal, no targets: exit 1" 1 "$RC"
check_has "plain --enable, no terminal: the stdin hint" \
    "  [ERROR] --enable needs the targets: pipe them in with --targets-stdin (one '<kind> <url>' line each), or run this from a terminal to type them. Nothing was changed." "$ERR"
check_lacks "plain --enable, no terminal: alerts_enable not run" "alerts_enable" "$CALLS"
SAT_STDIN="$TARGETS_IN" run_sa --enable --targets-stdin
check_rc "plain --enable --targets-stdin: exit 0" 0 "$RC"
check_has "plain --enable: the advice" \
    "  ->  Set the monitor's heartbeat interval to about 120 s with 1-2 retries: a node update or a restart you run yourself shows as a short down." "$OUT"
no_token "plain --enable"

# The menu: enable one kuma target (the URL typed after a refused one), then exit.
reset_host
printf '%s\n' 2 1 "https://kuma.example.org/nopush/${TOK}" "$KUMA" n 45 "" 7 > "$T/menu.in"
SAT_STDIN="$T/menu.in" run_sa
check_rc "menu enable: exit 0" 0 "$RC"
check_has "menu enable: the refusal names no URL" \
    "  [WARN] kuma: not an /api/push/<token> URL; enter it again, or press Enter to stop." "$OUT"
check_has "menu enable: kind@host echoed" "  [OK]  Target 1: kuma@kuma.example.org" "$OUT"
check_has "menu enable: the interval asked, stall and inactive derived" \
    "alerts_enable 45 180 900 fn=addons_say label=" "$CALLS"
check "menu enable: the target reached alerts_enable" "kuma ${KUMA_N}" "$(cat "$T/enable.stdin" 2>/dev/null)"
check "menu enable: the lock, then the migration, then released once" "lock write_begin release" \
    "$(printf '%s\n' "$CALLS" | grep -E '^(lock|write_begin|release)$' | tr '\n' ' ' | sed 's/ $//')"
no_token "menu enable"
# The menu on a node with alerts on: change the targets, disable, status, exit.
reset_host "NETWORK=testnet
ENABLE_ALERTS=true"
: > "$TIMER"
printf '%s\n' 3 3 "$HOOK" n "" 6 y "" 1 "" 7 > "$T/menu.in"
SAT_STDIN="$T/menu.in" run_sa
check_rc "menu change, disable, status: exit 0" 0 "$RC"
check "menu change, disable, status: the calls" "source: TN_ALERT_TARGETS unset
lock
write_begin
alerts_set_targets fn=addons_say
baseline fn=addons_say
write_begin
alerts_disable fn=addons_say
baseline fn=addons_say
alerts_status fn=addons_say
release" "$CALLS"
check "menu change: the new target reached alerts_set_targets" "webhook ${HOOK}" "$(cat "$T/set.stdin" 2>/dev/null)"
check_has "menu change: kind@host echoed" "  [OK]  Target 1: webhook@hooks.example.net" "$OUT"
no_token "menu change"
# Enable on a node where alerts are on points to the other items; nothing runs.
printf '%s\n' 2 "" 7 > "$T/menu.in"
SAT_STDIN="$T/menu.in" run_sa
check_has "menu enable, already on: the pointer" \
    "  ->  Private alerts are on already. Pick 3 to change the targets, or 5 to refresh them after a script update." "$OUT"
check_lacks "menu enable, already on: alerts_enable not run" "alerts_enable" "$CALLS"
# The menu as a user: refused.
printf '7\n' > "$T/menu.in"
SAT_STDIN="$T/menu.in" SAT_UID=1000 run_sa
check_rc "menu as a user: exit 1" 1 "$RC"
check_has "menu as a user: the message" "  [ERROR] Run setup-alerts.sh as root (sudo). Nothing was changed." "$ERR"

# --- a library gap -----------------------------------------------------------------------------
cp "$TN_TEST_REPO/setup-alerts.sh" "$T/gap/setup-alerts.sh"
for f in "$TN_TEST_REPO"/lib/*; do
    case "${f##*/}" in
        alerts.sh|tn-heartbeat.sh) ;;
        *) cp -R "$f" "$T/gap/lib/" ;;
    esac
done
RC=0
( cd "$T/gap" && PATH="$T/bin:$PATH" bash ./setup-alerts.sh --json --status ) >"$T/out" 2>"$T/err" </dev/null || RC=$?
check_rc "library gap: exit 2" 2 "$RC"
check "library gap: one message naming update-scripts.sh" "1" \
    "$(grep -cE 'lib/alerts.sh and lib/tn-heartbeat.sh are older than this script .*run update-scripts.sh' "$T/err")"
check "library gap: stdout is one done event" "1 yes" \
    "$(grep -c '' "$T/out") $(grep -q '^{"event":"done","ok":false,.*update-scripts.sh' "$T/out" && echo yes)"
RC=0
( cd "$T/gap" && PATH="$T/bin:$PATH" bash ./setup-alerts.sh --disable ) >"$T/out" 2>"$T/err" </dev/null || RC=$?
check_rc "library gap, plain: exit 2" 2 "$RC"
check "library gap, plain: nothing on stdout" "" "$(cat "$T/out")"

finish
