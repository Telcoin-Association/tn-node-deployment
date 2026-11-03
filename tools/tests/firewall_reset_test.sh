#!/usr/bin/env bash
# =============================================================================
# tools/tests/firewall_reset_test.sh -- firewall-setup.sh apply_recommended_firewall:
# rule order (every allow before the default deny), SSH and P2P source lists,
# the mainnet refusals, and the fail-safe: a ufw call that fails at any step
# leaves the previous rule files and ufw state in place (rc 2), and a restore
# that fails too is rc 3 with a "DISABLED" message. Then the per-source new-flow
# limit on the P2P ports (nftables table inet tn_p2p): written in one transaction
# when no P2P source list is set, deleted with a list (comma list, IPv6 CIDR,
# list file, stored list) and on --reset without a node, TN_P2P_NEW_FLOW_RATE /
# TN_P2P_NEW_FLOW_BURST and their refusals, the warning without nft, the boot
# copy (/etc/telcoin/p2p-limit.nft and telcoin-p2p-limit.service, written and
# enabled with the table, disabled and removed with it), "Manage node ports"
# rewriting it (under the update lock, after the rate and burst are checked),
# the boot copy checked against the loaded table and a stopped change finished or
# reported, the status line and the --json status field p2p_new_flow_limit, and
# the expected rules naming the P2P source list (or saying it is not usable).
#
#   bash tools/tests/firewall_reset_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/firewall_reset_test.sh
#
# ufw, sshd, systemctl and nft are PATH stubs (tools/tests/fwstub.sh); ufw and nft
# keep their state in files under a fixture TN_ROOT_PREFIX. Nothing touches the
# host. When a real nft can run `nft -c` here (root with CAP_NET_ADMIN, as in
# `docker run --cap-add NET_ADMIN ubuntu:24.04` with nftables installed), the
# rendered table is also checked by it; otherwise that check is a SKIP.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export UFW_LOG="$T/ufw.log"
export NFT_LOG="$T/nft.log"
export TN_FW_SNAP_PARENT="$T/snap"
export TN_UPDATE_LOCK_FILE="$T/lock/update.lock"
# A real nft for the parse check, found before the stub directory goes on PATH.
REAL_NFT="$(PATH="${PATH}:/usr/sbin:/sbin"; command -v nft 2>/dev/null || true)"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin" "$TN_ROOT_PREFIX/etc/ufw" "$TN_ROOT_PREFIX/etc/default" \
    "$TN_ROOT_PREFIX/etc/ssh" "$TN_FW_SNAP_PARENT" "$T/fw" "$T/lock"
fw_stub_install "$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"

