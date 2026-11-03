#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V5/fw_v5_test.sh -- V5's independent checks of the FW
# package (firewall-setup.sh: the P2P new-flow limit, table inet tn_p2p, its
# boot copy, the status lines and --json field, the expected rows, Manage node
# ports, the signal and concurrency cases). Written from the specs before the
# implementer's checkpoint was read.
#
#   bash tasks/verify-fup/V5/fw_v5_test.sh
#   V5_SRC=/path/to/mutated/tree bash tasks/verify-fup/V5/fw_v5_test.sh
#
# V5_SRC (default: this checkout) is the tree whose firewall-setup.sh and lib/
# are tested; the mutation run points it at a copy with one hunk reverted.
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/tests/lib.sh
. "${HERE}/../../../tools/tests/lib.sh"
# shellcheck source=tools/tests/fwstub.sh
. "${TN_TEST_DIR}/fwstub.sh"
# shellcheck source=tasks/verify-fup/V5/v5stubs.sh
. "${HERE}/v5stubs.sh"
SRC="${V5_SRC:-$TN_TEST_REPO}"
T="$TN_TEST_TMP"

# Root with a root-owned, non-world-writable prefix: the library's own
# tn_write_root_file runs (real owner and mode). Otherwise the fixture writer.
V5_REAL_WRITER=0
if [[ "$(id -u)" == 0 ]] && R="$(mktemp -d /root/v5fx.XXXXXX 2>/dev/null)"; then
    V5_REAL_WRITER=1
else
    R="$T/root"
fi
export TN_ROOT_PREFIX="$R" V5_REAL_WRITER
export UFW_LOG="$T/ufw.log" V5_NFT_LOG="$T/nft.log" V5_SEQ="$T/seq.log" V5_SC_LOG="$T/sc.log"
export V5_WRITES="$T/writes" TN_FW_SNAP_PARENT="$T/snap"
mkdir -p "$R/etc/telcoin" "$R/etc/systemd/system" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh" \
    "$TN_FW_SNAP_PARENT" "$T/fw"
chmod 0755 "$R/etc" "$R/etc/telcoin" "$R/etc/systemd" "$R/etc/systemd/system"
fw_stub_install "$T/fwbin"
v5_stubs_install "$T/bin" "$T/fwbin"
mkdir -p "$T/bin-nonft"
for f in ufw sshd systemctl; do cp "$T/bin/$f" "$T/bin-nonft/$f"; done
P_FULL="$T/bin:/usr/local/bin:/usr/bin:/bin"
P_NONFT="$T/bin-nonft:/usr/local/bin:/usr/bin:/bin"
PATH="$P_FULL"
echo "info  writer: $([[ $V5_REAL_WRITER == 1 ]] && echo 'lib tn_write_root_file (root)' || echo fixture) prefix=$R"

grep -v '^main "\$@"$' "${SRC}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${SRC}/lib" "$T/fw/lib"
v5_overrides_text > "$T/overrides.sh"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
# shellcheck source=/dev/null
source "$T/overrides.sh"
set +e
META="$R/etc/telcoin/.node-meta"
TABLE="$R/.v5nft.table"
NFTFILE="$R/etc/telcoin/p2p-limit.nft"
UNIT="$R/etc/systemd/system/telcoin-p2p-limit.service"
SVC=telcoin-p2p-limit.service

