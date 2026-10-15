#!/usr/bin/env bash
# =============================================================================
# tools/tests/check_node_hardening_test.sh -- check-node.sh's hardening checks:
# check_bls_cleartext (cleartext bls.key without bls.kw fails, both warn),
# check_update_lock (free, held with the holder's PID, a dead holder, the mkdir
# fallback, an unsafe lock directory, the lock file's mode),
# check_ownership_layout (old layout warns, or fails on mainnet; a recorded
# layout 2 is checked path by path) and detect_data_dir's duplicated DATA_DIR.
#
#   bash tools/tests/check_node_hardening_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/check_node_hardening_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/check_node_hardening_test.sh
#
# The functions are cut out of check-node.sh (the HARDENING CHECKS section,
# detect_data_dir, have_fns) and run over a fixture tree (TN_ROOT_PREFIX).
# Cases that need root-owned files run as root only, under a root-only
# directory in /root; the lock directory case runs only inside a container.
# bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
MADE_RUN=0
trap 'tn_test_cleanup; [[ -z "$RB" ]] || rm -rf "$RB"; [[ $MADE_RUN == 0 ]] || rm -rf /run/telcoin' EXIT

CN="$TN_TEST_REPO/check-node.sh"
{
    sed -n '/^have_fns() {/,/^}/p' "$CN"
    sed -n '/^detect_data_dir() {/,/^}/p' "$CN"
    awk '/^# HARDENING CHECKS/ { f = 1 } /^# REPORT HEADER/ { f = 0 } f' "$CN"
} > "$T/fns.sh"

TN_ROOT_PREFIX="$T/fx"
eval "$(tn_test_source_common)"
# shellcheck source=/dev/null
source "$T/fns.sh"
HEALTH_ISSUES=0

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1

check "functions cut out of check-node.sh" "yes yes yes yes" \
    "$(for f in check_bls_cleartext check_update_lock check_ownership_layout detect_data_dir; do declare -F "$f" >/dev/null && printf 'yes ' || printf 'no '; done | sed 's/ $//')"

# meta LINE... -- the unified .node-meta of the fixture at $TN_ROOT_PREFIX.
meta() {
    local l
    mkdir -p "${TN_ROOT_PREFIX}/etc/telcoin"
    : > "${TN_ROOT_PREFIX}/etc/telcoin/.node-meta"
    for l in "$@"; do
        printf '%s\n' "$l" >> "${TN_ROOT_PREFIX}/etc/telcoin/.node-meta"
    done
}
# run FN -- OUT and the HEALTH_ISSUES it added (ADDED).
run() {
    local before="$HEALTH_ISSUES"
    "$1" > "$T/out" 2>&1
    OUT="$(cat "$T/out")"
    ADDED=$(( HEALTH_ISSUES - before ))
}

# -----------------------------------------------------------------------------
# check_bls_cleartext
# -----------------------------------------------------------------------------
DD="$T/fx/var/lib/telcoin"
mkdir -p "$DD/node-keys"
meta "NETWORK=testnet" "DATA_DIR=${DD}"
: > "$DD/node-keys/bls.kw"
run check_bls_cleartext
check "bls: wrapped key only is OK" "yes 0" "$(has "$OUT" "passphrase-wrapped") $ADDED"
: > "$DD/node-keys/bls.key"
run check_bls_cleartext
check "bls: both present warns, no failure" "yes 0" "$(has "$OUT" "cleartext copy of the BLS key") $ADDED"
rm -f "$DD/node-keys/bls.kw"
run check_bls_cleartext
check "bls: cleartext key without bls.kw fails" "yes 1" "$(has "$OUT" "stored in the clear") $ADDED"
rm -rf "$DD/node-keys"
run check_bls_cleartext
check "bls: no keys yet, nothing said" "" "$OUT"
mkdir -p "$DD/node-keys"
: > "$DD/node-keys/bls.key"
if [[ $IS_ROOT == 0 ]]; then
    chmod 000 "$DD/node-keys"
    run check_bls_cleartext
    chmod 0755 "$DD/node-keys"
    check "bls: unreadable keys dir reported as not checked" "yes 0" "$(has "$OUT" "not checked") $ADDED"
else
    skip "bls: unreadable keys dir reported as not checked" "root reads everything"
