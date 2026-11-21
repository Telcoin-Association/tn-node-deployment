#!/usr/bin/env bash
# V-CHAIN harness: check-node.sh per chain id. chain_network / network_chain_id,
# resolve_network without .node-meta (the local chain id stands in), the local-RPC
# chain check of section 2 (the "not a Telcoin network" line and the mismatch
# line) and check_network_chain (the public RPC on another chain).
#
#   bash tasks/verify-req/V-CHAIN/harness/h_check.sh
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
CN="${REPO}/check-node.sh"
{
    for f in have_fns hex_to_dec network_chain_id network_rpc_url chain_network resolve_network check_network_chain; do
        sed -n "/^${f}() {/,/^}/p" "$CN"
    done
    printf 'probe_block() {\n'
    awk '/^print_step "Probing local RPC\.\.\."/ { f = 1; next } f { print } f && /^esac/ { exit }' "$CN"
    printf '}\n'
} > "$T/fns.sh"
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx/etc/telcoin"
eval "$(tn_test_source_common)"
# shellcheck source=/dev/null
. "$T/fns.sh"
check "the probe block was extracted" "yes" "$(grep -q 'is not a Telcoin network' "$T/fns.sh" && echo yes)"

echo "== chain_network / network_chain_id"
check "network_chain_id mainnet" "731" "$(network_chain_id mainnet)"
for id in 731 487 2017 32285 12345; do
    printf '   chain_network %-6s -> "%s"\n' "$id" "$(chain_network "$id")"
done
check "chain_network 731 / 487 / 2017 / 32285 / 12345" "mainnet||testnet|devnet|" \
    "$(chain_network 731)|$(chain_network 487)|$(chain_network 2017)|$(chain_network 32285)|$(chain_network 12345)"

# probe HEX META_NETWORK -> the section-2 lines and the issue count
probe() {
    LOCAL_RPC_MODE=HEALTHY LOCAL_CHAIN_ID="$1"
    NODE_NETWORK="" NETWORK_SRC="" NETWORK_NOTE="" NETWORK_RPC="" QUERY_NETWORK=true EXPECTED_CHAIN_ID=""
    if [[ -n "$2" ]]; then printf 'NETWORK=%s\n' "$2" > "$T/fx/etc/telcoin/.node-meta"; else rm -f "$T/fx/etc/telcoin/.node-meta"; fi
    resolve_network
    HEALTH_ISSUES=0
    probe_block 2>&1
    printf 'net=%s src=%s want=%s rpc=%s issues=%s\n' "$NODE_NETWORK" "$NETWORK_SRC" "$EXPECTED_CHAIN_ID" "$NETWORK_RPC" "$HEALTH_ISSUES"
}
echo "== section 2, no .node-meta"
for hx in 0x2db 0x1e7 0x7e1 0x7e1d 0x3039; do
    out="$(probe "$hx" "")"
    printf -- '-- local %s, no meta:\n%s\n' "$hx" "$out"
done
out="$(probe 0x2db "")"
check_has "no meta, 0x2db: mainnet from the local chain id" "net=mainnet src=the local chain id want=731 rpc=https://rpc.telcoin.network issues=0" "$out"
out="$(probe 0x1e7 "")"
check_has "no meta, 0x1e7: not a Telcoin network, 1 issue" "net= src= want= rpc= issues=1" "$out"
check "no meta, 0x1e7: the message" "yes" \
    "$(grep -q 'Chain ID 0x1e7 (487) is not a Telcoin network (testnet 2017, mainnet 731, devnet 32285)' <<< "$out" && echo yes)"
echo "== section 2, NETWORK in .node-meta"
out="$(probe 0x1e7 mainnet)"
printf '%s\n' "$out"
check "meta mainnet, local 0x1e7: mismatch line" "yes" \
    "$(grep -q 'Chain ID mismatch: 0x1e7 (487) -- .node-meta says mainnet (chain 731)' <<< "$out" && echo yes)"
out="$(probe 0x2db mainnet)"
check "meta mainnet, local 0x2db: matches" "yes" "$(grep -q 'Chain ID:        0x2db (731 -- mainnet)' <<< "$out" && echo yes)"
out="$(probe 0x2db devnet)"
printf '%s\n' "$out"
check "meta devnet, local 0x2db: mismatch names mainnet" "yes" \
    "$(grep -q 'Chain ID mismatch: 0x2db (731 -- mainnet) -- .node-meta says devnet (chain 32285)' <<< "$out" && echo yes)"
out="$(probe 0x1e7 devnet)"
printf '%s\n' "$out"

echo "== check_network_chain (the public RPC's own chain)"
STUB_HEX=""
tn_rpc_call() { printf '{"jsonrpc":"2.0","id":1,"result":"%s"}' "$STUB_HEX"; }
for hx in 0x2db 0x1e7 0x7e1; do
    NODE_NETWORK=mainnet EXPECTED_CHAIN_ID=731 NETWORK_RPC=https://rpc.telcoin.network NETWORK_WRONG_CHAIN=false
    STUB_HEX="$hx"
    out="$(check_network_chain 2>&1; printf 'wrong=%s' "$NETWORK_WRONG_CHAIN")"
    printf -- '-- mainnet node, public answers %s:\n%s\n' "$hx" "$out"
    case "$hx" in 0x2db) want="wrong=false" ;; *) want="wrong=true" ;; esac
    check_has "check_network_chain, mainnet, public ${hx}" "$want" "$out"
done
finish