reset_ufw() {
    printf 'allow 22/tcp\n' > "$R/etc/ufw/user.rules"
    printf 'ENABLED=%s\n' "${1:-yes}" > "$R/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "$R/etc/default/ufw"
    rm -f "$R/.ufw.n"
    : > "$UFW_LOG"; : > "$V5_NFT_LOG"; : > "$V5_SEQ"; : > "$V5_SC_LOG"; : > "$V5_WRITES"
}
flags() { FW_SSH_FROM=""; FW_P2P_FROM=""; FW_SSH_ANYWHERE=false; FW_P2P_ANYWHERE=false; FW_P2P_LOADED=false; FW_P2P_SRCS=(); }
apply() {
    flags
    RC=0
    apply_recommended_firewall "$@" > "$T/out" 2>&1 || RC=$?
    OUT="$(cat "$T/out")"
}
nft_writes() { grep -c '^nft -f -$' "$V5_NFT_LOG"; }
mutating_ufw() { grep -v '^status' "$UFW_LOG"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
limit_json() {
    flags
    json_fw_status 3> "$T/j" > /dev/null 2>&1
    grep -o '"p2p_new_flow_limit":{[^}]*}' "$T/j"
}
clean_limit() { rm -f "$TABLE" "$NFTFILE" "$UNIT" "$R/.v5sc.enabled"; }
printf 'NETWORK=testnet\n' > "$META"
NETWORK=testnet

# ---- A. The rendered program ---------------------------------------------------------
PROG="$(fw_p2p_limit_text 20 40)"
printf '%s\n' "$PROG" > "$T/prog.nft"
check "A1 first statements add, delete, re-add table inet tn_p2p" \
    $'table inet tn_p2p\ndelete table inet tn_p2p\ntable inet tn_p2p {' \
    "$(grep -v '^#' "$T/prog.nft" | grep -v '^[[:space:]]*$' | head -n 3)"
check "A2 two rules, each ct state new udp dport { 49590, 49594 }" "2" \
    "$(grep -c 'ct state new udp dport { 49590, 49594 } update @' "$T/prog.nft")"
check "A3 every rule line (update/drop) starts with ct state new" "" \
    "$(grep -E 'drop|update @' "$T/prog.nft" | grep -v '^[[:space:]]*ct state new ')"
check_sub "A4 v4 meter keyed per saddr, defaults 20/40" \
    "update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop" "$PROG"
check_sub "A5 v6 meter keyed per /64, defaults 20/40" \
    "update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over 20/minute burst 40 packets } drop" "$PROG"
check "A6 no accept verdict except the chain policy" "" \
    "$(grep -o '[a-z]* *accept' "$T/prog.nft" | grep -v '^policy accept$')"
check_sub "A7 input hook at priority -10 (before ufw at 0), policy accept" \
    "type filter hook input priority -10; policy accept;" "$PROG"
check "A8 set types ipv4_addr / ipv6_addr, dynamic,timeout" "2 2" \
    "$(grep -c 'type ipv[46]_addr' "$T/prog.nft") $(grep -c 'flags dynamic,timeout' "$T/prog.nft")"
check "A9 timeout = ceil(burst*60/rate) = 120s for 20/40" "2" "$(grep -c 'timeout 120s' "$T/prog.nft")"
check "A10 timeout floor 60s (rate 100000 burst 1)" "2" "$(fw_p2p_limit_text 100000 1 | grep -c 'timeout 60s')"
check "A11 timeout cap 86400s (rate 1 burst 100000)" "2" "$(fw_p2p_limit_text 1 100000 | grep -c 'timeout 86400s')"
check "A12 no drop of anything but the two new-flow rules" "2" "$(grep -c 'drop' "$T/prog.nft")"
# ports from fw_p2p_ports: one, three (a second worker)
export V5_PORTS='49590 primary\n'
check "A13 one port: dport { 49590 }" "2" "$(fw_p2p_limit_text 20 40 | grep -c 'udp dport { 49590 } update')"
export V5_PORTS='49590 primary\n49594 worker-0\n49595 worker-1\n'
check "A14 three ports (second worker)" "2" "$(fw_p2p_limit_text 20 40 | grep -c 'udp dport { 49590, 49594, 49595 } update')"
export V5_PORTS='49590 primary\nabc worker-0\n'
NONNUM="$(fw_p2p_limit_text 20 40)"
printf '%s\n' "$NONNUM" > "$T/prog-nonnum.nft"
check_sub "A15 a non-numeric port line goes into the program as is (nft must refuse it)" "dport { 49590, abc }" "$NONNUM"
unset V5_PORTS

# ---- B. Written only after a complete ufw apply --------------------------------------
reset_ufw yes; clean_limit
apply
check_rc "B1 enable without lists rc 0" 0 "$RC"
check "B2 one nft -f - write" "1" "$(nft_writes)"
check "B3 the program nft got is fw_p2p_limit_text 20 40" "$PROG" \
    "$(sed -n 's/^| //p' "$V5_NFT_LOG")"
seq_enable="$(grep -n '^ufw --force enable$' "$V5_SEQ" | head -n1 | cut -d: -f1)"
seq_nft="$(grep -n '^nft -f -$' "$V5_SEQ" | head -n1 | cut -d: -f1)"
check "B4 nft write after ufw --force enable" "yes" "$([[ -n "$seq_enable" && -n "$seq_nft" && "$seq_nft" -gt "$seq_enable" ]] && echo yes)"
check "B5 no ufw call after the nft write" "" "$(sed -n "$((seq_nft + 1)),\$p" "$V5_SEQ" | grep '^ufw ' | grep -v '^ufw status')"
check "B6 table present" "yes" "$([[ -f "$TABLE" ]] && echo yes)"
check_sub "B7 info line names the rate and burst" "at most 20 new flows per minute" "$OUT"
# ufw failure at every mutating step: never reaches nft, never writes the boot copy
total="$(cat "$R/.ufw.n")"
fails=""
n=1
while [[ "$n" -le "$total" ]]; do
    reset_ufw yes; clean_limit
    export UFW_FAIL_AT="$n"
    apply
    unset UFW_FAIL_AT
    if [[ "$RC" -ne 0 ]]; then
        if [[ "$(nft_writes)" != "0" || -e "$NFTFILE" || -e "$UNIT" ]]; then
            fails="${fails} step${n}(rc${RC})"
        fi
    fi
    n=$((n + 1))
done
check "B8 a ufw call failing at any step: no nft write, no boot copy (over ${total} calls)" "" "$fails"
reset_ufw yes; clean_limit
export UFW_FAIL_FROM=6
apply
unset UFW_FAIL_FROM
check "B9 ufw failure with a failed restore (rc ${RC}) never reaches nft" "0 no" \
    "$(nft_writes) $([[ -e "$TABLE" ]] && echo yes || echo no)"

# ---- C. Boot copy --------------------------------------------------------------------
reset_ufw yes; clean_limit
apply
check "C1 boot program == the loaded program" "$PROG" "$(cat "$NFTFILE" 2>/dev/null)"
check "C2 boot program mode 0640" "640" "$(mode_of "$NFTFILE")"
check "C3 unit mode 0644" "644" "$(mode_of "$UNIT")"
check_sub "C4 both written through tn_write_root_file" "${NFTFILE} 0640" "$(cat "$V5_WRITES")"
check_sub "C4b unit through tn_write_root_file" "${UNIT} 0644" "$(cat "$V5_WRITES")"
if [[ "$V5_REAL_WRITER" == 1 ]]; then
    check "C4c owner root:root (real writer)" "0:0 0:0" "$(stat -c '%u:%g' "$NFTFILE") $(stat -c '%u:%g' "$UNIT")"
else
    skip "C4c owner root" "needs root"
fi
NFTBIN="$(command -v nft)"
UT="$(cat "$UNIT" 2>/dev/null)"
cp "$UNIT" "$T/telcoin-p2p-limit.service" 2>/dev/null
for want in "Type=oneshot" "RemainAfterExit=yes" "After=ufw.service" "ConditionPathExists=/etc/telcoin/p2p-limit.nft" \
            "ExecStart=${NFTBIN} -f /etc/telcoin/p2p-limit.nft" "ExecStop=-${NFTBIN} delete table inet tn_p2p" \
            "WantedBy=multi-user.target"; do
    check_sub "C5 unit has ${want}" "$want" "$UT"
done
check "C6 ExecStart/ExecStop use an absolute nft" "yes" "$([[ "$NFTBIN" == /* ]] && echo yes)"
check_sub "C7 daemon-reload" "daemon-reload" "$(cat "$V5_SC_LOG")"
check_sub "C8 enable the unit" "enable ${SVC}" "$(cat "$V5_SC_LOG")"
check "C9 enable, never start/restart/--now" "" "$(grep -E '^(start|restart|reload-or-restart)|--now' "$V5_SC_LOG")"
check "C10 unit enabled" "enabled" "$(systemctl is-enabled "$SVC")"
# the unit text alone, for systemd-analyze on the host (run.sh)
fw_p2p_limit_unit_text /usr/sbin/nft > "$T/unit-usr-sbin.service"
mkdir -p "${HERE}/records"
cp "$T/unit-usr-sbin.service" "${HERE}/records/telcoin-p2p-limit.service.rendered" 2>/dev/null
cp "$T/prog.nft" "${HERE}/records/p2p-limit.nft.rendered" 2>/dev/null
cp "$T/prog-nonnum.nft" "${HERE}/records/p2p-limit-nonnum.nft.rendered" 2>/dev/null
# the boot copy cannot be written
reset_ufw yes; clean_limit
export V5_WRITE_FAIL="$NFTFILE"
apply
unset V5_WRITE_FAIL
check_rc "C11 boot file not writable: rc 0" 0 "$RC"
check_sub "C12 boot file not writable: warning" "will not come back after a reboot" "$OUT"
check "C13 boot file not writable: table still loaded, unit not enabled" "yes no" \
    "$([[ -f "$TABLE" ]] && echo yes) $(systemctl is-enabled "$SVC" >/dev/null 2>&1 && echo yes || echo no)"
reset_ufw yes; clean_limit
export V5_WRITE_FAIL="$UNIT"
apply
unset V5_WRITE_FAIL
check_sub "C14 unit not writable: warning names it" "telcoin-p2p-limit.service could not be written" "$OUT"
check "C14b unit not writable: rc 0" "0" "$RC"
reset_ufw yes; clean_limit
export V5_SC_FAIL=enable
apply
unset V5_SC_FAIL
check_sub "C15 enable fails: warning" "systemctl could not enable" "$OUT"
check "C15b enable fails: rc 0, table loaded" "0 yes" "$RC $([[ -f "$TABLE" ]] && echo yes)"
# systemctl absent (rc 127 for every call: what a container without systemd gives)
reset_ufw yes; clean_limit
export V5_SC_ABSENT=1
apply
check "C16 no systemctl: rc 0, table loaded" "0 yes" "$RC $([[ -f "$TABLE" ]] && echo yes)"
check_sub "C17 no systemctl: warning" "will not come back after a reboot" "$OUT"
C18="$(limit_json)"
unset V5_SC_ABSENT
check "C18 no systemctl: --json says active, not persistent" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false}' "$C18"
check "C19 no systemctl: boot files left behind (written before enable failed)" "yes yes" \
    "$([[ -f "$NFTFILE" ]] && echo yes || echo no) $([[ -f "$UNIT" ]] && echo yes || echo no)"

