#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_floor.sh -- IMG check 3 (V7 spec): the storage
# migration floor by network. storage_migration_floor per network and for a host
# whose network cannot be told (the testnet floor); storage_migrating_upgrade
# with the network given and with the host's (.node-meta NETWORK under
# TN_ROOT_PREFIX, read by the library); update_downgrade_check's
# storage_downgrade flag in --json (mainnet v0.2.0 -> v0.1.3 is a plain
# downgrade, testnet v0.16.0-adiri -> v0.15.0-adiri a storage one). A copy of
# update-node.sh without its main line is sourced at the top level.
#
#   bash tasks/verify-r2/V7-IMG/t_floor.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
mkdir -p "$T/h" "$T/root/etc/telcoin" "$T/root/var/lib/telcoin"
grep -v '^main "\$@"$' "$V7_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$V7_REPO/lib" "$T/h/lib"
export TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common

hostnet() {  # NETWORK|none
    if [[ "$1" == none ]]; then
        rm -f "$T/root/etc/telcoin/.node-meta"
    else
        printf 'NETWORK=%s\n' "$1" > "$T/root/etc/telcoin/.node-meta"
    fi
}
fl() { local o; o="$(storage_migration_floor "$@" 2>/dev/null)"; printf '[%s]' "$o"; }
check "floor testnet" "[0.16.0]" "$(fl testnet)"
check "floor mainnet" "[]" "$(fl mainnet)"
check "floor devnet" "[]" "$(fl devnet)"
check "floor unknown name keeps the testnet floor" "[0.16.0]" "$(fl prod)"
hostnet mainnet
check "floor of a mainnet host" "[]" "$(fl)"
hostnet testnet
check "floor of a testnet host" "[0.16.0]" "$(fl)"
hostnet devnet
check "floor of a devnet host" "[]" "$(fl)"
hostnet none
check "floor of a host whose network cannot be told" "[0.16.0]" "$(fl)"

mig() {  # NAME RUN NEW [NETWORK] EXPECTED-RC
    local rc=0
    storage_migrating_upgrade "$2" "$3" ${4:+"$4"} 2>/dev/null || rc=$?
    check_rc "migrating: $1" "$5" "$rc"
}
mig "mainnet v0.1.3 -> v0.2.0 is not one way" v0.1.3 v0.2.0 mainnet 1
mig "mainnet image tags tn-mainnet:v0.1.3 -> tn-mainnet:v0.2.0" tn-mainnet:v0.1.3 tn-mainnet:v0.2.0 mainnet 1
mig "mainnet v0.1.3 -> v0.17.0 is not one way" v0.1.3 v0.17.0 mainnet 1
mig "mainnet unknown running -> v0.2.0 is not one way" "" v0.2.0 mainnet 1
mig "testnet v0.15.2-adiri -> v0.16.0-adiri is one way" v0.15.2-adiri v0.16.0-adiri testnet 0
mig "testnet v0.15.0-adiri -> v0.17.0-adiri is one way" v0.15.0-adiri v0.17.0-adiri testnet 0
mig "testnet v0.16.0-adiri -> v0.17.0-adiri is not" v0.16.0-adiri v0.17.0-adiri testnet 1
mig "testnet unknown running -> v0.16.0-adiri counts as one way" "" v0.16.0-adiri testnet 0
mig "testnet v0.14.0-adiri -> v0.15.0-adiri is not" v0.14.0-adiri v0.15.0-adiri testnet 1
mig "devnet v0.15.0 -> v0.16.0 is not one way" v0.15.0 v0.16.0 devnet 1
hostnet mainnet
mig "mainnet host, no network given: v0.1.3 -> v0.2.0 not one way" v0.1.3 v0.2.0 "" 1
hostnet testnet
mig "testnet host, no network given: v0.15.2-adiri -> v0.16.0-adiri one way" v0.15.2-adiri v0.16.0-adiri "" 0
hostnet devnet
mig "devnet host, no network given: v0.15.0 -> v0.16.0 not one way" v0.15.0 v0.16.0 "" 1
hostnet none
mig "unknown host: v0.15.0 -> v0.16.0 one way (testnet floor)" v0.15.0 v0.16.0 "" 0

dg() {  # NAME HOSTNET RUN NEW EXPECTED ("rc storage_downgrade")
    local rc=0 sd
    hostnet "$2"
    : > "$T/j.out"
    ( exec 3>"$T/j.out"; JSON_MODE=true; ALLOW_DOWNGRADE=false; update_downgrade_check "$3" "$4" ) 2>/dev/null || rc=$?
    sd="$(sed -n 's/.*"storage_downgrade":\([a-z]*\).*/\1/p' "$T/j.out")"
    check "downgrade: $1" "$5" "$rc ${sd:-none} $(v7_json_tail "$T/j.out" | cut -d' ' -f1-4)"
}
dg "mainnet v0.2.0 -> v0.1.3 refused, not a storage downgrade" mainnet v0.2.0 v0.1.3 "1 false 2 1 error done"
dg "mainnet v0.17.0 -> v0.15.0 refused, not a storage downgrade" mainnet v0.17.0 v0.15.0 "1 false 2 1 error done"
dg "mainnet v0.1.3 -> v0.2.0 is no downgrade" mainnet v0.1.3 v0.2.0 "0 none 0 1 none none"
dg "testnet v0.16.0-adiri -> v0.15.0-adiri storage downgrade" testnet v0.16.0-adiri v0.15.0-adiri "1 true 2 1 error done"
dg "testnet v0.17.0-adiri -> v0.16.0-adiri plain downgrade" testnet v0.17.0-adiri v0.16.0-adiri "1 false 2 1 error done"
dg "devnet v0.17.0 -> v0.15.0 not a storage downgrade" devnet v0.17.0 v0.15.0 "1 false 2 1 error done"
dg "unknown host v0.16.0 -> v0.15.0 storage downgrade (testnet floor)" none v0.16.0 v0.15.0 "1 true 2 1 error done"
finish
