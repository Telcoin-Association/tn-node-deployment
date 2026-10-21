#!/usr/bin/env bash
# tools/tests/listener_env_test.sh -- edit-config.sh's launch editors without
# perl or sed on generated files: set_listener_var rewrites node.env only (and
# moves an older install to node.env first), set_verbosity re-renders the start
# script with only the -v word changed, and set_rpc_addr changes only the bind
# words (plus the public RPC limits for 0.0.0.0) and refuses any other value,
# including ones holding /, & or a line break. set_field keeps a listener on
# the advertised external port .node-meta records. perl on PATH fails loudly. A copy
# of edit-config.sh without its last line is sourced at the top level; root
# writes go straight to the test dir. Maintainer tooling (not updater-tracked).
# bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/bin" "$T/root/etc/telcoin" "$T/root/etc/systemd/system" "$T/root/usr/local/libexec/telcoin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
printf '#!/bin/sh\necho "perl called: $*" >> "%s/perl.log"\nexit 99\n' "$T" > "$T/bin/perl"
chmod 0755 "$T/bin/perl"
PATH="$T/bin:$PATH"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common

# Root writes land in the test dir; backups are only recorded.
tn_write_root_file() { cat > "$1"; }
_tn_root_binary_ok() { return 0; }
resolve_launch_file() { return 0; }
edit_backup() { grep -qxF -- "$1" "$T/backups" 2>/dev/null || printf '%s\n' "$1" >> "$T/backups"; return 0; }

P=/ip4/10.0.0.5/udp/49590/quic-v1
W=/ip4/10.0.0.5/udp/49594/quic-v1
ENVF="$T/root/etc/telcoin/node.env"
TARGET_SERVICE="telcoin"
TARGET_SERVICE_FILE="$T/root/etc/systemd/system/telcoin.service"
TARGET_LAUNCH_FILE="$T/root/usr/local/libexec/telcoin/tn-start"
NETWORK=testnet DATA_DIR=/var/lib/telcoin PASSPHRASE_METHOD=stdin LOG_TARGET=file
printf 'NETWORK=testnet\nINSTALL_METHOD=source\nDATA_DIR=/var/lib/telcoin\n' > "$T/root/etc/telcoin/.node-meta"
ARGS="--datadir /var/lib/telcoin --log.stdout.format log-fmt -vvv --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1"
fresh() {
    _tn_node_env_text "$P" "$W" > "$ENVF"
    _tn_start_script_text source /opt/telcoin/telcoin-network "$ARGS" > "$TARGET_LAUNCH_FILE"
    printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$TARGET_SERVICE_FILE"
    rm -f "$T/backups" "$T/perl.log"
}
same() { cmp -s "$1" "$2" && echo same || echo changed; }

# --- set_listener_var -------------------------------------------------------------
fresh
cp "$TARGET_LAUNCH_FILE" "$T/launch.before"; cp "$TARGET_SERVICE_FILE" "$T/unit.before"
NEWP=/ip4/10.0.0.9/udp/49590/quic-v1
rc=0; set_listener_var PRIMARY_LISTENER_MULTIADDR "$NEWP" >/dev/null 2>&1 || rc=$?
check_rc "listener: set" 0 "$rc"
check "listener: node.env has the new primary, the same worker" \
    "$(printf 'PRIMARY_LISTENER_MULTIADDR=%s\nWORKER_LISTENER_MULTIADDR=%s\nTN_RPC_ADDR=127.0.0.1' "$NEWP" "$W")" \
    "$(grep -v '^#' "$ENVF")"
check "listener: start script untouched" "same" "$(same "$T/launch.before" "$TARGET_LAUNCH_FILE")"
check "listener: unit untouched" "same" "$(same "$T/unit.before" "$TARGET_SERVICE_FILE")"
check_has "listener: node.env backed up" "$ENVF" "$(cat "$T/backups" 2>/dev/null)"
check "listener: perl never ran" "no" "$([[ -s "$T/perl.log" ]] && echo yes || echo no)"
check "listener: reader takes node.env" "$NEWP" "$(read_listener_from_launch PRIMARY_LISTENER_MULTIADDR)"
cp "$ENVF" "$T/env.before"
for bad in "/ip4/10.0.0.9/udp/49590/quic-v1;x" '/ip4/1.2.3.4/udp/1/quic-v1 $(id)' "/ip4/1.2.3.4/tcp/1" ""; do
    rc=0; set_listener_var WORKER_LISTENER_MULTIADDR "$bad" >/dev/null 2>&1 || rc=$?
    check "listener refused, node.env unchanged: '${bad}'" "1 same" "$rc $(same "$T/env.before" "$ENVF")"