fi
meta "NETWORK=testnet" "DATA_DIR=${DD}" "DATA_DIR=/elsewhere"
detect_data_dir > /dev/null
check_rc "detect_data_dir: duplicated DATA_DIR is rc 2" 2 "$?"
check "detect_data_dir: prints nothing then" "" "$(detect_data_dir)"
run check_bls_cleartext
check "bls: duplicated DATA_DIR, left to the disk section" "0" "$ADDED"
rm -rf "$DD/node-keys"

# -----------------------------------------------------------------------------
# check_update_lock
# -----------------------------------------------------------------------------
TN_UPDATE_LOCK_FILE="$T/update.lock"
run check_update_lock
check "lock: free" "yes yes" "$(has "$OUT" "is free") $(has "$OUT" "override")"
: > "$T/flock.probe"
if [[ -r /proc/locks ]] && flock -n -o "$T/flock.probe" true 2>/dev/null; then
    # A live holder: inside a container /proc/locks hides a lock whose owner
    # has exited (the flock process that took it), so the owner stays alive here.
    : > "$T/update.lock"
    flock -n -o "$T/update.lock" sleep 60 &
    HOLDER=$!
    n=0
    while ! grep -q " FLOCK " /proc/locks 2>/dev/null && [[ $n -lt 50 ]]; do
        n=$(( n + 1 ))
        sleep 0.1 2>/dev/null || sleep 1
    done
    printf '%s\n' "$$" > "$T/update.lock"
    run check_update_lock
    check "lock: held, with the holder's PID" "yes 0" "$(has "$OUT" "held by PID $$") $ADDED"
    printf '999999\n' > "$T/update.lock"
    run check_update_lock
    check "lock: held for a PID that is gone warns" "yes" "$(has "$OUT" "is not running")"
    # -o kept the descriptor away from sleep, so ending the flock process frees
    # the lock; its sleep child goes too.
    pkill -P "$HOLDER" 2>/dev/null
    kill "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
    run check_update_lock
    check "lock: free again" "yes" "$(has "$OUT" "is free")"
else
    skip "lock: held, with the holder's PID" "flock -o or /proc/locks absent"
fi
mkdir "$T/update.lock.d"
printf '%s\n' "$$" > "$T/update.lock.d/pid"
run check_update_lock
check "lock: mkdir fallback held" "yes" "$(has "$OUT" "held by PID $$")"
rm -rf "$T/update.lock.d"
unset TN_UPDATE_LOCK_FILE
if [[ $IS_ROOT == 1 && -e /.dockerenv && ! -e /run/telcoin ]]; then
    MADE_RUN=1
    run check_update_lock
    check "lock: no lock directory yet" "yes 0" "$(has "$OUT" "not created yet") $ADDED"
    mkdir -p -m 0777 /run/telcoin
    chmod 0777 /run/telcoin
    run check_update_lock
    check "lock: a lock directory others can write fails" "yes 1" "$(has "$OUT" "not a root-owned directory") $ADDED"
    chmod 0755 /run/telcoin
    : > /run/telcoin/update.lock
    chown 65534 /run/telcoin/update.lock 2>/dev/null
    run check_update_lock
    check "lock: a lock file not owned by root fails" "yes 1" "$(has "$OUT" "not owned by root") $ADDED"
    chown 0 /run/telcoin/update.lock
    chmod 0644 /run/telcoin/update.lock
    run check_update_lock
    check "lock: a 0644 lock file warns and names the mode" "yes yes yes 0" \
        "$(has "$OUT" "is mode 644, not 0600") $(has "$OUT" "sets it to 0600") $(has "$OUT" "is free (mode 644)") $ADDED"
    chmod 0600 /run/telcoin/update.lock
    run check_update_lock
    check "lock: root-owned directory and 0600 file" "yes no 0" \
        "$(has "$OUT" "is free (mode 600)") $(has "$OUT" "not 0600") $ADDED"
else
    skip "lock: the default lock directory" "needs root inside a container with no /run/telcoin"
fi
TN_UPDATE_LOCK_FILE="$T/update.lock"

# -----------------------------------------------------------------------------
# check_ownership_layout: the layout key
# -----------------------------------------------------------------------------
meta "NETWORK=testnet"
run check_ownership_layout
check "layout: old layout on testnet warns" "yes 0" "$(has "$OUT" "Old file ownership layout") $ADDED"
meta "NETWORK=mainnet"
run check_ownership_layout
check "layout: old layout on mainnet fails" "yes yes 1" \
    "$(has "$OUT" "Old file ownership layout") $(has "$OUT" "install it fresh") $ADDED"
