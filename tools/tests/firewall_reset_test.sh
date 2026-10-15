#!/usr/bin/env bash
# =============================================================================
# tools/tests/firewall_reset_test.sh -- firewall-setup.sh apply_recommended_firewall:
# rule order (every allow before the default deny), SSH and P2P source lists,
# the mainnet refusals, and the fail-safe: a ufw call that fails at any step
# leaves the previous rule files and ufw state in place (rc 2), and a restore
# that fails too is rc 3 with a "DISABLED" message.
#
#   bash tools/tests/firewall_reset_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/firewall_reset_test.sh
#
# ufw, sshd and systemctl are PATH stubs (tools/tests/fwstub.sh); ufw keeps its
# state in files under a fixture TN_ROOT_PREFIX. Nothing touches the host.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export UFW_LOG="$T/ufw.log"
export TN_FW_SNAP_PARENT="$T/snap"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin" "$TN_ROOT_PREFIX/etc/ufw" "$TN_ROOT_PREFIX/etc/default" \
    "$TN_ROOT_PREFIX/etc/ssh" "$TN_FW_SNAP_PARENT" "$T/fw"
fw_stub_install "$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"

# Source firewall-setup.sh without its trailing main call (it sources lib/common.sh).
grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e
META="$TN_ROOT_PREFIX/etc/telcoin/.node-meta"

# Fixture node: two P2P ports, no Caddy, no VPN, not on GCE.
detect_installed_nodes() { echo "telcoin.service"; }
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
caddy_serves_public_edge() { return 1; }
ip() { return 1; }

# reset_state ENABLED -- a fixture ufw with one custom rule.
reset_state() {
    printf 'allow 8080/tcp\nallow 22/tcp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
    printf 'ENABLED=%s\n' "$1" > "$TN_ROOT_PREFIX/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "$TN_ROOT_PREFIX/etc/default/ufw"
    rm -f "$TN_ROOT_PREFIX/.ufw.n"
    : > "$UFW_LOG"
}
state() { cat "$TN_ROOT_PREFIX/etc/ufw/user.rules" "$TN_ROOT_PREFIX/etc/ufw/ufw.conf" "$TN_ROOT_PREFIX/etc/default/ufw"; }
line_no() { grep -nxF -- "$1" "$UFW_LOG" | head -n1 | cut -d: -f1; }
last_allow_no() { grep -n '^allow' "$UFW_LOG" | tail -n1 | cut -d: -f1; }
mutating() { grep -v '^status' "$UFW_LOG"; }
run_apply() {
    RC=0
    apply_recommended_firewall "$@" >"$T/out" 2>&1 || RC=$?
    OUT="$(cat "$T/out")"
}
fresh_flags() {
    FW_SSH_FROM=""; FW_P2P_FROM=""; FW_SSH_ANYWHERE=false; FW_P2P_ANYWHERE=false; FW_P2P_LOADED=false
}

# --- testnet --reset, no source lists: order -----------------------------------
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet; fresh_flags; reset_state yes
run_apply --reset
check_rc "testnet reset rc 0" 0 "$RC"
check_has "blanket ssh rule" "allow 22/tcp" "$(cat "$UFW_LOG")"
check_has "kuma monitor rule" "allow from ${TN_KUMA_SRC} to any port ${TN_KUMA_PORT} proto tcp" "$(cat "$UFW_LOG")"
check_has "p2p 49594 open" "allow 49594/udp" "$(cat "$UFW_LOG")"
deny="$(line_no 'default deny incoming')"
lastallow="$(last_allow_no)"
check "every allow before the default deny" "yes" "$([[ -n "$deny" && "$lastallow" -lt "$deny" ]] && echo yes)"
check "enable is the last call" "--force enable" "$(mutating | tail -n1)"
check "custom rule gone after reset" "" "$(grep -x 'allow 8080/tcp' "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check "ufw active after reset" "ENABLED=yes" "$(cat "$TN_ROOT_PREFIX/etc/ufw/ufw.conf")"
check "no snapshot left behind" "0" "$(find "$TN_FW_SNAP_PARENT" -mindepth 1 | wc -l | tr -d ' ')"

# --- mainnet without SSH sources refuses before any change --------------------
printf 'NETWORK=mainnet\n' > "$META"
NETWORK=mainnet; fresh_flags; reset_state yes
before="$(state)"
run_apply --reset
check_rc "mainnet no --ssh-from rc 1" 1 "$RC"
check "mainnet refusal makes no ufw change" "" "$(mutating)"
check "mainnet refusal leaves state" "$before" "$(state)"
check_has "mainnet refusal names --ssh-from" "yes" "$(grep -q -- '--ssh-from' "$T/out" && echo yes)"

