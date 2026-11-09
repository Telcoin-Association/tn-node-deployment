#!/usr/bin/env bash
# =============================================================================
# tools/tests/check_node_hardening_test.sh -- check-node.sh's hardening checks:
# check_bls_cleartext (cleartext bls.key without bls.kw fails, both warn),
# check_update_lock (free, held with the holder's PID, a dead holder, the mkdir
# fallback, an unsafe lock directory, the lock file's mode),
# check_ownership_layout (old layout warns, or fails on mainnet; a recorded
# layout 2 is checked path by path, the private alerts files included),
# check_alerts (alerts_status's issue count, the skip without lib/alerts.sh),
# detect_data_dir's duplicated DATA_DIR and
# check_p2p_committee (the P2P committee allowlist: binary, table, timer,
# staleness, `tn-p2p-allow-sync check` and config drift).
#
#   bash tools/tests/check_node_hardening_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/check_node_hardening_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/check_node_hardening_test.sh
#
# The functions are cut out of check-node.sh (the HARDENING CHECKS section,
# detect_data_dir, have_fns, fmt_secs, utc_time) and run over a fixture tree
# (TN_ROOT_PREFIX).
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
    sed -n '/^fmt_secs() {/,/^}/p' "$CN"
    sed -n '/^utc_time() {/,/^}/p' "$CN"
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
if [[ -d /proc/$$ ]]; then
    mkdir "$T/update.lock.d"
    printf '%s\n' "$$" > "$T/update.lock.d/pid"
    run check_update_lock
    check "lock: mkdir fallback held" "yes" "$(has "$OUT" "held by PID $$")"
    rm -rf "$T/update.lock.d"
else
    skip "lock: mkdir fallback held" "/proc absent: check-node reads the holder PID there"
fi
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
# check_alerts: alerts_status (lib/alerts.sh) is a stand-in here
# -----------------------------------------------------------------------------
check "check_alerts cut out of check-node.sh and in the hardening loop" "yes yes" \
    "$(declare -F check_alerts >/dev/null && echo yes || echo no) $(sed -n '/^for _hc in check_bls_cleartext/,/; do$/p' "$CN" | grep -q 'check_alerts; do$' && echo yes || echo no)"
alerts_status() { printf 'Private alerts: on (stand-in)\n'; return "${STUB_ALERTS_RC:-0}"; }
TIMER="${TN_ROOT_PREFIX}/etc/systemd/system/telcoin-heartbeat.timer"
meta "NETWORK=testnet" "ENABLE_ALERTS=true"
STUB_ALERTS_RC=0
run check_alerts
check "alerts: no issue, alerts_status's lines shown" "yes 0" "$(has "$OUT" "Private alerts: on (stand-in)") $ADDED"
STUB_ALERTS_RC=3
run check_alerts
check "alerts: alerts_status's issue count goes into HEALTH_ISSUES" "yes 3" "$(has "$OUT" "Private alerts: on (stand-in)") $ADDED"
unset STUB_ALERTS_RC
unset -f alerts_status
CN_SKIPPED_CHECKS=""
meta "NETWORK=testnet"
run check_alerts
check "alerts: no lib/alerts.sh and no alerts here: silent, not listed as skipped" "|0|" "${OUT}|${ADDED}|${CN_SKIPPED_CHECKS}"
meta "NETWORK=testnet" "ENABLE_ALERTS=false"
run check_alerts
check "alerts: no lib/alerts.sh, ENABLE_ALERTS=false: not listed as skipped" "|0|" "${OUT}|${ADDED}|${CN_SKIPPED_CHECKS}"
for v in true pending; do
    CN_SKIPPED_CHECKS=""
    meta "NETWORK=testnet" "ENABLE_ALERTS=${v}"
    run check_alerts
    check "alerts: no lib/alerts.sh, ENABLE_ALERTS=${v}: listed as skipped" "|0| check_alerts" "${OUT}|${ADDED}|${CN_SKIPPED_CHECKS}"