# Source firewall-setup.sh without its trailing main call (it sources lib/common.sh).
grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e
# Root-owned writes land in the fixture (tn_root_dir_ok cannot pass under a temp
# dir): each call is logged as "PATH MODE"; WRITE_FAIL names a path that fails.
WRITES="$T/writes"
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$WRITES"
    if [[ -n "${WRITE_FAIL:-}" && "$1" == "$WRITE_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    mkdir -p "${1%/*}"
    cat > "$1"
}
export SYSTEMCTL_LOG="$T/systemctl.log"
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

# A replaced list on --enable (no reset): the rules of the sources it drops go, after
# the new rules are in; sources it keeps stay.
printf 'NETWORK=mainnet\nSSH_ALLOW_FROM=203.0.113.0/24\nP2P_ALLOW_FROM=198.51.100.0/24,198.51.100.9\n' > "$META"
fresh_flags; FW_SSH_FROM="192.0.2.0/24"; FW_P2P_FROM="198.51.100.0/24,192.0.2.7"
: > "$UFW_LOG"
run_apply
check_rc "replaced lists rc 0" 0 "$RC"
rules="$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check_has "new SSH source rule" "allow from 192.0.2.0/24 to any port 22 proto tcp" "$rules"
check_lacks "dropped SSH source rule gone" "allow from 203.0.113.0/24" "$rules"
check_has "kept P2P source rule" "allow from 198.51.100.0/24 to any port 49590 proto udp" "$rules"
check_has "new P2P source rule" "allow from 192.0.2.7 to any port 49594 proto udp" "$rules"
check_lacks "dropped P2P source rules gone" "allow from 198.51.100.9 " "$rules"
add="$(line_no 'allow from 192.0.2.0/24 to any port 22 proto tcp')"
del="$(line_no 'delete allow from 203.0.113.0/24 to any port 22 proto tcp')"
check "dropped SSH source deleted after the new one is in" "yes" "$([[ -n "$add" && -n "$del" && "$add" -lt "$del" ]] && echo yes)"
check "replaced lists: enable is the last call" "--force enable" "$(mutating | tail -n1)"
# --ssh-anywhere drops the stored per-source rules too (the blanket rule covers them).
printf 'NETWORK=testnet\nSSH_ALLOW_FROM=192.0.2.0/24\n' > "$META"
NETWORK=testnet; fresh_flags; FW_SSH_ANYWHERE=true
: > "$UFW_LOG"
run_apply
check_rc "--ssh-anywhere over a stored list rc 0" 0 "$RC"
rules="$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check_has "--ssh-anywhere: blanket rule" "allow 22/tcp" "$rules"
check_lacks "--ssh-anywhere: stored source rule gone" "allow from 192.0.2.0/24" "$rules"
# On GCE the IAP range stays even when the old list named it and the new one does not.
mkdir -p "$TN_ROOT_PREFIX/sys/class/dmi/id"
echo "Google Compute Engine" > "$TN_ROOT_PREFIX/sys/class/dmi/id/product_name"
printf 'NETWORK=testnet\nSSH_ALLOW_FROM=35.235.240.0/20,192.0.2.0/24\n' > "$META"
fresh_flags; FW_SSH_FROM="203.0.113.0/24"
: > "$UFW_LOG"
run_apply
check_rc "GCE replaced list rc 0" 0 "$RC"
check_has "GCE: IAP rule kept" "allow from 35.235.240.0/20 to any port 22 proto tcp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check_lacks "GCE: dropped source gone" "allow from 192.0.2.0/24 to any port 22" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
rm -rf "$TN_ROOT_PREFIX/sys"
NETWORK=mainnet

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

# --- the P2P new-flow limit (nftables table inet tn_p2p) -------------------------
TABLE="$TN_ROOT_PREFIX/.nft.table"
nft_reset() { rm -f "$TABLE"; : > "$NFT_LOG"; }
nft_table() { cat "$TABLE" 2>/dev/null; }
# nft_prog -- the program of the last `nft -f -` call in the log, without the "| ".
nft_prog() { awk '/^nft -f -$/ { n++; p = "" } /^\| / && n { p = p substr($0, 3) "\n" } END { printf "%s", p }' "$NFT_LOG"; }
nft_applies() { grep -c '^nft -f -$' "$NFT_LOG" | tr -d ' '; }
# status_field -- the p2p_new_flow_limit object of json_fw_status.
status_field() {
    json_fw_status 3>"$T/status.json" >/dev/null 2>&1
    grep -o '"p2p_new_flow_limit":{[^}]*}' "$T/status.json"
}
V4_RULE='ct state new udp dport { 49590, 49594 } update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop'
V6_RULE='ct state new udp dport { 49590, 49594 } update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over 20/minute burst 40 packets } drop'
UNITF="$TN_ROOT_PREFIX/etc/systemd/system/telcoin-p2p-limit.service"
LIMITF="$TN_ROOT_PREFIX/etc/telcoin/p2p-limit.nft"
# boot_reset -- no boot copy, no enabled unit, empty logs of the writes and systemctl.
boot_reset() { rm -f "$UNITF" "$LIMITF" "$TN_ROOT_PREFIX/.systemctl.enabled"; : > "$WRITES"; : > "$SYSTEMCTL_LOG"; }
# boot_fake -- a boot copy from an earlier run, its unit enabled.
boot_fake() {
    mkdir -p "${UNITF%/*}" "${LIMITF%/*}"
    printf '[Unit]\n' > "$UNITF"; printf 'table inet tn_p2p\n' > "$LIMITF"
    printf 'telcoin-p2p-limit.service\n' > "$TN_ROOT_PREFIX/.systemctl.enabled"
    : > "$WRITES"; : > "$SYSTEMCTL_LOG"
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
trim() { sed 's/^[[:space:]]*//'; }

printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet; fresh_flags; reset_state yes; nft_reset; boot_reset
run_apply --reset
check_rc "limit: open P2P reset rc 0" 0 "$RC"
tbl="$(nft_table | trim)"
check_has "limit: v4 meter on both ports, defaults" "$V4_RULE" "$tbl"
check_has "limit: v6 meter on both ports, defaults" "$V6_RULE" "$tbl"
check_has "limit: input hook ahead of ufw" "type filter hook input priority -10; policy accept;" "$tbl"
check_has "limit: v4 set keyed by address" "type ipv4_addr" "$tbl"
check_has "limit: v6 set keyed by address" "type ipv6_addr" "$tbl"
check_has "limit: entries expire after a refill (40 at 20/minute)" "timeout 120s" "$tbl"
check "limit: every rule matches new flows only" "2 2" \
    "$(grep -c 'dport' <<< "$tbl" | tr -d ' ') $(grep -c '^ct state new udp dport' <<< "$tbl" | tr -d ' ')"
check_lacks "limit: no rule accepts" "accept" "$(grep 'dport' <<< "$tbl")"
check "limit: one nft transaction" "1" "$(nft_applies)"
check "limit: program adds, deletes, then writes the table" "table inet tn_p2p
delete table inet tn_p2p
table inet tn_p2p {" "$(nft_prog | grep -v '^#' | head -n 3)"
check_has "limit: says what it applied" "  ->  P2P new-flow limit: UDP 49590 and 49594 accept at most 20 packets of new, not yet answered flows per minute from one IPv4 address or IPv6 /64 after a burst of 40 (nftables table inet tn_p2p)." "$OUT"
check_has "limit: v6 set keyed on the /64" "yes" "$(grep -qF 'update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate' <<< "$tbl" && echo yes)"
# The boot copy: the same program, the unit that loads it, enabled and not started.
check "limit: boot copy is the program nft loaded" "$(nft_prog)" "$(cat "$LIMITF" 2>/dev/null)"
check_has "limit: boot copy written root 0640" "$LIMITF 0640" "$(cat "$WRITES")"
check_has "limit: unit written root 0644" "$UNITF 0644" "$(cat "$WRITES")"
check "limit: unit text" "# Written by firewall-setup.sh: loads the per-source limit on new P2P flows
# (nftables table inet tn_p2p) at boot. firewall-setup.sh rewrites
# /etc/telcoin/p2p-limit.nft with the table and removes both files when the
# limit is not wanted.
[Unit]
Description=Telcoin Network per-source limit on new P2P flows (nftables table inet tn_p2p)
After=ufw.service network-pre.target
ConditionPathExists=/etc/telcoin/p2p-limit.nft

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$T/bin/nft -f /etc/telcoin/p2p-limit.nft
ExecStop=-$T/bin/nft delete table inet tn_p2p

[Install]
WantedBy=multi-user.target" "$(cat "$UNITF" 2>/dev/null)"
check "limit: daemon-reload then enable, never a start" "daemon-reload
enable telcoin-p2p-limit.service" "$(grep -v '^is-enabled' "$SYSTEMCTL_LOG")"
check_has "limit: says it comes back at boot" "  ->  telcoin-p2p-limit.service loads it again at boot (from /etc/telcoin/p2p-limit.nft)." "$OUT"
check "limit: status active and persistent" '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":true,"persistent_reason":null}' "$(status_field)"
check_has "limit: status line at boot" "  [OK]  New-flow limit at boot: loaded by telcoin-p2p-limit.service (enabled)" "$(fw_p2p_limit_report 2>&1 | plain)"
if command -v systemd-analyze >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    mkdir -p "$T/unitcheck"
    cp "$UNITF" "$T/unitcheck/telcoin-p2p-limit.service"
    systemd-analyze verify --man=no "$T/unitcheck/telcoin-p2p-limit.service" >"$T/sa.out" 2>&1
    check_rc "limit: systemd-analyze verify accepts the unit" 0 "$?"
else
    skip "limit: systemd-analyze verify on the unit" "no systemd here"
fi
check "limit: ufw rules still complete" "ENABLED=yes" "$(cat "$TN_ROOT_PREFIX/etc/ufw/ufw.conf")"
check_has "limit: ufw still opens the P2P port" "allow 49590/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
cp "$TABLE" "$T/table.default"
if [[ -n "$REAL_NFT" ]] && "$REAL_NFT" -c -f - >/dev/null 2>&1 <<'NFTPROBE'
table inet tn_probe
NFTPROBE
then
    fw_p2p_limit_text 20 40 > "$T/rendered.nft"
    "$REAL_NFT" -c -f "$T/rendered.nft" >"$T/nftc.out" 2>&1
    check_rc "limit: real nft -c -f accepts the rendered table" 0 "$?"
    fw_p2p_limit_text 1 100000 > "$T/rendered.nft"
    "$REAL_NFT" -c -f "$T/rendered.nft" >"$T/nftc.out" 2>&1
    check_rc "limit: real nft -c -f accepts rate 1 burst 100000" 0 "$?"
else
    skip "limit: real nft -c -f on the rendered table" "no nft here that can run -c (needs root with CAP_NET_ADMIN)"
fi

# A second enable rewrites the table whole, still one transaction.
: > "$NFT_LOG"
fresh_flags
run_apply
check_rc "limit: re-enable rc 0" 0 "$RC"
check "limit: re-enable leaves the same table" "$(cat "$T/table.default")" "$(nft_table)"
check "limit: re-enable is one transaction" "1" "$(nft_applies)"

# Overrides.
export TN_P2P_NEW_FLOW_RATE=30 TN_P2P_NEW_FLOW_BURST=90
fresh_flags; reset_state yes; nft_reset
run_apply
check_rc "limit: env overrides rc 0" 0 "$RC"
tbl="$(nft_table | trim)"
check_has "limit: env rate and burst (v4)" "ct state new udp dport { 49590, 49594 } update @tn_p2p_src4 { ip saddr limit rate over 30/minute burst 90 packets } drop" "$tbl"
check_has "limit: env rate and burst (v6)" "ct state new udp dport { 49590, 49594 } update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over 30/minute burst 90 packets } drop" "$tbl"
check_has "limit: timeout follows the refill (90 at 30/minute)" "timeout 180s" "$tbl"
check "limit: status field with the overrides" '"p2p_new_flow_limit":{"active":true,"rate":30,"burst":90,"reason":null,"persistent":true,"persistent_reason":null}' "$(status_field)"
check "limit: the boot copy follows the overrides" "$(nft_prog)" "$(cat "$LIMITF" 2>/dev/null)"
unset TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST
check "limit: timeout floor is a minute" "timeout 60s" "$(fw_p2p_limit_text 100 5 | grep -o 'timeout [0-9]*s' | head -n 1)"
check "limit: timeout cap is a day" "timeout 86400s" "$(fw_p2p_limit_text 1 100000 | grep -o 'timeout [0-9]*s' | head -n 1)"

# Bad values stop the run before anything changes.
for var in TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST; do
    for bad in 0 020 100001 abc -5 1.5 " 7" "7 "; do
        export "$var=$bad"
        fresh_flags; reset_state yes; nft_reset
        run_apply --reset
        unset "$var"
        check_rc "limit: ${var}='${bad}' rc 1" 1 "$RC"
        check "limit: ${var}='${bad}' no ufw change" "" "$(mutating)"
        check "limit: ${var}='${bad}' no nft call" "" "$(cat "$NFT_LOG")"
        check_has "limit: ${var}='${bad}' named" "yes" "$(grep -q "${var} is '${bad}', not a whole number from 1 to 100000" "$T/out" && echo yes)"
    done
done
export TN_P2P_NEW_FLOW_RATE=100000 TN_P2P_NEW_FLOW_BURST=1
fresh_flags; reset_state yes; nft_reset
run_apply
unset TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST
check_rc "limit: rate 100000 burst 1 accepted" 0 "$RC"

# A ufw step that fails never reaches the table.
cp "$T/table.default" "$TABLE"; : > "$NFT_LOG"; : > "$WRITES"
fresh_flags; reset_state yes
UFW_FAIL_AT=3 run_apply --reset
check_rc "limit: ufw fails at call 3 rc 2" 2 "$RC"
check "limit: ufw failure leaves the table" "$(cat "$T/table.default")" "$(nft_table)"
check "limit: ufw failure makes no nft call" "" "$(cat "$NFT_LOG")"
check "limit: ufw failure writes no boot copy" "" "$(grep -F 'p2p-limit' "$WRITES")"

# A P2P source list (IPv4 and IPv6 CIDRs) replaces the limit: the table goes.
for how in comma file stored; do
    printf 'NETWORK=testnet\n' > "$META"
    fresh_flags; reset_state yes
    cp "$T/table.default" "$TABLE"; : > "$NFT_LOG"; boot_fake
    case "$how" in
        comma) FW_P2P_FROM="10.0.0.0/8,2001:db8::/32" ;;
        file)  printf '# peers\n10.0.0.0/8, 2001:db8::/32  # two ranges\n\n' > "$T/p2p.list"; FW_P2P_FROM="$T/p2p.list" ;;
        stored) printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8,2001:db8::/32\n' > "$META" ;;
    esac
    run_apply --reset
    check_rc "limit: P2P list (${how}) rc 0" 0 "$RC"
    rules="$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
    check_has "limit: P2P list (${how}) v4 source rule" "allow from 10.0.0.0/8 to any port 49590 proto udp" "$rules"
    check_has "limit: P2P list (${how}) v6 source rule" "allow from 2001:db8::/32 to any port 49594 proto udp" "$rules"
    check_lacks "limit: P2P list (${how}) no open P2P rule" "allow 49590/udp" "$rules"
    check "limit: P2P list (${how}) table deleted" "" "$(nft_table)"
    check "limit: P2P list (${how}) delete program" "table inet tn_p2p
delete table inet tn_p2p" "$(nft_prog)"
    check_lacks "limit: P2P list (${how}) writes no meter" "limit rate" "$(cat "$NFT_LOG")"
    check "limit: P2P list (${how}) unit removed" "no" "$([[ -e "$UNITF" ]] && echo yes || echo no)"
    check "limit: P2P list (${how}) boot copy removed" "no" "$([[ -e "$LIMITF" ]] && echo yes || echo no)"
    check "limit: P2P list (${how}) unit disabled and stopped, then daemon-reload" "disable --now telcoin-p2p-limit.service
daemon-reload" "$(cat "$SYSTEMCTL_LOG")"
    check "limit: P2P list (${how}) writes no boot copy" "" "$(cat "$WRITES")"
done
# With the list and no table, nothing is applied (only the tables are listed).
: > "$NFT_LOG"
fresh_flags
run_apply
check_rc "limit: list, no table rc 0" 0 "$RC"
check "limit: list, no table: no nft transaction" "0" "$(nft_applies)"
check "limit: status with a stored list" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"p2p-list","persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
check_has "limit: status line with a list" "  ->  New-flow limit: not used; the P2P ports take only the P2P source list (P2P_ALLOW_FROM)" "$(fw_p2p_limit_report 2>&1)"
# --p2p-anywhere drops the stored list and the limit comes back.
fresh_flags; FW_P2P_ANYWHERE=true; reset_state yes; : > "$NFT_LOG"
run_apply
check_rc "limit: --p2p-anywhere rc 0" 0 "$RC"
check "limit: --p2p-anywhere writes the table" "$(cat "$T/table.default")" "$(nft_table)"
check "limit: --p2p-anywhere writes the boot copy" "yes yes" "$([[ -f "$LIMITF" ]] && echo yes) $([[ -f "$UNITF" ]] && echo yes)"
printf 'NETWORK=testnet\n' > "$META"

# --reset without a node deletes the table.
detect_installed_nodes() { echo "none"; }
fresh_flags; reset_state yes; cp "$T/table.default" "$TABLE"; : > "$NFT_LOG"; boot_fake
run_apply --reset
check_rc "limit: reset without a node rc 0" 0 "$RC"
check "limit: reset without a node deletes the table" "" "$(nft_table)"
check "limit: reset without a node removes the boot copy" "no no" "$([[ -e "$UNITF" ]] && echo yes || echo no) $([[ -e "$LIMITF" ]] && echo yes || echo no)"
check_has "limit: reset without a node disables the unit" "disable --now telcoin-p2p-limit.service" "$(cat "$SYSTEMCTL_LOG")"
detect_installed_nodes() { echo "telcoin.service"; }

# nft refuses the program: a warning, rc 0, the table it had stays.
fresh_flags; reset_state yes
printf 'table inet tn_p2p {\n    chain old {\n    }\n}\n' > "$TABLE"; : > "$NFT_LOG"; boot_reset
NFT_FAIL=1 run_apply
check_rc "limit: nft refuses rc 0" 0 "$RC"
check_has "limit: nft refusal warned" "yes" "$(grep -q 'nft did not load the P2P new-flow limit (exit 1: Error: Could not process rule: Operation not supported); table inet tn_p2p stays as it was. The ufw rules are applied.' "$T/out" && echo yes)"
check "limit: nft refusal keeps the old table" "table inet tn_p2p {
    chain old {
    }
}" "$(nft_table)"
check "limit: nft refusal writes no boot copy" "" "$(cat "$WRITES")"
check "limit: status: a table without the limit rule" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"unreadable","persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
check_has "limit: ufw applied despite nft" "allow 49594/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"

