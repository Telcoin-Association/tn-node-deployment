#!/usr/bin/env bash
# tools/tests/quorum_guard_test.sh -- tn_committee_down_guard. A curl function
# answers the JSON-RPC calls from generated fixtures: the node's mode, the
# current committee (n members) and the latest consensus commit (with `live`
# distinct authors). Covers n = 4, 7 and 10 with 0 to f+1 members down, a node
# that is not voting, an unreadable committee on mainnet and testnet, a stale or
# other-epoch commit, the fallback to the public RPC (a node that does not answer
# is counted among the down, not added again), a mainnet node with no
# VALIDATOR_ADDRESS, and TN_ALLOW_QUORUM_RISK=1.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TN_ROOT_PREFIX="$TN_TEST_TMP/root"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin"
eval "$(tn_test_source_common)"
META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"
LOCAL="http://127.0.0.1:8545"

# Fixture knobs, read by the curl function.
MODE=CvvActive N=4 LIVE=4 EPOCH=7 HDR_EPOCH=7 AGE=5 LOCAL_UP=1 PUBLIC_UP=1 COMMITTEE_UP=1
STAKED=0
node_is_staked_validator() { return "$STAKED"; }

committee_json() {
    local i list=""
    for ((i = 1; i <= N; i++)); do
        list="${list:+${list},}\"0x$(printf '%040x' "$i")\""
    done
    printf '{"jsonrpc":"2.0","id":1,"result":{"epochId":%s,"blockHeight":100,"epochDuration":86400,"stakeVersion":0,"committee":[%s]}}' "$EPOCH" "$list"
}
header_json() {
    local i hs="" now
    now="$(date +%s)"
    for ((i = 1; i <= LIVE; i++)); do
        # Two headers per live author: the count must be of distinct authors.
        hs="${hs:+${hs},}{\"author\":\"Auth${i}x\",\"epoch\":${HDR_EPOCH}},{\"author\":\"Auth${i}x\",\"epoch\":${HDR_EPOCH}}"
    done
    printf '{"jsonrpc":"2.0","id":1,"result":{"number":5,"sub_dag":{"headers":[%s],"commit_timestamp":%s}}}' "$hs" "$((now - AGE))"
}
curl() {
    local data="" url="" a method
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data) data="$2"; shift 2 ;;
            --url) url="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    method="$(printf '%s' "$data" | sed -n 's/.*"method":"\([A-Za-z_]*\)".*/\1/p')"
    if [[ "$url" == "$LOCAL" && "$LOCAL_UP" != 1 ]]; then return 7; fi
    if [[ "$url" != "$LOCAL" && "$PUBLIC_UP" != 1 ]]; then return 7; fi
    case "$method" in
        tn_nodeMode) [[ "$url" == "$LOCAL" ]] || return 7; a="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"${MODE}\"}" ;;
        tn_getCurrentEpochInfo) [[ "$COMMITTEE_UP" == 1 ]] || return 7; a="$(committee_json)" ;;
        tn_latestConsensusHeader) a="$(header_json)" ;;
        eth_chainId)
            if [[ "$url" == "$LOCAL" ]]; then a='{"jsonrpc":"2.0","id":1,"result":"0x1e7"}'
            else a="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x$(printf '%x' "${PUB_CHAIN:-487}")\"}"; fi ;;
        *) return 7 ;;
    esac
    printf '%s\n200' "$a"
}

guard() {  # guard NAME EXPECTED-RC -> also leaves MSG
    local rc=0
    MSG="$(tn_committee_down_guard "$LOCAL" 2>&1 >/dev/null)" || rc=$?
    check_rc "$1" "$2" "$rc" || printf '      %s\n' "$MSG"
}

printf 'NETWORK=mainnet\nVALIDATOR_ADDRESS=0x%040x\n' 1 > "$META"

for n in 4 7 10; do
    f=$(( (n - 1) / 3 ))
    for ((d = 0; d <= f + 1; d++)); do
        N=$n LIVE=$((n - d))
        want=0
        (( d + 1 < f + 1 )) || want=1
        guard "n=${n} f=${f}: ${d} down -> rc ${want}" "$want"
    done
done
N=10 LIVE=7
guard "n=10, 3 down: refused" 1
check_has "refusal names the override" "yes" "$(printf '%s' "$MSG" | grep -q -- '--allow-quorum-risk' && echo yes)"
TN_ALLOW_QUORUM_RISK=1 guard "n=10, 3 down, override: allowed" 0
check_has "override still warns" "yes" "$(printf '%s' "$MSG" | grep -q 'override' && echo yes)"
MODE=CvvInactive guard "not voting (CvvInactive): allowed with 3 down" 0
MODE=Observer guard "observer: allowed with 3 down" 0
N=10 LIVE=10
guard "n=10 all up: allowed" 0
N=10 LIVE=12
guard "more authors than members counts as none down" 0