done
CN_SKIPPED_CHECKS=""
meta "NETWORK=testnet"
mkdir -p "${TIMER%/*}"
: > "$TIMER"
run check_alerts
check "alerts: no lib/alerts.sh, the timer unit is there: listed as skipped" "|0| check_alerts" "${OUT}|${ADDED}|${CN_SKIPPED_CHECKS}"
rm -f "$TIMER"
CN_SKIPPED_CHECKS=""

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
    install -o root -g root -m 0644 /dev/null "$F/etc/telcoin/bls-passphrase.cred"
    run check_ownership_layout
    check "layout 2: a loose credential file listed" yes \
        "$(has "$OUT" "${F}/etc/telcoin/bls-passphrase.cred: root:root 644, expected root:root 600")"
    chmod 0600 "$F/etc/telcoin/bls-passphrase.cred"
    rm -f "$F/usr/local/libexec/telcoin/tn-start"
    run check_ownership_layout
    check "layout 2: a missing start script fails" "yes 1" "$(has "$OUT" "tn-start: missing") $ADDED"
    install -o root -g root -m 0755 /dev/null "$F/usr/local/libexec/telcoin/tn-start"
    # The private alerts files: each checked only when it exists, against its row.
    install -o root -g root -m 0755 /dev/null "$F/usr/local/libexec/telcoin/tn-heartbeat"
    install -d -o root -g root -m 0755 "$F/etc/telcoin/alerts"
    install -o root -g root -m 0600 /dev/null "$F/etc/telcoin/alerts/targets"
    install -o root -g root -m 0644 /dev/null "$F/etc/telcoin/alerts/alerts.env"
    run check_ownership_layout
    check "layout 2: the private alerts files hold" "yes 0" "$(has "$OUT" "Ownership layout 2: install") $ADDED"
    chown nobody "$F/usr/local/libexec/telcoin/tn-heartbeat"
    chmod 0700 "$F/etc/telcoin/alerts"
    chmod 0644 "$F/etc/telcoin/alerts/targets"
    chmod 0600 "$F/etc/telcoin/alerts/alerts.env"
    run check_ownership_layout
    check "layout 2: drifted private alerts files fail" "yes 1" "$(has "$OUT" "differ from it") $ADDED"
    check "layout 2: a service-account heartbeat runner listed" yes \
        "$(has "$OUT" "${F}/usr/local/libexec/telcoin/tn-heartbeat: nobody:root 755, expected root:root 755")"
    check "layout 2: a loose alerts dir listed" yes \
        "$(has "$OUT" "${F}/etc/telcoin/alerts: root:root 700, expected root:root 755")"
    check "layout 2: a readable targets file listed" yes \
        "$(has "$OUT" "${F}/etc/telcoin/alerts/targets: root:root 644, expected root:root 600")"
    check "layout 2: alerts.env with the wrong mode listed" yes \
        "$(has "$OUT" "${F}/etc/telcoin/alerts/alerts.env: root:root 600, expected root:root 644")"
    chown root "$F/usr/local/libexec/telcoin/tn-heartbeat"
    chmod 0755 "$F/etc/telcoin/alerts"
    chmod 0644 "$F/etc/telcoin/alerts/alerts.env"
    rm -f "$F/etc/telcoin/alerts/targets"
    ln -s /etc/hostname "$F/etc/telcoin/alerts/targets"
    run check_ownership_layout
    check "layout 2: a symlinked targets file fails" "yes 1" \
        "$(has "$OUT" "${F}/etc/telcoin/alerts/targets: a symlink") $ADDED"
    rm -f "$F/etc/telcoin/alerts/targets"
    run check_ownership_layout
    check "layout 2: no targets file, the rest of the alerts files hold" "yes 0" "$(has "$OUT" "Ownership layout 2: install") $ADDED"
    rm -rf "${F:?}/etc/telcoin/alerts" "${F:?}/usr/local/libexec/telcoin/tn-heartbeat"
    if _tn_log_group_ensure 2>/dev/null; then
        install -d -o root -g root -m 0755 "$F/var/log"
        install -d -o root -g telcoin-log -m 0750 "$F/var/log/telcoin"
        install -d -o nobody -g telcoin-log -m 2750 "$F/var/log/telcoin/node"
        meta "NETWORK=testnet" "OWNERSHIP_LAYOUT=2" "INSTALL_METHOD=binary" "HOST_SERVICE_USER=nobody" \
            "HOST_SERVICE_GROUP=${SVC_GROUP}" "DATA_DIR=${F}/var/lib/telcoin" "NODE_LOG_DIR=/var/log/telcoin/node"
        chmod 0600 "$F/etc/telcoin/.node-meta"
        run check_ownership_layout
        check "layout 2: setgid node log dir holds" "yes 0" "$(has "$OUT" "Ownership layout 2: install") $ADDED"
        chmod g-s "$F/var/log/telcoin/node"
        run check_ownership_layout
        check "layout 2: node log dir without setgid listed" yes \
            "$(has "$OUT" "${F}/var/log/telcoin/node: nobody:telcoin-log 750, expected nobody:telcoin-log 2750")"
    else
        skip "layout 2: node log dir" "telcoin-log group cannot be created"
    fi