# Status field and line for each state.
cp "$T/table.default" "$TABLE"
check "limit: status active, no boot copy" '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
fw_p2p_limit_report > "$T/report" 2>&1
check_has "limit: status line active" "  [OK]  New-flow limit: at most 20 packets of new, not yet answered P2P flows per minute from one IPv4 address or IPv6 /64 after a burst of 40 (nftables table inet tn_p2p)" "$(plain < "$T/report")"
check_has "limit: status line, not restored at boot" "  [WARN] New-flow limit at boot: not restored after a reboot (/etc/telcoin/p2p-limit.nft is missing); run Enable recommended defaults (or --enable) again" "$(plain < "$T/report")"
if command -v python3 >/dev/null 2>&1; then
    check "limit: status object parses as JSON" "True 20 40 None False" \
        "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["p2p_new_flow_limit"]; print(d["active"], d["rate"], d["burst"], d["reason"], d["persistent"])' < "$T/status.json" 2>&1)"
else
    skip "limit: status object parses as JSON" "no python3 here"
fi
rm -f "$TABLE"
check "limit: status not applied" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"not-applied","persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
check_has "limit: status line not applied" "  [WARN] New-flow limit: not applied; run Enable recommended defaults (or --enable) to add it" "$(fw_p2p_limit_report 2>&1 | plain)"
# After a reboot the unit is enabled but nothing loaded the table: said so.
boot_fake
check "limit: status, unit enabled but no table" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"not-applied","persistent":true,"persistent_reason":null}' "$(status_field)"
check_has "limit: status line, unit enabled but no table" "  [WARN] New-flow limit at boot: telcoin-p2p-limit.service is enabled but the table is not loaded; check: systemctl status telcoin-p2p-limit.service" "$(fw_p2p_limit_report 2>&1 | plain)"
boot_reset
export NFT_LIST_FAIL=1
check "limit: status unreadable" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"unreadable","persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
unset NFT_LIST_FAIL
view_status </dev/null >"$T/view.out" 2>&1
check_has "limit: view_status shows the limit line" "yes" "$(grep -q "New-flow limit: not applied" "$T/view.out" && echo yes)"