# The count cannot be made.
N=10 LIVE=10
COMMITTEE_UP=0 guard "mainnet voting node, committee unreadable: refused (rc 2)" 2
COMMITTEE_UP=0 TN_ALLOW_QUORUM_RISK=1 guard "mainnet, committee unreadable, override: allowed" 0
AGE=600 guard "mainnet, commit 600 s old: refused (rc 2)" 2
HDR_EPOCH=6 guard "mainnet, commit from another epoch: refused (rc 2)" 2
LOCAL_UP=0 PUBLIC_UP=0 STAKED=0 guard "mainnet, nothing answers, staked: refused (rc 2)" 2
LOCAL_UP=0 PUBLIC_UP=0 STAKED=1 guard "mainnet, nothing answers: the stake is not read either, refused (rc 2)" 2
LOCAL_UP=0 COMMITTEE_UP=0 STAKED=0 guard "mainnet, no committee, staked: refused (rc 2)" 2
LOCAL_UP=0 COMMITTEE_UP=0 STAKED=1 guard "mainnet, no committee, not staked: allowed" 0
LOCAL_UP=0 COMMITTEE_UP=0 STAKED=2 guard "mainnet, no committee, stake unknown: refused (rc 2)" 2
# The public RPC is trusted only when it answers with the network's chain id.
PUB_CHAIN=2017 LOCAL_UP=0 PUBLIC_UP=1 LIVE=9 guard "mainnet, local down, public RPC on chain 2017: not counted (rc 2)" 2
check_has "the refusal says the public RPC serves another chain" "yes" \
    "$(printf '%s' "$MSG" | grep -q 'does not answer with chain 487' && echo yes)"
PUB_CHAIN=2017 LOCAL_UP=0 COMMITTEE_UP=0 STAKED=1 guard "mainnet, public RPC on chain 2017: its stake answer is not used (rc 2)" 2
PUB_CHAIN=487 LOCAL_UP=0 PUBLIC_UP=1 LIVE=9 guard "mainnet, local down, public RPC on chain 487: counted" 0
# A node that does not answer authored nothing: it is among the down already,
# so stopping it adds none.
LOCAL_UP=0 PUBLIC_UP=1 LIVE=7 guard "local down, public RPC counts 3 down (this node among them): allowed" 0
check_has "the count says this node is among them" "yes" "$(printf '%s' "$MSG" | grep -q 'counted among them' && echo yes)"
LOCAL_UP=0 PUBLIC_UP=1 LIVE=6 guard "local down, public RPC counts 4 down: refused" 1
LOCAL_UP=0 PUBLIC_UP=1 LIVE=9 guard "local down, public RPC counts 1 down: allowed" 0
LOCAL_UP=0 PUBLIC_UP=1 N=4 LIVE=3 guard "n=4, this node crashed, the other 3 up: allowed" 0
LOCAL_UP=0 PUBLIC_UP=1 N=4 LIVE=2 guard "n=4, this node and one more down: refused" 1

# Mainnet with no VALIDATOR_ADDRESS to ask the registry about: the stake is not
# known, so a blind stop is refused.
printf 'NETWORK=mainnet\n' > "$META"
LOCAL_UP=0 PUBLIC_UP=0 STAKED=1 guard "mainnet, nothing answers, no VALIDATOR_ADDRESS: refused (rc 2)" 2
check_has "the refusal says the address is missing" "yes" "$(printf '%s' "$MSG" | grep -q 'no VALIDATOR_ADDRESS' && echo yes)"
LOCAL_UP=0 PUBLIC_UP=0 TN_ALLOW_QUORUM_RISK=1 guard "mainnet, no VALIDATOR_ADDRESS, override: allowed" 0

printf 'NETWORK=testnet\n' > "$META"
COMMITTEE_UP=0 guard "testnet, committee unreadable: warns, allowed" 0
check_has "testnet warning says so" "yes" "$(printf '%s' "$MSG" | grep -q 'could not count' && echo yes)"
N=10 LIVE=7 guard "testnet, 3 of 10 down: still refused" 1
printf 'NETWORK=bogus\n' > "$META"
COMMITTEE_UP=0 guard "unknown network, committee unreadable: refused (rc 2)" 2

# progress-fn gets the messages; nothing on stdout.
printf 'NETWORK=mainnet\n' > "$META"
SAID=""
say() { SAID="${SAID}$1:$2|"; }
rc=0; out="$(N=4 LIVE=4 tn_committee_down_guard "$LOCAL" say; printf 'said=%s' "$SAID")" || rc=$?
check_rc "progress-fn form: rc 0" 0 "$rc"
check "progress-fn form: one log line, no stdout" "yes" \
    "$(printf '%s' "$out" | grep -q '^said=log:committee of 4' && echo yes)"
finish
