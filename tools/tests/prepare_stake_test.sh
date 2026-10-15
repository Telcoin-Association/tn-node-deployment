#!/usr/bin/env bash
# =============================================================================
# tools/tests/prepare_stake_test.sh -- prepare-stake.sh: duplicated .node-meta
# keys stop the run, HOST_SERVICE_USER/GROUP select the service account, and
# --rotate-address hands keytool the passphrase as an unexported TN_KEYTOOL_PASS
# (never TN_BLS_PASSPHRASE), migrates the ownership layout under the lock
# before any write, and backs up and restores node-info.yaml as the service
# account (root never chowns or chmods inside the data dir).
#
#   bash tools/tests/prepare_stake_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/prepare_stake_test.sh
#
# The script is sourced without its last line (main "$@") over a fixture tree
# (TN_ROOT_PREFIX); the network, keytool, the service-account runner, meta_set
# and the ownership migration are shell-function stubs, and chown is a PATH
# wrapper that records every call. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/bin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/prepare-stake.sh" > "$T/h/prepare-stake.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
export TN_BLS_PASSPHRASE="env-pass-value-0001"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/prepare-stake.sh"
tn_test_post_common
set +e

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

check "start: TN_BLS_PASSPHRASE taken out of the environment" "no" \
    "$(has "$(env)" "TN_BLS_PASSPHRASE=")"
check "start: kept in the private copy" "env-pass-value-0001" "$PS_ENV_PASS"

OLD="0x1111111111111111111111111111111111111111"
NEW="0x2222222222222222222222222222222222222222"
NI="$T/fx/var/lib/telcoin/node-info.yaml"
NI_TEXT="name: node-a
bls_public_key: 0xabcdef
execution_address: \"${OLD}\""
ME="$(id -un)"

# fixture [META-LINE...] -- the node tree: .node-meta with NETWORK and the
# service account, node-info.yaml (mode 0640), RPC_PORT 8545.
fixture() {
    local l
    rm -rf "$T/fx"
    mkdir -p "$T/fx/etc/telcoin" "$T/fx/var/lib/telcoin"
    {
        printf 'NETWORK=testnet\nRPC_PORT=8545\nHOST_SERVICE_USER=%s\n' "$ME"
        for l in "$@"; do
            printf '%s\n' "$l"
        done
    } > "$T/fx/etc/telcoin/.node-meta"
    printf '%s\n' "$NI_TEXT" > "$NI"
    chmod 0640 "$NI"
    rm -f "$T/kt.decl" "$T/kt.env" "$T/calls" "$T/mig" "$T/metaset" "$T/chown.log"
    : > "$T/chown.log"
}

# resolve -- ps_resolve_node in a subshell; RC, OUT (and the service account it chose).
resolve() {
    OUT="$( ( ps_resolve_node >/dev/null 2>&1 || exit $?; printf '%s:%s' "$SERVICE_USER" "$SERVICE_GROUP" ) 2>&1)"
    RC=$?
    ERR="$( ( ps_resolve_node ) 2>&1)"
}

# -----------------------------------------------------------------------------
# Duplicated keys stop the run; the recorded service account is used
# -----------------------------------------------------------------------------
fixture "HOST_SERVICE_GROUP=svcgrp"
resolve
check_rc "resolve: rc" 0 "$RC"
check "resolve: HOST_SERVICE_USER/GROUP select the service account" "${ME}:svcgrp" "$OUT"

for k in NETWORK=mainnet VALIDATOR_ADDRESS=${OLD} RPC_PORT=8546 HOST_SERVICE_USER=other; do
    key="${k%%=*}"
    if [[ "$key" == NETWORK || "$key" == RPC_PORT || "$key" == HOST_SERVICE_USER ]]; then
        fixture "$k"
    else
        fixture "$k" "$k"
    fi
    resolve
    check_rc "duplicate ${key}: stops" 1 "$RC"
    check "duplicate ${key}: says why" yes "$(has "$ERR" "${key} is set more than once")"
