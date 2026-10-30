#!/usr/bin/env bash
# tools/tests/quorum_guard_test.sh -- tn_committee_down_guard. A curl function
# answers the JSON-RPC calls from generated fixtures: the node's mode, the
# current committee (n members) and the latest consensus commit (with `live`
# distinct authors). Covers n = 4, 7 and 10 with 0 to f+1 members down, a node
# that is not voting, an unreadable committee on mainnet and testnet, a stale or
# other-epoch commit, the fallback to the public RPC (a node that does not answer
# is counted as still voting unless tn_info on the node proves it authored
# nothing), a mainnet node with no VALIDATOR_ADDRESS, TN_ALLOW_QUORUM_RISK=1, and
# the helpers _tn_commit_has_author and tn_node_authority_id.
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
# LOCAL_MODE_FAIL: timeout (tn_nodeMode on the node times out) or rpc-error (it
# answers a JSON-RPC error). LOCAL_INFO: the authority_id tn_info on the node
# answers with; empty, tn_info fails. CALLS logs "<url> <method>" per call and
# TIMES "<method> <max-time>"; guard empties both before each run.
LOCAL_MODE_FAIL="" LOCAL_INFO=""
CALLS="$TN_TEST_TMP/calls" TIMES="$TN_TEST_TMP/times"
STAKED=0
node_is_staked_validator() { return "$STAKED"; }

committee_json() {
    local i list=""
    for ((i = 1; i <= N; i++)); do
        list="${list:+${list},}\"0x$(printf '%040x' "$i")\""
    done
    printf '{"jsonrpc":"2.0","id":1,"result":{"epochId":%s,"blockHeight":100,"epochDuration":86400,"stakeVersion":0,"committee":[%s]}}' "$EPOCH" "$list"
}
# auth_id I -- a 22-character base58 authority id for member I, distinct per I:
# a 0 in I becomes z (0 is not base58) and x pads it, so no id is a prefix of
# another.
auth_id() {
    local s
    s="Auth${1//0/z}xxxxxxxxxxxxxxxxxxxxxx"
    printf '%s\n' "${s:0:22}"
}
header_json() {
    local i hs="" now a
    now="$(date +%s)"
    for ((i = 1; i <= LIVE; i++)); do
        a="$(auth_id "$i")"
        # Two headers per live author: the count must be of distinct authors.
        hs="${hs:+${hs},}{\"author\":\"${a}\",\"epoch\":${HDR_EPOCH}},{\"author\":\"${a}\",\"epoch\":${HDR_EPOCH}}"
    done
    printf '{"jsonrpc":"2.0","id":1,"result":{"number":5,"sub_dag":{"headers":[%s],"commit_timestamp":%s}}}' "$hs" "$((now - AGE))"
}
curl() {
    local data="" url="" a method max=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data) data="$2"; shift 2 ;;
            --url) url="$2"; shift 2 ;;
            --max-time) max="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    method="$(printf '%s' "$data" | sed -n 's/.*"method":"\([A-Za-z_]*\)".*/\1/p')"
    printf '%s %s\n' "$url" "$method" >> "$CALLS"
    printf '%s %s\n' "$method" "$max" >> "$TIMES"
    if [[ "$url" == "$LOCAL" && "$LOCAL_UP" != 1 ]]; then return 7; fi
    if [[ "$url" != "$LOCAL" && "$PUBLIC_UP" != 1 ]]; then return 7; fi
    case "$method" in
        tn_nodeMode)
            [[ "$url" == "$LOCAL" ]] || return 7
            case "$LOCAL_MODE_FAIL" in
                timeout) return 28 ;;
                rpc-error) a='{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}' ;;
                *) a="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"${MODE}\"}" ;;
            esac
            ;;
        tn_info)
            [[ "$url" == "$LOCAL" && -n "$LOCAL_INFO" ]] || return 7
            a="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"chain_id\":2017,\"version\":\"x\",\"authority_id\":\"${LOCAL_INFO}\"}}"
            ;;
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
    : > "$CALLS"
    : > "$TIMES"
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
# A node whose mode cannot be read may still be voting: it is counted as voting,
# so stopping it adds one, unless tn_info on the node itself proves it authored
# nothing in the counted commit. With the local RPC down, tn_info fails too.
LOCAL_UP=0 PUBLIC_UP=1 LIVE=7 guard "local down, public RPC counts 3 down, this node still counted as voting: refused" 1
check_has "the count says this node is counted as voting" "yes" "$(printf '%s' "$MSG" | grep -q 'counted as still voting' && echo yes)"
LOCAL_UP=0 PUBLIC_UP=1 LIVE=6 guard "local down, public RPC counts 4 down: refused" 1
LOCAL_UP=0 PUBLIC_UP=1 LIVE=9 guard "local down, public RPC counts 1 down: allowed" 0
LOCAL_UP=0 PUBLIC_UP=1 N=4 LIVE=3 guard "n=4, local RPC down, the other 3 up: this node counted as voting, refused" 1
check_has "tn_info is asked of the node" "yes" "$(grep -qxF "$LOCAL tn_info" "$CALLS" && echo yes)"
check_lacks "tn_info is never asked of the public RPC" "$MAINNET_RPC_URL tn_info" "$(cat "$CALLS")"
LOCAL_UP=0 PUBLIC_UP=1 N=4 LIVE=2 guard "n=4, this node and one more down: refused" 1