# nft absent: one warning, rc 0, ufw rules applied, status says so.
mv "$T/bin/nft" "$T/bin/nft.off"; hash -r
if command -v nft >/dev/null 2>&1; then
    skip "limit: nft absent" "an nft other than the stub is on PATH ($(command -v nft))"
else
    fresh_flags; reset_state yes; : > "$NFT_LOG"; boot_fake
    run_apply --reset
    check_rc "limit: nft absent rc 0" 0 "$RC"
    check "limit: nft absent removes a boot copy that could not run" "no no" "$([[ -e "$UNITF" ]] && echo yes || echo no) $([[ -e "$LIMITF" ]] && echo yes || echo no)"
    check "limit: nft absent warns once" "1" "$(grep -c 'nftables (nft) is not installed, so the P2P new-flow limit is not applied; P2P stays open to every source' "$T/out" | tr -d ' ')"
    check_has "limit: nft absent, ufw rules applied" "allow 49590/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
    check "limit: nft absent, ufw enabled" "ENABLED=yes" "$(cat "$TN_ROOT_PREFIX/etc/ufw/ufw.conf")"
    check "limit: status nft missing" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"nft-missing","persistent":false,"persistent_reason":"boot-file-missing"}' "$(status_field)"
    check_has "limit: status line nft missing" "  [WARN] New-flow limit: not applied; nftables (nft) is not installed, so P2P stays open to every source" "$(fw_p2p_limit_report 2>&1 | plain)"
    # With a list set, a missing nft is not worth a warning.
    fresh_flags; FW_P2P_FROM="10.0.0.0/8"; reset_state yes
    run_apply --reset
    check_rc "limit: nft absent with a list rc 0" 0 "$RC"
    check_lacks "limit: nft absent with a list: no warning" "nftables (nft) is not installed" "$OUT"