else
    skip "layout 2: path by path" "needs root and a root-only directory under /root"
fi

# --audit runs tn_host_audit alone and exits with its rc (0 clean, 1 a warning).
rc=0; out="$(bash "$TN_TEST_REPO/check-node.sh" --audit 2>&1)" || rc=$?
check "--audit exits 0 or 1" yes "$( [[ $rc -eq 0 || $rc -eq 1 ]] && echo yes || echo "no ($rc)")"
check "--audit prints the systemd line" yes "$(printf '%s\n' "$out" | grep -q 'systemd' && echo yes || echo no)"
check "--help lists --audit" yes "$(bash "$TN_TEST_REPO/check-node.sh" --help 2>&1 | grep -q -- '--audit' && echo yes || echo no)"

# -----------------------------------------------------------------------------
# check_p2p_committee: the P2P committee allowlist, over the fwstub nft,
# systemctl and tn-p2p-allow-sync stubs, a stand-in firewall-setup.sh (its
# --json --status line) and a stand-in tn_epoch_info. Every case starts from a
# clean committee node (cn_clean) and changes one thing.
# -----------------------------------------------------------------------------
check "check_p2p_committee cut out of check-node.sh" "yes" \
    "$(declare -F check_p2p_committee >/dev/null && echo yes || echo no)"
export TN_ROOT_PREFIX="$T/fx"
unset TN_UPDATE_LOCK_FILE
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
fw_stub_install "$T/fwbin"
PATH="$T/fwbin:$PATH"
hash -r
SCRIPT_DIR="$T/cn"
AD="$T/fx/var/lib/telcoin-p2p-allow"
mkdir -p "$SCRIPT_DIR" "$AD" "${TN_P2P_ALLOW_BIN%/*}"
cat > "$SCRIPT_DIR/firewall-setup.sh" <<'STUB'
#!/bin/sh
# firewall-setup.sh stand-in: --json --status prints $CN_FW_JSON.
[ "$*" = "--json --status" ] || exit 2
printf '%s\n' "${CN_FW_JSON:-}"
STUB
REC="$T/rec"
export REC
export SYSTEMCTL_LOG="$T/systemctl.log"
printf 'LEAK\n' > "$T/leak"
# the node's RPC, as the stand-in answers tn_getCurrentEpochInfo
tn_epoch_info() {
    [[ -n "${CN_EPOCH_LINE:-}" ]] || { printf 'rpc-down\n'; return 1; }
    printf '%s\n' "$CN_EPOCH_LINE"
}
FW_JSON_OK='{"installed":true,"p2p_ports":[{"port":49590,"proto":"udp","label":"primary","allowed":true},{"port":49594,"proto":"udp","label":"worker-0","allowed":true}],"p2p_new_flow_limit":{"active":false}}'
CHECK_OK='result=ok missing_total=0 mismatch_total=0'
# st_write [KEY=VALUE...] -- the status file the tool writes, a fresh run by
# default; each argument replaces its key's line.
st_write() {
    local line o out=""
    for line in STATUS_VERSION=1 TOOL_VERSION=0.1.0 RESULT=unchanged "LAST_RUN=${NOW}" "LAST_GOOD=${NOW}" \
        EPOCH=42 EPOCH_DURATION=21600 STALE_SINCE= STALE_REASON= ALLOWED_V4=3 ALLOWED_V6=1 STATIC_V4=1 \
        STATIC_V6=0 FLOOR=2 KEYS=4 DNS_SKIPPED=0 UNPARSED=0 UNKNOWN_SLOTS=0; do
        for o in "$@"; do
            [[ "${o%%=*}" != "${line%%=*}" ]] || line="$o"
        done
        out="${out}${line}"$'\n'
    done
    printf '%s' "$out" > "$AD/status"
}
# cfg_write RPC_PORT P2P_PORTS P2P_ALLOW_FROM -- the config the scripts write.
cfg_write() {
    printf '# tn-p2p-allow-sync config, written by firewall-setup.sh\nCONFIG_VERSION=1\nRPC_PORT=%s\nP2P_PORTS=%s\nP2P_ALLOW_FROM=%s\n' \
        "$1" "$2" "$3" > "$AD/config"
}
# cn_clean -- committee mode on and everything as it should be.
cn_clean() {
    NOW="$(date +%s)"
    meta "NETWORK=testnet" "P2P_COMMITTEE=on" "RPC_PORT=8545" "P2P_ALLOW_FROM=203.0.113.0/24,198.51.100.9"
    cfg_write 8545 49590,49594 203.0.113.0/24,198.51.100.9
    st_write
    cp "$T/fwbin/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"
    : > "$T/fx/.nft.allow"
    rm -f "$T/fx/.nft.table" "$REC.log" "$REC.argv" "$REC.env" "$REC.stdin" "$SYSTEMCTL_LOG"
    printf '%s\n' telcoin-p2p-allow-sync.timer telcoin-p2p-allow.service > "$T/fx/.systemctl.enabled"
    unset NFT_LIST_FAIL LOCAL_RPC_MODE TN_P2P_STUB_RC_CHECK SYSTEMCTL_SHOW
    export CN_FW_JSON="$FW_JSON_OK" TN_P2P_STUB_OUT_CHECK="$CHECK_OK"
    CN_EPOCH_LINE="42 1000 21600 1 -"
}
called() { [[ -s "$REC.log" ]] && echo yes || echo no; }

