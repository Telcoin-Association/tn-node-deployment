#!/usr/bin/env bash
# tools/tests/setup_passphrase_test.sh -- setup-node.sh keeps the BLS passphrase out of
# every child's environment and argv: --passphrase-stdin is read once, a passphrase that
# fails tn_passphrase_ok stops the run before the root check (so before any write),
# TN_BLS_PASSPHRASE is dropped from setup's own environment before anything runs, keytool
# gets the passphrase on stdin only, and keygen keeps only a wrapped key (bls.kw).
#
# A copy of setup-node.sh without its last line (`main "$@"`) is sourced at the top level
# (the lib is linked beside it), then the steps that touch the host are replaced: the
# root check records that it was reached, step_preflight runs apt-get and cargo shims
# that record their environment, tn_as_service_user runs the command as is (it must not
# hide a leaked variable), tn_write_root_file writes into the test dir. The real
# step_generate_keys and tn_keytool run against a recording telcoin-network stub.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
REC="$T/rec"
export REC
mkdir -p "$T/sn" "$T/bin" "$REC" "$T/written" "$T/root"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"

# Recording stubs: the node binary (keytool) and two package tools.
cat > "$T/bin/telcoin-network" <<'STUB'
#!/bin/sh
: > "$REC/keytool.argv"
dd=""
prev=""
for a in "$@"; do
    printf '%s\n' "$a" >> "$REC/keytool.argv"
    [ "$prev" = "--datadir" ] && dd="$a"
    prev="$a"
done
cat > "$REC/keytool.stdin"
env > "$REC/keytool.env"
mkdir -p "$dd/node-keys"
: > "$dd/node-keys/bls.kw"
[ -z "${STUB_CLEARTEXT:-}" ] || : > "$dd/node-keys/bls.key"
printf 'name: stub\n' > "$dd/node-info.yaml"
STUB
printf '#!/bin/sh\nenv > "$REC/$(basename "$0").env"\n' > "$T/bin/apt-get"
cp "$T/bin/apt-get" "$T/bin/cargo"
chmod 0755 "$T/bin/telcoin-network" "$T/bin/apt-get" "$T/bin/cargo"
PATH="$T/bin:$PATH"

TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e
if [[ "$(id -u)" == 0 ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
else
    SERVICE_USER="$(id -un)"
    SERVICE_GROUP="$(id -gn)"
fi
TN_UPDATE_LOCK_FILE="$T/update.lock"

check_root() { : > "$REC/root-reached"; }
step_preflight() {
    apt-get install -y build-essential
    cargo build --release
    cat > "$REC/stdin-rest"
}
step_config() { :; }
step_create_infrastructure() {
    mkdir -p "$DATA_DIR"
    if [[ "$(id -u)" == 0 ]]; then chown nobody "$DATA_DIR"; fi
}
tn_as_service_user() { "$@"; }
tn_write_root_file() { cat > "$T/written/${1##*/}"; }
display_node_info() { :; }

KG=(--json --phase=keygen --network testnet --install-method existing
    --binary-path "$T/bin/telcoin-network"
    --address 0x1111111111111111111111111111111111111111
    --external-primary /ip4/1.2.3.4/udp/49590/quic-v1
    --external-worker /ip4/1.2.3.4/udp/49595/quic-v1
    --listener-primary /ip4/10.0.0.1/udp/49590/quic-v1
    --listener-worker /ip4/10.0.0.1/udp/49595/quic-v1
    --data-dir "$T/data")

# reset: a clean data dir and no recordings.
reset() {
    rm -rf "${T:?}/data" "${T:?}/update.lock" "${T:?}/update.lock.d"
    rm -f "${REC:?}"/* "${T:?}/written"/*
}
# run_main INPUT-FILE ARGS... -- main in a subshell, stdin from INPUT-FILE; JSON on
# $T/out, the rest on $T/err. Prints main's exit status.
run_main() {
    local in="$1" rc=0
    shift
    ( main "$@" ) < "$in" > "$T/out" 2> "$T/err" || rc=$?
    printf '%s\n' "$rc"
}
# all_child_env -- every environment a child recorded.
all_child_env() { cat "$REC"/*.env 2>/dev/null; }

# ---- --passphrase-stdin: read once, on stdin only --------------------------------------
PASS="stdin-pass-Q1w2e3"
reset
printf '%s\nleftover-line\n' "$PASS" > "$T/in"
rc="$(run_main "$T/in" "${KG[@]}" --passphrase-stdin)"
check_rc "stdin: keygen rc" 0 "$rc"
check_has "stdin: done ok" "yes" "$(grep -q '"event":"done","ok":true,"phase":"keygen"' "$T/out" && echo yes)"
check "stdin: one line read, the rest left on stdin" "leftover-line" "$(cat "$REC/stdin-rest")"
check "stdin: keytool got the passphrase on stdin" "$PASS" "$(cat "$REC/keytool.stdin")"
check_has "stdin: keytool --bls-passphrase-source" "--bls-passphrase-source" "$(cat "$REC/keytool.argv")"
check_has "stdin: keytool source stdin" "stdin" "$(cat "$REC/keytool.argv")"
check_lacks "stdin: passphrase in no argv" "$PASS" "$(cat "$REC/keytool.argv")"
check_lacks "stdin: passphrase in no child env" "$PASS" "$(all_child_env)"
check "stdin: three children recorded an env" "3" "$(ls "$REC"/*.env | wc -l | tr -d ' ')"
check "stdin: passphrase file content" "$PASS" "$(cat "$T/written/bls-passphrase")"
check "stdin: wrapped key kept" "yes no" \
    "$([[ -f "$T/data/node-keys/bls.kw" ]] && echo yes || echo no) $([[ -e "$T/data/node-keys/bls.key" ]] && echo yes || echo no)"

# ---- TN_BLS_PASSPHRASE: dropped from the environment before any child runs ---------------
ENVPASS="env-pass-Z9x8c7"
reset
rc="$( export TN_BLS_PASSPHRASE="$ENVPASS" TN_SETUP_PASS="inherited-junk-1" TN_KEYTOOL_PASS="inherited-junk-2"
       run_main /dev/null "${KG[@]}" )"
check_rc "env: keygen rc" 0 "$rc"
check "env: keytool got it on stdin" "$ENVPASS" "$(cat "$REC/keytool.stdin")"
check_lacks "env: TN_BLS_PASSPHRASE in no child env" "TN_BLS_PASSPHRASE" "$(all_child_env)"
check_lacks "env: TN_SETUP_PASS in no child env" "TN_SETUP_PASS" "$(all_child_env)"
check_lacks "env: TN_KEYTOOL_PASS in no child env" "TN_KEYTOOL_PASS" "$(all_child_env)"
check_lacks "env: passphrase in no child env" "$ENVPASS" "$(all_child_env)"
check_lacks "env: passphrase in no argv" "$ENVPASS" "$(cat "$REC/keytool.argv")"

# ---- one trailing CR is dropped ----------------------------------------------------------
reset
printf 'crlf-pass-9\r\n' > "$T/in"
rc="$(run_main "$T/in" "${KG[@]}" --passphrase-stdin)"
check_rc "crlf: keygen rc" 0 "$rc"
check "crlf: CR dropped" "crlf-pass-9" "$(cat "$REC/keytool.stdin")"

# ---- refusals: non-zero before the root check, nothing written --------------------------
# refused NAME INPUT-FILE ARGS... -- main fails, never reaches check_root, takes no lock,
# runs no child and writes nothing.
refused() {
    local name="$1" in="$2" rc
    shift 2
    reset
    rc="$(run_main "$in" "$@")"
    check_rc "$name: rc" 1 "$rc"
    check "$name: stopped before the root check, no lock, no child, no write" "no no no no" \
        "$([[ -e "$REC/root-reached" ]] && echo yes || echo no) $([[ -e "$T/update.lock" || -e "$T/update.lock.d" ]] && echo yes || echo no) $(ls "$REC"/*.env >/dev/null 2>&1 && echo yes || echo no) $(ls "$T/written"/* >/dev/null 2>&1 && echo yes || echo no)"
    check_has "$name: done ok:false" "yes" "$(grep -q '"event":"done","ok":false' "$T/out" && echo yes)"
}
printf ' lead-secret-x\n' > "$T/in"
refused "stdin leading space" "$T/in" "${KG[@]}" --passphrase-stdin
check_lacks "stdin leading space: secret not echoed" "lead-secret-x" "$(cat "$T/out" "$T/err")"
printf 'trail-secret-y \n' > "$T/in"
refused "stdin trailing space" "$T/in" "${KG[@]}" --passphrase-stdin
refused "stdin empty" /dev/null "${KG[@]}" --passphrase-stdin
printf '\n' > "$T/in"
refused "stdin empty line" "$T/in" "${KG[@]}" --passphrase-stdin
reset
printf 'tab\there\n' > "$T/in"
check_rc "stdin interior tab is fine" 0 "$(run_main "$T/in" "${KG[@]}" --passphrase-stdin)"
printf 'both-pass-1\n' > "$T/in"
export TN_BLS_PASSPHRASE="both-pass-2"
refused "env and stdin both" "$T/in" "${KG[@]}" --passphrase-stdin
check_has "env and stdin both: message" "yes" "$(grep -q 'one way' "$T/out" && echo yes)"
export TN_BLS_PASSPHRASE="env-bad-z "
refused "env trailing space" /dev/null "${KG[@]}"
check_lacks "env trailing space: secret not echoed" "env-bad-z" "$(cat "$T/out" "$T/err")"
unset TN_BLS_PASSPHRASE
refused "no passphrase at all" /dev/null "${KG[@]}"

# ---- the mainnet length rule (json_check_keygen_inputs) ----------------------------------
# keygen_inputs PASS NETWORK -- json_check_keygen_inputs' status for PASS on NETWORK.
keygen_inputs() {
    local rc=0
    ( JSON_MODE=false; JSON_PHASE=keygen; NETWORK="$2"; TN_SETUP_PASS="$1"
      VALIDATOR_ADDRESS=0x1111111111111111111111111111111111111111
      PRIMARY_MULTIADDR=a; WORKER_MULTIADDR=b; PRIMARY_LISTENER_MULTIADDR=c; WORKER_LISTENER_MULTIADDR=d
      json_check_keygen_inputs ) >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
check_rc "mainnet: 15 bytes refused" 1 "$(keygen_inputs abcdefghijklmno mainnet)"
check_rc "mainnet: 16 bytes accepted" 0 "$(keygen_inputs abcdefghijklmnop mainnet)"
check_rc "testnet: 3 bytes accepted" 0 "$(keygen_inputs abc testnet)"

# ---- keygen that leaves a cleartext bls.key fails and removes the keys -------------------
reset
printf 'clear-pass-1\n' > "$T/in"
export STUB_CLEARTEXT=1
rc="$(run_main "$T/in" "${KG[@]}" --passphrase-stdin)"
unset STUB_CLEARTEXT
check_rc "cleartext key: rc" 1 "$rc"
check "cleartext key: keys dir removed, no passphrase file" "no no" \
    "$([[ -e "$T/data/node-keys" ]] && echo yes || echo no) $([[ -e "$T/written/bls-passphrase" ]] && echo yes || echo no)"

# ---- the interactive prompt (twice, checked, asked again) --------------------------------
# prompt INPUT-FILE NETWORK -- setup_keygen_passphrase at the prompt; prints its rc and
# leaves the value it settled on in $REC/prompt.
prompt() {
    local rc=0
    ( JSON_MODE=false; NETWORK="$2"; TN_SETUP_PASS=""; TN_SETUP_PASS_SRC=""
      setup_keygen_passphrase >/dev/null 2>&1 || exit $?
      printf '%s' "$TN_SETUP_PASS" > "$REC/prompt" ) < "$1" || rc=$?
    printf '%s\n' "$rc"
}
reset
printf 'one\ntwo\n lead\n lead\n\n\ngood-pass\ngood-pass\n' > "$T/in"
check_rc "prompt: rc" 0 "$(prompt "$T/in" testnet)"
check "prompt: mismatch, whitespace and empty asked again" "good-pass" "$(cat "$REC/prompt")"
reset
printf 'short-pass\nshort-pass\nlong-enough-pass-16\nlong-enough-pass-16\n' > "$T/in"
check_rc "prompt mainnet: rc" 0 "$(prompt "$T/in" mainnet)"
check "prompt mainnet: short one asked again" "long-enough-pass-16" "$(cat "$REC/prompt")"
check_rc "prompt: end of input stops" 1 "$(prompt /dev/null testnet)"

finish