fi
mv "$T/bin/nft.off" "$T/bin/nft"; hash -r
rm -f "$TABLE"

# The boot copy cannot be written: the table is loaded, a warning says it will not
# come back after a reboot, rc 0.
for which in file unit; do
    fresh_flags; reset_state yes; nft_reset; boot_reset
    if [[ "$which" == file ]]; then WRITE_FAIL="$LIMITF"; else WRITE_FAIL="$UNITF"; fi
    export WRITE_FAIL
    run_apply
    unset WRITE_FAIL
    check_rc "limit: boot ${which} write fails rc 0" 0 "$RC"
    check "limit: boot ${which} write fails: table loaded" "$(cat "$T/table.default")" "$(nft_table)"
    if [[ "$which" == file ]]; then
        check_has "limit: boot file write fails: warned" "yes" "$(grep -q 'The P2P new-flow limit is loaded now but will not come back after a reboot: /etc/telcoin/p2p-limit.nft could not be written. Fix that and run --enable again.' "$T/out" && echo yes)"
        check "limit: boot file write fails: no unit" "no" "$([[ -e "$UNITF" ]] && echo yes || echo no)"
    else
        check_has "limit: boot unit write fails: warned" "yes" "$(grep -q 'will not come back after a reboot: /etc/systemd/system/telcoin-p2p-limit.service could not be written' "$T/out" && echo yes)"
    fi
    check_lacks "limit: boot ${which} write fails: nothing enabled" "enable" "$(cat "$SYSTEMCTL_LOG")"
    if [[ "$which" == file ]]; then why=boot-file-missing; else why=unit-not-enabled; fi
    check "limit: boot ${which} write fails: status not persistent" "{\"active\":true,\"rate\":20,\"burst\":40,\"reason\":null,\"persistent\":false,\"persistent_reason\":\"${why}\"}" "$(status_field | sed 's/^"p2p_new_flow_limit"://')"