# ---- D. Deleted with a list, without a node, on --reset to a list --------------------
seed_limit() { reset_ufw yes; clean_limit; printf 'NETWORK=testnet\n' > "$META"; apply; : > "$V5_NFT_LOG"; : > "$V5_SC_LOG"; : > "$UFW_LOG"; }
del_checks() {
    local what="$1"
    check_rc "D ${what}: rc 0" 0 "$RC"
    check "D ${what}: table gone, boot files gone, unit not enabled" "no no no no" \
        "$([[ -f "$TABLE" ]] && echo yes || echo no) $([[ -e "$NFTFILE" ]] && echo yes || echo no) $([[ -e "$UNIT" ]] && echo yes || echo no) $(systemctl is-enabled "$SVC" >/dev/null 2>&1 && echo yes || echo no)"
    check "D ${what}: no table write" "" "$(grep -n 'table inet tn_p2p {' "$V5_NFT_LOG")"
    check_sub "D ${what}: unit disabled and stopped" "disable --now ${SVC}" "$(cat "$V5_SC_LOG")"
}
seed_limit
flags; FW_P2P_FROM="10.0.0.0/8,2001:db8::/32"; RC=0
apply_recommended_firewall > "$T/out" 2>&1 || RC=$?
del_checks "--p2p-from comma list"
for want in "allow from 10.0.0.0/8 to any port 49590 proto udp" "allow from 2001:db8::/32 to any port 49590 proto udp" \
            "allow from 10.0.0.0/8 to any port 49594 proto udp" "allow from 2001:db8::/32 to any port 49594 proto udp" \
            "delete allow 49590/udp" "delete allow 49594/udp"; do
    check_sub "D list: ufw ${want}" "$want" "$(cat "$UFW_LOG")"
