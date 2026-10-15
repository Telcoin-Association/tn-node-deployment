#!/usr/bin/env bash
# =============================================================================
# tools/tests/network_detect_test.sh -- update-node.sh's network detection and
# the source prepare's build features: CRLF .node-meta, the genesis chain id
# fallback, a duplicated or unknown NETWORK (fail closed, no git, no cargo),
# duplicated INSTALL_METHOD and BINARY_PATH, the build log and the build
# output check.
#
#   bash tools/tests/network_detect_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/network_detect_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/network_detect_test.sh
#
# Runs as any user; everything lives in a fixture tree (TN_ROOT_PREFIX). git
# and cargo are stubs on PATH that leave a marker when they run.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/bin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common

run() {
    OUT="$("$@" 2>"$T/.err")"
    RC=$?
    ERR="$(cat "$T/.err")"
}
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }

for c in cargo git; do
    printf '#!/bin/sh\ntouch "%s/%s-ran"\nexit 1\n' "$T" "$c" > "$T/bin/$c"
    chmod 0755 "$T/bin/$c"
done
PATH="$T/bin:$PATH"

META="$T/fx/etc/telcoin/.node-meta"
DD="$T/fx/data"
mkdir -p "$T/fx/etc/telcoin" "$DD/genesis"

# meta LINE... -- write .node-meta with these lines (and DATA_DIR) as given.
# DATA_DIR is recorded as the node sees it; the resolvers prefix TN_ROOT_PREFIX.
meta() {
    : > "$META"
    printf 'DATA_DIR=/data\n' >> "$META"
    while [[ $# -gt 0 ]]; do
        printf '%s' "$1" >> "$META"
        shift
    done
}
genesis() { printf 'chainId: %s\n' "$1" > "$DD/genesis/genesis.yaml"; }
no_genesis() { rm -f "$DD/genesis/genesis.yaml"; }

# -----------------------------------------------------------------------------
# detect_network
# -----------------------------------------------------------------------------
no_genesis
meta $'NETWORK=mainnet\r\n'
run detect_network
check_rc "CRLF NETWORK=mainnet: rc 0" 0 "$RC"
check "CRLF NETWORK=mainnet: mainnet" "mainnet" "$OUT"

meta $'INSTALL_METHOD=source\r\n' $'NETWORK=testnet\r\n'
run detect_network
check "CRLF NETWORK=testnet: testnet" "testnet" "$OUT"

genesis 487
meta $'INSTALL_METHOD=source\n'
run detect_network
check_rc "no NETWORK, genesis 487: rc 0" 0 "$RC"
check "no NETWORK, genesis 487: mainnet" "mainnet" "$OUT"
genesis 2017
run detect_network
check "no NETWORK, genesis 2017: testnet" "testnet" "$OUT"
genesis 32285
run detect_network
check_rc "no NETWORK, devnet genesis: rc 1" 1 "$RC"
check "no NETWORK, devnet genesis: nothing printed" "" "$OUT"
no_genesis
run detect_network
check_rc "no NETWORK, no genesis: rc 1" 1 "$RC"

genesis 487
meta $'NETWORK=foo\n'
run detect_network
check_rc "NETWORK=foo: rc 1 (no genesis fallback)" 1 "$RC"
check "NETWORK=foo: nothing printed" "" "$OUT"
check "NETWORK=foo: reason on stderr" yes "$(has "$ERR" "NETWORK='foo'")"
meta $'NETWORK=devnet\n'
run detect_network
check_rc "NETWORK=devnet: rc 1" 1 "$RC"
meta $'NETWORK=\n'
run detect_network
check_rc "NETWORK empty: rc 1" 1 "$RC"

meta $'NETWORK=mainnet\n' $'NETWORK=testnet\n'
run detect_network
check_rc "duplicate NETWORK: rc 1 (no genesis fallback)" 1 "$RC"
check "duplicate NETWORK: nothing printed" "" "$OUT"
check "duplicate NETWORK: named on stderr" yes "$(has "$ERR" "NETWORK is set 2 times")"

# -----------------------------------------------------------------------------
# prepare: an unknown network stops before git and cargo
# -----------------------------------------------------------------------------
confirm() { return 0; }

prep_case() {
    local name="$1"
    rm -f "$T/cargo-ran" "$T/git-ran"
    run prepare_source_build v0.16.0-adiri
    check_rc "${name}: prepare rc 1" 1 "$RC"
    check "${name}: prepare names the network problem" yes "$(has "$OUT$ERR" "Cannot tell which network")"
    check "${name}: cargo never ran" no "$(exists "$T/cargo-ran")"
    check "${name}: git never ran" no "$(exists "$T/git-ran")"
    exec 3>"$T/json.log"
    JSON_MODE=true
    run json_prepare_source v0.16.0-adiri
    JSON_MODE=false
    exec 3>&-
    check_rc "${name}: --json prepare rc 1" 1 "$RC"
    check "${name}: --json error event" yes "$(has "$(cat "$T/json.log")" "cannot tell which network")"
    check "${name}: --json cargo never ran" no "$(exists "$T/cargo-ran")"
    check "${name}: --json git never ran" no "$(exists "$T/git-ran")"
}

genesis 487
meta $'NETWORK=foo\n'
prep_case "NETWORK=foo"
meta $'NETWORK=mainnet\n' $'NETWORK=mainnet\n'
prep_case "duplicate NETWORK"
meta $'NETWORK=devnet\n'
prep_case "NETWORK=devnet"
genesis 32285
meta $'INSTALL_METHOD=source\n'
prep_case "no NETWORK, devnet genesis"

# Positive controls: a known network gets its features and gets past the check.
meta $'NETWORK=testnet\r\n'
rm -f "$T/cargo-ran"
run prepare_source_build v0.16.0-adiri
check "testnet: prepare builds with the adiri feature" yes "$(has "$OUT$ERR" "Network: testnet -- building with --features adiri")"
check "testnet: cargo never ran (no source tree here)" no "$(exists "$T/cargo-ran")"
meta $'NETWORK=mainnet\n'
run prepare_source_build v0.16.0
check "mainnet: prepare builds without the adiri feature" yes "$(has "$OUT$ERR" "Network: mainnet -- building without the adiri feature")"
run tn_cargo_features_for "$(detect_network)"
check "mainnet: no cargo features" "" "$OUT"

# -----------------------------------------------------------------------------
# INSTALL_METHOD and BINARY_PATH through meta_get
# -----------------------------------------------------------------------------
meta $'INSTALL_METHOD=source\r\n'
run detect_install_method
check_rc "INSTALL_METHOD CRLF: rc 0" 0 "$RC"
check "INSTALL_METHOD CRLF: source" "source" "$OUT"
meta $'INSTALL_METHOD=source\n' $'INSTALL_METHOD=docker\n'
run detect_install_method
check_rc "duplicate INSTALL_METHOD: rc 2" 2 "$RC"
check "duplicate INSTALL_METHOD: nothing printed" "" "$OUT"
meta $'NETWORK=testnet\n'
run detect_install_method
check_rc "no INSTALL_METHOD: rc 0" 0 "$RC"
check "no INSTALL_METHOD: nothing printed" "" "$OUT"

tn_launch_runner() { return 1; }
meta $'BINARY_PATH=/usr/local/bin/tn-a\n' $'BINARY_PATH=/usr/local/bin/tn-b\n'
run existing_binary_path
check_rc "duplicate BINARY_PATH: rc 2" 2 "$RC"
check "duplicate BINARY_PATH: not the default path" no "$(has "$OUT" "${DEFAULT_INSTALL_DIR}/telcoin-network")"
check "duplicate BINARY_PATH: neither recorded path" no "$(has "$OUT" "/usr/local/bin/tn-")"
check "duplicate BINARY_PATH: explained" yes "$(has "$ERR" "BINARY_PATH is set more than once")"
meta $'BINARY_PATH=/usr/local/bin/tn-a\n'
run existing_binary_path
check "single BINARY_PATH: used" "/usr/local/bin/tn-a" "$OUT"

# -----------------------------------------------------------------------------
# Build log and build output
# -----------------------------------------------------------------------------
mkdir -p "$T/tmpdir"
L1="$(TMPDIR="$T/tmpdir" build_log_file)"
L2="$(TMPDIR="$T/tmpdir" build_log_file)"
check "build log: under TMPDIR with the tn-build prefix" yes "$(has "$L1" "$T/tmpdir/tn-build.")"
check "build log: mode 600" "600" "$(stat -c '%a' -- "$L1" 2>/dev/null)"
check "build log: a new name each time" yes "$([[ -n "$L1" && "$L1" != "$L2" ]] && echo yes || echo no)"

printf 'bin\n' > "$T/built"
run _uc_built_binary_ok "$T/built"
check_rc "built binary: regular file owned by this uid" 0 "$RC"
ln -s "$T/built" "$T/built-link"
run _uc_built_binary_ok "$T/built-link"
check_rc "built binary: symlink refused" 1 "$RC"
run _uc_built_binary_ok "$T/missing"
check_rc "built binary: missing refused" 1 "$RC"
mkdir "$T/built-dir"
run _uc_built_binary_ok "$T/built-dir"
check_rc "built binary: directory refused" 1 "$RC"
run _uc_built_binary_ok "$T/built" 4242
check_rc "built binary: another owner refused" 1 "$RC"

finish
