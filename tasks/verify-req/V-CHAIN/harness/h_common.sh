#!/usr/bin/env bash
# V-CHAIN harness (verifier-owned, not a fixture of the suite): what lib/common.sh
# answers for each chain id. tn_detect_network (genesis only; NETWORK=mainnet over
# a 487 genesis; NETWORK=devnet over a 731 genesis), tn_genesis_chain_id,
# tn_is_public_chain_id, select_network's menu, _tn_rpc_chain_is, the quorum
# guard's public-RPC trust (_tn_guard_src_ok, _tn_guard_unreadable) and
# _tn_mode_unknown_wait_url.
#
#   bash tasks/verify-req/V-CHAIN/harness/h_common.sh
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx/etc/telcoin" "$T/fx/data/genesis"
eval "$(tn_test_source_common)"

META="$T/fx/etc/telcoin/.node-meta"
GEN="$T/fx/data/genesis/genesis.yaml"
setmeta() {
    printf 'DATA_DIR=/data\n' > "$META"
    while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >> "$META"; shift; done
}
genesis() { printf 'config:\n  chainId: %s\n  homesteadBlock: 0\n' "$1" > "$GEN"; }
detect() {
    local o rc=0
    o="$(tn_detect_network 2>"$T/err")" || rc=$?
    printf '%s rc=%s' "${o:--}" "$rc"
}

IDS="731 0x2db 0x2DB 0x02db 487 0x1e7 0x1E7 0x01e7 2017 0x7e1 32285 0x7e1d 12345"

echo "== constants"
check "MAINNET_CHAIN_ID" "731" "$MAINNET_CHAIN_ID"
check "TESTNET_CHAIN_ID" "2017" "$TESTNET_CHAIN_ID"
check "DEVNET_CHAIN_ID" "32285" "$DEVNET_CHAIN_ID"
check "TN_MAINNET_ENABLED still 0" "0" "$TN_MAINNET_ENABLED"

echo "== tn_genesis_chain_id and tn_detect_network, genesis only (no NETWORK key)"
for id in $IDS; do
    setmeta
    genesis "$id"
    gid="$(tn_genesis_chain_id "$GEN" 2>/dev/null)" || gid="rc$?"
    case "$id" in
        731|0x2db|0x2DB|0x02db) want="mainnet rc=0" ;;
        2017|0x7e1) want="testnet rc=0" ;;
        *) want="- rc=1" ;;
    esac
    got="$(detect)"
    printf '   genesis %-7s -> id %-6s detect %s | %s\n' "$id" "$gid" "$got" "$(cat "$T/err")"
    check "detect, genesis ${id}" "$want" "$got"
done
# JSON forms of the genesis key
printf '{"config":{"chainId":"0x2db","homesteadBlock":0}}\n' > "$GEN"
check "detect, one-line JSON chainId \"0x2db\"" "mainnet rc=0" "$(detect)"
printf '{\n  "chain_id": 487\n}\n' > "$GEN"
check "detect, JSON chain_id 487" "- rc=1" "$(detect)"
check_has "detect, 487: the reason names 487 and 731" "yes" \
    "$(grep -q '(487) is neither 731 nor 2017' "$T/err" && echo yes)"

echo "== tn_detect_network with a NETWORK key"
setmeta NETWORK=mainnet; genesis 487
check "NETWORK=mainnet over a 487 genesis: the key decides" "mainnet rc=0" "$(detect)"
setmeta NETWORK=devnet; genesis 731
check "NETWORK=devnet over a 731 genesis: rc 1, no genesis fallback" "- rc=1" "$(detect)"
setmeta NETWORK=testnet; genesis 731
check "NETWORK=testnet over a 731 genesis: the key decides" "testnet rc=0" "$(detect)"

echo "== tn_is_public_chain_id"
for id in $IDS; do
    rc=0; tn_is_public_chain_id "$id" || rc=$?
    case "$id" in
        731|0x2db|0x2DB|0x02db|2017|0x7e1|32285|0x7e1d) want=0 ;;
        *) want=1 ;;
    esac
    check_rc "tn_is_public_chain_id ${id}" "$want" "$rc"
done