done
seed_limit
printf '# P2P peers\n10.1.0.0/16, 192.0.2.7\n2001:db8:1::/48\n' > "$T/p2p.list"
flags; FW_P2P_FROM="$T/p2p.list"; RC=0
apply_recommended_firewall > "$T/out" 2>&1 || RC=$?
del_checks "--p2p-from list file"
check_sub "D file: v6 entry from the file" "allow from 2001:db8:1::/48 to any port 49594 proto udp" "$(cat "$UFW_LOG")"
seed_limit
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
apply
del_checks "P2P_ALLOW_FROM in .node-meta"
seed_limit
export V5_NODES=none
apply
del_checks "no node"
unset V5_NODES
seed_limit
flags; FW_P2P_FROM="10.0.0.0/8"; RC=0
apply_recommended_firewall --reset > "$T/out" 2>&1 || RC=$?
del_checks "--reset to a list"
check_sub "D reset to a list: ufw reset ran first" "--force reset" "$(head -n 3 "$UFW_LOG")"
# --reset without a list writes it
reset_ufw yes; clean_limit
apply --reset
check "D --reset without a list: one write, table present" "1 yes" "$(nft_writes) $([[ -f "$TABLE" ]] && echo yes)"
# --p2p-anywhere after a stored list: the limit comes back
reset_ufw yes; clean_limit
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
flags; FW_P2P_ANYWHERE=true; RC=0
apply_recommended_firewall > "$T/out" 2>&1 || RC=$?
check "D --p2p-anywhere after a list: table written, boot copy enabled" "0 1 yes enabled" \
    "$RC $(nft_writes) $([[ -f "$TABLE" ]] && echo yes) $(systemctl is-enabled "$SVC")"
