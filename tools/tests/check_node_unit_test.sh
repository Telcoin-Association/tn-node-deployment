#!/usr/bin/env bash
# tools/tests/check_node_unit_test.sh -- check-node.sh's passphrase-delivery,
# sandbox and mainnet health-monitor checks (check_unit_environ,
# check_unit_sandbox, check_healthcheck_on_mainnet) on fixture trees, as a
# normal user: a current start script and unit pass; an older script that
# exports the passphrase, a unit that sets it, and a mainnet node with the
# health monitor fail; a unit without the sandbox warns. The functions are cut
# from check-node.sh. Maintainer tooling (not updater-tracked). bash 3.2 safe.
set -u
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
CN="$TN_TEST_REPO/check-node.sh"
{
    sed -n '/^have_fns() {/,/^}/p' "$CN"
    sed -n '/^detect_data_dir() {/,/^}/p' "$CN"
    awk '/^# HARDENING CHECKS/ { f = 1 } /^# REPORT HEADER/ { f = 0 } f' "$CN"
} > "$T/fns.sh"
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx/etc/telcoin" "$T/fx/etc/systemd/system" "$T/fx/usr/local/libexec/telcoin"
eval "$(tn_test_source_common)"
# shellcheck source=/dev/null
. "$T/fns.sh"
# The fixture tree is not root-owned; the launch target is the fixture script.
tn_node_launch_target() { printf 'telcoin source %s\n' "$T/fx/usr/local/libexec/telcoin/tn-start"; }
SERVICE_NAME=telcoin
NETWORK=testnet DATA_DIR=/var/lib/telcoin PASSPHRASE_METHOD=stdin LOG_TARGET=file
printf 'NETWORK=testnet\nINSTALL_METHOD=source\n' > "$T/fx/etc/telcoin/.node-meta"
UNIT="$T/fx/etc/systemd/system/telcoin.service"
SCRIPT="$T/fx/usr/local/libexec/telcoin/tn-start"
ARGS="--datadir /var/lib/telcoin -vvv --http --http.addr 127.0.0.1"

runc() {  # runc FN -> OUT, ISSUES
    HEALTH_ISSUES=0
    OUT="$("$1" 2>&1; printf '\nissues=%s' "$HEALTH_ISSUES")"
}
current() {
    _tn_node_unit_text source > "$UNIT"
    _tn_start_script_text source /opt/telcoin/telcoin-network "$ARGS" > "$SCRIPT"
}

current
runc check_unit_environ
check_has "current form: no issue" "issues=0" "$OUT"
check_has "current form: stdin reported" "yes" "$(printf '%s' "$OUT" | grep -q 'on stdin' && echo yes)"
runc check_unit_sandbox
check_has "current unit: sandbox in place" "yes" "$(printf '%s' "$OUT" | grep -q 'sandbox in place' && echo yes)"
sed 's/^UMask=0027$/UMask=0077/' "$UNIT" > "$T/u77" && cp "$T/u77" "$UNIT"
runc check_unit_sandbox
check_has "older UMask=0077 unit: sandbox in place" "yes" "$(printf '%s' "$OUT" | grep -q 'sandbox in place' && echo yes)"
sed 's/^UMask=0077$/UMask=0022/' "$UNIT" > "$T/u77" && cp "$T/u77" "$UNIT"
runc check_unit_sandbox
check_has "UMask=0022: sandbox warning" "yes" "$(printf '%s' "$OUT" | grep -q 'lacks sandbox settings: UMask=0027' && echo yes)"
current

printf '#!/bin/bash\nexport TN_BLS_PASSPHRASE=$(cat "$CREDENTIALS_DIRECTORY/bls-passphrase")\nexec /opt/telcoin/telcoin-network node %s\n' "$ARGS" > "$SCRIPT"
runc check_unit_environ
check_has "exporting script: an issue" "issues=1" "$OUT"
current
printf 'Environment="TN_BLS_PASSPHRASE=hunter2"\n' >> "$UNIT"
runc check_unit_environ
check_has "unit Environment= with the passphrase: an issue" "issues=1" "$OUT"
check_lacks "the value is never printed" "hunter2" "$OUT"
current
printf 'TN_BLS_PASSPHRASE=x\n' > "$T/fx/etc/telcoin/node.env"
runc check_unit_environ
check_has "EnvironmentFile with the passphrase: an issue" "issues=1" "$OUT"
rm -f "$T/fx/etc/telcoin/node.env"

printf '[Service]\nUser=telcoin\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$UNIT"
runc check_unit_sandbox
check_has "bare unit: sandbox warning" "yes" "$(printf '%s' "$OUT" | grep -q 'lacks sandbox settings' && echo yes)"
check_has "bare unit: a warning, not an issue" "issues=0" "$OUT"

