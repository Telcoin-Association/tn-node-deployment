#!/usr/bin/env bash
# =============================================================================
# tools/tests/edit_config_resync_test.sh -- edit-config.sh's P2P committee
# allowlist resync (edit_committee_resync) and its three call sites: the
# apply_changes and run_set success branches and the menu's Restart node
# (restart_node), which is where an edit saved with "restart later" reaches the
# node.
#
#   bash tools/tests/edit_config_resync_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/edit_config_resync_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/edit_config_resync_test.sh
#
# edit-config.sh is sourced without its main call from a copy beside a stub
# firewall-setup.sh, which logs its arguments, whether the update lock is free,
# whether fd 3 (the --json event channel) is open and how many bytes it read on
# stdin, then exits FW_STUB_RC. Cases: which edits trigger the sync (node.env,
# bootstrap-peers.yaml, no backup at all) and which do not (the launch file
# alone, P2P_COMMITTEE off, missing or set twice); the update lock released
# before the child runs; the child's exit codes; --json events on fd 3 with the
# child's output kept off it; the sync only after a restart the node came back
# from, after the host baseline, and before the done event of --set.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
FWLOG="$T/fw.log"
TN_UPDATE_LOCK_FILE="$T/update.lock"
export FWLOG TN_UPDATE_LOCK_FILE
mkdir -p "$T/h" "$T/fx/etc/telcoin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
cat > "$T/h/firewall-setup.sh" <<'FWS'
#!/bin/sh
lock=held
if command -v flock >/dev/null 2>&1; then
    if flock -n "$TN_UPDATE_LOCK_FILE" true 2>/dev/null; then lock=free; fi
elif [ ! -d "$TN_UPDATE_LOCK_FILE.d" ]; then
    lock=free
fi
fd3=closed
if { true >&3; } 2>/dev/null; then fd3=open; fi
n="$(cat | wc -c | tr -d ' ')"
printf 'firewall-setup %s lock=%s fd3=%s stdin=%s\n' "$*" "$lock" "$fd3" "$n" >> "$FWLOG"
echo "stub stdout line"
exit "${FW_STUB_RC:-0}"
FWS
META="$T/fx/etc/telcoin/.node-meta"
ENVF="$T/fx/etc/telcoin/node.env"
PEERS="$T/fx/etc/telcoin/bootstrap-peers.yaml"
LAUNCH="$T/fx/usr/local/libexec/telcoin/tn-start"

TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common
tn_migrate_ownership() { return 0; }
edit_legacy_reason() { return 1; }

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
fwlog() { cat "$FWLOG" 2>/dev/null; }
SYNC="firewall-setup --p2p-committee sync lock=free fd3=closed stdin=0"
# fake_backups FILE... -- the backup state edit_backup records for an edit of FILEs:
# the copy path, a sum that is not the file's (the edit changed it) and a mode, so
# edit_bk_changed sees a change and the rollback of a failed restart has entries to
# read. The rollback itself has its own fixture; the restore is a stub here.
fake_backups() {
    local f
    EDIT_BK_FILES=() EDIT_BK_COPIES=() EDIT_BK_SUMS=() EDIT_BK_MODES=()
    for f in "$@"; do
        EDIT_BK_FILES+=("$f")
        EDIT_BK_COPIES+=("$f.bk")
        EDIT_BK_SUMS+=("0000000000000000000000000000000000000000000000000000000000000000")
        EDIT_BK_MODES+=("644 root")
    done
}
edit_restore_backups() { EDIT_PENDING=false; return 0; }

# resync MODE FILE... -- P2P_COMMITTEE=MODE (none: no key, twice: two lines), the
# edit's backups FILE..., the lock held, then edit_committee_resync; OUT and RC.
resync() {
    local mode="$1"
    shift
    case "$mode" in
        none)  printf 'NETWORK=testnet\n' > "$META" ;;
        twice) printf 'NETWORK=testnet\nP2P_COMMITTEE=on\nP2P_COMMITTEE=on\n' > "$META" ;;
        *)     printf 'NETWORK=testnet\nP2P_COMMITTEE=%s\n' "$mode" > "$META" ;;
    esac
    fake_backups "$@"
    : > "$FWLOG"
    : > "$T/json"
    edit_lock
    edit_committee_resync > "$T/out" 2>&1 3> "$T/json"
    RC=$?
    OUT="$(cat "$T/out")"
}

