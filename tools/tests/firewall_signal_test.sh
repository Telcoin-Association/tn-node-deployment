#!/usr/bin/env bash
# =============================================================================
# tools/tests/firewall_signal_test.sh -- firewall-setup.sh stopped by a signal
# while it applies rules: the CLI `--reset --ssh-from` run and the
# `--json --enable --ssh-from --p2p-from` run are sent TERM while ufw call 2, 3
# or 5 is in flight, to the script alone (the call finishes first) or to its
# whole process group (the call dies too). Each run must end with the previous
# rule set or the complete new one (never a partial set with ufw disabled),
# never close SSH, leave no saved rule files, release the update lock, and in
# --json mode still end with a done event. The same TERMs land while the nft
# transaction of the P2P new-flow limit is in flight (the CLI run writes table
# inet tn_p2p, the --json run with a P2P list deletes it): the table is then the
# old one or the complete new state, never part of one, the ufw rules are the
# complete new set, and a run stopped during the ufw calls leaves the table as it
# was.
#
#   bash tools/tests/firewall_signal_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/firewall_signal_test.sh
#
# ufw, sshd, systemctl and nft are PATH stubs (tools/tests/fwstub.sh) with a
# wrapper around ufw that holds call N until the test releases it and records any
# moment ufw is on with a default deny and no SSH rule; NFT_HOLD=1 holds the nft
# transaction after it has read its program. The script runs through
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
export NFT_LOG="$T/nft.log"
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

# OLD_TABLE -- the table inet tn_p2p of the fixture, from an earlier release.
OLD_TABLE='table inet tn_p2p {
    chain input {
        type filter hook input priority -10; policy accept;
        ct state new udp dport { 49590 } limit rate over 5/minute burst 10 packets drop
    }
}'
# fixture -- a mainnet host with ufw on: blanket SSH and open P2P ports, and an
# older P2P new-flow limit table.
fixture() {
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh"
    printf 'NETWORK=mainnet\nSERVICE_NAME=telcoin\nOWNERSHIP_LAYOUT=2\n' > "$R/etc/telcoin/.node-meta"
    printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$R/etc/ufw/user.rules"
    printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "$R/etc/default/ufw"
    printf 'Port 22\n' > "$R/etc/ssh/sshd_config"
    printf '%s\n' "$OLD_TABLE" > "$R/.nft.table"
    : > "$UFW_LOG"
    : > "$NFT_LOG"
    rm -rf "$T/lock"/* "$T/snap"/*
}
state() { sort "$R/etc/ufw/user.rules"; cat "$R/etc/ufw/ufw.conf" "$R/etc/default/ufw"; }
table() { if [ -f "$R/.nft.table" ]; then cat "$R/.nft.table"; else echo "(no table)"; fi; }
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

# run_term MODE AT TARGET -- start MODE, send TERM while ufw call AT (a number) or
# the nft transaction (AT=nft) is held, to the script (pid) or its process group
# (group), then release the call. HELD names the file the held call writes.

run_term() {
    local mode="$1" at="$2" target="$3" pid i ufw_at=0 nft_hold="" release
    fixture
    if [ "$at" = nft ]; then
        nft_hold=1
        HELD="$R/.nft.held"
        release="$R/.nft.release"
    else
        ufw_at="$at"
        HELD="$R/.ufw.held"
        release="$R/.ufw.release"
    fi
    set -m
    if [ "$mode" = cli ]; then
        UFW_HOLD_AT="$ufw_at" NFT_HOLD="$nft_hold" bash "$T/fw/driver.sh" --reset --ssh-from 203.0.113.0/24 >"$T/out" 2>&1 </dev/null &
    else
        UFW_HOLD_AT="$ufw_at" NFT_HOLD="$nft_hold" bash "$T/fw/driver.sh" --json --enable --ssh-from 203.0.113.0/24 --p2p-from 198.51.100.0/24 >"$T/out" 2>"$T/err" </dev/null &
    fi
    pid=$!
    set +m
    i=0
    while [ ! -e "$HELD" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
    if [ "$target" = group ]; then
        kill -TERM -- "-$pid" 2>/dev/null
    else
        kill -TERM "$pid" 2>/dev/null
    fi
    sleep 0.2
    touch "$release"
    TERM_RC=0
    wait "$pid" || TERM_RC=$?
}

for mode in cli json; do
    run_clean "$mode"
    check_rc "$mode clean run rc 0" 0 "$CLEAN_RC"
    new_st="$(state)"
    new_tbl="$(table)"
    fixture
    old_st="$(state)"
    old_tbl="$(table)"
    if [ "$mode" = cli ]; then
        check_has "$mode clean run writes the new-flow limit" "ct state new udp dport { 49590, 49594 } update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop" "$(printf '%s\n' "$new_tbl" | sed 's/^ *//')"
    else
        check "$mode clean run deletes the new-flow limit (P2P list)" "(no table)" "$new_tbl"
    fi
    for at in 2 3 5 nft; do
        for target in pid group; do
            if [ "$at" = nft ]; then
                name="$mode TERM ($target) during the nft transaction"
            else
                name="$mode TERM ($target) at ufw call $at"
            fi
            run_term "$mode" "$at" "$target"
            now="$(state)"
            check "$name: held call reached" "yes" "$([ -e "$HELD" ] && echo yes)"
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
            now_tbl="$(table)"
            if [ "$at" = nft ]; then
                check "$name: ufw rules are the complete new set" "$new_st" "$now"
                # TERM to the script alone lets nft finish; to the group it kills
                # nft before it applies anything.
                if [ "$target" = pid ]; then
                    check "$name: nft finished, table is the complete new state" "$new_tbl" "$now_tbl"
                else
                    check "$name: nft killed, table is the old one" "$old_tbl" "$now_tbl"
                fi
                check "$name: one nft transaction" "1" "$(grep -c '^nft -f -$' "$NFT_LOG" | tr -d ' ')"
            else
                check "$name: table left as it was" "$old_tbl" "$now_tbl"
                check "$name: no nft transaction" "0" "$(grep -c '^nft -f -$' "$NFT_LOG" | tr -d ' ')"
            fi
            if [ "$mode" = json ]; then
                check "$name: stdout ends with a done event" "yes" \
                    "$(tail -n1 "$T/out" | grep -q '"event":"done"' && echo yes)"
            elif [ "$at" != nft ]; then
                check "$name: says the old rules were put back" "yes" \
                    "$(grep -q 'previous ufw rules were put back' "$T/out" && echo yes)"
            fi
        done
    done
done

finish