done
fixture "DATA_DIR=/a" "DATA_DIR=/b"
resolve
check_rc "duplicate DATA_DIR: stops" 1 "$RC"
check "duplicate DATA_DIR: says why" yes "$(has "$ERR" "DATA_DIR is set more than once")"

# -----------------------------------------------------------------------------
# --rotate-address
# -----------------------------------------------------------------------------
REAL_CHOWN="$(command -v chown)"
printf '#!/bin/sh\nprintf "%%s\\n" "chown $*" >> "%s"\nexec "%s" "$@"\n' "$T/chown.log" "$REAL_CHOWN" > "$T/bin/chown"
chmod 0755 "$T/bin/chown"
ORIG_PATH="$PATH"

ps_check_chain() { :; }
ps_read_status() { STATUS_RC=0; STATUS_LINE="0 0 0 0"; }
node_stake_status() { printf 'none\n'; }
ps_runner() { RUNNER="binary:/opt/telcoin/telcoin-network"; }
confirm() { return 0; }
meta_set() { printf '%s=%s\n' "$1" "$2" >> "$T/metaset"; }
MIG_RC=0
tn_migrate_ownership() {
    printf '%s\n' "${1:-}" >> "$T/mig"
    return "$MIG_RC"
}
tn_as_service_user() {
    printf 'as-svc %s\n' "$*" >> "$T/calls"
    "$@"
}
KT_FAIL=0
tn_keytool() {
    declare -p TN_KEYTOOL_PASS > "$T/kt.decl" 2>&1
    env > "$T/kt.env"
    [[ -s "$T/mig" ]] && printf 'migrated-first\n' >> "$T/kt.decl"
    if [[ "$KT_FAIL" == 1 ]]; then
        printf 'garbage\n' > "$NI"
        printf 'Error: bad passphrase\n' >&2
        return 1
    fi
    sed "s/${OLD}/${NEW}/" "$NI" > "$NI.new" && cat "$NI.new" > "$NI" && rm -f "$NI.new"
    chmod 0600 "$NI"
    return 0
}
TN_UPDATE_LOCK_FILE="$T/update.lock"
PS_YES=1
PS_NO_RESTART=1
PS_JSON=0
NEW_CS_WANT="$(ps_checksum_address "$NEW")"

# rotate [SERVICE-USER] -- ps_rotate to NEW in a subshell; RC, OUT.
rotate() {
    OUT="$( (
        PATH="$T/bin:$ORIG_PATH"
        PS_ROTATE="$NEW"
        PS_ENV_PASS="rotate-pass-value-42"
        ps_resolve_node >/dev/null 2>&1
        [[ -z "${1:-}" ]] || SERVICE_USER="$1"
        ps_rotate
    ) 2>&1)"
    RC=$?
}
backup_of() { ls "$T/fx/var/lib/telcoin/" | grep -c '^node-info\.yaml\.bak\.' ; }

fixture
rotate
check_rc "rotate: rc" 0 "$RC"
check "rotate: keytool got TN_KEYTOOL_PASS unexported" "declare -- TN_KEYTOOL_PASS=\"rotate-pass-value-42\"
migrated-first" "$(cat "$T/kt.decl" 2>/dev/null)"
check "rotate: no passphrase variable in keytool's environment" "no no no" \
    "$(has "$(cat "$T/kt.env")" "TN_BLS_PASSPHRASE") $(has "$(cat "$T/kt.env")" "TN_KEYTOOL_PASS") $(has "$(cat "$T/kt.env")" "rotate-pass-value-42")"
check "rotate: ownership migration under the lock, with a progress printer" "ps_progress" "$(cat "$T/mig" 2>/dev/null)"
check "rotate: backup made by the service account" yes \
    "$(has "$(cat "$T/calls")" "as-svc cp -p -- ${NI} ${NI}.bak.")"