# --- the trigger ---------------------------------------------------------------
resync on "$ENVF"
check_rc "node.env changed, on: rc 0" 0 "$RC"
check "node.env changed, on: one sync, lock free, fd 3 closed, no stdin" "$SYNC" "$(fwlog)"
check "node.env changed, on: the lock is released first" "false" "$EDIT_LOCK_HELD"
check "node.env changed, on: the child's stdout passes through" yes "$(has "$OUT" "stub stdout line")"
check "node.env changed, on: no warning" no "$(has "$OUT" "WARN")"
check "node.env changed, on: nothing on fd 3 in human mode" "" "$(cat "$T/json")"
resync on "$PEERS"
check "bootstrap-peers.yaml changed, on: one sync" "$SYNC" "$(fwlog)"
resync on
check "no backup (the chain-config refresh), on: one sync" "$SYNC" "$(fwlog)"
resync on "$LAUNCH"
check "only the launch file changed, on: no sync, the lock still held" "| true" "$(fwlog)| $EDIT_LOCK_HELD"
edit_unlock
resync on "$LAUNCH" "$ENVF"
check "launch file and node.env changed, on: one sync" "$SYNC" "$(fwlog)"
resync off "$ENVF"
check "node.env changed, off: no sync, the lock still held" "| true" "$(fwlog)| $EDIT_LOCK_HELD"
edit_unlock
resync none "$ENVF"
check "node.env changed, no P2P_COMMITTEE: no sync" "" "$(fwlog)"
edit_unlock
resync twice "$ENVF"
check "P2P_COMMITTEE twice: no sync" "" "$(fwlog)"
check "P2P_COMMITTEE twice: says why and what to run" yes \
    "$(has "$OUT" "P2P_COMMITTEE is set more than once in .node-meta, so the P2P committee allowlist was not synced with this edit; remove the extra lines, then run: sudo bash ${T}/h/firewall-setup.sh --p2p-committee sync")"
edit_unlock

# --- the child's exit code ---------------------------------------------------------
export FW_STUB_RC=2
resync on "$ENVF"
check_rc "sync failed: rc 0" 0 "$RC"
check "sync failed: warned with the command" yes \
    "$(has "$OUT" "The P2P committee allowlist was not synced with this edit (firewall-setup.sh exit 2); run: sudo bash ${T}/h/firewall-setup.sh --p2p-committee sync")"
export FW_STUB_RC=3
resync on "$ENVF"
check "stale: the timer named" yes "$(has "$OUT" "keeps its last-good set for now")"
export FW_STUB_RC=0

# --- --json: events on fd 3, the child's output never there --------------------------
JSON_MODE=true
export FW_STUB_RC=2
resync on "$ENVF"
check "json: step event" yes "$(has "$(cat "$T/json")" '{"event":"step","msg":"Syncing the P2P committee allowlist with the edit"}')"
check "json: warn event names the command" yes \
    "$(has "$(cat "$T/json")" "\"event\":\"warn\",\"msg\":\"The P2P committee allowlist was not synced with this edit (firewall-setup.sh exit 2)")"
check "json: the child's stdout is not on fd 3" no "$(has "$(cat "$T/json")" "stub stdout line")"
check "json: fd 3 closed for the child" "$SYNC" "$(fwlog)"
export FW_STUB_RC=0
JSON_MODE=false

# --- apply_changes: after a restart the node came back from, never otherwise ------
EV=""
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$FWLOG"
    case "$1" in
        is-active) return "${ACTIVE_RC:-0}" ;;
    esac
    return 0
}
confirm() { return "${CONFIRM_RC:-0}"; }
edit_epoch_wait() { return 0; }
edit_baseline_refresh() { printf 'baseline\n' >> "$FWLOG"; }
sleep() { :; }
TARGET_SERVICE=telcoin
apply_menu() {
    printf 'NETWORK=testnet\nP2P_COMMITTEE=on\n' > "$META"
    fake_backups "$ENVF"
    : > "$FWLOG"
    edit_lock
    apply_changes < /dev/null > "$T/out" 2>&1
    set +e
}
apply_menu
check "menu: restarted, baseline, then one sync, the lock released" "systemctl daemon-reload
systemctl restart telcoin
systemctl show -p NRestarts --value telcoin
systemctl is-active --quiet telcoin
baseline
${SYNC}" "$(fwlog)"
check "menu: lock released at the end" "false" "$EDIT_LOCK_HELD"
ACTIVE_RC=3
apply_menu
check "menu: the node did not come back: no sync" no "$(has "$(fwlog)" "firewall-setup")"
ACTIVE_RC=0
CONFIRM_RC=1
apply_menu
check "menu: restart later: no sync" no "$(has "$(fwlog)" "firewall-setup")"
CONFIRM_RC=0