printf 'NETWORK=mainnet\nINSTALL_METHOD=source\n' > "$T/fx/etc/telcoin/.node-meta"
current
runc check_healthcheck_on_mainnet
check_has "mainnet without the monitor: ok" "issues=0" "$OUT"
_tn_start_script_text source /opt/telcoin/telcoin-network "$ARGS --healthcheck 9090" > "$SCRIPT"
runc check_healthcheck_on_mainnet
check_has "mainnet with --healthcheck: an issue" "issues=1" "$OUT"
current
printf 'NETWORK=mainnet\nENABLE_HEALTHCHECK_MONITOR=true\n' > "$T/fx/etc/telcoin/.node-meta"
runc check_healthcheck_on_mainnet
check_has "mainnet with the monitor in .node-meta: an issue" "issues=1" "$OUT"
printf 'NETWORK=testnet\nENABLE_HEALTHCHECK_MONITOR=true\n' > "$T/fx/etc/telcoin/.node-meta"
runc check_healthcheck_on_mainnet
check "testnet: not checked" "issues=0" "$(printf '%s' "$OUT" | tail -n 1)"

# ---- LIB-B: resolve_network picks the network's own RPC, never another's -------------
# resolve_network and the helpers it calls, cut from check-node.sh, over the
# fixture .node-meta; LOCAL_CHAIN_ID stands in for the local RPC's chain id.
{
    for f in network_chain_id network_rpc_url chain_network hex_to_dec resolve_network network_gap_reason; do
        sed -n "/^${f}() {/,/^}/p" "$CN"
    done
} > "$T/net.sh"
# shellcheck source=/dev/null
. "$T/net.sh"
NWMETA="$T/fx/etc/telcoin/.node-meta"
# resolve META-LINE NETWORK-RPC QUERY -- one resolve_network from a clean state.
resolve() {
    if [[ -n "$1" ]]; then printf '%s\n' "$1" > "$NWMETA"; else rm -f "$NWMETA"; fi
    NODE_NETWORK="" NETWORK_SRC="" NETWORK_NOTE="" EXPECTED_CHAIN_ID=""
    NETWORK_RPC="$2" QUERY_NETWORK="$3" NETWORK_RPC_LABEL="" NETWORK_SKIP_WHY="--no-network"
    NETWORK_WRONG_CHAIN=""
    LOCAL_CHAIN_ID=""
    resolve_network
}
resolve "NETWORK=mainnet" "" true
check "mainnet: its own public RPC" "$MAINNET_RPC_URL" "$NETWORK_RPC"
check "mainnet: the header line names the network" "$MAINNET_RPC_URL (mainnet public RPC)" "$NETWORK_RPC_LABEL"
check "mainnet: the network is queried" true "$QUERY_NETWORK"
resolve "NETWORK=testnet" "" true
check "testnet: its own public RPC" "$TESTNET_RPC_URL" "$NETWORK_RPC"
resolve "NETWORK=devnet" "" true
check "devnet: its own public RPC" "$DEVNET_RPC_URL" "$NETWORK_RPC"
resolve "" "" true
check "unknown network: no network RPC" "" "$NETWORK_RPC"
check "unknown network: not queried" false "$QUERY_NETWORK"
check "unknown network: the skip note" "network unknown; give --network-rpc URL to compare" "$NETWORK_SKIP_WHY"
check "unknown network: the reason other sections give" "network unknown; give --network-rpc URL to compare" "$(network_gap_reason)"
check "unknown network: the header line says none" "none (network unknown; give --network-rpc URL to compare)" "$NETWORK_RPC_LABEL"
resolve "NETWORK=adiri" "" true
check "NETWORK not a known name: no network RPC" "" "$NETWORK_RPC"
check_lacks "NETWORK not a known name: never the testnet RPC" "adiri.tel" "$NETWORK_RPC $NETWORK_RPC_LABEL"
resolve "" "https://rpc.example.org" true
check "unknown network, --network-rpc: used" "https://rpc.example.org" "$NETWORK_RPC"
check "unknown network, --network-rpc: queried" true "$QUERY_NETWORK"
check "unknown network, --network-rpc: the header line" "https://rpc.example.org (--network-rpc, for an unknown network)" "$NETWORK_RPC_LABEL"
resolve "NETWORK=mainnet" "https://rpc.example.org" true
check "mainnet, --network-rpc wins" "https://rpc.example.org" "$NETWORK_RPC"
check "mainnet, --network-rpc: the header line" "https://rpc.example.org (--network-rpc, for mainnet)" "$NETWORK_RPC_LABEL"
resolve "" "" false
check "--no-network, unknown network: no header line" "" "$NETWORK_RPC_LABEL"
check "--no-network: the reason stays --no-network" "--no-network" "$(network_gap_reason)"
rm -f "$NWMETA"
NODE_NETWORK="" NETWORK_RPC="" QUERY_NETWORK=true LOCAL_CHAIN_ID="0x$(printf '%x' "$MAINNET_CHAIN_ID")"
resolve_network
check "no .node-meta, a mainnet chain id: the mainnet RPC" "$MAINNET_RPC_URL" "$NETWORK_RPC"
# The report prints the header line and the section 3 skip from these variables.
check "the report header prints NETWORK_RPC_LABEL" 1 "$(grep -c 'print_info "Network RPC:  ${NETWORK_RPC_LABEL}"' "$CN")"
check "the section 3 skip prints NETWORK_SKIP_WHY" 1 "$(grep -c 'print_info "Network query skipped (${NETWORK_SKIP_WHY})"' "$CN")"
finish
