#!/usr/bin/env bash
# tools/tests/update_guard_test.sh -- update-node.sh around the stop: the
# committee quorum guard runs before the epoch wait (also with --no-epoch-wait)
# and its refusal stops the apply before the node is stopped; a duplicated
# RPC_PORT stops detect_node instead of guessing a port; json_prepare_docker
# composes a bare tag against the network's repository and refuses any other
# image before it pulls, logging the pull to a fresh file; a run that ends
# with the node stopped says so in its exit trap. A copy of
# update-node.sh without its last line is sourced at the top level. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/root/etc/telcoin" "$T/root/etc/systemd/system"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common
META="$T/root/etc/telcoin/.node-meta"
printf 'NETWORK=testnet\nRPC_PORT=8545\n' > "$META"
: > "$T/root/etc/systemd/system/telcoin.service"

GUARD_RC=0 WAITED=no
tn_committee_down_guard() { GUARDED=yes; return "$GUARD_RC"; }
tn_wait_restart_window() { WAITED=yes; return 0; }
SERVICE_NAME=telcoin JSON_MODE=false

GUARDED=no WAITED=no GUARD_RC=1
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "refused guard: rc 1, no wait" "1 yes no" "$rc $GUARDED $WAITED"
GUARDED=no WAITED=no GUARD_RC=0
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "allowed guard: waits" "0 yes yes" "$rc $GUARDED $WAITED"
GUARDED=no WAITED=no GUARD_RC=2 NO_EPOCH_WAIT=true
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "--no-epoch-wait still runs the guard" "1 yes no" "$rc $GUARDED $WAITED"
NO_EPOCH_WAIT=false

# The apply paths stop the node only after update_epoch_wait succeeds.
check "every update_epoch_wait call stops the apply on refusal" "4" \
    "$(grep -c 'update_epoch_wait || ' "$TN_TEST_REPO/update-node.sh")"

# detect_node: a duplicated RPC_PORT stops it.
printf 'NETWORK=testnet\nRPC_PORT=8545\nRPC_PORT=9545\n' > "$META"
rc=0; ( RPC_URL=""; detect_node ) >/dev/null 2>&1 || rc=$?
check_rc "duplicated RPC_PORT stops detect_node" 1 "$rc"
printf 'NETWORK=testnet\nRPC_PORT=9545\n' > "$META"
RPC_URL=""; detect_node >/dev/null 2>&1
check "single RPC_PORT is used" "http://127.0.0.1:9545" "$RPC_URL"

# json_prepare_docker: which images reach docker pull.
JSON_MODE=true
json_emit() { printf '%s\n' "$1" >> "$T/json.log"; }
detect_current_docker_image() { echo "us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri"; }
write_pending_state() { cat > "$T/pending"; }
storage_migration_begin() { return 0; }
docker() { if [[ "$1" == pull ]]; then printf '%s\n' "$2" > "$T/pulled"; fi; return 0; }
prep_case() {  # prep_case NAME RC ARG PULLED
    local rc=0
    rm -f "$T/pulled"
    json_prepare_docker "$3" >/dev/null 2>&1 || rc=$?
    check "$1" "$2 $4" "$rc $(cat "$T/pulled" 2>/dev/null || echo none)"
}
REPO="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
prep_case "bare release tag composed on the testnet repository" 0 v0.16.0-adiri "${REPO}:v0.16.0-adiri"
prep_case "full release reference accepted" 0 "${REPO}:v0.16.0-adiri" "${REPO}:v0.16.0-adiri"
prep_case "other registry refused before the pull" 1 "docker.io/library/busybox:v0.16.0-adiri" none
prep_case "non-release tag refused before the pull" 1 "v0.16.0-adiri-hotfix" none
prep_case "leading dash refused" 1 "--help" none
check_lacks "pull log is not a fixed /tmp name" "/tmp/tn-update-build.log" "$(cat "$TN_TEST_REPO/update-node.sh")"
# update_node_log_dir: an observability host's JSON logs move off the root-owned dir.
LF="$T/tn-start"
NETWORK=testnet DATA_DIR=/var/lib/telcoin PASSPHRASE_METHOD=stdin LOG_TARGET=file
tn_node_launch_target() { printf 'telcoin source %s\n' "$LF"; }
tn_root_dir_ok() { return 0; }
getent() { return 0; }
install() { printf '%s\n' "$*" > "$T/install.log"; return 0; }
tn_launch_flag_set() { printf '%s %s\n' "$2" "$3" > "$T/flag.log"; return 0; }
meta_set() { printf '%s=%s\n' "$1" "$2" > "$T/metaset.log"; return 0; }
nld_case() {  # nld_case NAME META ARGS EXPECTED-FLAG-LOG
    rm -f "$T/flag.log" "$T/metaset.log"
    printf '%s\n' "$2" > "$META"
    _tn_start_script_text source /opt/telcoin/telcoin-network "$3" > "$LF" 2>/dev/null
    update_node_log_dir >/dev/null 2>&1
    check "$1" "$4" "$(cat "$T/flag.log" 2>/dev/null || echo none)"
}
OBS="--datadir /var/lib/telcoin --http --log.file.format json --log.file.directory /var/log/telcoin"
nld_case "obs host on the old log dir: moved to /var/log/telcoin/node" \
    "$(printf 'NETWORK=testnet\nENABLE_OBSERVABILITY=true')" "$OBS" "--log.file.directory /var/log/telcoin/node"
