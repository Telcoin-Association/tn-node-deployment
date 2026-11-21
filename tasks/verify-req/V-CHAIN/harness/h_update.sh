#!/usr/bin/env bash
# V-CHAIN harness: update-node.sh per chain id. detect_network and image_network
# (no NETWORK key: the genesis chain id decides), the build features that follow
# from the network, and the post-restart chain check of
# verify_consensus_participation (a mainnet node answering 0x1e7 is refused,
# 0x2db passes).
#
#   bash tasks/verify-req/V-CHAIN/harness/h_update.sh
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/fx/etc/telcoin" "$T/fx/data/genesis"
grep -v '^main "\$@"$' "${REPO}/update-node.sh" > "$T/h/update-node.sh"
ln -s "${REPO}/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common

META="$T/fx/etc/telcoin/.node-meta"
GEN="$T/fx/data/genesis/genesis.yaml"
setmeta() {
    printf 'DATA_DIR=/data\n' > "$META"
    while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >> "$META"; shift; done
}
genesis() { printf 'config:\n  chainId: %s\n' "$1" > "$GEN"; }
ans() { local o rc=0; o="$("$@" 2>/dev/null)" || rc=$?; printf '%s rc=%s' "${o:--}" "$rc"; }

echo "== detect_network / image_network / tn_cargo_features_for"
for id in 731 0x2db 487 0x1e7 2017 32285 12345; do
    setmeta; genesis "$id"
    net="$(detect_network 2>/dev/null)" || net=""
    printf '   no key, genesis %-6s: detect_network "%s" | image_network "%s" | features "%s"\n' \
        "$id" "$(ans detect_network)" "$(ans image_network)" "$(ans tn_cargo_features_for "$net")"
done
setmeta; genesis 731
check "no key, genesis 731: detect mainnet" "mainnet rc=0" "$(ans detect_network)"
check "no key, genesis 731: no adiri feature" " rc=0" "$(tn_cargo_features_for mainnet; printf ' rc=%s' "$?")"
setmeta; genesis 487
check "no key, genesis 487: detect refuses" "- rc=1" "$(ans detect_network)"
check "no key, genesis 487: image_network refuses" "- rc=1" "$(ans image_network)"
setmeta NETWORK=devnet; genesis 487
check "NETWORK=devnet, genesis 487: image_network devnet" "devnet rc=0" "$(ans image_network)"
setmeta NETWORK=mainnet; genesis 487
check "NETWORK=mainnet, genesis 487: detect mainnet (the key decides)" "mainnet rc=0" "$(ans detect_network)"

echo "== verify_consensus_participation: the chain part"
STUB_HEX=""
tn_rpc_call() {
    case "$2" in
        eth_chainId) printf '{"jsonrpc":"2.0","id":1,"result":"%s"}' "$STUB_HEX" ;;
        *) return 1 ;;
    esac
}
SERVICE_NAME=telcoin JSON_MODE=false RPC_URL="http://127.0.0.1:8545"
vcp() {
    local hx="$1"; shift
    setmeta "$@"; STUB_HEX="$hx"
    verify_consensus_participation 2>&1 | tr '\n' ' '
}
for args in "0x2db NETWORK=mainnet" "0x1e7 NETWORK=mainnet" "0x7e1 NETWORK=mainnet" "0x2db NETWORK=testnet" "0x1e7 NETWORK=devnet" "0x7e1d NETWORK=devnet"; do
    # shellcheck disable=SC2086
    out="$(vcp $args)"
    printf '   %-22s -> %s\n' "$args" "$out"
done
out="$(vcp 0x1e7 NETWORK=mainnet)"
check "mainnet node answering 0x1e7: refused naming 487 and 731" "yes" \
    "$(grep -q 'runs chain id 487, not 731 (mainnet)' <<< "$out" && echo yes)"
out="$(vcp 0x2db NETWORK=mainnet)"
check "mainnet node answering 0x2db: the chain passes (it fails later, on the header stub)" "yes" \
    "$(grep -q 'gave no consensus header number' <<< "$out" && echo yes)"
genesis 731
out="$(vcp 0x2db)"
check "no key, genesis 731, answering 0x2db: passes the chain check" "yes" \
    "$(grep -q 'gave no consensus header number' <<< "$out" && echo yes)"
genesis 487
out="$(vcp 0x1e7)"
printf '   no key, genesis 487, answering 0x1e7 -> %s\n' "$out"
check "no key, genesis 487: network unknown, chain not checked (warning)" "yes" \
    "$(grep -q 'The network of this node is unknown, so its chain id (487) is not checked' <<< "$out" && echo yes)"
finish