echo "== select_network"
menu="$(printf '2\n\n1\n' | select_network 2>&1)"
check_has "menu, mainnet off: line 2" "  2) Mainnet        (Chain ID: 731)  -- for production (coming soon)" "$menu"
check_has "menu: line 1" "  1) Adiri Testnet  (Chain ID: 2017)  -- for testing" "$menu"
check_lacks "menu: no 487" "487" "$menu"
(
    tn_mainnet_enabled() { return 0; }
    printf '2\n' > "$T/sel.in"
    select_network < "$T/sel.in" >/dev/null 2>&1
    printf '%s|%s|%s|%s' "${NETWORK:-}" "${CHAIN_ID:-}" "${CHAIN_NAME:-}" "${RPC_URL:-}"
) > "$T/sel"
check "menu, mainnet on (stubbed), choice 2" "mainnet|731|telcoin|https://rpc.telcoin.network" "$(cat "$T/sel")"

echo "== _tn_rpc_chain_is (tn_rpc_call stubbed)"
STUB_HEX=""
tn_rpc_call() { printf '{"jsonrpc":"2.0","id":1,"result":"%s"}' "$STUB_HEX"; }
for hx in 0x2db 0x2DB 0x02db 0x1e7 0x7e1 0x7e1d 0x3039; do
    STUB_HEX="$hx"; rc=0
    _tn_rpc_chain_is "https://x.invalid" "$MAINNET_CHAIN_ID" || rc=$?
    case "$hx" in 0x2db|0x2DB|0x02db) want=0 ;; *) want=1 ;; esac
    check_rc "_tn_rpc_chain_is answer ${hx} vs mainnet" "$want" "$rc"
done

echo "== quorum guard: the public RPC is trusted only on chain 731 (mainnet)"
setmeta NETWORK=mainnet VALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111
genesis 731
src_ok() {
    local url="http://127.0.0.1:8545" pub="$MAINNET_RPC_URL" want="$MAINNET_CHAIN_ID" pub_state="" pub_note="" rc=0
    _tn_guard_src_ok "$pub" || rc=$?
    printf '%s|%s' "$rc" "$pub_note"
}
STUB_HEX=0x2db
check "_tn_guard_src_ok, public answers 0x2db" "0|" "$(src_ok)"
STUB_HEX=0x1e7
check "_tn_guard_src_ok, public answers 0x1e7" "1|; https://rpc.telcoin.network does not answer with chain 731" "$(src_ok)"
node_is_staked_validator() { return 1; }
_tn_guard_say() { printf '%s: %s\n' "$1" "$2"; }
for hx in 0x2db 0x1e7; do
    STUB_HEX="$hx"; rc=0
    out="$(_tn_guard_unreadable "test" "" "" 2>&1)" || rc=$?
    printf '   unreadable, public %s -> rc %s: %s\n' "$hx" "$rc" "$out"
    case "$hx" in 0x2db) want=0 ;; *) want=2 ;; esac
    check_rc "_tn_guard_unreadable, unstaked mainnet node, public ${hx}" "$want" "$rc"
done
check_has "the 0x1e7 refusal names chain 731" "yes" \
    "$(grep -q 'does not answer with chain 731, so the stake was not read there' <<< "$out" && echo yes)"
# No NETWORK, genesis 487 (a pre-change mainnet rehearsal host without the key):
setmeta VALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111
genesis 487
STUB_HEX=0x2db; rc=0
out="$(_tn_guard_unreadable "test" "" "" 2>&1)" || rc=$?
printf '   no NETWORK, genesis 487 -> network "%s", rc %s: %s\n' "$(_tn_guard_network)" "$rc" "$out"
check "guard network, no key, genesis 487" "" "$(_tn_guard_network)"
check_rc "_tn_guard_unreadable, network unknown (487): refused" 2 "$rc"

echo "== _tn_mode_unknown_wait_url: the public RPC is asked only on chain 731"
setmeta NETWORK=mainnet VALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111
genesis 731
ASKED=""
node_is_staked_validator() { ASKED="${ASKED}${2:-local};"; return 1; }
for hx in 0x2db 0x1e7; do
    STUB_HEX="$hx"; ASKED=""; rc=0
    _tn_mode_unknown_wait_url "http://127.0.0.1:8545" >/dev/null 2>&1 || rc=$?
    printf '   public %s -> rc %s, stake asked of: %s\n' "$hx" "$rc" "${ASKED:-nobody}"
    case "$hx" in 0x2db) want="https://rpc.telcoin.network;" ;; *) want="" ;; esac
    check "_tn_mode_unknown_wait_url, public ${hx}: who is asked" "$want" "$ASKED"
done

finish