check "obs host: NODE_LOG_DIR recorded" "NODE_LOG_DIR=/var/log/telcoin/node" "$(cat "$T/metaset.log" 2>/dev/null)"
check_has "obs host: dir made for the service user, group telcoin-log, 0750" "yes" \
    "$(grep -q -- '-g telcoin-log -m 0750 -- /var/log/telcoin/node' "$T/install.log" && echo yes)"
nld_case "NODE_LOG_DIR from .node-meta wins" \
    "$(printf 'NETWORK=testnet\nENABLE_OBSERVABILITY=true\nNODE_LOG_DIR=/var/log/telcoin/n2')" "$OBS" "--log.file.directory /var/log/telcoin/n2"
nld_case "observability off: untouched" "NETWORK=testnet" "$OBS" none
nld_case "already elsewhere: untouched" "$(printf 'NETWORK=testnet\nENABLE_OBSERVABILITY=true')" \
    "--datadir /var/lib/telcoin --http --log.file.directory /var/log/telcoin/node" none
unset -f tn_node_launch_target tn_root_dir_ok getent install tn_launch_flag_set meta_set

# --- update_on_exit: a run that ends with the node stopped says so -------------------
NODE_STATE=stopped
systemctl() { case "$1" in is-active) [[ "$NODE_STATE" == running ]] ;; *) return 0 ;; esac; }
tn_release_update_lock() { return 0; }
# (json_emit is the recording stub above: the JSON stream lands in json.log.)
exit_case() {  # exit_case JSON-MODE RC -> OUT (what the terminal shows), JS (the JSON stream)
    : > "$T/json.log"
    ( JSON_MODE="$1"; JSON_DONE_SENT=false; trap update_on_exit EXIT; exit "$2" ) > "$T/out" 2>&1
    OUT="$(cat "$T/out")"
    JS="$(cat "$T/json.log")"
}
exit_case false 143
check "TERM with the node stopped: says it is stopped and how to start it" "yes yes" \
    "$([[ "$OUT" == *"telcoin is stopped"* ]] && echo yes || echo no) $([[ "$OUT" == *"sudo systemctl start telcoin"* ]] && echo yes || echo no)"
exit_case true 143
check "--json, TERM with the node stopped: one done, then the error event" "1 yes" \
    "$(printf '%s\n' "$JS" | grep -c '"event":"done"') $(printf '%s\n' "$JS" | tail -n 1 | grep -q '"event":"error".*telcoin is stopped' && echo yes || echo no)"
NODE_STATE=running
exit_case false 143
check "TERM with the node running: no stopped message" no "$([[ "$OUT" == *"is stopped"* ]] && echo yes || echo no)"
NODE_STATE=stopped
exit_case false 0
check "a run that ends well says nothing about a stopped node" no "$([[ "$OUT" == *"is stopped"* ]] && echo yes || echo no)"
unset -f systemctl tn_release_update_lock
finish
