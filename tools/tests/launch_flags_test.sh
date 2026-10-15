#!/usr/bin/env bash
# tools/tests/launch_flags_test.sh -- launch-line flags. setup-node.sh adds the
# public RPC limits (bounded log queries, subscriptions and request size, HTTP
# limited to eth, net, web3 and tn) only when the node serves public RPC; the
# library's flag rule and the start-script writer accept them, and the launch
# editors read them back. A copy of setup-node.sh without its last line is
# sourced at the top level with the host-touching steps replaced. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn" "$T/root"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e  # setup-node.sh makes SERVICE_NAME readonly; tn_test_post_common would assign it

LIMITS="--rpc.max-blocks-per-filter 10000 --rpc.max-logs-per-response 10000 --rpc.max-subscriptions-per-connection 100 --rpc.max-request-size 2 --http.api eth,net,web3,tn"

# Host-touching steps of prepare_node_extra_flags.
node_runner_spec() { printf 'binary:/opt/telcoin/telcoin-network\n'; }
require_node_flag() { return 0; }
install_bootstrap_peers() { return 0; }
write_node_meta() { return 0; }
node_flag_warnings() { return 0; }

prep() {  # prep ENABLE_PUBLIC_RPC -> NODE_EXTRA_FLAGS
    NODE_EXTRA_FLAGS="" NODE_EXTRA_FLAGS_SPEC="" ENABLE_PUBLIC_RPC="$1" STATE_EXPORT=off BOOTSTRAP_PEERS_SRC=""
    prepare_node_extra_flags >/dev/null 2>&1
}
prep true
check "public RPC: the limits are on the launch line" "$LIMITS" "$NODE_EXTRA_FLAGS"
prep false
check "private RPC: no limits" "" "$NODE_EXTRA_FLAGS"
STATE_EXPORT=3
NODE_EXTRA_FLAGS="" NODE_EXTRA_FLAGS_SPEC="" ENABLE_PUBLIC_RPC=true BOOTSTRAP_PEERS_SRC=""
prepare_node_extra_flags >/dev/null 2>&1
check "public RPC with state export: both" "--enable-state-export --state-export-keep 3 ${LIMITS}" "$NODE_EXTRA_FLAGS"

for w in $LIMITS; do
    case "$w" in
        --*) rc=0; _tn_launch_flag_ok "$w" || rc=$?; check_rc "flag rule accepts ${w}" 0 "$rc" ;;
    esac
done

# The start-script writer takes them, and the launch editors read them back.
NETWORK=testnet DATA_DIR=/var/lib/telcoin PASSPHRASE_METHOD=stdin LOG_TARGET=file
ARGS="--datadir /var/lib/telcoin --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${LIMITS}"
rc=0; _tn_start_script_text source /opt/telcoin/telcoin-network "$ARGS" > "$T/tn-start" 2>/dev/null || rc=$?
check_rc "start script with the limits renders" 0 "$rc"
check "editor reads --rpc.max-request-size" "2" "$(tn_launch_flag_get "$T/tn-start" --rpc.max-request-size 2>/dev/null)"
check "editor reads --http.api" "eth,net,web3,tn" "$(tn_launch_flag_get "$T/tn-start" --http.api 2>/dev/null)"
check "editor reads --rpc.max-logs-per-response" "10000" "$(tn_launch_flag_get "$T/tn-start" --rpc.max-logs-per-response 2>/dev/null)"
finish