check_sub "D --p2p-anywhere: the stale per-source rule is deleted" "delete allow from 10.0.0.0/8 to any port 49590 proto udp" "$(cat "$UFW_LOG")"
printf 'NETWORK=testnet\n' > "$META"
# nft refuses the delete
seed_limit
export V5_NFT_DEL_FAIL=1
flags; FW_P2P_FROM="10.0.0.0/8"; RC=0
apply_recommended_firewall > "$T/out" 2>&1 || RC=$?
OUT="$(cat "$T/out")"
unset V5_NFT_DEL_FAIL
check_rc "D nft refuses the delete: rc 0" 0 "$RC"
check_sub "D nft refuses the delete: warning names the command" "sudo nft delete table inet tn_p2p" "$OUT"
# nft refuses the write: old table and boot copy stay
seed_limit
cp "$TABLE" "$T/table.before"; cp "$NFTFILE" "$T/nftfile.before"
export V5_NFT_FAIL=1 TN_P2P_NEW_FLOW_RATE=7
apply
unset V5_NFT_FAIL TN_P2P_NEW_FLOW_RATE
check_rc "D nft refuses the write: rc 0" 0 "$RC"
check_sub "D nft refuses the write: warning" "nft did not load the P2P new-flow limit" "$OUT"
check "D nft refuses the write: table and boot copy unchanged" "same same" \
    "$(cmp -s "$TABLE" "$T/table.before" && echo same) $(cmp -s "$NFTFILE" "$T/nftfile.before" && echo same)"

# ---- E. No nft -------------------------------------------------------------------------
if PATH="$P_NONFT" command -v nft > /dev/null 2>&1; then
    skip "E no-nft cases" "nft found on the reduced PATH"
else
    seed_limit
    PATH="$P_NONFT"
    apply
    E_JSON="$(limit_json)"
    PATH="$P_FULL"
    check_rc "E1 no nft: rc 0" 0 "$RC"
    check "E2 no nft: the warning once" "1" \
        "$(grep -c 'nftables (nft) is not installed, so the P2P new-flow limit is not applied; P2P stays open to every source' "$T/out")"
    check_sub "E3 no nft: ufw P2P rules applied" "allow 49590/udp" "$(cat "$UFW_LOG")"
    check_sub "E4 no nft: ufw enabled" "--force enable" "$(cat "$UFW_LOG")"
    check "E5 no nft: boot unit and file removed" "no no" \
        "$([[ -e "$NFTFILE" ]] && echo yes || echo no) $([[ -e "$UNIT" ]] && echo yes || echo no)"
    check "E6 no nft: --json reason nft-missing" \
        '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"nft-missing","persistent":false}' "$E_JSON"
fi

# ---- F. Env validation: refused before any change ----------------------------------------
fbad=""
for var in TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST; do
    for v in 0 -1 020 100001 abc "1 2" "20/minute" " 20" "1e3" "+5" "999999999999999999999"; do
        reset_ufw yes; clean_limit
        export "$var=$v"
        apply
        unset "$var"
        if [[ "$RC" -ne 1 || -n "$(mutating_ufw)" || "$(nft_writes)" != 0 || "$OUT" != *"${var} is '${v}'"* || "$OUT" != *"nothing was changed"* ]]; then
            fbad="${fbad} ${var}=[${v}](rc${RC})"
        fi
    done
done
check "F1 every bad rate/burst: rc 1, message names it, no ufw or nft change" "" "$fbad"
reset_ufw yes; clean_limit
export TN_P2P_NEW_FLOW_RATE="" TN_P2P_NEW_FLOW_BURST=""
apply
unset TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST
check_sub "F2 empty values = defaults" "limit rate over 20/minute burst 40 packets" "$(cat "$TABLE" 2>/dev/null)"
reset_ufw yes; clean_limit
export TN_P2P_NEW_FLOW_RATE=5 TN_P2P_NEW_FLOW_BURST=10
apply
unset TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST
check "F3 override 5/10 on both rules" "2" "$(grep -c 'limit rate over 5/minute burst 10 packets' "$TABLE" 2>/dev/null)"
check "F4 override 5/10: json reads them back" \
    '"p2p_new_flow_limit":{"active":true,"rate":5,"burst":10,"reason":null,"persistent":true}' "$(limit_json)"
