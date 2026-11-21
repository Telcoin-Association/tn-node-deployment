#!/usr/bin/env bash
# V-CHAIN harness: entry scripts that each source lib/common.sh, so one process per
# script (the library's constants are readonly). Pass the part to run:
#   setup  -- setup-node.sh json_set_network mainnet (refused while off; 731 when on)
#   edit   -- edit-config.sh set_private_forward_targets true per genesis chain id
#   caddy  -- install-caddy.sh caddy_mainnet_gate per NETWORK key and genesis id
# With no part it runs all three, each in its own bash.
#
#   bash tasks/verify-req/V-CHAIN/harness/h_entry.sh [setup|edit|caddy]
set -u
HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HDIR}/../../../.." && pwd)"
if [[ $# -eq 0 ]]; then
    rc=0
    for p in setup edit caddy; do bash "${BASH_SOURCE[0]}" "$p" || rc=1; done
    exit "$rc"
fi
PART="$1"
# shellcheck source=/dev/null
. "${REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/fx/etc/telcoin" "$T/fx/data/genesis"
ln -s "${REPO}/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
META="$T/fx/etc/telcoin/.node-meta"
GEN="$T/fx/data/genesis/genesis.yaml"
setmeta() {
    printf 'DATA_DIR=/data\n' > "$META"
    while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >> "$META"; shift; done
}
genesis() { printf 'config:\n  chainId: %s\n' "$1" > "$GEN"; }
load() {
    grep -v '^main "\$@"$' "${REPO}/$1" > "$T/h/$1"
    tn_test_pre_common
    # shellcheck source=/dev/null
    source "$T/h/$1"
    # setup-node.sh makes SERVICE_NAME readonly, so post_common cannot run there
    [[ "$1" == setup-node.sh ]] || tn_test_post_common
    set +e
}

case "$PART" in
setup)
    load setup-node.sh
    echo "== setup-node.sh json_set_network"
    out="$( (json_set_network mainnet; printf 'reached %s %s' "$NETWORK" "$CHAIN_ID") 2>&1 | tr '\n' ' ')"
    printf '   mainnet, off -> %s\n' "$out"
    check "json_set_network mainnet while off: refused" "yes" \
        "$(grep -q 'Mainnet is not enabled in this script release' <<< "$out" && ! grep -q reached <<< "$out" && echo yes)"
    out="$( (tn_mainnet_enabled() { return 0; }; json_set_network mainnet; printf '%s|%s|%s' "$NETWORK" "$CHAIN_ID" "$RPC_URL") 2>&1)"
    check "json_set_network mainnet, on (stubbed)" "mainnet|731|https://rpc.telcoin.network" "$out"
    ;;
edit)
    load edit-config.sh
    echo "== edit-config.sh set_private_forward_targets true"
    detect_data_dir() { printf '%s\n' "$T/fx/data"; }
    printf 'allow_private_forward_targets: true\n' > "$T/fx/data/parameters.yaml"
    for id in 731 0x2db 487 0x1e7 2017 32285 12345; do
        genesis "$id"; rc=0
        out="$(set_private_forward_targets true 2>&1)" || rc=$?
        printf '   genesis %-6s -> rc %s %s\n' "$id" "$rc" "$(tr '\n' ' ' <<< "$out")"
        case "$id" in 731|0x2db|2017) want=1 ;; *) want=0 ;; esac
        check_rc "private forward targets, genesis ${id}" "$want" "$rc"
    done
    genesis 731
    out="$(set_private_forward_targets true 2>&1)"
    check "731: the refusal names mainnet" "yes" "$(grep -q 'this node runs chain 731 (mainnet), a public network' <<< "$out" && echo yes)"
    ;;
caddy)
    load install-caddy.sh
    echo "== install-caddy.sh caddy_mainnet_gate"
    STAKE_RC=1
    node_is_staked_validator() { return "$STAKE_RC"; }
    gate() {
        ( CADDY_GATE_DONE=false; caddy_mainnet_gate; printf 'passed' ) 2>&1 | tr '\n' ' '
    }
    A=VALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111
    for c in "731 -" "487 -" "731 NETWORK=mainnet" "487 NETWORK=mainnet" "487 NETWORK=devnet"; do
        id="${c%% *}"; k="${c#* }"
        for s in 0 1; do
            if [[ "$k" == "-" ]]; then setmeta "$A"; else setmeta "$k" "$A"; fi
            genesis "$id"; STAKE_RC="$s"
            printf '   genesis %-4s key %-15s staked-rc %s -> %s\n' "$id" "$k" "$s" "$(gate)"
        done
    done
    setmeta "$A"; genesis 731; STAKE_RC=0
    check "no key, genesis 731, staked: refused as a mainnet validator" "yes" \
        "$(grep -q 'is a staked validator' <<< "$(gate)" && echo yes)"
    setmeta "$A"; genesis 487; STAKE_RC=0
    check "no key, genesis 487: refused, the network cannot be told" "yes" \
        "$(grep -q 'The network of this node cannot be told' <<< "$(gate)" && echo yes)"
    ;;
*) echo "unknown part ${PART}" >&2; exit 2 ;;
esac
finish
