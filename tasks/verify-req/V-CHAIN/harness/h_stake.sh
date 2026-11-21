#!/usr/bin/env bash
# V-CHAIN harness: prepare-stake.sh per chain id. ps_chain_name, EXPECTED_CHAIN_ID
# for NETWORK=mainnet in .node-meta (ps_resolve_node; prepare-stake has no
# --network flag) and ps_check_chain against a network RPC answering each id
# (tn_rpc_call stubbed).
#
#   bash tasks/verify-req/V-CHAIN/harness/h_stake.sh
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/fx/etc/telcoin" "$T/fx/var/lib/telcoin"
grep -v '^main "\$@"$' "${REPO}/prepare-stake.sh" > "$T/h/prepare-stake.sh"
ln -s "${REPO}/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/prepare-stake.sh"
tn_test_post_common
set +e

echo "== ps_chain_name"
for id in 731 487 2017 32285 12345; do printf '   %-6s -> %s\n' "$id" "$(ps_chain_name "$id")"; done
check "ps_chain_name 731 / 487" "mainnet|not a Telcoin network" "$(ps_chain_name 731)|$(ps_chain_name 487)"

echo "== ps_resolve_node, NETWORK=mainnet"
printf 'NETWORK=mainnet\nDATA_DIR=/var/lib/telcoin\n' > "$T/fx/etc/telcoin/.node-meta"
printf 'name: n\nexecution_address: "0x1111111111111111111111111111111111111111"\n' > "$T/fx/var/lib/telcoin/node-info.yaml"
out="$( (ps_resolve_node >/dev/null 2>&1; printf '%s|%s' "$EXPECTED_CHAIN_ID" "$NETWORK_RPC") )"
check "mainnet: EXPECTED_CHAIN_ID and the default network RPC" "731|https://rpc.telcoin.network" "$out"

echo "== ps_check_chain"
STUB_HEX=""
tn_rpc_call() { printf '{"jsonrpc":"2.0","id":1,"result":"%s"}' "$STUB_HEX"; }
pcc() {
    STUB_HEX="$1"
    ( NETWORK=mainnet EXPECTED_CHAIN_ID=731 NETWORK_RPC=https://rpc.telcoin.network; ps_check_chain 2>&1; printf 'rc=0' ) | tr '\n' ' '
}
for hx in 0x2db 0x1e7 0x7e1; do printf '   mainnet, rpc %-6s -> %s\n' "$hx" "$(pcc "$hx")"; done
check "mainnet, rpc 0x1e7: refused, naming 487 and 731" "yes" \
    "$(grep -q 'serves chain 487 (not a Telcoin network), not chain 731 (mainnet)' <<< "$(pcc 0x1e7)" && echo yes)"
check "mainnet, rpc 0x2db: passes" "yes" "$(grep -q 'serves chain 731 (mainnet).*rc=0' <<< "$(pcc 0x2db)" && echo yes)"
finish
