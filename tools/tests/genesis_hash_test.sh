#!/usr/bin/env bash
# =============================================================================
# tools/tests/genesis_hash_test.sh -- chain configs pinned to a hash:
# tn_chain_configs_check, ensure_chain_configs_available and setup-node.sh's
# step_write_config. The testnet fixture files (genesis.d/testnet) are the
# repository's chain-configs/testnet at the pinned tag and must match the
# TESTNET_*_SHA256 constants; a changed, missing or symlinked file is refused
# before anything is copied; mainnet refuses while its pins are empty; the
# working directory is never searched.
#
#   bash tools/tests/genesis_hash_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
FX="$TN_TEST_DIR/genesis.d/testnet"
REC="$T/rec"
mkdir -p "$T/bin" "$T/sn" "$REC" "$T/good" "$T/bad" "$T/data" "$T/cwd/chain-configs/testnet"
export REC
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$REC/git.argv"\nexit 0\n' > "$T/bin/git"
chmod 0755 "$T/bin/git"
PATH="$T/bin:$PATH"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
source "$T/sn/setup-node.sh"
set +e

cp "$FX"/*.yaml "$T/good/"
cp "$FX"/*.yaml "$T/bad/"
printf '# changed\n' >> "$T/bad/genesis.yaml"

chk() {
    local rc=0
    tn_chain_configs_check "$1" "$2" > "$T/out" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
has() { grep -qF -- "$1" "$T/out" && echo yes || echo no; }

# ---- the pins and the fixture files -----------------------------------------------------
check "pins: testnet tag recorded" "v0.16.0-adiri" "$TESTNET_CHAIN_CONFIGS_TAG"
for f in genesis committee parameters; do
    got="$(sha256sum < "$FX/${f}.yaml" | cut -d' ' -f1)"
    check "fixture ${f}.yaml has the pinned hash" "$(tn_chain_config_pin testnet "${f}.yaml")" "$got"
done
check "mainnet genesis pin empty until the ceremony" "" "$MAINNET_GENESIS_SHA256"

# ---- tn_chain_configs_check ---------------------------------------------------------------
check_rc "testnet fixture passes" 0 "$(chk "$T/good" testnet)"
check_rc "changed genesis refused" 1 "$(chk "$T/bad" testnet)"
check "changed genesis: expected value printed" yes "$(has "expected ${TESTNET_GENESIS_SHA256}")"
check "changed genesis: actual value printed" yes "$(has "sha256 $(sha256sum < "$T/bad/genesis.yaml" | cut -d' ' -f1)")"
mkdir -p "$T/link"
cp "$FX/committee.yaml" "$FX/parameters.yaml" "$T/link/"
ln -s "$FX/genesis.yaml" "$T/link/genesis.yaml"
check_rc "symlinked genesis refused" 1 "$(chk "$T/link" testnet)"
mkdir -p "$T/missing"
cp "$FX/genesis.yaml" "$FX/committee.yaml" "$T/missing/"
check_rc "missing parameters refused" 1 "$(chk "$T/missing" testnet)"
check_rc "mainnet refused while its pins are empty" 1 "$(chk "$T/good" mainnet)"
check "mainnet: says the pins are not published" yes "$(has "no pinned sha256")"
check_rc "devnet: no pins, warned, rc 0" 0 "$(chk "$T/good" devnet)"
check_rc "unknown network refused" 1 "$(chk "$T/good" foo)"
check_rc "empty network refused" 1 "$(chk "$T/good" "")"

# ---- ensure_chain_configs_available -------------------------------------------------------
confirm() { return 1; }
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
mkdir -p "$SRC/.git" "$SRC/chain-configs/testnet"
cp "$FX"/*.yaml "$SRC/chain-configs/testnet/"
rc=0; TN_GENESIS_DIR="" ensure_chain_configs_available testnet > "$T/out" 2>&1 || rc=$?
check_rc "ensure: pinned checkout passes" 0 "$rc"
check "ensure: testnet pulls --ff-only" yes "$(grep -q 'pull --ff-only' "$REC/git.argv" && echo yes || echo no)"
rc=0; TN_GENESIS_DIR="$T/bad" ensure_chain_configs_available testnet > "$T/out" 2>&1 || rc=$?
check_rc "ensure: a --genesis-dir that does not match is refused" 1 "$rc"
: > "$REC/git.argv"
rc=0; TN_GENESIS_DIR="" ensure_chain_configs_available mainnet > "$T/out" 2>&1 || rc=$?
check_rc "ensure: mainnet refused while unpinned" 1 "$rc"
check "ensure: mainnet never pulls" "" "$(grep pull "$REC/git.argv" 2>/dev/null)"
rc=0; TN_GENESIS_DIR="" ensure_chain_configs_available foo > "$T/out" 2>&1 || rc=$?
check_rc "ensure: unknown network refused" 1 "$rc"

# ---- step_write_config: check before copy, no working-directory search ------------------
tn_as_service_user() { printf '%s\n' "$*" >> "$REC/as_user"; "$@"; }
write_advertised_name() { :; }
SERVICE_USER="$(id -un)"
DATA_DIR="$T/data"
CONFIG_DIR="$T/conf"
NETWORK=testnet
JSON_MODE=true
json_setup_fds() { :; }
exec 3>/dev/null
# write RUNDIR GENESIS_DIR -- run step_write_config in a subshell from RUNDIR.
write() {
    rm -rf "${T:?}/data/genesis" "$T/data/parameters.yaml"
    : > "$REC/as_user"
    ( cd "$1" && TN_GENESIS_DIR="$2" step_write_config ) > "$T/out" 2>&1
    printf '%s\n' "$?"
}
rm -rf "$SRC/chain-configs"

check_rc "write: a tampered --genesis-dir stops setup" 1 "$(write "$T" "$T/bad")"
check "write: tampered, nothing copied" "no" "$([[ -e "$T/data/genesis/genesis.yaml" ]] && echo yes || echo no)"
check "write: tampered, no cp ran" "" "$(grep '^cp ' "$REC/as_user")"
check_rc "write: the pinned files are copied" 0 "$(write "$T" "$T/good")"
check "write: genesis copied" "$TESTNET_GENESIS_SHA256" "$(sha256sum < "$T/data/genesis/genesis.yaml" | cut -d' ' -f1)"
check "write: parameters copied" "$TESTNET_PARAMETERS_SHA256" "$(sha256sum < "$T/data/parameters.yaml" | cut -d' ' -f1)"
cp "$FX"/*.yaml "$T/cwd/chain-configs/testnet/"
check_rc "write: ./chain-configs in the working directory is not used" 1 "$(write "$T/cwd" "")"
check "write: cwd files not copied" "no" "$([[ -e "$T/data/genesis/genesis.yaml" ]] && echo yes || echo no)"
NETWORK=foo
check_rc "write: unknown network stops setup" 1 "$(write "$T" "$T/good")"
check "write: unknown network message" yes "$(has "no chain-configs for network foo")"
finish