cn_clean
meta "NETWORK=testnet" "P2P_COMMITTEE=off"
run check_p2p_committee
check "committee: off is silent, the tool is not run" "0 no" "${#OUT} $(called)"
meta "NETWORK=testnet"
run check_p2p_committee
check "committee: no key is off" "0 no" "${#OUT} $(called)"

cn_clean
TN_P2P_STUB_STDIN=1 TN_BLS_PASSPHRASE=hunter2 run check_p2p_committee < "$T/leak"
check "committee: all clean says nothing" "" "$OUT"
check "committee: all clean adds no failure" "0" "$ADDED"
check "committee: check runs on the state dir" "--state-dir
${AD}
check" "$(cat "$REC.argv")"
check "committee: the tool gets stdin closed" "" "$(cat "$REC.stdin")"
check "committee: the tool never sees the passphrase" "no" "$(grep -q '^TN_BLS_PASSPHRASE=' "$REC.env" && echo yes || echo no)"

cn_clean
meta "NETWORK=testnet" "P2P_COMMITTEE=on" "P2P_COMMITTEE=on"
run check_p2p_committee
check "committee: P2P_COMMITTEE twice warns, nothing checked" "yes 0 no" \
    "$(has "$OUT" "P2P_COMMITTEE is set more than once") $ADDED $(called)"

cn_clean
rm -f "$TN_P2P_ALLOW_BIN"
run check_p2p_committee
check "committee: binary missing fails with the fix line" "yes yes 1 no" \
    "$(has "$OUT" "tn-p2p-allow-sync is missing") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync  (reinstalls") $ADDED $(called)"

cn_clean
rm -f "$T/fx/.nft.allow"
run check_p2p_committee
check "committee: table missing fails, P2P open" "yes yes 1 no" \
    "$(has "$OUT" "no table inet tn_p2p_allow: P2P is open to every source") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $ADDED $(called)"

cn_clean
NFT_LIST_FAIL=1 run check_p2p_committee
check "committee: nft cannot list, warned, check not run" "yes 0 no" \
    "$(has "$OUT" "nft could not list the nftables tables") $ADDED $(called)"

cn_clean
: > "$T/fx/.nft.table"
run check_p2p_committee
check "committee: the new-flow limit table loaded too warns" "yes yes 0" \
    "$(has "$OUT" "new-flow limit table inet tn_p2p is loaded as well") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --enable") $ADDED"

cn_clean
printf 'telcoin-p2p-allow.service\n' > "$T/fx/.systemctl.enabled"
run check_p2p_committee
check "committee: timer disabled warns" "yes yes 0" \
    "$(has "$OUT" "telcoin-p2p-allow-sync.timer is not enabled and active") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $ADDED"

cn_clean
CN_EPOCH_LINE=""
st_write "LAST_GOOD=$(( NOW - 1300 ))" EPOCH_DURATION=600 RESULT=stale "STALE_SINCE=$(( NOW - 1000 ))" STALE_REASON=rpc-unreachable
run check_p2p_committee
check "committee: stale by age, the status file's duration" "yes yes yes yes 0" \
    "$(has "$OUT" "is stale: no good sync for 21m") $(has "$OUT" "more than 2 epochs of 10m 0s") $(has "$OUT" "failing since") $(has "$OUT" "(rpc-unreachable)") $ADDED"
