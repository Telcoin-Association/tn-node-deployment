#!/usr/bin/env bash
# tools/tests/restart_window_test.sh -- the stop sites check the committee again
# after the epoch wait (guard, wait, guard, stop), and tn_wait_restart_window
# pauses a random 0 to TN_EPOCH_JITTER_MAX seconds after the settle, inside the
# TN_EPOCH_WAIT_MAX cap (0 turns the pause off). The margin and settle follow
# the epoch length read with the boundary unless TN_EPOCH_MARGIN or
# TN_EPOCH_SETTLE is set, and a cap shorter than the wait it bounds is kept with
# a warning. When no epoch length can be read (the blind wait), they derive the
# same way from the network's epoch constant (tn_network_epoch_duration), and
# the warning names where each value came from.
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
# Margin 10 + settle 20 + two polls of 15 is 60, so a cap of 60 stands and
# leaves the pause 60 - 15 - 20 = 25 s at most.
hi=0
for seed in 1 2 3 4 5 6 7 8 9 10; do
    RANDOM=$seed
    n="$(TN_EPOCH_JITTER_MAX=30 TN_EPOCH_MARGIN=10 TN_EPOCH_WAIT_MAX=60 naps)"
    (( n > hi )) && hi=$n
done
check "the pause stays inside TN_EPOCH_WAIT_MAX" "yes" "$([[ $hi -le 60 ]] && echo yes || echo "no ${hi}")"
check "a cap equal to the wait it bounds: no warning" no "$(grep -q 'is shorter than margin' "$T/say" && echo yes || echo no)"
check "the default is at most 30s" "yes" \
    "$(n="$(unset TN_EPOCH_JITTER_MAX; naps)"; [[ $n -ge 35 && $n -le 65 ]] && echo yes || echo "no ${n}")"
check "no epoch length: the fixed margin, the settle from the environment" yes \
    "$(grep -qF 'Margin 300s by default; settle 20s from TN_EPOCH_SETTLE.' "$T/say" && echo yes || echo no)"

# ---- tn_wait_restart_window: margin and settle from the epoch length -----------------
unset TN_EPOCH_MARGIN TN_EPOCH_SETTLE TN_EPOCH_WAIT_MAX TN_EPOCH_POLL TN_SKIP_EPOCH_WAIT
check "timing: 6 h epoch" "300 derived 90 derived" "$(_tn_epoch_timing 21600)"
check "timing: 12 h epoch, inside the clamps" "600 derived 180 derived" "$(_tn_epoch_timing 43200)"
check "timing: 7-day epoch, clamped high" "900 derived 300 derived" "$(_tn_epoch_timing 604800)"
check "timing: 1 h epoch, clamped low" "300 derived 90 derived" "$(_tn_epoch_timing 3600)"
check "timing: length unknown" "300 default 90 default" "$(_tn_epoch_timing 0)"
check "timing: the environment wins, never clamped" "5000 env 10 env" \
    "$(TN_EPOCH_MARGIN=5000 TN_EPOCH_SETTLE=10 _tn_epoch_timing 604800)"
check "timing: a value that is not a number is ignored" "900 derived 300 derived" \
    "$(TN_EPOCH_MARGIN=abc _tn_epoch_timing 604800)"
EPOCH_ANSWER=""
tn_epoch_secs_left() { printf '%s\n' "$EPOCH_ANSWER"; }
# EPOCH_NOW is the epoch the polls read: 6 closes epoch 5 at the first poll.
EPOCH_NOW=6
tn_epoch_info() { printf '%s 0 0\n' "$EPOCH_NOW"; }
# win SECS-LEFT EPOCH-LENGTH -- one wait in this shell (no pause after the settle,
# poll 15); NAPPED and the say file tell what it did.
win() {
    rm -f "$T/say"
    NAPPED=0
    EPOCH_ANSWER="$1 5 $(( 1000 + $1 )) $2"
    TN_EPOCH_JITTER_MAX=0 TN_EPOCH_POLL=15 tn_wait_restart_window "http://127.0.0.1:8545" say
}
said() { grep -qF -- "$1" "$T/say" && echo yes || echo no; }
win 5000 604800
check "7-day epoch, boundary far away: no wait" 0 "$NAPPED"
check "7-day epoch: the log says margin 900 and settle 300 are derived" yes \
    "$(said 'outside the 900s margin; no need to wait. Margin 900s and settle 300s, derived from a 604800 s epoch.')"