done

# "Manage node ports" opening the P2P ports rewrites the limit and its boot copy
# (a third P2P port here), and deletes them when a P2P source list is set.
printf 'NETWORK=mainnet\n' > "$META"
NETWORK=mainnet
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n49595 worker-1\n'; }
fresh_flags; reset_state yes; nft_reset; boot_reset
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
# The host baseline refresh (AUDIT-2) after the limit and its boot copy change.
tn_host_baseline_refresh() { printf 'refresh %s\n' "${1:-}" >> "$T/hb.calls"; }
rm -f "$T/hb.calls"
( confirm() { return 0; }; manage_node_ports ) </dev/null > "$T/mnp.out" 2>&1
check "menu: the host baseline is made again" "refresh fw_baseline_say" "$(cat "$T/hb.calls" 2>/dev/null)"
check_has "menu: third P2P port opened" "allow 49595/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check_has "menu: table rewritten with the third port" "ct state new udp dport { 49590, 49594, 49595 } update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop" "$(nft_table | trim)"
check "menu: boot copy rewritten" "$(nft_prog)" "$(cat "$LIMITF" 2>/dev/null)"
check_has "menu: unit enabled" "enable telcoin-p2p-limit.service" "$(cat "$SYSTEMCTL_LOG")"
printf 'NETWORK=mainnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
fresh_flags; : > "$NFT_LOG"; : > "$SYSTEMCTL_LOG"
printf 'allow 22/tcp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
rm -f "$T/hb.calls"
( confirm() { return 0; }; manage_node_ports ) </dev/null > "$T/mnp.out" 2>&1
check "menu with a list: the host baseline is made again" "refresh fw_baseline_say" "$(cat "$T/hb.calls" 2>/dev/null)"
check_has "menu with a list: source rule" "allow from 10.0.0.0/8 to any port 49595 proto udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check "menu with a list: table deleted" "" "$(nft_table)"
check "menu with a list: boot copy removed" "no no" "$([[ -e "$UNITF" ]] && echo yes || echo no) $([[ -e "$LIMITF" ]] && echo yes || echo no)"
# Declining the prompt changes nothing.
printf 'NETWORK=mainnet\n' > "$META"
fresh_flags; : > "$NFT_LOG"
printf 'allow 22/tcp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
rm -f "$T/hb.calls"
( confirm() { return 1; }; manage_node_ports ) </dev/null > "$T/mnp.out" 2>&1
check "menu declined: no nft call" "" "$(cat "$NFT_LOG")"
check "menu declined: no host baseline refresh" "" "$(cat "$T/hb.calls" 2>/dev/null)"
unset -f tn_host_baseline_refresh
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet
rm -f "$TABLE"; boot_reset

# --- the expected rules name the P2P source list ------------------------------------
# desired_p2p SPEC -- the desired-rule object of SPEC in the --json status.
desired_p2p() {
    json_fw_status 3>"$T/status.json" >/dev/null 2>&1
    grep -o "{\"spec\":\"$1\",[^}]*}" "$T/status.json"
}
mkdir -p "$TN_ROOT_PREFIX/etc/systemd/system"
printf '[Service]\n' > "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8,2001:db8::/32\n' > "$META"
NETWORK=testnet; fresh_flags; reset_state yes
check "expected: P2P primary row names the stored list" '{"spec":"49590/udp","label":"Node P2P (primary)","source":"10.0.0.0/8,2001:db8::/32","ok":false}' "$(desired_p2p 49590/udp)"
check "expected: P2P worker row names the stored list" '{"spec":"49594/udp","label":"Node P2P (worker)","source":"10.0.0.0/8,2001:db8::/32","ok":false}' "$(desired_p2p 49594/udp)"
check "expected: SSH row without a list says anywhere" '{"spec":"22/tcp","label":"SSH","source":"anywhere","ok":true}' "$(desired_p2p 22/tcp)"
fresh_flags; FW_P2P_FROM="198.51.100.0/24"
check_has "expected: the run's --p2p-from list wins" "$(printf '49590/udp\tNode P2P (primary)\t198.51.100.0/24')" "$(desired_firewall_rules 2>/dev/null)"
fresh_flags; FW_P2P_ANYWHERE=true
check_has "expected: --p2p-anywhere says anywhere" "$(printf '49590/udp\tNode P2P (primary)\tanywhere')" "$(desired_firewall_rules 2>/dev/null)"
printf 'NETWORK=testnet\n' > "$META"
fresh_flags; reset_state yes
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
check "expected: P2P row without a list says anywhere" '{"spec":"49590/udp","label":"Node P2P (primary)","source":"anywhere","ok":true}' "$(desired_p2p 49590/udp)"
view_status </dev/null > "$T/view.out" 2>&1
check_has "expected: status screen row" "yes" "$(grep -q 'Node P2P (primary) (49590/udp)' "$T/view.out" && echo yes)"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
printf 'allow 22/tcp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
view_status </dev/null > "$T/view.out" 2>&1
check_has "expected: status screen names the list of a missing rule" "yes" "$(grep -q 'Node P2P (primary) (49590/udp) -- MISSING (expected from 10.0.0.0/8)' "$T/view.out" && echo yes)"
rm -f "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
printf 'NETWORK=testnet\n' > "$META"
fresh_flags