# --- mainnet with SSH and P2P source lists --------------------------------------
NETWORK=mainnet; fresh_flags; reset_state yes
FW_SSH_FROM="203.0.113.0/24,2001:db8::/48"
FW_P2P_FROM="198.51.100.0/24"
run_apply --reset
check_rc "mainnet --ssh-from rc 0" 0 "$RC"
log="$(cat "$UFW_LOG")"
check_has "ssh v4 source rule" "allow from 203.0.113.0/24 to any port 22 proto tcp" "$log"
check_has "ssh v6 source rule" "allow from 2001:db8::/48 to any port 22 proto tcp" "$log"
check_lacks "mainnet adds no blanket ssh" "allow 22/tcp" "$(grep -v '^delete' "$UFW_LOG")"
check_lacks "mainnet adds no health rule" "allow from ${TN_KUMA_SRC}" "$(grep -v '^delete' "$UFW_LOG")"
check_lacks "mainnet adds no health port at all" "port ${TN_KUMA_PORT}" "$(grep -v '^delete' "$UFW_LOG")"
check_has "p2p source rule" "allow from 198.51.100.0/24 to any port 49590 proto udp" "$log"
check_has "p2p open rule deleted" "delete allow 49590/udp" "$log"
check_lacks "p2p never opened to all" "allow 49590/udp" "$(grep -v '^delete' "$UFW_LOG")"
del="$(line_no 'delete allow 22/tcp')"
src="$(line_no 'allow from 203.0.113.0/24 to any port 22 proto tcp')"
check "blanket ssh deleted after the source rule" "yes" "$([[ -n "$del" && "$src" -lt "$del" ]] && echo yes)"
check "final rules lack the blanket ssh" "" "$(grep -x 'allow 22/tcp' "$TN_ROOT_PREFIX/etc/ufw/user.rules")"

# Second enable without flags: the stored list keeps the blanket rule away.
printf 'NETWORK=mainnet\nSSH_ALLOW_FROM=203.0.113.0/24\nP2P_ALLOW_FROM=198.51.100.0/24\n' > "$META"
fresh_flags
: > "$UFW_LOG"
run_apply
check_rc "mainnet re-enable from stored lists rc 0" 0 "$RC"
check_lacks "re-enable adds no blanket ssh" "allow 22/tcp" "$(grep -v '^delete' "$UFW_LOG")"
check "re-enable final rules lack blanket ssh" "" "$(grep -x 'allow 22/tcp' "$TN_ROOT_PREFIX/etc/ufw/user.rules")"

# A duplicated stored list refuses.
printf 'NETWORK=mainnet\nSSH_ALLOW_FROM=203.0.113.0/24\nSSH_ALLOW_FROM=0.0.0.0/0\n' > "$META"
fresh_flags; reset_state yes
run_apply
check_rc "duplicated SSH_ALLOW_FROM rc 1" 1 "$RC"
check "duplicated SSH_ALLOW_FROM makes no change" "" "$(mutating)"

# --- preflight refusals --------------------------------------------------------
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet; fresh_flags; reset_state yes
FW_SSH_FROM="0.0.0.0/0"
run_apply --reset
check_rc "--ssh-from 0.0.0.0/0 rc 1" 1 "$RC"
check "--ssh-from 0.0.0.0/0 no change" "" "$(mutating)"
for bad in 010.0.113.0/24 203.0.113.07 128.0.0.0/1 2000::/3; do
    fresh_flags; reset_state yes
    FW_SSH_FROM="203.0.113.0/24,${bad}"
    run_apply --reset
    check_rc "--ssh-from ${bad} rc 1" 1 "$RC"
    check "--ssh-from ${bad} no change" "" "$(mutating)"
    fresh_flags; reset_state yes
    FW_SSH_FROM="203.0.113.0/24"; FW_P2P_FROM="198.51.100.0/24,${bad}"
    run_apply --reset
    check_rc "--p2p-from ${bad} rc 1" 1 "$RC"
    check "--p2p-from ${bad} no change" "" "$(mutating)"