for v in 1 100000; do
    reset_ufw yes; clean_limit
    export TN_P2P_NEW_FLOW_RATE="$v" TN_P2P_NEW_FLOW_BURST="$v"
    apply
    unset TN_P2P_NEW_FLOW_RATE TN_P2P_NEW_FLOW_BURST
    check "F5 bound ${v} accepted" "0 1" "$RC $(nft_writes)"
done

# ---- G. Status lines and --json in every state -----------------------------------------------
seed_limit
check "G1 active + persistent" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":true}' "$(limit_json)"
G1R="$(flags; fw_p2p_limit_report 2>&1)"
check_sub "G1r status: active line" "New-flow limit: at most 20 new P2P flows per minute" "$G1R"
check_sub "G1r status: at boot line" "New-flow limit at boot: loaded by telcoin-p2p-limit.service (enabled)" "$G1R"
VS="$(view_status < /dev/null 2>&1)"
check_sub "G1v view_status shows the New-flow limit line" "New-flow limit: at most 20" "$VS"
systemctl disable "$SVC" > /dev/null 2>&1
check "G2 active + not persistent (unit not enabled)" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false}' "$(limit_json)"
check_sub "G2r status: not restored at boot" "not restored after a reboot" "$(flags; fw_p2p_limit_report 2>&1)"
systemctl enable "$SVC" > /dev/null 2>&1
rm -f "$NFTFILE"
check "G3 unit enabled but ruleset file missing: not persistent" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false}' "$(limit_json)"
seed_limit
rm -f "$UNIT"; systemctl disable "$SVC" > /dev/null 2>&1
check "G4 ruleset file present, unit missing: not persistent" \
    '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":false}' "$(limit_json)"
seed_limit
rm -f "$TABLE"
check "G5 not-applied (no table), boot copy enabled" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"not-applied","persistent":true}' "$(limit_json)"
check_sub "G5r status warns the enabled unit has no table" "is enabled but the table is not loaded" "$(flags; fw_p2p_limit_report 2>&1)"
clean_limit
check "G6 not-applied, nothing at boot" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"not-applied","persistent":false}' "$(limit_json)"
check_sub "G6r status: not applied" "New-flow limit: not applied; run Enable recommended defaults" "$(flags; fw_p2p_limit_report 2>&1)"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
check "G7 p2p-list" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"p2p-list","persistent":false}' "$(limit_json)"
check_sub "G7r status: p2p-list" "not used; the P2P ports take only the P2P source list" "$(flags; fw_p2p_limit_report 2>&1)"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\nP2P_ALLOW_FROM=192.0.2.0/24\n' > "$META"
check "G8 two P2P_ALLOW_FROM lines, no table: unreadable" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"unreadable","persistent":false}' "$(limit_json)"
printf 'NETWORK=testnet\n' > "$META"
seed_limit
export V5_NFT_LIST_FAIL=1
check "G9 nft cannot list: unreadable (boot copy still reported)" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"unreadable","persistent":true}' "$(limit_json)"
check_sub "G9r status: unknown" "New-flow limit: unknown" "$(flags; fw_p2p_limit_report 2>&1)"
unset V5_NFT_LIST_FAIL
if ! PATH="$P_NONFT" command -v nft > /dev/null 2>&1; then
    clean_limit
    PATH="$P_NONFT"
    G10="$(limit_json)"; G10R="$(flags; fw_p2p_limit_report 2>&1)"
    printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
    G11="$(limit_json)"
    PATH="$P_FULL"
    printf 'NETWORK=testnet\n' > "$META"
    check "G10 nft-missing" \
        '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"nft-missing","persistent":false}' "$G10"
    check_sub "G10r status: nft missing" "nftables (nft) is not installed, so P2P stays open to every source" "$G10R"
    check "G11 nft missing but a list is set: p2p-list" \
        '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"p2p-list","persistent":false}' "$G11"
else
    skip "G10/G11 nft-missing" "nft found on the reduced PATH"