st_write "LAST_GOOD=$(( NOW - 1300 ))" EPOCH_DURATION=21600 RESULT=stale "STALE_SINCE=$(( NOW - 1000 ))" STALE_REASON=rpc-unreachable
run check_p2p_committee
check "committee: under 2 epochs is not stale yet" "" "$OUT"

cn_clean
CN_EPOCH_LINE="42 1000 600 1 -"
st_write "LAST_GOOD=$(( NOW - 1300 ))" EPOCH_DURATION=21600
run check_p2p_committee
check "committee: stale by age, the live epoch duration" "yes yes 0" \
    "$(has "$OUT" "is stale: no good sync for 21m") $(has "$OUT" "more than 2 epochs of 10m 0s") $ADDED"
LOCAL_RPC_MODE=DOWN run check_p2p_committee
check "committee: no live duration while the local RPC is down" "" "$OUT"

st_write RESULT=stale "STALE_SINCE=${NOW}" STALE_REASON=rpc-method-missing
run check_p2p_committee
# the operator line, byte for byte as firewall-setup.sh says it
check "committee: rpc-method-missing warned at once, the method or --http.api" "yes yes no no 0" \
    "$(has "$OUT" "(rpc-method-missing): this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api. Until then") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/update-node.sh") $(has "$OUT" "is stale:") $(has "$OUT" "predates it") $ADDED"
st_write RESULT=stale "STALE_SINCE=${NOW}" STALE_REASON=snapshot-version-2
run check_p2p_committee
check "committee: snapshot-version-2 warned at once" "yes yes 0" \
    "$(has "$OUT" "admission snapshot version 2, which the installed tn-p2p-allow-sync does not read") $(has "$OUT" "update-scripts.sh, then sudo bash") $ADDED"