# The node answers everything but tn_nodeMode.
LOCAL_MODE_FAIL=timeout N=4 LIVE=3 guard "n=4, mode times out, no tn_info: counted as voting, refused" 1
check_has "says counted as still voting" "yes" "$(printf '%s' "$MSG" | grep -q 'counted as still voting' && echo yes)"
check_has "tn_info asked of the node" "yes" "$(grep -qxF "$LOCAL tn_info" "$CALLS" && echo yes)"
check_has "tn_info bounded at 3 s" "yes" "$(grep -qxF 'tn_info 3' "$TIMES" && echo yes)"
check "refusal under the UI cut" "yes" "$([[ ${#MSG} -le 300 ]] && echo yes)"
check_has "refusal names the override" "yes" "$(printf '%s' "$MSG" | grep -q -- '--allow-quorum-risk' && echo yes)"
LOCAL_MODE_FAIL=rpc-error N=4 LIVE=3 LOCAL_INFO="$(auth_id 1)" guard "n=4, mode rpc-error, authored in the commit: refused" 1
check_has "says it authored in the latest commit" "yes" "$(printf '%s' "$MSG" | grep -q 'authored in the latest commit' && echo yes)"
LOCAL_MODE_FAIL=rpc-error N=4 LIVE=3 LOCAL_INFO="$(auth_id 4)" guard "n=4, mode rpc-error, authored nothing: already down, allowed" 0
check_has "says it authored nothing" "yes" "$(printf '%s' "$MSG" | grep -q 'authored nothing' && echo yes)"
LOCAL_MODE_FAIL=timeout N=4 LIVE=2 LOCAL_INFO="$(auth_id 4)" guard "n=4, authored nothing, 2 others down: refused" 1
check_has "says it authored nothing (refused)" "yes" "$(printf '%s' "$MSG" | grep -q 'authored nothing' && echo yes)"
# The longest refusal: the authored-nothing note with a two-digit committee.
LOCAL_MODE_FAIL=timeout N=10 LIVE=6 LOCAL_INFO="$(auth_id 10)" guard "n=10, authored nothing, 4 others down: refused" 1
check "longest refusal under the UI cut" "yes" "$([[ ${#MSG} -le 300 ]] && echo yes)"
check_has "longest refusal names the override" "yes" "$(printf '%s' "$MSG" | grep -q -- '--allow-quorum-risk' && echo yes)"
LOCAL_MODE_FAIL=timeout N=4 LIVE=3 LOCAL_INFO="not-base58-0OIl" guard "n=4, malformed authority id ignored: counted as voting, refused" 1
check_has "malformed id: says counted as still voting" "yes" "$(printf '%s' "$MSG" | grep -q 'counted as still voting' && echo yes)"
LOCAL_MODE_FAIL=timeout N=4 LIVE=3 TN_ALLOW_QUORUM_RISK=1 guard "n=4, mode times out, override: allowed" 0
check_has "override warns" "yes" "$(printf '%s' "$MSG" | grep -q 'override' && echo yes)"
# A readable mode never asks tn_info.
MODE=CvvActive N=4 LIVE=4 guard "n=4, CvvActive, none down: allowed" 0
check_lacks "tn_info not asked when the mode is readable" "tn_info" "$(cat "$CALLS")"
MODE=CvvActive N=4 LIVE=3 guard "n=4, CvvActive, one down: refused" 1
check_lacks "tn_info not asked when the mode is readable (refused)" "tn_info" "$(cat "$CALLS")"

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

# _tn_commit_has_author JSON ID: 0 present, 1 absent, 2 not a base58 id.
hdr="$(LIVE=3 header_json)"
has_author() { local rc=0; _tn_commit_has_author "$1" "$2" || rc=$?; printf '%s\n' "$rc"; }
check "has_author: present" 0 "$(has_author "$hdr" "$(auth_id 2)")"
check "has_author: absent" 1 "$(has_author "$hdr" "$(auth_id 4)")"
check "has_author: a prefix of an author is absent" 1 "$(has_author "$hdr" Auth1)"
check "has_author: spaces around the colon" 0 "$(has_author '{"author" :  "Abc123"}' Abc123)"
check "has_author: not base58" 2 "$(has_author "$hdr" Auth0)"
check "has_author: regex text is not an id" 2 "$(has_author "$hdr" 'Auth.*')"
check "has_author: empty id" 2 "$(has_author "$hdr" "")"

# tn_node_authority_id: the id, the rpc failure line, or malformed.
rc=0; out="$(LOCAL_INFO="$(auth_id 3)" tn_node_authority_id "$LOCAL" 3)" || rc=$?
check "authority id: rc 0 and the id" "0 $(auth_id 3)" "$rc $out"
rc=0; out="$(LOCAL_UP=0 tn_node_authority_id "$LOCAL" 3)" || rc=$?
check "authority id: transport failure line" "1 transport connect" "$rc $out"
rc=0; out="$(LOCAL_INFO="not-base58-0OIl" tn_node_authority_id "$LOCAL" 3)" || rc=$?
check "authority id: malformed" "1 malformed authority-id not-base58-0OIl" "$rc $out"
rc=0; out="$(LOCAL_INFO='Abc' tn_node_authority_id "$LOCAL" 3)" || rc=$?
check "authority id: short id is malformed" "1 malformed authority-id Abc" "$rc $out"
rc=0; out="$(LOCAL_INFO='ab c!x;' tn_node_authority_id "$LOCAL" 3)" || rc=$?
check "authority id: malformed id is sanitised" "1 malformed authority-id abcx" "$rc $out"
finish