# --- round 3: menu refusals, the lock, the boot copy check, unusable lists ---------
# hold_lock / release_lock -- another run holding the update lock (flock, else the
# mkdir lock with this shell as its live holder).
HOLDER=""
hold_lock() {
    rm -f "$T/lock.ready" "$T/lock.release"
    if command -v flock >/dev/null 2>&1; then
        flock "$TN_UPDATE_LOCK_FILE" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' _ "$T/lock.ready" "$T/lock.release" &
        HOLDER=$!
        i=0
        while [ ! -e "$T/lock.ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    else
        mkdir -p "${TN_UPDATE_LOCK_FILE}.d"
        echo "$$" > "${TN_UPDATE_LOCK_FILE}.d/pid"
        HOLDER=""
    fi
}
release_lock() {
    if [ -n "$HOLDER" ]; then
        touch "$T/lock.release"
        wait "$HOLDER" 2>/dev/null
        HOLDER=""
    else
        rm -rf "${TN_UPDATE_LOCK_FILE}.d"
    fi
}
# menu ANSWER -- run "Manage node ports" with every prompt answered ANSWER (yes|no)
# in a subshell; it records whether the update lock is still held afterwards.
menu() {
    if [[ "$1" == yes ]]; then
        ( confirm() { return 0; }; manage_node_ports; echo "kind=${TN_UPDATE_LOCK_KIND:-}" > "$T/menu.lock" ) </dev/null > "$T/mnp.out" 2>&1
    else
        ( confirm() { return 1; }; manage_node_ports; echo "kind=${TN_UPDATE_LOCK_KIND:-}" > "$T/menu.lock" ) </dev/null > "$T/mnp.out" 2>&1
    fi
}
printf 'NETWORK=mainnet\n' > "$META"
NETWORK=mainnet
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n49595 worker-1\n'; }

# A bad rate refuses before the menu opens anything.
fresh_flags; reset_state yes; nft_reset; boot_reset
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
export TN_P2P_NEW_FLOW_RATE=0
menu yes
unset TN_P2P_NEW_FLOW_RATE
check "menu, bad rate: no ufw change" "" "$(mutating)"
check_lacks "menu, bad rate: third port not opened" "allow 49595/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check "menu, bad rate: no nft call" "" "$(cat "$NFT_LOG")"
check_has "menu, bad rate: refused, nothing changed" "yes" "$(grep -q "TN_P2P_NEW_FLOW_RATE is '0', not a whole number from 1 to 100000 (packets of new, not yet answered P2P flows per minute from one IPv4 address or IPv6 /64); nothing was changed." "$T/mnp.out" && echo yes)"

# Another run holds the update lock: the menu changes nothing.
fresh_flags; reset_state yes; nft_reset; boot_reset
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
hold_lock
menu yes
release_lock
check "menu, lock held: no P2P rule change" "" "$(mutating | grep udp)"
check "menu, lock held: no nft call" "" "$(cat "$NFT_LOG")"
check_has "menu, lock held: says another update runs" "yes" "$(grep -q 'Another update is already running' "$T/mnp.out" && echo yes)"
# Free again: the port opens, the table and its boot copy follow, the lock is released.
fresh_flags; : > "$UFW_LOG"; : > "$NFT_LOG"
menu yes
check_has "menu: third port opened under the lock" "allow 49595/udp" "$(cat "$TN_ROOT_PREFIX/etc/ufw/user.rules")"
check "menu: lock released after the change" "kind=" "$(cat "$T/menu.lock")"
check_has "menu: the lock was taken" "yes" "$([[ -s "$TN_UPDATE_LOCK_FILE" || -d "${TN_UPDATE_LOCK_FILE}.d" ]] && echo yes)"
check "menu: boot copy follows" "$(nft_prog)" "$(cat "$LIMITF" 2>/dev/null)"

# All ports already open, the table older (two ports): the menu rewrites it.
fresh_flags; reset_state yes; nft_reset; boot_reset
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\nallow 49595/udp\n' > "$TN_ROOT_PREFIX/etc/ufw/user.rules"
cp "$T/table.default" "$TABLE"
menu no
check "menu, ports already open: no P2P rule change" "" "$(mutating | grep udp)"
check_has "menu, ports already open: table rewritten with every port" "ct state new udp dport { 49590, 49594, 49595 } update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop" "$(nft_table | trim)"
check "menu, ports already open: boot copy rewritten" "$(nft_prog)" "$(cat "$LIMITF" 2>/dev/null)"
check "menu, ports already open: lock released" "kind=" "$(cat "$T/menu.lock")"
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet

# The boot copy is checked against the loaded table: rate, burst and ports.
mkdir -p "${UNITF%/*}" "${LIMITF%/*}"
cp "$T/table.default" "$TABLE"
printf '[Unit]\n' > "$UNITF"
printf 'telcoin-p2p-limit.service\n' > "$TN_ROOT_PREFIX/.systemctl.enabled"
fw_p2p_limit_text 30 90 > "$LIMITF"
check "boot copy differs (rate): not persistent" '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false,"persistent_reason":"boot-copy-differs"}' "$(status_field)"
check_has "boot copy differs: status line" "  [WARN] New-flow limit at boot: /etc/telcoin/p2p-limit.nft holds another rate, burst or port set than the loaded table, so a reboot would load that one; run Enable recommended defaults (or --enable) again" "$(fw_p2p_limit_report 2>&1 | plain)"
fw_p2p_ports() { printf '49590 primary\n'; }
fw_p2p_limit_text 20 40 > "$LIMITF"
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
check "boot copy differs (ports): not persistent" "boot-copy-differs" "$(status_field | grep -o '"persistent_reason":"[^"]*"' | cut -d'"' -f4)"
sed 's/{ 49590, 49594 }/{ 49594, 49590 }/' "$T/table.default" > "$T/boot.reordered"
{ printf 'table inet tn_p2p\ndelete table inet tn_p2p\n'; cat "$T/boot.reordered"; } > "$LIMITF"
check "boot copy, same ports in another order: persistent" '"persistent":true,"persistent_reason":null' "$(status_field | grep -o '"persistent":[a-z]*,"persistent_reason":[a-z]*')"
check "params: one port as nft lists it" "20 40 49590" "$(fw_p2p_limit_params <<< '        ct state new udp dport 49590 update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop')"
check "params: a sorted set" "7 5 49590,49594,49600" "$(fw_p2p_limit_params <<< 'ct state new udp dport { 49600, 49590, 49594 } update @tn_p2p_src4 { ip saddr limit rate over 7/minute burst 5 packets } drop')"
rm -f "$TN_ROOT_PREFIX/.systemctl.enabled"
check "boot copy, unit not enabled" "unit-not-enabled" "$(status_field | grep -o '"persistent_reason":"[^"]*"' | cut -d'"' -f4)"
check_has "boot copy, unit not enabled: status line" "  [WARN] New-flow limit at boot: not restored after a reboot (telcoin-p2p-limit.service is not enabled); run Enable recommended defaults (or --enable) again" "$(fw_p2p_limit_report 2>&1 | plain)"

# A stop while the limit was being written or removed is finished or reported.
prog="$(fw_p2p_limit_text 20 40)"
nft_reset; boot_reset
nft -f - <<< "$prog" > /dev/null
FW_LIMIT_INFLIGHT=write; FW_LIMIT_PROG="$prog"
fw_p2p_limit_on_exit 143 > "$T/onexit.out" 2>&1
check "stopped after the load: boot copy written" "$prog" "$(cat "$LIMITF" 2>/dev/null)"
check_has "stopped after the load: unit enabled" "enable telcoin-p2p-limit.service" "$(cat "$SYSTEMCTL_LOG")"
check_has "stopped after the load: said" "yes" "$(grep -q 'Stopped (exit 143) after the P2P new-flow limit was loaded; its boot copy was written too.' "$T/onexit.out" && echo yes)"
check "stopped after the load: marker cleared" "" "$FW_LIMIT_INFLIGHT"
nft_reset; boot_reset
cp "$T/table.default" "$TABLE"
FW_LIMIT_INFLIGHT=write; FW_LIMIT_PROG="$(fw_p2p_limit_text 30 90)"
fw_p2p_limit_on_exit 143 > "$T/onexit.out" 2>&1
check "stopped before the load: no boot copy written" "" "$(cat "$WRITES")"
check_has "stopped before the load: said" "yes" "$(grep -q 'Stopped (exit 143) before the P2P new-flow limit was loaded; the previous limit and its boot copy stay as they were.' "$T/onexit.out" && echo yes)"
check "stopped before the load: table as it was" "$(cat "$T/table.default")" "$(nft_table)"
boot_fake; cp "$T/table.default" "$TABLE"; : > "$NFT_LOG"
FW_LIMIT_INFLIGHT=delete
fw_p2p_limit_on_exit 143 > "$T/onexit.out" 2>&1
check "stopped in a removal: finished" "no no " "$([[ -e "$UNITF" ]] && echo yes || echo no) $([[ -e "$LIMITF" ]] && echo yes || echo no) $(nft_table)"
check_has "stopped in a removal: said" "yes" "$(grep -q 'Stopped (exit 143) while the P2P new-flow limit was being removed; the removal was finished.' "$T/onexit.out" && echo yes)"
nft_reset; boot_reset

# A source list set twice is not usable: the expected rows say so, never anywhere.
mkdir -p "$TN_ROOT_PREFIX/etc/systemd/system"
printf '[Service]\n' > "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\nP2P_ALLOW_FROM=0.0.0.0/0\nSSH_ALLOW_FROM=203.0.113.0/24\nSSH_ALLOW_FROM=192.0.2.0/24\n' > "$META"
fresh_flags; reset_state yes
check "expected: P2P list set twice" '{"spec":"49590/udp","label":"Node P2P (primary)","source":"unknown (P2P source list not usable)","ok":false}' "$(desired_p2p 49590/udp)"
check "expected: SSH list set twice" '{"spec":"22/tcp","label":"SSH","source":"unknown (SSH source list not usable)","ok":true}' "$(desired_p2p 22/tcp)"
check_lacks "expected: never anywhere for an unusable list" '"source":"anywhere"' "$(cat "$T/status.json")"
run_apply
check_rc "expected: the same list refuses an enable" 1 "$RC"
rm -f "$TN_ROOT_PREFIX/etc/systemd/system/telcoin.service"
printf 'NETWORK=testnet\n' > "$META"
fresh_flags

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