win 600 604800
check "7-day epoch, boundary inside 900 s: waits one poll and the 300 s settle" 315 "$NAPPED"
check "7-day epoch: the step says why" yes "$(said 'Waiting at most 1800s (TN_EPOCH_WAIT_MAX); set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 900s and settle 300s, derived from a 604800 s epoch.')"
check "7-day epoch, TN_EPOCH_WAIT_MAX unset: no warning" no "$(grep -q '^warn ' "$T/say" && echo yes || echo no)"
TN_EPOCH_MARGIN=120 win 600 604800
check "TN_EPOCH_MARGIN=120 wins over the derived 900" 0 "$NAPPED"
check "the log names TN_EPOCH_MARGIN" yes \
    "$(said 'outside the 120s margin; no need to wait. Margin 120s from TN_EPOCH_MARGIN; settle 300s derived from a 604800 s epoch.')"
TN_EPOCH_MARGIN=1000 TN_EPOCH_SETTLE=20 win 950 21600
check "an explicit margin above 900 and settle below 90 are used as given" 35 "$NAPPED"
TN_EPOCH_WAIT_MAX=100 win 600 604800
check "TN_EPOCH_WAIT_MAX=100 is kept at 100 with the warning" yes \
    "$(said 'warn TN_EPOCH_WAIT_MAX 100 is shorter than margin 900 + settle 300 + two polls; the restart may land before the epoch has settled. Set it to at least 1230, or TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose.')"
check "the kept cap is the one the step reports" yes "$(said 'Waiting at most 100s (TN_EPOCH_WAIT_MAX)')"
check "TN_EPOCH_WAIT_MAX=100: one poll and a settle cut to fit, 100 s in all" 100 "$NAPPED"
EPOCH_NOW=5
TN_EPOCH_WAIT_MAX=100 win 600 604800
check "TN_EPOCH_WAIT_MAX=100, the epoch never closes: the wait stops at 100 s" 100 "$NAPPED"
check "TN_EPOCH_WAIT_MAX=100, the epoch never closes: the cap is named" yes \
    "$(said 'has not closed after 100s (limit 100s, TN_EPOCH_WAIT_MAX)')"
EPOCH_NOW=6
hi=0
for seed in 1 2 3 4 5; do
    RANDOM=$seed
    EPOCH_ANSWER="600 5 1600 604800"
    NAPPED=0
    TN_EPOCH_JITTER_MAX=30 TN_EPOCH_WAIT_MAX=100 TN_EPOCH_POLL=15 tn_wait_restart_window "http://127.0.0.1:8545" say
    (( NAPPED > hi )) && hi=$NAPPED
done
check "TN_EPOCH_WAIT_MAX=100 with the pause on: never more than 100 s" yes "$([[ $hi -le 100 ]] && echo yes || echo "no ${hi}")"
TN_EPOCH_WAIT_MAX=1230 win 600 604800
check "a cap equal to margin + settle + two polls: no warning" no "$(said 'is shorter than margin')"
TN_EPOCH_MARGIN=2000 win 5000 604800
check "the default cap below an explicit margin + settle + two polls: kept and warned" yes \
    "$(said 'warn TN_EPOCH_WAIT_MAX 1800 is shorter than margin 2000 + settle 300 + two polls; the restart may land before the epoch has settled. Set it to at least 2330, or TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose.')"
win 5000 21600
check "6 h epoch: margin 300 and settle 90 as before" yes \
    "$(said 'outside the 300s margin; no need to wait. Margin 300s and settle 90s, derived from a 21600 s epoch.')"
win 600 21600
check "6 h epoch, boundary 600 s away: no wait, as before" 0 "$NAPPED"
win 200 21600
check "6 h epoch, boundary inside 300 s: one poll and the 90 s settle" 105 "$NAPPED"
TN_EPOCH_WAIT_MAX=0 win 200 604800
check "TN_EPOCH_WAIT_MAX=0 still turns the wait off" 0 "$NAPPED"
check "TN_EPOCH_WAIT_MAX=0: said so" yes "$(said 'epoch wait disabled by TN_EPOCH_WAIT_MAX=0')"
check "TN_EPOCH_WAIT_MAX=0: no warning" no "$(grep -q '^warn ' "$T/say" && echo yes || echo no)"