meta "NETWORK=testnet" "OWNERSHIP_LAYOUT=2" "OWNERSHIP_LAYOUT=2"
run check_ownership_layout
check "layout: duplicated key fails" "yes 1" "$(has "$OUT" "set more than once") $ADDED"
rm -f "$T/fx/etc/telcoin/.node-meta"
mkdir -p "$T/fx/etc/telcoin/validator"
printf 'NETWORK=testnet\n' > "$T/fx/etc/telcoin/validator/.node-meta"
run check_ownership_layout
check "layout: legacy per-role install not checked" "yes 0" "$(has "$OUT" "legacy per-role install") $ADDED"
rm -rf "$T/fx/etc/telcoin/validator"
if [[ $IS_ROOT == 0 ]]; then
    meta "NETWORK=testnet" "OWNERSHIP_LAYOUT=2"
    chmod 000 "$T/fx/etc/telcoin/.node-meta"
    run check_ownership_layout
    chmod 0600 "$T/fx/etc/telcoin/.node-meta"
    check "layout: .node-meta unreadable without sudo" "yes 0" "$(has "$OUT" "readable by root only") $ADDED"
else
    skip "layout: .node-meta unreadable without sudo" "root reads everything"
fi

# -----------------------------------------------------------------------------
# check_ownership_layout: layout 2, path by path (root only)
# -----------------------------------------------------------------------------
if [[ $IS_ROOT == 1 ]]; then
    RB="$(mktemp -d /root/.tn-test.XXXXXX 2>/dev/null)" || RB=""
fi
SVC_GROUP="$(id -gn nobody 2>/dev/null || true)"
if [[ -n "$RB" && -n "$SVC_GROUP" ]] && chmod 0700 "$RB" && tn_root_dir_ok "$RB"; then
    TN_ROOT_PREFIX="$RB/fx"
    F="$RB/fx"
    install -d -o root -g root -m 0755 "$F" "$F/opt" "$F/opt/telcoin" "$F/etc" "$F/etc/telcoin" \
        "$F/usr" "$F/usr/local" "$F/usr/local/libexec" "$F/usr/local/libexec/telcoin" "$F/var" "$F/var/lib"
    install -d -o nobody -g "$SVC_GROUP" -m 0700 "$F/var/lib/telcoin"
    install -o root -g root -m 0755 /dev/null "$F/opt/telcoin/telcoin-network"
    install -o root -g root -m 0755 /dev/null "$F/usr/local/libexec/telcoin/tn-start"
    install -o root -g root -m 0600 /dev/null "$F/etc/telcoin/bls-passphrase"
    meta "NETWORK=testnet" "OWNERSHIP_LAYOUT=2" "INSTALL_METHOD=binary" "HOST_SERVICE_USER=nobody" \
        "HOST_SERVICE_GROUP=${SVC_GROUP}" "DATA_DIR=${F}/var/lib/telcoin"
    chmod 0600 "$F/etc/telcoin/.node-meta"
    run check_ownership_layout
    check "layout 2: the table holds" "yes 0" "$(has "$OUT" "Ownership layout 2: install") $ADDED"
    chown nobody "$F/opt/telcoin/telcoin-network"
    chmod 0644 "$F/etc/telcoin/bls-passphrase"
    ln -s /etc/hostname "$F/etc/telcoin/planted"
    run check_ownership_layout
    check "layout 2: drift fails" "yes 1" "$(has "$OUT" "differ from it") $ADDED"
    check "layout 2: a service-account binary listed" yes \
        "$(has "$OUT" "${F}/opt/telcoin/telcoin-network: nobody:root 755, expected root:root 755")"
    check "layout 2: a loose passphrase file listed" yes \
        "$(has "$OUT" "${F}/etc/telcoin/bls-passphrase: root:root 644, expected root:root 600")"
    check "layout 2: the binary listed as not root-owned" yes \
        "$(has "$OUT" "${F}/opt/telcoin/telcoin-network: not owned by root")"
    chown root "$F/opt/telcoin/telcoin-network"
    chmod 0600 "$F/etc/telcoin/bls-passphrase"
    rm -f "$F/etc/telcoin/planted"
    rm -f "$F/usr/local/libexec/telcoin/tn-start"
    run check_ownership_layout
    check "layout 2: a missing start script fails" "yes 1" "$(has "$OUT" "tn-start: missing") $ADDED"
else
    skip "layout 2: path by path" "needs root and a root-only directory under /root"
fi

finish