check "rotate: mode put back by the service account" yes "$(has "$(cat "$T/calls")" "as-svc chmod -- 640 ${NI}")"
check "rotate: mode back to 0640" "640" "$(stat -c '%a' "$NI" 2>/dev/null || stat -f '%Lp' "$NI")"
check "rotate: node-info names the new address" yes "$(has "$(cat "$NI")" "$NEW")"
check "rotate: backup holds the old file" "$NI_TEXT" "$(cat "$T"/fx/var/lib/telcoin/node-info.yaml.bak.* 2>/dev/null)"
check "rotate: VALIDATOR_ADDRESS recorded" "VALIDATOR_ADDRESS=${NEW_CS_WANT}" "$(cat "$T/metaset" 2>/dev/null)"
check "rotate: root never ran chown" "" "$(cat "$T/chown.log")"

fixture
KT_FAIL=1
rotate
KT_FAIL=0
check_rc "keytool fails: rc 4 (rolled back)" 4 "$RC"
check "keytool fails: node-info.yaml back as it was" "$NI_TEXT" "$(cat "$NI")"
check "keytool fails: restored by the service account" yes \
    "$(has "$(cat "$T/calls")" "as-svc cp -p -- ${NI}.bak.")"
check "keytool fails: nothing recorded in .node-meta" "" "$(cat "$T/metaset" 2>/dev/null)"
check "keytool fails: root never ran chown" "" "$(cat "$T/chown.log")"

fixture
MIG_RC=3
rotate
MIG_RC=0
check_rc "old layout on mainnet: refused" 3 "$RC"
check "old layout on mainnet: says why" yes "$(has "$OUT" "must be installed fresh")"
check "old layout on mainnet: keytool never ran, no backup" "no 0" \
    "$([[ -e "$T/kt.decl" ]] && echo yes || echo no) $(backup_of)"

fixture
MIG_RC=1
rotate
MIG_RC=0
check_rc "migration stops: rc 1" 1 "$RC"
check "migration stops: keytool never ran" no "$([[ -e "$T/kt.decl" ]] && echo yes || echo no)"

fixture
mv "$NI" "$T/fx/ni-real"
ln -s "$T/fx/ni-real" "$NI"
rotate
check_rc "node-info.yaml a symlink: refused" 1 "$RC"
check "node-info.yaml a symlink: says why" yes "$(has "$OUT" "not a regular file")"
check "node-info.yaml a symlink: keytool never ran, no backup" "no 0" \
    "$([[ -e "$T/kt.decl" ]] && echo yes || echo no) $(backup_of)"

fixture
other="nobody"
[[ "$ME" == nobody ]] && other="root"
rotate "$other"
check_rc "node-info.yaml not the service account's: refused" 1 "$RC"
check "node-info.yaml not the service account's: says why" yes "$(has "$OUT" "is not owned by the service account")"
check "node-info.yaml not the service account's: keytool never ran" no "$([[ -e "$T/kt.decl" ]] && echo yes || echo no)"

# ps_restart_node: the committee check, the epoch wait, the check again, then the
# restart; a refusal at either check leaves the node running (RESTARTED=false).
psr() {  # psr AFTER-RC -- "<order>|<RESTARTED>" for one ps_restart_node
    (
        ORDER=""
        PS_NO_RESTART=0 SERVICE=telcoin LOCAL_RPC=http://127.0.0.1:8545 NEW_CS=0xabc RESTARTED=""
        eval "tn_committee_down_guard() { ORDER=\"\${ORDER} guard\"; case \"\$ORDER\" in *wait*) return $1 ;; esac; return 0; }"
        tn_wait_restart_window() { ORDER="${ORDER} wait"; }
        systemctl() { case "$1" in restart) ORDER="${ORDER} restart" ;; esac; return 0; }
        sleep() { :; }
        ps_restart_node >/dev/null 2>&1
        printf '%s|%s\n' "${ORDER# }" "$RESTARTED"
    )
}
check "rotate restart: guard, wait, guard, restart" "guard wait guard restart|true" "$(psr 0)"
check "rotate restart: refused after the wait, not restarted" "guard wait guard|false" "$(psr 1)"
finish