fi
# a table whose rule is not the expected shape
seed_limit
printf 'table inet tn_p2p {\n}\n' > "$TABLE"
check "G12 table without the src4 rule: unreadable" \
    '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"unreadable","persistent":true}' "$(limit_json)"
J="$(cat "$T/j")"
check "G13 the --json status line parses as one JSON object" "ok" \
    "$(printf '%s\n' "$J" | tail -n1 | { command -v python3 > /dev/null 2>&1 && python3 -c 'import json,sys; json.loads(sys.stdin.read()); print("ok")' 2>&1 || echo ok; })"

# ---- H. Expected P2P rows name the list --------------------------------------------------
printf 'NETWORK=testnet\n' > "$META"
flags; FW_P2P_FROM="10.0.0.0/8,2001:db8::/32"
H1="$(desired_firewall_rules 2>/dev/null | grep 'Node P2P')"
check "H1 --p2p-from: both rows carry the list" \
    "$(printf '49590/udp\tNode P2P (primary)\t10.0.0.0/8,2001:db8::/32\n49594/udp\tNode P2P (worker)\t10.0.0.0/8,2001:db8::/32')" "$H1"
flags
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8,192.0.2.7\n' > "$META"
check "H2 stored list" "10.0.0.0/8,192.0.2.7 10.0.0.0/8,192.0.2.7" \
    "$(desired_firewall_rules 2>/dev/null | grep 'Node P2P' | cut -f3 | paste -sd' ' -)"
flags; FW_P2P_ANYWHERE=true
check "H3 --p2p-anywhere over a stored list: anywhere" "anywhere anywhere" \
    "$(desired_firewall_rules 2>/dev/null | grep 'Node P2P' | cut -f3 | paste -sd' ' -)"
flags
printf 'NETWORK=testnet\n' > "$META"
check "H4 no list: anywhere" "anywhere anywhere" "$(desired_firewall_rules 2>/dev/null | grep 'Node P2P' | cut -f3 | paste -sd' ' -)"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\nP2P_ALLOW_FROM=192.0.2.0/24\n' > "$META"
H5="$(desired_firewall_rules 2>/dev/null | grep 'Node P2P' | cut -f3 | paste -sd' ' -)"
check "H5 (adversarial) two P2P_ALLOW_FROM lines: the row must not claim anywhere" "no" \
    "$([[ "$H5" == *anywhere* ]] && echo yes || echo no)"
echo "info  H5 rows source with a doubled P2P_ALLOW_FROM: [$H5]"
reset_ufw yes; clean_limit
apply
check "H6 (adversarial) two P2P_ALLOW_FROM lines: enable refuses before any change" "1 0" "$RC $(nft_writes)"
check_sub "H6b refusal message" "The P2P source list is not usable; nothing was changed." "$OUT"
JD="$(json_fw_status 3>&1 >/dev/null 2>&1)"
check_lacks "H7 (adversarial) --json desired with a doubled P2P_ALLOW_FROM does not say anywhere for P2P" \
    '"spec":"49590/udp","label":"Node P2P (primary)","source":"anywhere"' "$JD"
printf 'NETWORK=testnet\n' > "$META"

# ---- I. Manage node ports: syncs on the open path ------------------------------------------------
mnp() { flags; RC=0; TN_ASSUME_YES=true manage_node_ports < /dev/null > "$T/out" 2>&1 || RC=$?; OUT="$(cat "$T/out")"; }
reset_ufw yes; clean_limit
printf 'allow 22/tcp\n' > "$R/etc/ufw/user.rules"
mnp
check "I1 Manage node ports opens P2P and writes the table and boot copy" "1 yes enabled" \
    "$(nft_writes) $([[ -f "$TABLE" ]] && echo yes) $(systemctl is-enabled "$SVC")"
check_sub "I1b ufw rules opened" "allow 49594/udp" "$(cat "$UFW_LOG")"
# a new worker port: the table follows it
export V5_PORTS='49590 primary\n49594 worker-0\n49595 worker-1\n'
: > "$V5_NFT_LOG"
mnp
check_sub "I2 a second worker port reaches the table" "dport { 49590, 49594, 49595 }" "$(cat "$TABLE" 2>/dev/null)"
unset V5_PORTS
# with a stored list: deletes
reset_ufw yes
printf 'allow 22/tcp\n' > "$R/etc/ufw/user.rules"
printf 'NETWORK=testnet\nP2P_ALLOW_FROM=10.0.0.0/8\n' > "$META"
mnp
check "I3 Manage node ports with a stored list: table and boot copy deleted" "no no" \
    "$([[ -f "$TABLE" ]] && echo yes || echo no) $([[ -e "$UNIT" ]] && echo yes || echo no)"