# ---- tn_wait_restart_window: the blind wait follows the network's epoch constant -------
check "mainnet epoch constant: 6 h" 21600 "$(tn_network_epoch_duration mainnet)"
check "testnet epoch constant: 6 h" 21600 "$(tn_network_epoch_duration testnet)"
check "devnet has no epoch constant" "" "$(tn_network_epoch_duration devnet)"
check "no constant for a name that is not a network" "" "$(tn_network_epoch_duration other)"
# The node mode cannot be read, the node must wait (keytool_test covers that
# decision) and no RPC gives the epoch timing: the wait is margin + settle with
# nothing to poll. The network is the real tn_detect_network's answer for
# NETWORK in a .node-meta under TN_ROOT_PREFIX; naps are counted.
TN_ROOT_PREFIX="$T/root"
mkdir -p "$T/root/etc/telcoin"
tn_node_mode() { printf 'rpc down'; return 1; }
_tn_mode_unknown_wait_url() { printf 'http://127.0.0.1:8545\n'; return 3; }
tn_epoch_secs_left() { printf 'connection refused'; return 1; }
# blind NETWORK -- one blind wait on a node whose .node-meta says NETWORK=NETWORK.
blind() {
    printf 'NETWORK=%s\n' "$1" > "$T/root/etc/telcoin/.node-meta"
    rm -f "$T/say"
    NAPPED=0
    TN_EPOCH_JITTER_MAX=0 TN_EPOCH_POLL=15 tn_wait_restart_window "http://127.0.0.1:8545" say 2>/dev/null
}
check "the blind wait sees the network of the .node-meta" mainnet \
    "$(printf 'NETWORK=mainnet\n' > "$T/root/etc/telcoin/.node-meta"; tn_detect_network 2>/dev/null)"
blind mainnet
check "mainnet blind wait derives from the 6 h constant: 300 + 90" 390 "$NAPPED"
check "mainnet blind wait: the warning names the network default" yes \
    "$(said 'Waiting 390s (TN_EPOCH_MARGIN + TN_EPOCH_SETTLE, at most TN_EPOCH_WAIT_MAX) so the restart does not land on it; set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 300s and settle 90s (network default: epoch 21600 s).')"
blind testnet
check "testnet blind wait derives from its constant: 300 + 90" 390 "$NAPPED"
check "testnet blind wait: the warning names the network default" yes \
    "$(said 'Margin 300s and settle 90s (network default: epoch 21600 s).')"
blind devnet
check "devnet blind wait keeps the fixed default: 300 + 90" 390 "$NAPPED"
check "devnet blind wait: the warning says default" yes "$(said 'Margin 300s and settle 90s (default).')"
check "devnet blind wait: no network default named" no "$(said 'network default')"
TN_EPOCH_MARGIN=120 blind mainnet
check "env margin wins over the constant: 120 + 90" 210 "$NAPPED"
check "env margin: each value names its source" yes \
    "$(said 'Waiting 210s (TN_EPOCH_MARGIN + TN_EPOCH_SETTLE, at most TN_EPOCH_WAIT_MAX) so the restart does not land on it; set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 120s (TN_EPOCH_MARGIN) and settle 90s (network default: epoch 21600 s).')"
TN_EPOCH_MARGIN=120 TN_EPOCH_SETTLE=30 blind mainnet
check "env margin and settle both win: 120 + 30" 150 "$NAPPED"
check "env margin and settle: both named" yes "$(said 'Margin 120s and settle 30s (TN_EPOCH_MARGIN, TN_EPOCH_SETTLE).')"
TN_EPOCH_SETTLE=30 blind devnet
check "devnet with an env settle: 300 + 30" 330 "$NAPPED"
check "devnet with an env settle: each value names its source" yes \
    "$(said 'Margin 300s (default) and settle 30s (TN_EPOCH_SETTLE).')"
TN_EPOCH_WAIT_MAX=100 blind mainnet
check "mainnet blind wait: TN_EPOCH_WAIT_MAX still caps it" 100 "$NAPPED"
TN_ROOT_PREFIX=""

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
        # stop_legacy removes the legacy container after the stop; never the host's docker.
        docker() { :; }
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

# setup-node passes --allow-quorum-risk (TN_ALLOW_QUORUM_RISK) to the
# install-caddy.sh child that restarts the node for public RPC.
check "setup-node: the rpc-enable child gets TN_ALLOW_QUORUM_RISK" 1 \
    "$(grep -c 'TN_ALLOW_QUORUM_RISK="${TN_ALLOW_QUORUM_RISK:-}" bash "$caddy" --phase=rpc-enable' "$TN_TEST_REPO/setup-node.sh")"
# shellcheck disable=SC2016
check "the variable reaches a child that way" "1" \
    "$(TN_ALLOW_QUORUM_RISK=1; TN_ALLOW_QUORUM_RISK="${TN_ALLOW_QUORUM_RISK:-}" bash -c 'printf %s "${TN_ALLOW_QUORUM_RISK:-}"')"
finish