done

# An install from before node.env is moved first, after its files are backed up.
fresh
rm -f "$ENVF"
tn_rerender_node_launch() { printf 'rerender\n' >> "$T/backups"; _tn_node_env_text "$P" "$W" > "$ENVF"; return 0; }
rc=0; set_listener_var WORKER_LISTENER_MULTIADDR "$W" >/dev/null 2>&1 || rc=$?
check_rc "older install: moved, then set" 0 "$rc"
check "older install: backups (both start-script paths too) before the move" \
    "$(printf '%s\n%s\n%s\n%s\nrerender' "$ENVF" "$TARGET_LAUNCH_FILE" "$TARGET_SERVICE_FILE" "$T/root/usr/local/libexec/telcoin/tn-start-docker")" "$(cat "$T/backups")"
tn_rerender_node_launch() { return 1; }
fresh
rm -f "$ENVF"
rc=0; set_listener_var WORKER_LISTENER_MULTIADDR "$W" >/dev/null 2>&1 || rc=$?
check "older install that cannot be moved: refused, no node.env" "1 no" "$rc $([[ -e "$ENVF" ]] && echo yes || echo no)"

# --- set_field: a listener keeps the advertised external port ----------------------
META_F="$T/root/etc/telcoin/.node-meta"
cp "$META_F" "$T/meta.saved"
printf 'EXTERNAL_PRIMARY_ADDR=/ip4/203.0.113.7/udp/49590/quic-v1\nEXTERNAL_WORKER_ADDR=/ip4/203.0.113.7/udp/49594/quic-v1\n' >> "$META_F"
fresh
field_case() {  # field_case NAME FIELD VALUE EXPECTED-RC
    cp "$ENVF" "$T/env.before"
    EDIT_LAST_ERROR=""
    rc=0; set_field "$2" "$3" >/dev/null 2>&1 || rc=$?
    if [[ "$4" == 0 ]]; then
        check "$1" "0 yes" "$rc $(grep -qxF -- "$([[ "$2" == primary_listener ]] && echo PRIMARY || echo WORKER)_LISTENER_MULTIADDR=$3" "$ENVF" && echo yes || echo no)"
    else
        check "$1" "1 same" "$rc $(same "$T/env.before" "$ENVF")"
    fi
}
field_case "set_field: primary on the advertised port" primary_listener /ip4/10.0.0.9/udp/49590/quic-v1 0
field_case "set_field: primary on another port refused" primary_listener /ip4/10.0.0.9/udp/40000/quic-v1 1
check "set_field: the refusal names the advertised port" yes \
    "$([[ "$EDIT_LAST_ERROR" == *"advertised external port 49590"* ]] && echo yes || echo no)"
check "set_field: the refusal explains a NAT port mapping and the override" yes \
    "$([[ "$EDIT_LAST_ERROR" == *"maps external UDP 49590 to local UDP 40000"*"--allow-port-mismatch"* ]] && echo yes || echo no)"
field_case "set_field: worker on the advertised port" worker_listener /ip6/::/udp/49594/quic-v1 0
field_case "set_field: worker on the primary's port refused" worker_listener /ip4/10.0.0.9/udp/49590/quic-v1 1
printf 'EXTERNAL_PRIMARY_ADDR=/ip4/203.0.113.8/udp/49590/quic-v1\n' >> "$META_F"
field_case "set_field: a duplicated external address refused" primary_listener /ip4/10.0.0.9/udp/49590/quic-v1 1
cp "$T/meta.saved" "$META_F"
printf 'EXTERNAL_PRIMARY_ADDR=/ip4/203.0.113.7/udp/49590/quic-v1\n' >> "$META_F"
TN_ALLOW_PORT_MISMATCH=1
field_case "set_field: another port with the mismatch allowed (NAT mapping)" primary_listener /ip4/10.0.0.9/udp/40000/quic-v1 0
field_case "set_field: allowed mismatch still needs a UDP port" primary_listener /ip4/10.0.0.9/udp/400000/quic-v1 1
unset TN_ALLOW_PORT_MISMATCH
cp "$T/meta.saved" "$META_F"
field_case "set_field: no external address recorded (older install) accepted" primary_listener /ip4/10.0.0.9/udp/40000/quic-v1 0

