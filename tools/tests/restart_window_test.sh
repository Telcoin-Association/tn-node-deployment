#!/usr/bin/env bash
# tools/tests/restart_window_test.sh -- the stop sites check the committee again
# after the epoch wait (guard, wait, guard, stop), and tn_wait_restart_window
# pauses a random 0 to TN_EPOCH_JITTER_MAX seconds after the settle, inside the
# TN_EPOCH_WAIT_MAX cap (0 turns the pause off).
#
# migrate-node-naming's stop_legacy runs from the functions cut out of the
# script; setup-node's restart is checked in its source. Sleeps are counted, not
# slept. Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
eval "$(tn_test_source_common)"

# ---- tn_wait_restart_window: the pause after the settle --------------------------------
tn_node_mode() { printf 'CvvActive'; }
tn_epoch_secs_left() { printf '10 5 1010 0\n'; }
tn_epoch_info() { printf '6 0 0\n'; }
_tn_now() { printf '1000\n'; }
NAPPED=0
_tn_nap() { NAPPED=$(( NAPPED + $1 )); return 0; }
say() { printf '%s %s\n' "$1" "$2" >> "$T/say"; }
# naps -- the seconds napped by one wait (poll 15, settle 20).
naps() { rm -f "$T/say"; NAPPED=0; TN_EPOCH_POLL=15 TN_EPOCH_SETTLE=20 tn_wait_restart_window "http://127.0.0.1:8545" say; echo "$NAPPED"; }
# naps runs in $( ), so it reports through its output; the say file is shared.
check "no pause with TN_EPOCH_JITTER_MAX=0" 35 "$(TN_EPOCH_JITTER_MAX=0 naps)"
check "TN_EPOCH_JITTER_MAX=0 says nothing about a pause" no "$(grep -q 'Pausing' "$T/say" && echo yes || echo no)"
lo=999 hi=0 said=no
for seed in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    RANDOM=$seed
    n="$(TN_EPOCH_JITTER_MAX=4 naps)"
    (( n < lo )) && lo=$n
    (( n > hi )) && hi=$n
    if grep -q 'Pausing [1-4]s more (random, at most 4s, TN_EPOCH_JITTER_MAX)' "$T/say"; then said=yes; fi
done
check "the pause stays within 0..TN_EPOCH_JITTER_MAX" "yes" "$([[ $lo -ge 35 && $hi -le 39 ]] && echo yes || echo "no ${lo}-${hi}")"
check "the pause is random (some runs pause)" "yes" "$([[ $hi -gt 35 ]] && echo yes || echo no)"
check "a pause is said" yes "$said"
hi=0
for seed in 1 2 3 4 5 6 7 8 9 10; do
    RANDOM=$seed
    n="$(TN_EPOCH_JITTER_MAX=30 TN_EPOCH_WAIT_MAX=40 naps)"
    (( n > hi )) && hi=$n
done
check "the pause stays inside TN_EPOCH_WAIT_MAX" "yes" "$([[ $hi -le 40 ]] && echo yes || echo "no ${hi}")"
check "the default is at most 30s" "yes" \
    "$(n="$(unset TN_EPOCH_JITTER_MAX; naps)"; [[ $n -ge 35 && $n -le 65 ]] && echo yes || echo "no ${n}")"

# ---- migrate-node-naming: stop_legacy ------------------------------------------------
{
    sed -n '/^stop_guard() {/,/^}/p' "$TN_TEST_REPO/migrate-node-naming.sh"
    sed -n '/^stop_legacy() {/,/^}/p' "$TN_TEST_REPO/migrate-node-naming.sh"
} > "$T/stop.sh"
mig() {  # mig AFTER-RC -- the order of one stop_legacy and its exit status
    (
        ORDER=""
        ROLE=observer STOP_RPC_URL=http://127.0.0.1:8545 LEGACY_CONTAINER=x STOPPED_LEGACY=false
        eval "tn_committee_down_guard() { ORDER=\"\${ORDER} guard\"; case \"\$ORDER\" in *wait*) return $1 ;; esac; return 0; }"
        tn_wait_restart_window() { ORDER="${ORDER} wait"; }
        systemctl() { [[ "$1" == stop ]] && ORDER="${ORDER} stop"; return 0; }
        migrate_drop_snapshot() { :; }
        print_step() { :; }
        print_ok() { :; }
        print_error() { :; }
        trap 'echo "rc=$? order=${ORDER# }"' EXIT
        # shellcheck source=/dev/null
        source "$T/stop.sh"
        stop_legacy
    ) 2>/dev/null
}
check "migrate stop_legacy: guard, wait, guard, stop" "rc=0 order=guard wait guard stop" "$(mig 0)"
check "migrate stop_legacy: refused after the wait, not stopped" "rc=1 order=guard wait guard" "$(mig 1)"

# ---- setup-node: the restart of a running node -----------------------------------------
check "setup-node: guard, wait, guard, then systemctl restart" \
    "setup_quorum_guard tn_wait_restart_window setup_quorum_guard systemctl" \
    "$(awk '/^            setup_quorum_guard "http/ { f = 1 } f && !/^ *#/ { print $1 } f && /systemctl restart/ { exit }' "$TN_TEST_REPO/setup-node.sh" | paste -sd' ' -)"
finish