done
fresh_flags; reset_state yes
SSHD_PORT_LINE="port 70000" run_apply --reset
check_rc "sshd port 70000 rc 1" 1 "$RC"
check "sshd port 70000 no change" "" "$(mutating)"
fresh_flags; reset_state yes
printf 'NETWORK=testnet\nKUMA_EXTRA_SRC=::/0\n' > "$META"
run_apply --reset
check_rc "stored ::/0 health source rc 1" 1 "$RC"
check "stored ::/0 health source no change" "" "$(mutating)"
printf 'NETWORK=testnet\n' > "$META"
fresh_flags; reset_state yes
mv "$T/bin/ufw" "$T/bin/ufw.off"; hash -r
run_apply --reset
check_rc "ufw absent rc 1" 1 "$RC"
mv "$T/bin/ufw.off" "$T/bin/ufw"; hash -r

# --- fail-safe: a failure at any ufw call restores the previous state ----------
# Count the calls of a full run (testnet, SSH + P2P lists), then fail each one.
NETWORK=testnet
for start in yes no; do
    fresh_flags; FW_SSH_FROM="203.0.113.0/24"; FW_P2P_FROM="198.51.100.0/24"; reset_state "$start"
    run_apply --reset
    total="$(wc -l < "$UFW_LOG" | tr -d ' ')"
    good="$(state)"
    bad=0
    n=1
    while [[ "$n" -le "$total" ]]; do
        fresh_flags; FW_SSH_FROM="203.0.113.0/24"; FW_P2P_FROM="198.51.100.0/24"; reset_state "$start"
        initial="$(state)"
        UFW_FAIL_AT="$n" run_apply --reset
        now="$(state)"
        if [[ "$RC" -eq 0 && "$now" == "$good" ]]; then
            :
        elif [[ "$RC" -eq 2 && "$now" == "$initial" ]]; then
            :
        else
            bad=$((bad + 1))
            printf '      fail at call %s (start %s): rc %s\n' "$n" "$start" "$RC"
        fi
        n=$((n + 1))
    done
    check "fail at each of ${total} calls (ufw ${start}): previous or complete rule set" "0" "$bad"
done
check "no snapshot left after restores" "" "$(ls "$TN_FW_SNAP_PARENT")"

# Mainnet: a failed delete of a health-port rule stops the run and restores (rc 2).
printf 'NETWORK=mainnet\nKUMA_EXTRA_SRC=198.51.100.7\n' > "$META"
NETWORK=mainnet
fresh_flags; FW_SSH_FROM="203.0.113.0/24"; reset_state yes
run_apply --reset
check_rc "mainnet health deletes: clean run rc 0" 0 "$RC"
kuma_calls="$(grep -n "^delete allow .*${TN_KUMA_PORT}" "$UFW_LOG" | cut -d: -f1 | paste -sd' ' -)"
check "mainnet run deletes three health rules" "3" "$(printf '%s\n' $kuma_calls | grep -c .)"
for n in $kuma_calls; do
    fresh_flags; FW_SSH_FROM="203.0.113.0/24"; reset_state yes
    initial="$(state)"
    UFW_FAIL_AT="$n" run_apply --reset
    check_rc "mainnet health delete fails at call ${n}: rc 2" 2 "$RC"
    check "mainnet health delete fails at call ${n}: old rules back" "$initial" "$(state)"
    check_has "mainnet health delete fails at call ${n}: named" "yes" "$(grep -q "health-port ${TN_KUMA_PORT}/tcp rules failed" "$T/out" && echo yes)"
done
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet

# A restore that fails too: rc 3 and the DISABLED message.
fresh_flags; reset_state yes
UFW_FAIL_FROM=4 run_apply --reset
check_rc "restore fails too rc 3" 3 "$RC"
check_has "restore failure says DISABLED" "yes" "$(grep -q 'DISABLED' "$T/out" && echo yes)"
rm -rf "${TN_FW_SNAP_PARENT:?}"/*

# --- fw_persist_sources -----------------------------------------------------------
META_CALLS="$T/meta.calls"
meta_set() { printf 'set %s %s\n' "$1" "$2" >> "$META_CALLS"; }
meta_unset() { printf 'unset %s\n' "$1" >> "$META_CALLS"; }
fresh_flags; FW_SSH_FROM="203.0.113.0/24, 192.0.2.1"; FW_P2P_ANYWHERE=true
FW_SSH_SRCS=("203.0.113.0/24" "192.0.2.1")
fw_persist_sources
check "persist writes the lists" "set SSH_ALLOW_FROM 203.0.113.0/24,192.0.2.1
unset P2P_ALLOW_FROM" "$(cat "$META_CALLS")"

finish