# --- set_verbosity ----------------------------------------------------------------
fresh
tn_write_start_script() { _tn_start_script_text "$@" > "$TARGET_LAUNCH_FILE"; }
cp "$TARGET_LAUNCH_FILE" "$T/launch.before"
rc=0; set_verbosity -vvvvv "$TARGET_LAUNCH_FILE" >"$T/v.log" 2>&1 || rc=$?; [[ $rc -eq 0 ]] || cat "$T/v.log"
check_rc "verbosity: set" 0 "$rc"
check "verbosity: only the -v word changed" \
    "$(sed 's/ -vvv / -vvvvv /' "$T/launch.before")" "$(cat "$TARGET_LAUNCH_FILE")"
check "verbosity: perl never ran" "no" "$([[ -s "$T/perl.log" ]] && echo yes || echo no)"
cp "$TARGET_LAUNCH_FILE" "$T/launch.before"
for bad in -vvvvvv "-v -x" "--v" "x"; do
    rc=0; set_verbosity "$bad" "$TARGET_LAUNCH_FILE" >/dev/null 2>&1 || rc=$?
    check "verbosity refused: '${bad}'" "1 same" "$rc $(same "$T/launch.before" "$TARGET_LAUNCH_FILE")"
done

# --- set_rpc_addr (edit_rpc) ------------------------------------------------------------
fresh
cp "$TARGET_LAUNCH_FILE" "$T/launch.before"; cp "$ENVF" "$T/env.before"
for bad in "127.0.0.1/8" "127.0.0.1&x" $'127.0.0.1\n--x' "0.0.0.0 --x" "1.2.3.4"; do
    rc=0; set_rpc_addr "$bad" >/dev/null 2>&1 || rc=$?
    check "rpc address refused, files unchanged: '$(printf '%s' "$bad" | tr '\n' '~')'" "1 same same" \
        "$rc $(same "$T/launch.before" "$TARGET_LAUNCH_FILE") $(same "$T/env.before" "$ENVF")"
done
rc=0; set_rpc_addr 0.0.0.0 >/dev/null 2>&1 || rc=$?
check_rc "rpc address 0.0.0.0 on testnet" 0 "$rc"
check "rpc: only the bind words changed, limits appended" \
    "$(sed 's/--http.addr 127.0.0.1/--http.addr 0.0.0.0/; s/--ws.addr 127.0.0.1/--ws.addr 0.0.0.0 --rpc.max-blocks-per-filter 10000 --rpc.max-logs-per-response 10000 --rpc.max-subscriptions-per-connection 100 --rpc.max-request-size 2 --http.api eth,net,web3,tn/' "$T/launch.before")" \
    "$(cat "$TARGET_LAUNCH_FILE")"
check_has "rpc: node.env follows" "TN_RPC_ADDR=0.0.0.0" "$(cat "$ENVF")"
printf 'NETWORK=mainnet\n' > "$T/root/etc/telcoin/.node-meta"
fresh
cp "$TARGET_LAUNCH_FILE" "$T/launch.before"
rc=0; set_rpc_addr 0.0.0.0 >/dev/null 2>&1 || rc=$?
check "rpc 0.0.0.0 refused on mainnet" "1 same" "$rc $(same "$T/launch.before" "$TARGET_LAUNCH_FILE")"
check "nothing ran perl" "no" "$([[ -s "$T/perl.log" ]] && echo yes || echo no)"
check "no sed -i or perl program with data left in edit-config.sh" "0" \
    "$(grep -cE 'sed -i|perl -i -pe "' "$TN_TEST_REPO/edit-config.sh")"
finish