st_write RESULT=stale "STALE_SINCE=${NOW}" STALE_REASON=epoch-regressed
run check_p2p_committee
check "committee: epoch-regressed warned at once, clears by itself, off then on past 2 epochs" "yes yes yes no no 0" \
    "$(has "$OUT" "epoch below the one the allowlist was built from (epoch-regressed, stale since ") $(has "$OUT" "It clears by itself once the node's tracked epoch is back at or above the applied one (after a startup record-sync replay).") $(has "$OUT" "If it persists past 2 epochs: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee off, then --p2p-committee on") $(has "$OUT" "clear on its own") $(has "$OUT" "is stale:") $ADDED"
st_write RESULT=error "STALE_SINCE=${NOW}" STALE_REASON=state-invalid
export SYSTEMCTL_SHOW='Result=exit-code
ExecMainStatus=2'
run check_p2p_committee
check "committee: state-invalid warned at once, off then on, not as staleness" "yes yes no no 0" \
    "$(has "$OUT" "cannot read its own state.json (state-invalid)") $(has "$OUT" "--p2p-committee off, then --p2p-committee on") $(has "$OUT" "is stale:") $(has "$OUT" "sync now:") $ADDED"
check "committee: state-invalid with the failed unit is one warning" "1" "$(grep -c 'WARN' "$T/out")"

# A failed run (RESULT=error) is said at once with its reason and the unit's
# journal, never only once it is 2 epochs old.
for r in nft-apply-failed state-io-failed floor-invalid reload-failed; do
    cn_clean
    st_write RESULT=error "STALE_SINCE=${NOW}" "STALE_REASON=${r}"
    run check_p2p_committee
    check "committee: RESULT=error ${r} warned at once with the journal" "yes yes no 0" \
        "$(has "$OUT" "P2P committee allowlist: its last sync failed (${r}, failing since ") $(has "$OUT" "Why: journalctl -u telcoin-p2p-allow-sync.service -n 20; sync now: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $(has "$OUT" "is stale:") $ADDED"
done
cn_clean
st_write RESULT=error "STALE_SINCE=${NOW}" STALE_REASON=config-invalid
run check_p2p_committee
check "committee: RESULT=error config-invalid, the resync rewrites the config" "yes yes no 0" \
    "$(has "$OUT" "its last sync failed (config-invalid, failing since ") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync  (rewrites its config)") $(has "$OUT" "journalctl") $ADDED"
cn_clean
st_write RESULT=error "LAST_GOOD=$(( NOW - 50000 ))" "STALE_SINCE=$(( NOW - 49000 ))" STALE_REASON=nft-apply-failed
export SYSTEMCTL_SHOW='ExecMainStatus=2
Result=exit-code'
run check_p2p_committee
check "committee: RESULT=error past 2 epochs and a failed unit, one warning" "yes no 1 0" \
    "$(has "$OUT" "its last sync failed (nft-apply-failed, failing since ") $(has "$OUT" "is stale:") $(grep -c 'WARN' "$T/out") $ADDED"
cn_clean
st_write RESULT=error STALE_REASON=
run check_p2p_committee
check "committee: RESULT=error without a reason still warns" "yes yes" \
    "$(has "$OUT" "its last sync failed, so it keeps its last-good set until a sync succeeds.") $(has "$OUT" "journalctl -u telcoin-p2p-allow-sync.service")"

# The sync unit's last run, as systemd shows it: a failure is said at once,
# exit 3 and 4 (the unit's SuccessExitStatus) are success.
cn_clean
export SYSTEMCTL_SHOW='ExecMainStatus=2
Result=exit-code'
run check_p2p_committee
check "committee: unit Result=exit-code warned at once with the journal" "yes yes no 0" \
    "$(has "$OUT" "the last run of telcoin-p2p-allow-sync.service failed (it exited with status 2), so the allowlist keeps its last-good set until a sync succeeds.") $(has "$OUT" "Why: journalctl -u telcoin-p2p-allow-sync.service -n 20; sync now: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $(has "$OUT" "is stale:") $ADDED"
check "committee: the unit's Result and ExecMainStatus are asked of systemd" "1" \
    "$(grep -cx 'show -p Result -p ExecMainStatus telcoin-p2p-allow-sync.service' "$SYSTEMCTL_LOG")"
export SYSTEMCTL_SHOW='Result=exit-code
ExecMainStatus=226'
run check_p2p_committee
check "committee: a unit that fails before the tool runs warned" "yes 0" \
    "$(has "$OUT" "telcoin-p2p-allow-sync.service failed (it exited with status 226)") $ADDED"
export SYSTEMCTL_SHOW='Result=signal
ExecMainStatus=9'
run check_p2p_committee
check "committee: unit killed by a signal warned" "yes" \
    "$(has "$OUT" "telcoin-p2p-allow-sync.service failed (it was killed by signal 9)")"
export SYSTEMCTL_SHOW='Result=timeout
ExecMainStatus=15'
run check_p2p_committee
check "committee: unit timed out warned" "yes" \
    "$(has "$OUT" "telcoin-p2p-allow-sync.service failed (systemd result timeout)")"
for u in "Result=success ExecMainStatus=0" "Result=success ExecMainStatus=3" "Result=exit-code ExecMainStatus=3" "Result=exit-code ExecMainStatus=4"; do
    export SYSTEMCTL_SHOW="${u% *}
${u#* }"
    run check_p2p_committee
    check "committee: healthy status, unit ${u}, says nothing" "" "$OUT"
done
st_write RESULT=stale "STALE_SINCE=${NOW}" STALE_REASON=rpc-unreachable
export SYSTEMCTL_SHOW='Result=success
ExecMainStatus=3'
run check_p2p_committee
check "committee: a fresh stale run with the unit's exit 3 says nothing" "" "$OUT"

cn_clean
export TN_P2P_STUB_RC_CHECK=1 TN_P2P_STUB_OUT_CHECK='missing 192.0.2.10
missing 2001:db8::7
result=missing missing_total=2 mismatch_total=0'
run check_p2p_committee
check "committee: check exit 1 is one failure naming both addresses" "yes yes 1" \
    "$(has "$OUT" "lacks 2 address(es) of the current committee (192.0.2.10, 2001:db8::7)") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $ADDED"
check "committee: one error line for the missing addresses" "1" "$(grep -c 'ERROR' "$T/out")"
export TN_P2P_STUB_OUT_CHECK='missing 192.0.2.1
missing 192.0.2.2
missing 192.0.2.3
missing 192.0.2.4
missing 192.0.2.5
result=missing missing_total=7 mismatch_total=0'
run check_p2p_committee
check "committee: at most five named, the rest counted" "yes 1" \
    "$(has "$OUT" "lacks 7 address(es) of the current committee (192.0.2.1, 192.0.2.2, 192.0.2.3, 192.0.2.4, 192.0.2.5, and 2 more)") $ADDED"
# a tool that prints more than five lines still gets five named
export TN_P2P_STUB_OUT_CHECK='missing 192.0.2.1
missing 192.0.2.2
missing 192.0.2.3
missing 192.0.2.4
missing 192.0.2.5
missing 192.0.2.6
result=missing missing_total=6 mismatch_total=0'
run check_p2p_committee
check "committee: six missing lines, five named" "yes no 1" \
    "$(has "$OUT" "lacks 6 address(es) of the current committee (192.0.2.1, 192.0.2.2, 192.0.2.3, 192.0.2.4, 192.0.2.5, and 1 more)") $(has "$OUT" "192.0.2.6") $ADDED"
export TN_P2P_STUB_OUT_CHECK='missing 192.0.2.1
missing 192.0.2.2
missing 192.0.2.3
missing 192.0.2.4
missing 192.0.2.5
missing 192.0.2.6
result=missing'
run check_p2p_committee
check "committee: six missing lines without a total, five named, the sixth counted" "yes 1" \
    "$(has "$OUT" "lacks 6 address(es) of the current committee (192.0.2.1, 192.0.2.2, 192.0.2.3, 192.0.2.4, 192.0.2.5, and 1 more)") $ADDED"
export TN_P2P_STUB_OUT_CHECK='result=absent missing_total=0 mismatch_total=0'
run check_p2p_committee
check "committee: check finds no table, P2P open" "yes 1" "$(has "$OUT" "P2P is open to every source") $ADDED"
# a table set dormant by hand enforces nothing; the sync re-applies and wakes it
export TN_P2P_STUB_OUT_CHECK='result=dormant missing_total=0 mismatch_total=0'
run check_p2p_committee
check "committee: check finds the table dormant, P2P open, sync is the fix" "yes yes no no 1" \
    "$(has "$OUT" "P2P committee mode is on, but tn-p2p-allow-sync check finds table inet tn_p2p_allow dormant (set by hand): it enforces nothing, and P2P is open to every source until a sync applies it again.") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync  (applies the allowlist again, which wakes the table)") $(has "$OUT" "consistency check failed") $(has "$OUT" "lacks") $ADDED"
check "committee: one error line for the dormant table" "1" "$(grep -c 'ERROR' "$T/out")"
export TN_P2P_STUB_OUT_CHECK='missing 198.51.100.7
result=dormant missing_total=1 mismatch_total=0'
run check_p2p_committee
check "committee: a dormant table with a missing address says both, as one failure" "yes yes yes 1" \
    "$(has "$OUT" "finds table inet tn_p2p_allow dormant (set by hand)") $(has "$OUT" "It also lacks 1 address(es) of the current committee (198.51.100.7), which the sync adds back.") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync") $ADDED"
check "committee: one error line for the dormant table with a missing address" "1" "$(grep -c 'ERROR' "$T/out")"

cn_clean
export TN_P2P_STUB_OUT_CHECK='mismatch 0x0123456789abcdef
mismatch 0xfedcba9876543210
result=ok missing_total=0 mismatch_total=2'
run check_p2p_committee
check "committee: mismatch lines are a warning" "yes yes 0" \
    "$(has "$OUT" "2 committee key(s) have node records that list other addresses") $(has "$OUT" "(0x0123456789abcdef, 0xfedcba9876543210)") $ADDED"
check "committee: mismatches alone are no error" "0" "$(grep -c 'ERROR' "$T/out")"
export TN_P2P_STUB_OUT_CHECK='mismatch 0x0000000000000001
mismatch 0x0000000000000002
mismatch 0x0000000000000003
mismatch 0x0000000000000004
mismatch 0x0000000000000005
mismatch 0x0000000000000006
result=ok missing_total=0 mismatch_total=6'
run check_p2p_committee
check "committee: six mismatch lines, five named" "yes no 0" \
    "$(has "$OUT" "6 committee key(s) have node records that list other addresses than the ones this node knows them by (0x0000000000000001, 0x0000000000000002, 0x0000000000000003, 0x0000000000000004, 0x0000000000000005, and 1 more)") $(has "$OUT" "0x0000000000000006") $ADDED"

cn_clean
export TN_P2P_STUB_RC_CHECK=3 TN_P2P_STUB_OUT_CHECK='behind snapshot_epoch=43 applied_epoch=42
missing 192.0.2.10
result=behind missing_total=1 mismatch_total=0'
run check_p2p_committee
check "committee: check exit 3 behind is an info line" "yes no 0" \
    "$(has "$OUT" "not compared with the committee: the last sync is behind the snapshot") $(has "$OUT" "192.0.2.10") $ADDED"
export TN_P2P_STUB_OUT_CHECK='stale reason=rpc-unreachable
result=stale missing_total=0 mismatch_total=0'
run check_p2p_committee
check "committee: check exit 3 stale names the reason" "yes 0" \
    "$(has "$OUT" "admission snapshot cannot be used now (rpc-unreachable)") $ADDED"

cn_clean
export TN_P2P_STUB_RC_CHECK=2 TN_P2P_STUB_OUT_CHECK='error reason=config-invalid detail="line 3: unknown key"'
run check_p2p_committee
check "committee: check exit 2 fails naming the token" "yes 1" \
    "$(has "$OUT" "tn-p2p-allow-sync check ended with reason config-invalid.") $ADDED"
export TN_P2P_STUB_OUT_CHECK=''
run check_p2p_committee
check "committee: check exit 2 without a reason names the exit code" "yes 1" \
    "$(has "$OUT" "tn-p2p-allow-sync check ended with exit 2.") $ADDED"

cn_clean
meta "NETWORK=testnet" "P2P_COMMITTEE=on" "RPC_PORT=8546" "P2P_ALLOW_FROM=203.0.113.0/24,198.51.100.9"
run check_p2p_committee
check "committee: RPC_PORT drift warns" "yes yes yes no no 0" \
    "$(has "$OUT" "config no longer matches this node") $(has "$OUT" "RPC_PORT: 8545 in the config, 8546 in .node-meta") $(has "$OUT" "Fix: sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync  (rewrites the config)") $(has "$OUT" "P2P_PORTS:") $(has "$OUT" "P2P_ALLOW_FROM:") $ADDED"

cn_clean
export CN_FW_JSON='{"p2p_ports":[{"port":49590,"proto":"udp","label":"primary","allowed":true},{"port":49600,"proto":"udp","label":"worker-0","allowed":true}]}'
run check_p2p_committee
check "committee: P2P_PORTS drift warns" "yes yes no 0" \
    "$(has "$OUT" "P2P_PORTS: 49590,49594 in the config, 49590,49600 on the node") $(has "$OUT" "--p2p-committee sync  (rewrites the config)") $(has "$OUT" "RPC_PORT:") $ADDED"
export CN_FW_JSON='{"installed":true}'
run check_p2p_committee
check "committee: no P2P ports from firewall-setup.sh, said" "yes no 0" \
    "$(has "$OUT" "P2P ports were not compared") $(has "$OUT" "no longer matches") $ADDED"

cn_clean
meta "NETWORK=testnet" "P2P_COMMITTEE=on" "RPC_PORT=8545" "P2P_ALLOW_FROM=203.0.113.0/24"
run check_p2p_committee
check "committee: P2P_ALLOW_FROM drift warns" "yes yes 0" \
    "$(has "$OUT" "P2P_ALLOW_FROM: 203.0.113.0/24,198.51.100.9 in the config, 203.0.113.0/24 in .node-meta") $(has "$OUT" "--p2p-committee sync  (rewrites the config)") $ADDED"
meta "NETWORK=testnet" "P2P_COMMITTEE=on" "RPC_PORT=8545"
run check_p2p_committee
check "committee: a list dropped from .node-meta is drift" "yes" \
    "$(has "$OUT" "P2P_ALLOW_FROM: 203.0.113.0/24,198.51.100.9 in the config, empty in .node-meta")"
meta "NETWORK=testnet" "P2P_COMMITTEE=on" "RPC_PORT=8545" "P2P_ALLOW_FROM=203.0.113.0/24, 198.51.100.9,"
run check_p2p_committee
check "committee: the same list written with blanks is no drift" "" "$OUT"

if [[ $IS_ROOT == 0 ]]; then
    cn_clean
    chmod 000 "$AD"
    run check_p2p_committee
    chmod 0700 "$AD"
    check "committee: state dir unreadable without sudo" "yes 0 no" \
        "$(has "$OUT" "readable by root only (run with sudo)") $ADDED $(called)"
else
    skip "committee: state dir unreadable without sudo" "root reads everything"
fi
finish
