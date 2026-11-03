#!/usr/bin/env bash
# =============================================================================
# tools/tests/firewall_signal_test.sh -- firewall-setup.sh stopped by a signal
# while it applies rules: the CLI `--reset --ssh-from` run and the
# `--json --enable --ssh-from --p2p-from` run are sent TERM while ufw call 2, 3
# or 5 is in flight, to the script alone (the call finishes first) or to its
# whole process group (the call dies too). Each run must end with the previous
# rule set or the complete new one (never a partial set with ufw disabled),
# never close SSH, leave no saved rule files, release the update lock, and in
# --json mode still end with a done event.
#
#   bash tools/tests/firewall_signal_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/firewall_signal_test.sh
#
# ufw, sshd and systemctl are PATH stubs (tools/tests/fwstub.sh) with a wrapper
# around ufw that holds call N until the test releases it and records any
# moment ufw is on with a default deny and no SSH rule. The script runs through
# a driver that replaces check_root and the host probes. Nothing touches the host.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
T="$TN_TEST_TMP"
R="$T/root"
export TN_ROOT_PREFIX="$R"
export UFW_LOG="$T/ufw.log"
export TN_FW_SNAP_PARENT="$T/snap"
export TN_UPDATE_LOCK_FILE="$T/lock/update.lock"
mkdir -p "$T/snap" "$T/lock" "$T/fw"
fw_stub_install "$T/bin"
mv "$T/bin/ufw" "$T/bin/ufw.real"
# The wrapper counts the calls that change something (not `status`), holds call
# UFW_HOLD_AT until $R/.ufw.release exists, runs the stub, then checks that SSH
# is still reachable whenever ufw is on with a default deny.
cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
here="$(cd "$(dirname "$0")" && pwd)"
case "$1" in status*) exec "$here/ufw.real" "$@" ;; esac
n=0
[ -f "$R/.sig.n" ] && n="$(cat "$R/.sig.n")"
n=$((n + 1))
echo "$n" > "$R/.sig.n"
if [ "$n" = "${UFW_HOLD_AT:-0}" ]; then
    echo "$$" > "$R/.ufw.held"
    while [ ! -e "$R/.ufw.release" ]; do sleep 0.1; done
fi
"$here/ufw.real" "$@"
rc=$?
if grep -q '^ENABLED=yes' "$R/etc/ufw/ufw.conf" 2>/dev/null \
    && grep -q 'DROP' "$R/etc/default/ufw" 2>/dev/null \
    && ! grep -qxE 'allow 22/tcp|allow from 203\.0\.113\.0/24 to any port 22 proto tcp' "$R/etc/ufw/user.rules" 2>/dev/null; then
    printf 'call %s (%s): SSH closed\n' "$n" "$*" >> "$R/.violations"
fi
exit "$rc"
STUB
chmod +x "$T/bin/ufw"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
cat > "$T/fw/driver.sh" <<'DRV'
# shellcheck source=/dev/null
source "$(dirname "$0")/firewall-setup.sh"
check_root() { :; }
tn_migrate_ownership() { return 0; }
detect_installed_nodes() { echo "telcoin.service"; }
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
caddy_serves_public_edge() { return 1; }
ip() { return 1; }
main "$@"
DRV

# fixture -- a mainnet host with ufw on: blanket SSH and open P2P ports.
fixture() {
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh"
    printf 'NETWORK=mainnet\nSERVICE_NAME=telcoin\nOWNERSHIP_LAYOUT=2\n' > "$R/etc/telcoin/.node-meta"
    printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$R/etc/ufw/user.rules"
    printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "$R/etc/default/ufw"
    printf 'Port 22\n' > "$R/etc/ssh/sshd_config"
    : > "$UFW_LOG"
    rm -rf "$T/lock"/* "$T/snap"/*
}
state() { sort "$R/etc/ufw/user.rules"; cat "$R/etc/ufw/ufw.conf" "$R/etc/default/ufw"; }
lock_free() {
    if [ -d "${TN_UPDATE_LOCK_FILE}.d" ]; then echo no; return; fi
    if command -v flock >/dev/null 2>&1 && [ -e "$TN_UPDATE_LOCK_FILE" ]; then
        if flock -n "$TN_UPDATE_LOCK_FILE" true; then echo yes; else echo no; fi
        return
    fi
    echo yes
}

# run_clean MODE -- the complete new rule set of MODE (cli|json), no signal.
run_clean() {
    fixture
    if [ "$1" = cli ]; then
        bash "$T/fw/driver.sh" --reset --ssh-from 203.0.113.0/24 >"$T/out" 2>&1 </dev/null
    else
        bash "$T/fw/driver.sh" --json --enable --ssh-from 203.0.113.0/24 --p2p-from 198.51.100.0/24 >"$T/out" 2>"$T/err" </dev/null
    fi
    CLEAN_RC=$?
}

# run_term MODE CALL TARGET -- start MODE, send TERM while ufw call CALL is held,
# to the script (pid) or its process group (group), then release the call.
run_term() {
    local mode="$1" at="$2" target="$3" pid i
    fixture
    set -m
    if [ "$mode" = cli ]; then
        UFW_HOLD_AT="$at" bash "$T/fw/driver.sh" --reset --ssh-from 203.0.113.0/24 >"$T/out" 2>&1 </dev/null &
    else
        UFW_HOLD_AT="$at" bash "$T/fw/driver.sh" --json --enable --ssh-from 203.0.113.0/24 --p2p-from 198.51.100.0/24 >"$T/out" 2>"$T/err" </dev/null &
    fi
    pid=$!
    set +m
    i=0
    while [ ! -e "$R/.ufw.held" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
    if [ "$target" = group ]; then
        kill -TERM -- "-$pid" 2>/dev/null
    else
        kill -TERM "$pid" 2>/dev/null
    fi
    sleep 0.2
    touch "$R/.ufw.release"
    TERM_RC=0
    wait "$pid" || TERM_RC=$?
}

for mode in cli json; do
    run_clean "$mode"
    check_rc "$mode clean run rc 0" 0 "$CLEAN_RC"
    new_st="$(state)"
    fixture
    old_st="$(state)"
    for at in 2 3 5; do
        for target in pid group; do
            name="$mode TERM ($target) at ufw call $at"
            run_term "$mode" "$at" "$target"
            now="$(state)"
            check "$name: held call reached" "yes" "$([ -e "$R/.ufw.held" ] && echo yes)"
            check "$name: script stopped (rc not 0)" "yes" "$([ "$TERM_RC" -ne 0 ] && echo yes)"
            if [ "$now" = "$old_st" ] || [ "$now" = "$new_st" ]; then
                check "$name: rules are the old or the complete new set" "ok" "ok"
            else
                check "$name: rules are the old or the complete new set" "$old_st" "$now"
            fi
            check "$name: ufw left enabled" "ENABLED=yes" "$(cat "$R/etc/ufw/ufw.conf")"
            check "$name: SSH never closed" "" "$(cat "$R/.violations" 2>/dev/null)"
            check "$name: no saved rule files left" "" "$(ls "$T/snap")"
            check "$name: update lock released" "yes" "$(lock_free)"
            if [ "$mode" = json ]; then
                check "$name: stdout ends with a done event" "yes" \
                    "$(tail -n1 "$T/out" | grep -q '"event":"done"' && echo yes)"
            else
                check "$name: says the old rules were put back" "yes" \
                    "$(grep -q 'previous ufw rules were put back' "$T/out" && echo yes)"
            fi
        done
    done
done

finish