# --- the menu's Restart node: an edit saved for later reaches the node here --------
edit_unlock
# restart_later -- an edit of node.env saved with "restart later", as the menu
# leaves it: the backups recorded, the lock released.
restart_later() {
    printf 'NETWORK=testnet\nP2P_COMMITTEE=on\n' > "$META"
    fake_backups "$ENVF"
    edit_lock
    CONFIRM_RC=1 apply_changes < /dev/null > "$T/out" 2>&1
    set +e
    edit_unlock
    : > "$FWLOG"
}
restart_menu() { restart_node < /dev/null > "$T/out" 2>&1; set +e; }
restart_later
restart_menu
check "restart node after restart later: restarted, baseline, then one sync" "systemctl is-active --quiet telcoin
systemctl restart telcoin
systemctl is-active --quiet telcoin
baseline
${SYNC}" "$(fwlog)"
check "restart node: the lock released at the end" "false" "$EDIT_LOCK_HELD"
restart_later
ACTIVE_RC=3
restart_menu
check "restart node: the node did not come back: no sync" no "$(has "$(fwlog)" "firewall-setup")"
ACTIVE_RC=0
restart_later
CONFIRM_RC=1
restart_menu
check "restart node cancelled: no restart, no sync" "no no" \
    "$(has "$(fwlog)" "systemctl restart") $(has "$(fwlog)" "firewall-setup")"
CONFIRM_RC=0
restart_later
edit_epoch_wait() { return 1; }
restart_menu
check "restart node refused by the committee check: no restart, no sync" "no no" \
    "$(has "$(fwlog)" "systemctl restart") $(has "$(fwlog)" "firewall-setup")"
edit_epoch_wait() { return 0; }
restart_later
printf 'NETWORK=testnet\nP2P_COMMITTEE=off\n' > "$META"
restart_menu
check "restart node, committee mode off: restarted, no sync" "yes no" \
    "$(has "$(fwlog)" "systemctl restart telcoin") $(has "$(fwlog)" "firewall-setup")"

# --- run_set: the sync comes before the done event ---------------------------------
edit_require_root() { :; }
resolve_target() { return 0; }
set_field() { fake_backups "$ENVF"; return 0; }
edit_any_changed() { return 0; }
edit_report_backups() { :; }
edit_restart() { printf 'restart\n' >> "$FWLOG"; return 0; }
JSON_MODE=true
JSON_DONE_SENT=false
EDIT_SET_PAIR="primary_listener=/ip4/0.0.0.0/udp/49600/quic-v1"
printf 'NETWORK=testnet\nP2P_COMMITTEE=on\n' > "$META"
: > "$FWLOG"
: > "$T/json"
run_set > "$T/out" 2>&1 3> "$T/json"
RC=$?
check_rc "--set primary_listener: rc 0" 0 "$RC"
check "--set primary_listener: restart, baseline, then one sync" "restart
baseline
${SYNC}" "$(fwlog)"
check "--set primary_listener: the sync step, then the done event last" \
    '{"event":"step","msg":"Syncing the P2P committee allowlist with the edit"}
{"event":"done","ok":true,"field":"primary_listener","value":"/ip4/0.0.0.0/udp/49600/quic-v1","msg":"applied and telcoin healthy"}' \
    "$(grep -v '"msg":"Setting ' "$T/json")"
set_field() { fake_backups "$LAUNCH"; return 0; }
EDIT_SET_PAIR="verbosity=-vv"
: > "$FWLOG"
: > "$T/json"
run_set > "$T/out" 2>&1 3> "$T/json"
check "--set verbosity (launch file only): no sync" no "$(has "$(fwlog)" "firewall-setup")"
edit_unlock
JSON_MODE=false

finish