printf 'NETWORK=testnet\n' > "$META"
# ports already open: nothing is synced
reset_ufw yes; clean_limit
printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$R/etc/ufw/user.rules"
mnp
echo "info  I4 ports already open: nft writes=$(nft_writes) table=$([[ -f "$TABLE" ]] && echo yes || echo no)"
# a bad rate on the menu path: what the message says
reset_ufw yes; clean_limit
printf 'allow 22/tcp\n' > "$R/etc/ufw/user.rules"
export TN_P2P_NEW_FLOW_RATE=0
mnp
unset TN_P2P_NEW_FLOW_RATE
check_sub "I5 menu path with a bad rate: ufw P2P rules were opened" "allow 49590/udp" "$(cat "$UFW_LOG")"
check_lacks "I6 (adversarial) menu path with a bad rate does not claim nothing was changed" "nothing was changed" "$OUT"

# ---- J. SIGTERM between the table write and the boot copy ---------------------------------------
cat > "$T/drv.sh" <<V5D
#!/usr/bin/env bash
source "$T/fw/firewall-setup.sh"
source "$T/overrides.sh"
check_root() { :; }
main "\$@"
V5D
seed_limit
before="$(cat "$NFTFILE")"
reset_ufw yes
export V5_TAG=A V5_NFT_HOLD_TAG=A TN_P2P_NEW_FLOW_RATE=10
bash "$T/drv.sh" --enable > "$T/drv.out" 2>&1 &
pid=$!
unset V5_TAG V5_NFT_HOLD_TAG TN_P2P_NEW_FLOW_RATE
n=0; while [[ ! -e "$R/.held.A" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
kill -TERM "$pid" 2>/dev/null
touch "$R/.release.A"
wait "$pid"; JRC=$?
rm -f "$R/.held.A" "$R/.release.A"
check "J1 SIGTERM mid-sync: exit 143" "143" "$JRC"
check "J2 SIGTERM after the nft write: live table is the new one (rate 10)" "2" "$(grep -c 'over 10/minute' "$TABLE" 2>/dev/null)"
check "J3 SIGTERM: the boot copy was not rewritten (still rate 20)" "$before" "$(cat "$NFTFILE")"
J4="$(limit_json)"
echo "info  J4 after the SIGTERM: $J4"
check "J4 (adversarial) persistent is not true while the boot copy differs from the live table" "no" \
    "$([[ "$J4" == *'"rate":10'* && "$J4" == *'"persistent":true'* ]] && echo yes || echo no)"
check "J5 no temp file left beside the boot copy" "" "$(find "$R/etc/telcoin" "$R/etc/systemd/system" -name '*.tmp*' -o -name '.tn*' 2>/dev/null | grep -v '^$')"

# ---- K. Concurrent enable runs without lists ---------------------------------------------------
seed_limit
reset_ufw yes
export V5_TAG=A V5_NFT_HOLD_TAG=A TN_P2P_NEW_FLOW_RATE=10
bash "$T/drv.sh" --enable > "$T/drvA.out" 2>&1 &
pa=$!
unset V5_TAG V5_NFT_HOLD_TAG TN_P2P_NEW_FLOW_RATE
n=0; while [[ ! -e "$R/.held.A" && "$n" -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
TN_P2P_NEW_FLOW_RATE=30 V5_TAG=B bash "$T/drv.sh" --enable > "$T/drvB.out" 2>&1
KB=$?
touch "$R/.release.A"
wait "$pa"; KA=$?
rm -f "$R/.held.A" "$R/.release.A"
echo "info  K concurrent: A rc=$KA B rc=$KB table rate=$(grep -o 'over [0-9]*/minute' "$TABLE" | head -n1) boot rate=$(grep -o 'over [0-9]*/minute' "$NFTFILE" | head -n1)"
check "K1 (adversarial) concurrent enables leave the live table and the boot copy agreeing" \
    "$(grep -o 'over [0-9]*/minute' "$TABLE" | head -n1)" "$(grep -o 'over [0-9]*/minute' "$NFTFILE" | head -n1)"
check "K2 B ran to completion while A held nft (no lock without a list)" "0" "$KB"

[[ "$V5_REAL_WRITER" == 1 ]] && rm -rf "$R"
finish
