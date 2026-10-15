#!/usr/bin/env bash
# tools/tests/keytool_test.sh -- tn_keytool passes the passphrase on stdin only,
# and tn_wait_restart_window waits for a staked node whose mode is unreadable
# (epoch timing from the public RPC, then the local one, else a bounded wait).
# A recording stub stands in for the node binary and for docker;
# tn_as_service_user is replaced by a shim that drops TN_BLS_PASSPHRASE the same
# way (its own privilege drop is covered by primitives_test.sh). Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"
T="$TN_TEST_TMP"

mkdir -p "$T/bin" "$T/data"
cat > "$T/bin/telcoin-network" <<'EOF'
#!/bin/sh
: > "$REC.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$REC.argv"; done
cat > "$REC.stdin"
env > "$REC.env"
EOF
chmod 0755 "$T/bin/telcoin-network"
cp "$T/bin/telcoin-network" "$T/bin/docker"
export REC="$T/rec"
PATH="$T/bin:$PATH"
tn_as_service_user() { ( unset TN_BLS_PASSPHRASE; "$@" ); }

if [[ "$(id -u)" == 0 ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
    chown nobody "$T/data"
else
    SERVICE_USER="$(id -un)"
    SERVICE_GROUP="$(id -gn)"
fi
BIN="binary:$T/bin/telcoin-network"
export TN_BLS_PASSPHRASE="env-secret-zz"
reset_rec() { rm -f "$REC".*; }

reset_rec
TN_KEYTOOL_PASS="pass phrase-yy"
rc=0; tn_keytool "$BIN" "$T/data" generate validator --address 0x01 || rc=$?
check_rc "keytool: binary rc" 0 "$rc"
check_has "keytool: stdin source flag" "--bls-passphrase-source" "$(cat "$REC.argv")"
check_has "keytool: stdin source value" "stdin" "$(cat "$REC.argv")"
check "keytool: passphrase on stdin" "pass phrase-yy" "$(cat "$REC.stdin")"
check_lacks "keytool: passphrase not in argv" "phrase-yy" "$(cat "$REC.argv")"
check_lacks "keytool: passphrase not in env" "phrase-yy" "$(cat "$REC.env")"
check_lacks "keytool: TN_BLS_PASSPHRASE not passed on" "env-secret-zz" "$(cat "$REC.env")"
check_has "keytool: binary HOME is the data dir (log dir writable)" "HOME=$T/data" "$(cat "$REC.env")"
check "keytool: global flags first" "-q --datadir $T/data --bls-passphrase-source stdin keytool generate" \
    "$(head -7 "$REC.argv" | tr '\n' ' ' | sed 's/ $//')"

reset_rec
export TN_KEYTOOL_PASS
rc=0; tn_keytool "$BIN" "$T/data" generate validator 2>/dev/null || rc=$?
check_rc "keytool: exported TN_KEYTOOL_PASS refused" 4 "$rc"
check "keytool: exported pass ran nothing" "no" "$([[ -e "$REC.argv" ]] && echo yes || echo no)"
export -n TN_KEYTOOL_PASS 2>/dev/null || { _p="$TN_KEYTOOL_PASS"; unset TN_KEYTOOL_PASS; TN_KEYTOOL_PASS="$_p"; }

reset_rec
rc=0; TN_KEYTOOL_PASS=prefixed tn_keytool "$BIN" "$T/data" generate validator 2>/dev/null || rc=$?
check_rc "keytool: prefix assignment (exported for the call) refused" 4 "$rc"

reset_rec
rc=0; tn_keytool "$BIN" "$T/data" generate validator --bls-passphrase-source env 2>/dev/null || rc=$?
check_rc "keytool: own passphrase source with TN_KEYTOOL_PASS refused" 4 "$rc"

reset_rec
TN_KEYTOOL_PASS=""
rc=0; tn_keytool "$BIN" "$T/data" export-staking-args --calldata || rc=$?
check_rc "keytool: no passphrase rc" 0 "$rc"
check_has "keytool: export-staking-args gets no-passphrase" "no-passphrase" "$(cat "$REC.argv")"
check "keytool: no passphrase, empty stdin" "" "$(cat "$REC.stdin")"
check_lacks "keytool: no passphrase still drops TN_BLS_PASSPHRASE" "env-secret-zz" "$(cat "$REC.env")"

reset_rec
TN_KEYTOOL_PASS="docker-pass-xx"
rc=0; tn_keytool "docker:img:v1" "$T/data" generate validator || rc=$?
check_rc "keytool: docker rc" 0 "$rc"
check_has "keytool: docker -i" "-i" "$(cat "$REC.argv")"
check_has "keytool: docker --user service uid:gid" \
    "$(id -u "$SERVICE_USER"):$(command getent group "$SERVICE_GROUP" | cut -d: -f3)" "$(cat "$REC.argv")"
check "keytool: docker passphrase on stdin" "docker-pass-xx" "$(cat "$REC.stdin")"
check_lacks "keytool: docker passphrase not in argv" "docker-pass-xx" "$(cat "$REC.argv")"
check_lacks "keytool: docker gets no TN_BLS_PASSPHRASE" "TN_BLS_PASSPHRASE" "$(cat "$REC.argv") $(cat "$REC.env")"

reset_rec
mkdir -p "$T/other"
[[ "$(id -u)" == 0 ]] && chown 4242 "$T/other"
SU_SAVE="$SERVICE_USER"
[[ "$(id -u)" == 0 ]] || SERVICE_USER=nobody
rc=0; tn_keytool "$BIN" "$T/other" generate validator 2>/dev/null || rc=$?
check_rc "keytool: data dir not the service user's refused" 4 "$rc"
SERVICE_USER="$SU_SAVE"
unset TN_BLS_PASSPHRASE

# tn_wait_restart_window with an unreadable node mode.
mkdir -p "$T/root/etc/telcoin"
META="$T/root/etc/telcoin/.node-meta"
TN_ROOT_PREFIX="$T/root"
NET=testnet
STAKED=0
tn_node_mode() { printf 'rpc down'; return 1; }
tn_detect_network() { printf '%s\n' "$NET"; }
node_is_staked_validator() { printf '%s\n' "$2" > "$T/stake-url"; return "$STAKED"; }
# The public RPC serves the network's chain (the chain-id check is quorum_guard_test's).
_tn_rpc_chain_is() { return 0; }
tn_epoch_secs_left() { printf '%s\n' "$1" > "$T/epoch-url"; printf '9999 5 0 0\n'; }
say() { printf '%s %s\n' "$1" "$2" >> "$T/say"; }
run_wait() { rm -f "$T/say" "$T/epoch-url" "$T/stake-url"; tn_wait_restart_window "http://127.0.0.1:8545" say; }

printf 'VALIDATOR_ADDRESS=0x%040d\n' 7 > "$META"
NET=testnet; STAKED=0; run_wait
check "wait: staked testnet node reads epoch from the public RPC" "$TESTNET_RPC_URL" "$(cat "$T/epoch-url" 2>/dev/null)"
check_has "wait: staked node is not skipped" "yes" "$(grep -q 'outside the' "$T/say" && echo yes)"
NET=testnet; STAKED=1; run_wait
check "wait: non-validator skips" "none" "$(cat "$T/epoch-url" 2>/dev/null || echo none)"
NET=testnet; STAKED=2; run_wait
check "wait: unreadable stake on testnet skips" "none" "$(cat "$T/epoch-url" 2>/dev/null || echo none)"
NET=mainnet; STAKED=2; run_wait
check "wait: unreadable stake on mainnet waits" "$MAINNET_RPC_URL" "$(cat "$T/epoch-url" 2>/dev/null)"
check_has "wait: mainnet unreadable stake warns" "yes" "$(grep -q '^warn ' "$T/say" && echo yes)"
printf 'VALIDATOR_ADDRESS=0x1\nVALIDATOR_ADDRESS=0x2\n' > "$META"
NET=mainnet; STAKED=0; run_wait
check "wait: duplicated address on mainnet waits" "$MAINNET_RPC_URL" "$(cat "$T/epoch-url" 2>/dev/null)"
printf 'NETWORK=testnet\n' > "$META"
NET=testnet; STAKED=0; run_wait
check "wait: no validator address skips" "none" "$(cat "$T/epoch-url" 2>/dev/null || echo none)"

# The epoch timing from the public RPC, then the local one; when neither answers,
# a node that must wait waits TN_EPOCH_MARGIN + TN_EPOCH_SETTLE (at most
# TN_EPOCH_WAIT_MAX). EPOCH_OK lists the URLs that answer; naps are counted.
EPOCH_OK=""
tn_epoch_secs_left() {
    printf '%s\n' "$1" >> "$T/epoch-url"
    case " $EPOCH_OK " in
        *" $1 "*) printf '9999 5 0 0\n' ;;
        *) printf 'connection refused'; return 1 ;;
    esac
}
NAPPED=0
_tn_nap() { NAPPED=$(( NAPPED + $1 )); return 0; }
LOCAL="http://127.0.0.1:8545"
printf 'VALIDATOR_ADDRESS=0x%040d\n' 7 > "$META"
NET=mainnet; STAKED=2; EPOCH_OK="$LOCAL"; NAPPED=0; run_wait
check "wait: public RPC down, epoch read from the local RPC next" "$(printf '%s\n%s' "$MAINNET_RPC_URL" "$LOCAL")" "$(cat "$T/epoch-url")"
check_has "wait: that answer is used (outside the margin)" "yes" "$(grep -q 'outside the' "$T/say" && echo yes)"
check "wait: no blind wait when the local RPC answers" "0" "$NAPPED"
NET=mainnet; STAKED=2; EPOCH_OK=""; NAPPED=0; run_wait
check "wait: neither answers on mainnet: waits margin + settle" "390" "$NAPPED"
check_has "wait: the blind wait warns" "yes" "$(grep -q '^warn .*Waiting 390s' "$T/say" && echo yes)"
NET=mainnet; STAKED=2; EPOCH_OK=""; NAPPED=0
TN_EPOCH_WAIT_MAX=100 run_wait
check "wait: the blind wait is capped by TN_EPOCH_WAIT_MAX" "100" "$NAPPED"
NET=mainnet; STAKED=2; EPOCH_OK=""; NAPPED=0
TN_SKIP_EPOCH_WAIT=1 run_wait
check "wait: TN_SKIP_EPOCH_WAIT=1 skips the blind wait" "0" "$NAPPED"
NET=testnet; STAKED=0; EPOCH_OK=""; NAPPED=0; run_wait
check "wait: staked testnet node, neither answers: waits" "390" "$NAPPED"
tn_detect_network() { return 1; }
NET=""; STAKED=2; EPOCH_OK=""; NAPPED=0; run_wait
check "wait: unknown network: epoch read from the local RPC" "$LOCAL" "$(cat "$T/epoch-url")"
check "wait: unknown network, local down: waits margin + settle" "390" "$NAPPED"
tn_node_mode() { printf 'CvvActive'; return 0; }
NET=mainnet; STAKED=0; EPOCH_OK=""; NAPPED=0; run_wait
check "wait: mode read, epoch unreadable: continues without a blind wait" "0" "$NAPPED"
_tn_nap() { NAPPED=$(( NAPPED + $1 )); return 143; }
tn_node_mode() { printf 'rpc down'; return 1; }
tn_detect_network() { printf '%s\n' "$NET"; }
NET=mainnet; STAKED=2; EPOCH_OK=""; NAPPED=0; run_wait
check_has "wait: a signal ends the blind wait" "yes" "$(grep -q 'a signal interrupted the wait' "$T/say" && echo yes)"
check "wait: after one nap" "15" "$NAPPED"

finish
