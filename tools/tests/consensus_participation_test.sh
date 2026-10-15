#!/usr/bin/env bash
# tools/tests/consensus_participation_test.sh -- update-node.sh's check after a
# restart (verify_consensus_participation): the chain id must be the network's, the
# consensus header must advance, and a node that was CvvActive before the stop must
# read CvvActive again within TN_UPDATE_VOTE_TIMEOUT. update_epoch_wait records the
# mode before the stop (UPDATE_MODE_BEFORE, MODE_BEFORE in the pending state), also
# with --no-epoch-wait. A failed check puts "voting":false in the --json done event.
#
# A curl shim on PATH answers each JSON-RPC method from a sequence file (one answer
# per call, the last one repeated); sleep is a function that only counts. A copy of
# update-node.sh without its last line is sourced at the top level. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
SEQ="$T/seq"
export SEQ
mkdir -p "$T/h" "$T/root/etc/telcoin" "$T/bin" "$SEQ"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common
printf 'NETWORK=testnet\nRPC_PORT=8545\n' > "$T/root/etc/telcoin/.node-meta"
SERVICE_NAME=telcoin JSON_MODE=false RPC_URL="http://127.0.0.1:8545"

cat > "$T/bin/curl" <<'SHIM'
#!/bin/sh
body=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--data" ]; then body="$2"; shift; fi
    shift
done
m="$(printf '%s' "$body" | sed -n 's/.*"method":"\([A-Za-z_]*\)".*/\1/p')"
f="$SEQ/$m"
[ -f "$f" ] || exit 7
n="$(cat "$f.n" 2>/dev/null || echo 0)"
n=$((n + 1))
echo "$n" > "$f.n"
total="$(awk 'END { print NR }' "$f")"
[ "$n" -gt "$total" ] && n="$total"
printf '%s\n200' "$(sed -n "${n}p" "$f")"
SHIM
chmod 0755 "$T/bin/curl"
PATH="$T/bin:$PATH"
SLEPT=0
sleep() { SLEPT=$(( SLEPT + ${1:-0} )); }

# rpc_seq METHOD ANSWER... -- the answers (JSON-RPC results) METHOD gives, in order.
rpc_seq() {
    local m="$1" a
    shift
    : > "$SEQ/$m"
    rm -f "$SEQ/$m.n"
    for a in "$@"; do
        printf '{"jsonrpc":"2.0","id":1,"result":%s}\n' "$a" >> "$SEQ/$m"
    done
}
hdr() { printf '{"number":%s,"sub_dag":{"headers":[]}}' "$1"; }
cpv() {  # cpv NAME MODE_BEFORE EXPECTED-RC EXPECTED-VOTING
    local rc=0
    SLEPT=0
    UPDATE_MODE_BEFORE="$2"
    verify_consensus_participation > "$T/out" 2>&1 || rc=$?
    check "$1" "$3 $4" "$rc $UPDATE_VOTING"
}
TN_UPDATE_VOTE_POLL=10 TN_UPDATE_VOTE_TIMEOUT=60

rpc_seq eth_chainId '"0x7e1"'
rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 101)"
rpc_seq tn_nodeMode '"CvvActive"'
cpv "was active: active again and the header advances" CvvActive 0 true
check "was active: one poll" 10 "$SLEPT"

rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 100)"
rpc_seq tn_nodeMode '"CvvActive"'
cpv "was active: active but the header does not advance" CvvActive 1 false
check "no progress: the window was used up" 60 "$SLEPT"
check "no progress: says so" yes "$(grep -q 'did not advance within 60s' "$T/out" && echo yes || echo no)"
check "no progress: --json done carries voting false" ',"voting":false' "$(update_vote_field)"

rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 102)"
rpc_seq tn_nodeMode '"CvvInactive"'
cpv "was active: not active again within the timeout" CvvActive 1 false
check "not active: says so" yes "$(grep -q 'was voting (CvvActive) before the update and reads CvvInactive' "$T/out" && echo yes || echo no)"

rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 105)"
rpc_seq tn_nodeMode '"CvvInactive"' '"CvvInactive"' '"CvvActive"'
cpv "was active: votes again after two polls" CvvActive 0 true
check "votes again: header poll plus two mode polls" 30 "$SLEPT"
check "passed: no voting field" "" "$(update_vote_field)"

rpc_seq tn_latestConsensusHeader "$(hdr 7)" "$(hdr 7)" "$(hdr 7)" "$(hdr 8)"
rpc_seq tn_nodeMode '"Observer"'
cpv "was an observer: header advances on the third poll" Observer 0 false

rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 101)"
rpc_seq tn_nodeMode '"CvvInactive"'
cpv "mode unknown before the stop: no vote requirement" "" 0 false

rpc_seq eth_chainId '"0x1e7"'
rpc_seq tn_latestConsensusHeader "$(hdr 100)" "$(hdr 101)"
cpv "testnet node on chain 487: refused" Observer 1 false
check "wrong chain: says so" yes "$(grep -q 'runs chain id 487, not 2017' "$T/out" && echo yes || echo no)"

rm -f "$SEQ/eth_chainId"
cpv "no eth_chainId answer: refused" Observer 1 false
rpc_seq eth_chainId '"0x7e1"'
rpc_seq tn_latestConsensusHeader 'null'
cpv "no header number: refused" Observer 1 false

# update_epoch_wait records the mode before the stop, also with --no-epoch-wait;
# a refused quorum guard stops before it.
tn_committee_down_guard() { return "$GUARD_RC"; }
tn_wait_restart_window() { return 0; }
pending_state_add() { printf '%s\n' "$*" >> "$T/pending.add"; }
GUARD_RC=0 NO_EPOCH_WAIT=true
rpc_seq tn_nodeMode '"CvvActive"'
: > "$T/pending.add"
UPDATE_MODE_BEFORE=""
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "epoch wait records the mode" "0 CvvActive" "$rc $UPDATE_MODE_BEFORE"
check "the mode goes into the pending state" "MODE_BEFORE=CvvActive" "$(cat "$T/pending.add")"
GUARD_RC=1
: > "$T/pending.add"
UPDATE_MODE_BEFORE=""
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "refused guard: rc 1, nothing recorded" "1  none" "$rc $UPDATE_MODE_BEFORE $(cat "$T/pending.add" 2>/dev/null || true)none"
GUARD_RC=0 NO_EPOCH_WAIT=false
rm -f "$SEQ/tn_nodeMode"
: > "$T/pending.add"
rc=0; update_epoch_wait >/dev/null 2>&1 || rc=$?
check "unreadable mode: recorded as unknown" "0 x" "$rc ${UPDATE_MODE_BEFORE}x"

# Every apply path runs the check before it reports success.
check "four apply paths run verify_consensus_participation" 4 \
    "$(grep -c 'verify_consensus_participation; then' "$TN_TEST_REPO/update-node.sh")"
finish
