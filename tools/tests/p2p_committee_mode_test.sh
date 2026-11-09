#!/usr/bin/env bash
# =============================================================================
# tools/tests/p2p_committee_mode_test.sh -- firewall-setup.sh --p2p-committee
# on|sync|off|status (fw_committee_on, fw_committee_sync, fw_committee_off,
# fw_committee_report, fw_allow_on_exit), the three unit texts, and how the
# verbs meet the ufw P2P rules and the new-flow limit, against the
# tools/tests/fwstub.sh stubs (ufw, systemctl, nft, tn-p2p-allow-sync) plus a
# flock stub, under a fixture TN_ROOT_PREFIX.
#
#   bash tools/tests/p2p_committee_mode_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/p2p_committee_mode_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/p2p_committee_mode_test.sh
#
# The first part sources firewall-setup.sh without its main call and drives the
# verb functions; the second runs `firewall-setup.sh --p2p-committee VERB` (and
# --enable, --reset, --json, the menu's node ports and the status screen) as
# its own process through a driver that replaces check_root and the host probes.
# Both replace tn_write_root_file (logs PATH MODE; WRITE_FAIL=PATH fails that
# write; in the driver KILL_AT=PATH sends TERM to the run after that write) and
# tn_p2p_allow_install (logs the call, INSTALL_RC, else copies the stub tool to
# the install path; its real download and verify are p2p_allow_install_test.sh's).
# The tool's own apply is simulated by loading a fixed table program into the
# nft stub.
#
# The tool's lock: the flock stub takes a lock call on fd 8 (FW_ALLOW_DIR/lock
# in fw_allow_uninstall) as holding that lock until `flock -u 8` and exits
# FLOCK_RC there (default 0). The stub tool on the install path first runs
# `flock -n FW_ALLOW_DIR/lock true`, which fails while the lock is held, and
# records "free" or "held" with its arguments, so every tool call shows whether
# bash held the tool's lock while it ran (it never may: the tool takes the lock
# itself and exits 4 when it is busy).
#
# Cases: on (tool calls, exact config bytes, writes, units, the limit gone, the
# open P2P rules kept and nothing deleted, P2P_COMMITTEE=on), the unit texts
# whole, sync (one plain sync, units rewritten only when they differ, a pin
# change or a --version the install's check refuses reinstalls, stale, busy and
# error codes, the reason= named), an exit 0 without result=applied or
# result=unchanged failing on and sync, the host baseline after an install or
# upgrade on every return, TN_BLS_PASSPHRASE kept from the tool, the mode of a
# lock off creates, the status report, off (the
# kill switch: user.rules and the limit files byte-identical to before on, with
# and without a static list, the binary, units and state dir gone, no tool
# call, under flock -w 30), on refusals that change nothing (no snapshot, no
# node, ufw inactive, no /usr/sbin/nft with an nft on PATH, no nft on PATH, no
# flock, an older library, a refused install), the reason texts (the
# rpc-method-missing line byte for byte, the four reasons the report warns of at
# once), a
# missing binary installed, a failed step undone, a busy lock on off, an
# in-flight on or off finished by fw_allow_on_exit, the dispatch with its
# refusals and its exit codes, a TERM in flight, --enable and --reset with
# committee mode on (the limit stays off, config rewritten, one resync), the
# menu's node ports, the preflight, the status screen, and the p2p_committee
# object of --json --status (the splice, a bad or failing tool, no binary).
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
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
export SYSTEMCTL_LOG="$T/systemctl.log"
export TN_FW_SNAP_PARENT="$T/snap"
export TN_UPDATE_LOCK_FILE="$T/lock/update.lock"
export REC="$T/rec"
R="$TN_ROOT_PREFIX"
mkdir -p "$R/etc/telcoin" "$R/etc/ufw" "$R/etc/default" "$R/etc/ssh" "$R/etc/systemd/system" \
    "$R/var/lib/telcoin/genesis" "$R/var/lib" "$R/usr/local/libexec/telcoin" "$T/fw" "$T/lock" "$TN_FW_SNAP_PARENT"
fw_stub_install "$T/bin"
# flock stub: logs its arguments. A lock call on fd 8 (the tool's lock) exits
# FLOCK_RC (default 0) and, when it succeeds, holds that lock until `-u 8`;
# `-n /PATH ...` (the stub tool's probe) fails while it is held; every other
# call exits 0 (the update lock uses fd 9).
cat > "$T/bin/flock" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${FLOCK_LOG:-/dev/null}"
case "$*" in
    "-u 8") rm -f "$FLOCK_HELD"; exit 0 ;;
    *" 8")
        rc="${FLOCK_RC:-0}"
        [ "$rc" -ne 0 ] || : > "$FLOCK_HELD"
        exit "$rc" ;;
    "-n /"*) [ ! -e "$FLOCK_HELD" ]; exit $? ;;
esac
exit 0
STUB
# the stub tool: probe the tool's lock, record the result, then the fwstub stub.
mv "$T/bin/tn-p2p-allow-sync" "$T/tool.stub"
cat > "$T/bin/tn-p2p-allow-sync" <<'STUB'
#!/bin/sh
if "$FLOCK_BIN" -n "$TN_ROOT_PREFIX/var/lib/telcoin-p2p-allow/lock" true; then s=free; else s=held; fi
printf '%s %s\n' "$s" "$*" >> "$LOCK_REC"
exec "$TOOL_STUB" "$@"
STUB
chmod +x "$T/bin/flock" "$T/bin/tn-p2p-allow-sync"
export FLOCK_LOG="$T/flock.log"
export FLOCK_HELD="$T/flock.held"
export FLOCK_BIN="$T/bin/flock"
export LOCK_REC="$T/lockrec"
export TOOL_STUB="$T/tool.stub"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"

grep -v '^main "\$@"$' "${TN_TEST_REPO}/firewall-setup.sh" > "$T/fw/firewall-setup.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/fw/lib"
# shellcheck source=/dev/null
source "$T/fw/firewall-setup.sh"
set +e
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
tn_migrate_ownership() { return 0; }
_tn_root_layout_dir() { printf 'layout %s %s %s\n' "$1" "$2" "$3" >> "$WRITES"; mkdir -p "$1" && chmod "$3" "$1"; }
INSTALLS="$T/installs"
tn_p2p_allow_install() {
    printf 'install %s\n' "${1:-}" >> "$INSTALLS"
    [[ "${INSTALL_RC:-0}" -eq 0 ]] || return "$INSTALL_RC"
    cp "$T/bin/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"
}
detect_installed_nodes() { echo "telcoin.service"; }
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
caddy_serves_public_edge() { return 1; }
ip() { return 1; }
: > "$R/etc/systemd/system/telcoin.service"
printf 'peers:\n  - /ip4/192.0.2.1/udp/49590/quic-v1\n' > "$R/etc/telcoin/bootstrap-peers.yaml"
META="$R/etc/telcoin/.node-meta"
D="$FW_ALLOW_DIR"
BOOTU="$R/etc/systemd/system/telcoin-p2p-allow.service"
SYNCU="$R/etc/systemd/system/telcoin-p2p-allow-sync.service"
TIMERU="$R/etc/systemd/system/telcoin-p2p-allow-sync.timer"
# the nft the tool runs and the boot unit names (FW_ALLOW_NFT); the fixture keeps
# a copy of the nft stub there, under $R, and the PATH nft stays $T/bin/nft.
NFTBIN="/usr/sbin/nft"
# what a successful tool sync loads (the program shape of the tool's render).
ALLOW_PROG='table inet tn_p2p_allow {
    set allow_v4 { type ipv4_addr; }
    set allow_v6 { type ipv6_addr; }
    set static_v4 { type ipv4_addr; flags interval; }
    set static_v6 { type ipv6_addr; flags interval; }
    counter tn_accept_p2p_listed { }
    counter tn_drop_p2p_unlisted { }
}
flush table inet tn_p2p_allow
flush set inet tn_p2p_allow allow_v4
flush set inet tn_p2p_allow allow_v6
flush set inet tn_p2p_allow static_v4
flush set inet tn_p2p_allow static_v6
table inet tn_p2p_allow {
    chain input {
        type filter hook input priority -20; policy accept;
        udp dport { 49590 } ip saddr @allow_v4 counter name "tn_accept_p2p_listed" accept
        udp dport { 49590 } ip saddr @static_v4 counter name "tn_accept_p2p_listed" accept
        udp dport { 49590 } ip6 saddr @allow_v6 counter name "tn_accept_p2p_listed" accept
        udp dport { 49590 } ip6 saddr @static_v6 counter name "tn_accept_p2p_listed" accept
        udp dport { 49590 } counter name "tn_drop_p2p_unlisted" drop
    }
}
add element inet tn_p2p_allow allow_v4 {
    192.0.2.10,
    198.51.100.7
}
add element inet tn_p2p_allow allow_v6 { 2001:db8::1 }
add element inet tn_p2p_allow static_v4 { 203.0.113.0/24 }
add element inet tn_p2p_allow static_v6 {
    2001:db8:1::/48,
    2001:db8:2::5
}'
export TN_P2P_STUB_OUT_SYNC="result=applied reason= epoch=42 v4=10 v6=2 static=0 floor=1 keys=7 dns_skipped=0 unparsed=0"

# fixture META_LINES -- a fresh host: ufw on with blanket SSH and open P2P, no
# allowlist, the stub tool installed, the limit loaded as --enable leaves it.
fixture() {
    rm -rf "$R/.nft.table" "$R/.nft.allow" "$R/.systemctl.enabled" "$D" "$BOOTU" "$SYNCU" "$TIMERU" "$R/etc/telcoin/p2p-limit.nft" \
        "$R/etc/systemd/system/telcoin-p2p-limit.service" "$R/.ufw.n"
    printf 'allow 22/tcp\nallow 49590/udp\nallow 49594/udp\n' > "$R/etc/ufw/user.rules"
    printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "$R/etc/default/ufw"
    printf '%s\n' "OWNERSHIP_LAYOUT=2" "NETWORK=mainnet" "RPC_PORT=8645" "$@" > "$META"
    cp "$T/bin/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"
    mkdir -p "$R/usr/sbin" && cp -f "$T/bin/nft" "${R}${NFTBIN}" && chmod 0755 "${R}${NFTBIN}"
    : > "$UFW_LOG"; : > "$NFT_LOG"; : > "$SYSTEMCTL_LOG"; : > "$WRITES"; : > "$INSTALLS"; : > "$FLOCK_LOG"; : > "$LOCK_REC"
    rm -f "$REC.log" "$FLOCK_HELD"
    FW_P2P_LOADED=false; FW_P2P_SRCS=(); FW_P2P_FROM=""; FW_COMMITTEE_ACTIVE=false; FW_ALLOW_INFLIGHT=""; FW_ALLOW_BIN_CHANGED=""
    unset TN_UPDATE_LOCK_KIND
    fw_p2p_limit_load
    fw_p2p_limit_sync telcoin.service > /dev/null 2>&1
    : > "$UFW_LOG"; : > "$NFT_LOG"; : > "$SYSTEMCTL_LOG"; : > "$WRITES"
}
# simulate_apply -- what the real tool's successful sync does to nft.
simulate_apply() { nft -f - <<< "$ALLOW_PROG" > /dev/null 2>&1; printf 'x\n' > "$D/current.nft"; }
snap() { cat "$R/etc/ufw/user.rules" "$R/etc/telcoin/p2p-limit.nft" "$R/etc/systemd/system/telcoin-p2p-limit.service" 2>/dev/null; cat "$R/.nft.table" 2>/dev/null; }
run() { RC=0; "$@" > "$T/out" 2>&1 || RC=$?; OUT="$(cat "$T/out")"; tn_release_update_lock > /dev/null 2>&1 || true; unset TN_UPDATE_LOCK_KIND; }
reclog() { grep -vx -- "--version" "$REC.log" 2>/dev/null; }
flocks() { grep " 8$" "$FLOCK_LOG"; }
# lock_held -- the tool calls that found the tool's lock held ("" when none did).
lock_held() { grep -v '^free ' "$LOCK_REC"; }
# enabled -- the units the systemctl stub has enabled; its `enable --now U`
# records --now as a unit too, which is not one.
enabled() { grep -vx -- "--now" "$R/.systemctl.enabled" 2>/dev/null; }
# check_in NAME STRING TEXT -- STRING appears somewhere in TEXT.
check_in() {
    CHECKS=$((CHECKS + 1))
    if grep -qF -- "$2" <<< "$3"; then
        printf "ok    %s\n" "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf "FAIL  %s\n      missing: %s\n      in:\n" "$1" "$2"
    printf "%s\n" "$3" | sed "s/^/        /"
    return 1
}

# --- the verb goes alone: the parser refuses every other flag before anything runs ----
# Run as a process (not root): the refusal comes before the root check.
parse_run() { PRC=0; POUT="$(bash "$TN_TEST_REPO/firewall-setup.sh" "$@" 2>&1)" || PRC=$?; }
parse_run --p2p-committee status --p2p-from 203.0.113.0/24
check "parser: --p2p-committee with --p2p-from exits 1" 1 "$PRC"
check_in "parser: --p2p-committee with --p2p-from is refused" "goes alone" "$POUT"
parse_run --p2p-committee on --ssh-anywhere
check "parser: --p2p-committee with --ssh-anywhere exits 1" 1 "$PRC"
check_in "parser: --p2p-committee with --ssh-anywhere is refused" "goes alone" "$POUT"
parse_run --p2p-committee status --json
check "parser: --p2p-committee with --json exits 1" 1 "$PRC"
check_in "parser: --p2p-committee with --json is refused" "goes alone" "$POUT"
parse_run --p2p-committee
check "parser: --p2p-committee without a verb exits 1" 1 "$PRC"
check_in "parser: --p2p-committee without a verb is refused" "takes on, off, sync or status" "$POUT"

# --- on: happy path -------------------------------------------------------------
fixture
before="$(snap)"
run fw_committee_on
check_rc "on: rc 0" 0 "$RC"
check "on: tool calls (capture-floor, then one authoritative sync)" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --require-authoritative --wait 30" "$(reclog)"
check "on: config exact bytes" "# tn-p2p-allow-sync config, written by firewall-setup.sh
CONFIG_VERSION=1
RPC_PORT=8645
P2P_PORTS=49590,49594
P2P_ALLOW_FROM=" "$(cat "$D/config")"
check "on: state dir made root 0700" "layout ${D} root 0700" "$(grep '^layout' "$WRITES")"
check "on: writes (config 0600, three units 0644, meta)" "${D}/config 0600
${BOOTU} 0644
${SYNCU} 0644
${TIMERU} 0644
${META} 0600" "$(grep -v '^layout' "$WRITES")"
# the units first, then the limit teardown (fw_p2p_limit_sync in committee mode)
check "on: systemctl calls" "daemon-reload
enable telcoin-p2p-allow.service
enable --now telcoin-p2p-allow-sync.timer
disable --now telcoin-p2p-limit.service
daemon-reload" "$(grep -v '^is-' "$SYSTEMCTL_LOG")"
check "on: limit table gone" "no" "$(grep -qx 'table inet tn_p2p' <<< "$(nft list tables)" && echo yes || echo no)"
check "on: limit file and unit gone" "no" "$([[ -e "$R/etc/telcoin/p2p-limit.nft" || -e "$R/etc/systemd/system/telcoin-p2p-limit.service" ]] && echo yes || echo no)"
check "on: open P2P rules kept, nothing deleted" "allow 22/tcp
allow 49590/udp
allow 49594/udp" "$(cat "$R/etc/ufw/user.rules")"
check_lacks "on: no ufw delete" "delete" "$(cat "$UFW_LOG")"
check "on: limit reason committee" "off committee" "$(fw_p2p_limit_live)"
check_has "on: desired P2P hint" "49590/udp	Node P2P (primary)	committee allowlist" "$(desired_firewall_rules)"
check_has "on: P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
check "on: not in flight" "" "$FW_ALLOW_INFLIGHT"
check "on: no install (binary current)" "" "$(cat "$INSTALLS")"
check_in "on: summary line" "epoch 42: 10 IPv4 and 2 IPv6 sources (7 keys, 1 floor, 0 static)" "$OUT"
check "on: no flock (the tool locks itself)" "" "$(flocks)"
check_has "on: the tool's lock probed at the sync" "free --state-dir ${D} sync --require-authoritative --wait 30" "$(cat "$LOCK_REC")"
check "on: the tool's lock was free at every tool call" "" "$(lock_held)"
check "on: boot unit and timer enabled, the limit unit not" "telcoin-p2p-allow.service
telcoin-p2p-allow-sync.timer" "$(enabled)"
check "boot unit text" "# Written by firewall-setup.sh: loads the P2P committee allowlist (nftables
# table inet tn_p2p_allow) at boot from the program tn-p2p-allow-sync last
# applied. firewall-setup.sh --p2p-committee off removes it.
[Unit]
Description=Telcoin Network P2P committee allowlist (nftables table inet tn_p2p_allow)
After=ufw.service network-pre.target
Before=telcoin.service
RequiresMountsFor=/var/lib/telcoin-p2p-allow
ConditionPathExists=/var/lib/telcoin-p2p-allow/current.nft

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /var/lib/telcoin-p2p-allow/current.nft
ExecStop=-/usr/sbin/nft delete table inet tn_p2p_allow
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_NETLINK AF_UNIX
IPAddressDeny=any
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
LimitCORE=0

[Install]
WantedBy=multi-user.target" "$(cat "$BOOTU")"
check "sync unit text" "# Written by firewall-setup.sh: one tn-p2p-allow-sync run, which brings the
# P2P committee allowlist in line with the admission snapshot of the node.
# telcoin-p2p-allow-sync.timer starts it; firewall-setup.sh --p2p-committee off
# removes it.
[Unit]
Description=Telcoin Network P2P committee allowlist sync (tn-p2p-allow-sync)
After=network-online.target telcoin.service telcoin-p2p-allow.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/telcoin/tn-p2p-allow-sync sync
SuccessExitStatus=3 4
UnsetEnvironment=TN_BLS_PASSPHRASE
UMask=0077
TimeoutStartSec=90
SyslogIdentifier=tn-p2p-allow
ProtectSystem=strict
ReadWritePaths=/var/lib/telcoin-p2p-allow
ReadOnlyPaths=-/var/lib/telcoin-p2p-allow/config -/var/lib/telcoin-p2p-allow/floor
InaccessiblePaths=/etc/telcoin -/var/lib/telcoin
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
IPAddressDeny=any
IPAddressAllow=localhost
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
MemoryMax=128M
CPUQuota=20%
TasksMax=32
LimitCORE=0" "$(cat "$SYNCU")"
check "timer unit text" "# Written by firewall-setup.sh: starts telcoin-p2p-allow-sync.service two minutes
# after boot, then five minutes after each run.
[Unit]
Description=Telcoin Network P2P committee allowlist sync timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=15s
RandomizedDelaySec=30s
Unit=telcoin-p2p-allow-sync.service

[Install]
WantedBy=timers.target" "$(cat "$TIMERU")"
check_has "boot: ConditionPathExists" "ConditionPathExists=/var/lib/telcoin-p2p-allow/current.nft" "$(cat "$BOOTU")"
check_has "boot: Before node" "Before=telcoin.service" "$(cat "$BOOTU")"
check_has "boot: ExecStart" "ExecStart=/usr/sbin/nft -f /var/lib/telcoin-p2p-allow/current.nft" "$(cat "$BOOTU")"
check_has "boot: ExecStop" "ExecStop=-/usr/sbin/nft delete table inet tn_p2p_allow" "$(cat "$BOOTU")"
check_lacks "boot: not the nft on PATH" "$(command -v nft)" "$(cat "$BOOTU")"
check_lacks "boot: no ProtectKernelModules" "ProtectKernelModules" "$(cat "$BOOTU")"
check_has "boot: WantedBy" "WantedBy=multi-user.target" "$(cat "$BOOTU")"
check_has "sync: After" "After=network-online.target telcoin.service telcoin-p2p-allow.service" "$(cat "$SYNCU")"
check_has "sync: ExecStart" "ExecStart=/usr/local/libexec/telcoin/tn-p2p-allow-sync sync" "$(cat "$SYNCU")"
check_has "sync: SuccessExitStatus" "SuccessExitStatus=3 4" "$(cat "$SYNCU")"
check_has "sync: AmbientCapabilities" "AmbientCapabilities=CAP_NET_ADMIN" "$(cat "$SYNCU")"
check_has "sync: InaccessiblePaths" "InaccessiblePaths=/etc/telcoin -/var/lib/telcoin" "$(cat "$SYNCU")"
check_has "sync: ReadOnlyPaths" "ReadOnlyPaths=-/var/lib/telcoin-p2p-allow/config -/var/lib/telcoin-p2p-allow/floor" "$(cat "$SYNCU")"
check_lacks "sync: no [Install]" "[Install]" "$(cat "$SYNCU")"
check_has "timer: OnUnitActiveSec" "OnUnitActiveSec=5min" "$(cat "$TIMERU")"
check_lacks "units: no fixture prefix" "$R" "$(cat "$BOOTU" "$SYNCU" "$TIMERU")"

# --- sync: units unchanged, one plain sync ------------------------------------------
: > "$SYSTEMCTL_LOG"; : > "$WRITES"; rm -f "$REC.log"; : > "$LOCK_REC"
run fw_committee_sync
check_rc "sync: rc 0" 0 "$RC"
check "sync: tool calls" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --wait 30" "$(reclog)"
check_has "sync: the tool's lock probed at the sync" "free --state-dir ${D} sync --wait 30" "$(cat "$LOCK_REC")"
check "sync: the tool's lock was free at every tool call" "" "$(lock_held)"
check "sync: no flock" "" "$(flocks)"
check "sync: config rewritten only" "${D}/config 0600" "$(grep -v '^layout' "$WRITES")"
check_lacks "sync: no daemon-reload when the units are current" "daemon-reload" "$(cat "$SYSTEMCTL_LOG")"
check_in "sync: report" "P2P committee allowlist applied: epoch 42" "$OUT"
# a unit that differs is rewritten, then daemon-reload
printf 'old\n' > "$TIMERU"; : > "$SYSTEMCTL_LOG"; : > "$WRITES"
run fw_committee_sync quiet
check_rc "sync quiet: rc 0" 0 "$RC"
check "sync quiet: says nothing" "" "$OUT"
check "sync quiet: only the timer rewritten" "${D}/config 0600
${TIMERU} 0644" "$(grep -v '^layout' "$WRITES")"
check_has "sync quiet: daemon-reload" "daemon-reload" "$(cat "$SYSTEMCTL_LOG")"
# a pin change reinstalls, then syncs once
rm -f "$REC.log"
TN_P2P_STUB_VERSION=0.0.9 run fw_committee_sync
check "sync: pin differs -> install" "install fw_baseline_say" "$(cat "$INSTALLS")"
check "sync: pin differs -> one plain sync after the install" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --wait 30" "$(reclog)"
: > "$INSTALLS"
# stale and busy are rc 3
rm -f "$REC.log"
TN_P2P_STUB_RC_SYNC=3 TN_P2P_STUB_OUT_SYNC="result=stale reason=rpc-unreachable epoch=42 v4=10 v6=2 static=0 floor=1 keys=7 dns_skipped=0 unparsed=0" run fw_committee_sync
check_rc "sync: stale rc 3" 3 "$RC"
check_in "sync: stale says why" "kept its last-good set: the node RPC does not answer" "$OUT"
TN_P2P_STUB_RC_SYNC=4 run fw_committee_sync
check_rc "sync: busy rc 3" 3 "$RC"
TN_P2P_STUB_RC_SYNC=2 run fw_committee_sync
check_rc "sync: error rc 2" 2 "$RC"
# the nft the tool runs gone: sync writes no unit, runs no sync, and names the path
rm -f "$REC.log"; rm -f "${R}${NFTBIN}"
run fw_committee_sync
check_rc "sync: no /usr/sbin/nft rc 2" 2 "$RC"
check_in "sync: no /usr/sbin/nft names it" "/usr/sbin/nft is missing or not executable (the path tn-p2p-allow-sync runs), so the P2P committee allowlist units were not written" "$OUT"
check_lacks "sync: no /usr/sbin/nft, no sync run" " sync " " $(reclog) "
mkdir -p "$R/usr/sbin" && cp -f "$T/bin/nft" "${R}${NFTBIN}" && chmod 0755 "${R}${NFTBIN}"
# on while on is a resync; a stale one is still rc 0
rm -f "$REC.log"
TN_P2P_STUB_RC_SYNC=3 run fw_committee_on
check_rc "on while on: stale resync rc 0" 0 "$RC"
check "on while on: one plain sync" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --wait 30" "$(reclog)"

# --- status report --------------------------------------------------------------------
printf 'STATUS_VERSION=1\nRESULT=applied\nEPOCH=42\nALLOWED_V4=10\nALLOWED_V6=2\nKEYS=7\nFLOOR=1\nSTALE_SINCE=\nSTALE_REASON=\n' > "$D/status"
TN_P2P_STUB_OUT_STATUS="$(printf 'RESULT=applied\nEPOCH=42\nALLOWED_V4=10\nALLOWED_V6=2\nKEYS=7\nFLOOR=1\nLOADED=true\nAGE_SECS=31\nSTALE=false\nCOUNTER_ACCEPT_PACKETS=5\nCOUNTER_DROP_PACKETS=9')" run fw_committee_report
check_in "report: loaded" "table inet tn_p2p_allow holds 10 IPv4 and 2 IPv6 sources (7 keys, 1 floor), epoch 42" "$OUT"
check_in "report: counters" "5 packets accepted from listed sources, 9 dropped" "$OUT"
check_in "report: age" "last good one 31s ago" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=false\nSTALE=true\nSTALE_SINCE=1700000000\nSTALE_REASON=rpc-method-missing')" run fw_committee_report
check_in "report: not loaded is an error" "is not loaded, so P2P is open to every source" "$OUT"
check_in "report: rpc-method-missing at once" "P2P committee allowlist: this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api; the last-good set stays loaded" "$OUT"
check "reason text: rpc-method-missing byte for byte" \
    "this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api" \
    "$(fw_allow_reason_text rpc-method-missing)"
# the four reasons check-node reports at once warn here at once too, before the
# tool reports STALE=true; any other reason waits for it.
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=false\nSTALE_SINCE=1700000000\nSTALE_REASON=epoch-regressed')" run fw_committee_report
check_in "report: epoch-regressed at once" "P2P committee allowlist: the node reports an epoch below the one the allowlist was built from (epoch-regressed); it clears by itself once the node's tracked epoch is back at or above the applied one (after a startup record-sync replay); if it persists past 2 epochs, recover with --p2p-committee off, then --p2p-committee on; the last-good set stays loaded" "$OUT"
check_lacks "report: epoch-regressed is not reported as stale" "stale since" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=false\nSTALE_SINCE=1700000000\nSTALE_REASON=state-invalid')" run fw_committee_report
check_in "report: state-invalid at once" "P2P committee allowlist: tn-p2p-allow-sync cannot read its own state.json (state-invalid), so every sync fails; recover with --p2p-committee off, then --p2p-committee on; the last-good set stays loaded" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=false\nSTALE_SINCE=1700000000\nSTALE_REASON=snapshot-version-2')" run fw_committee_report
check_in "report: snapshot-version-* at once" "P2P committee allowlist: the node serves a snapshot version this tool does not read (snapshot-version-2)" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=false\nSTALE_SINCE=1700000000\nSTALE_REASON=rpc-unreachable')" run fw_committee_report
check_lacks "report: another reason waits for STALE=true" "rpc-unreachable" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=true\nSTALE_SINCE=1700000000\nSTALE_REASON=rpc-unreachable')" run fw_committee_report
check_in "report: another reason once STALE=true" "stale since 1700000000: the node RPC does not answer on 127.0.0.1 (rpc-unreachable)" "$OUT"
# A failed last sync (RESULT=error, from the status file when the live answer has
# none) warns at once with its reason, in check-node's words, before the tool
# reports STALE=true; the unit's failed run is then not said again.
FIX="sudo bash ${SCRIPT_DIR}/firewall-setup.sh --p2p-committee sync"
printf 'STATUS_VERSION=1\nRESULT=error\nEPOCH=42\nSTALE_SINCE=1700000000\nSTALE_REASON=nft-apply-failed\n' > "$D/status"
export SYSTEMCTL_SHOW='Result=exit-code
ExecMainStatus=2'
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nSTALE=false')" run fw_committee_report
check_in "report: RESULT=error at once, its reason named" "[WARN] P2P committee allowlist: its last sync failed (nft-apply-failed, failing since 1700000000), so it keeps its last-good set until a sync succeeds; see journalctl -u telcoin-p2p-allow-sync.service -n 20, then run: ${FIX}" "$OUT"
check_lacks "report: RESULT=error: the failed unit run is not said again" "the last run of" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'RESULT=error\nLOADED=true\nSTALE=true\nSTALE_SINCE=1700000000\nSTALE_REASON=config-invalid')" run fw_committee_report
check_in "report: RESULT=error with STALE=true: the failed sync" "its last sync failed (config-invalid, failing since 1700000000)" "$OUT"
check_lacks "report: RESULT=error with STALE=true: not also stale" "stale since" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'RESULT=error\nLOADED=true\nSTALE=false\nSTALE_SINCE=\nSTALE_REASON=')" run fw_committee_report
check_in "report: RESULT=error without a reason" "P2P committee allowlist: its last sync failed, so it keeps its last-good set until a sync succeeds; see journalctl" "$OUT"
TN_P2P_STUB_OUT_STATUS="$(printf 'RESULT=error\nLOADED=true\nSTALE=false\nSTALE_SINCE=1700000000\nSTALE_REASON=state-invalid')" run fw_committee_report
check_in "report: RESULT=error state-invalid: its own words" "tn-p2p-allow-sync cannot read its own state.json (state-invalid)" "$OUT"
check_lacks "report: RESULT=error state-invalid: said once" "its last sync failed" "$OUT"
check_lacks "report: RESULT=error state-invalid: no unit line" "the last run of" "$OUT"
# A failed run of the sync unit that left no RESULT=error (in the sandbox, on an
# unsafe state dir) warns at once too, in check-node's words; exit 3 (stale), 4
# (busy) and 0 are the unit's success.
printf 'STATUS_VERSION=1\nRESULT=applied\nEPOCH=42\nSTALE_SINCE=\nSTALE_REASON=\n' > "$D/status"
LIVE_OK="$(printf 'LOADED=true\nSTALE=false\nAGE_SECS=31')"
TN_P2P_STUB_OUT_STATUS="$LIVE_OK" run fw_committee_report
check_in "report: failed unit run (exit 2) at once" "[WARN] P2P committee allowlist: the last run of telcoin-p2p-allow-sync.service failed (it exited with status 2), so the allowlist keeps its last-good set until a sync succeeds; see journalctl -u telcoin-p2p-allow-sync.service -n 20, then run: ${FIX}" "$OUT"
check_lacks "report: failed unit run: no failed sync line" "its last sync failed" "$OUT"
check_in "report: the unit read asks systemctl for Result and ExecMainStatus" "show -p Result -p ExecMainStatus telcoin-p2p-allow-sync.service" "$(cat "$SYSTEMCTL_LOG")"
export SYSTEMCTL_SHOW='ExecMainStatus=9
Result=signal'
TN_P2P_STUB_OUT_STATUS="$LIVE_OK" run fw_committee_report
check_in "report: failed unit run (signal)" "telcoin-p2p-allow-sync.service failed (it was killed by signal 9), so" "$OUT"
export SYSTEMCTL_SHOW='Result=timeout
ExecMainStatus=0'
TN_P2P_STUB_OUT_STATUS="$LIVE_OK" run fw_committee_report
check_in "report: failed unit run (systemd result)" "telcoin-p2p-allow-sync.service failed (systemd result timeout), so" "$OUT"
for u in 'Result=exit-code ExecMainStatus=3' 'Result=exit-code ExecMainStatus=4' 'Result=exit-code ExecMainStatus=0' 'Result=success ExecMainStatus=0' 'ExecMainStatus=1'; do
    export SYSTEMCTL_SHOW="${u% *}
${u#* }"
    TN_P2P_STUB_OUT_STATUS="$LIVE_OK" run fw_committee_report
    check_lacks "report: no unit warning for ${u}" "the last run of" "$OUT"
done
unset SYSTEMCTL_SHOW
TN_P2P_STUB_OUT_STATUS="$LIVE_OK" run fw_committee_report
check_lacks "report: no unit warning when systemd says nothing" "the last run of" "$OUT"

# --- off: kill switch ------------------------------------------------------------------
simulate_apply
rm -f "$REC.log"; : > "$SYSTEMCTL_LOG"; : > "$NFT_LOG"
run fw_committee_off
check_rc "off: rc 0" 0 "$RC"
check "off: never runs the tool" "" "$(reclog)"
check "off: user.rules and limit files as before on" "$before" "$(snap)"
check "off: units gone" "no" "$([[ -e "$BOOTU" || -e "$SYNCU" || -e "$TIMERU" ]] && echo yes || echo no)"
check "off: state dir gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
check "off: binary gone" "no" "$([[ -e "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)"
check_lacks "off: table gone" "tn_p2p_allow" "$(nft list tables)"
check "off: flock -w 30 on fd 8, then unlock" "-w 30 8
-u 8" "$(flocks)"
check "off: the tool's lock released" "no" "$([[ -e "$FLOCK_HELD" ]] && echo yes || echo no)"
check "off: the limit unit enabled again, the allowlist units not" "telcoin-p2p-limit.service" "$(enabled)"
# the limit and its boot unit come back before the allowlist units go
check "off: systemctl order" "daemon-reload
enable telcoin-p2p-limit.service
disable --now telcoin-p2p-allow-sync.timer
stop telcoin-p2p-allow-sync.service
disable --now telcoin-p2p-allow.service
daemon-reload" "$(grep -v '^is-' "$SYSTEMCTL_LOG")"
check_has "off: P2P_COMMITTEE=off" "P2P_COMMITTEE=off" "$(cat "$META")"
check_lacks "off: P2P_COMMITTEE=on gone" "P2P_COMMITTEE=on" "$(cat "$META")"
run fw_committee_off
check_rc "off again: rc 0" 0 "$RC"
check_in "off again: nothing to do" "off already" "$OUT"
# the stub tool's probe sees a lock that is held
: > "$LOCK_REC"; : > "$FLOCK_HELD"
"$T/bin/tn-p2p-allow-sync" --version > /dev/null 2>&1
rm -f "$FLOCK_HELD"
check "lock probe: a held lock is seen" "held --version" "$(cat "$LOCK_REC")"

# --- on/off with a static list: byte-identical restore ----------------------------------
fixture "P2P_ALLOW_FROM=203.0.113.0/24"
fw_p2p_allow > /dev/null 2>&1; fw_p2p_limit_sync telcoin.service > /dev/null 2>&1; FW_P2P_LOADED=false
before="$(snap)"
: > "$UFW_LOG"
run fw_committee_on
check_rc "on (list): rc 0" 0 "$RC"
check_has "on (list): config static list" "P2P_ALLOW_FROM=203.0.113.0/24" "$(cat "$D/config")"
check "on (list): open rules added, per-source rules kept" "allow 22/tcp
allow from 203.0.113.0/24 to any port 49590 proto udp
allow from 203.0.113.0/24 to any port 49594 proto udp
allow 49590/udp
allow 49594/udp" "$(cat "$R/etc/ufw/user.rules")"
check_lacks "on (list): no ufw delete" "delete" "$(cat "$UFW_LOG")"
simulate_apply
run fw_committee_off
check_rc "off (list): rc 0" 0 "$RC"
check "off (list): user.rules and limit files as before on" "$before" "$(snap)"

# --- on refusals: nothing changed -------------------------------------------------------
fixture
before="$(snap)"
TN_P2P_STUB_RC_SYNC=1 TN_P2P_STUB_OUT_SYNC="result=stale reason=rpc-method-missing epoch= v4=0 v6=0 static=0 floor=1 keys=0 dns_skipped=0 unparsed=0" run fw_committee_on
check_rc "on refused (rpc-method-missing): rc 1" 1 "$RC"
check_in "on refused: the message" "P2P committee mode was not turned on: this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api. Nothing was changed." "$OUT"
check "on refused: state dir removed" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
check "on refused: no unit" "no" "$([[ -e "$BOOTU" || -e "$SYNCU" || -e "$TIMERU" ]] && echo yes || echo no)"
check "on refused: no ufw call" "" "$(grep -v '^status' "$UFW_LOG")"
check "on refused: rules and limit as before" "$before" "$(snap)"
check_lacks "on refused: no P2P_COMMITTEE" "P2P_COMMITTEE" "$(cat "$META")"
check "on refused: binary kept (it was there)" "yes" "$([[ -x "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)"
TN_P2P_STUB_RC_SYNC=1 TN_P2P_STUB_OUT_SYNC="result=stale reason=empty-set epoch=42 v4=0 v6=0 static=0 floor=1 keys=0 dns_skipped=0 unparsed=0" run fw_committee_on
check_in "on refused (empty-set): the message" "the snapshot lists no addresses beyond the floor and static list" "$OUT"
# the binary missing: installed, and removed again by a refusal
rm -f "$TN_P2P_ALLOW_BIN"
TN_P2P_STUB_RC_SYNC=1 run fw_committee_on
check "on refused (fresh install): installed once" "install fw_baseline_say" "$(cat "$INSTALLS")"
check "on refused (fresh install): binary removed again" "no" "$([[ -e "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)"
# install refused: nothing changed
: > "$INSTALLS"
rm -f "$REC.log"; rm -f "$TN_P2P_ALLOW_BIN"
INSTALL_RC=1 run fw_committee_on
check_rc "on: install refused rc 1" 1 "$RC"
check "on: install refused, no tool call" "" "$(reclog | grep -v '^--version$')"
check "on: install refused, no state dir" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
cp "$T/bin/tn-p2p-allow-sync" "$TN_P2P_ALLOW_BIN"
# the binary missing: installed, then on goes through
fixture
rm -f "$TN_P2P_ALLOW_BIN"
run fw_committee_on
check_rc "on (binary missing): rc 0" 0 "$RC"
check "on (binary missing): installed once" "install fw_baseline_say" "$(cat "$INSTALLS")"
check "on (binary missing): at the libexec path" "${R}/usr/local/libexec/telcoin/tn-p2p-allow-sync yes" \
    "${TN_P2P_ALLOW_BIN} $([[ -x "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)"
check "on (binary missing): then capture-floor and one authoritative sync" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --require-authoritative --wait 30" "$(reclog)"
check_has "on (binary missing): P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
# preconditions
fixture
detect_installed_nodes() { echo "none"; }
run fw_committee_on
check_rc "on: no node rc 1" 1 "$RC"
detect_installed_nodes() { echo "telcoin.service"; }
printf 'ENABLED=no\n' > "$R/etc/ufw/ufw.conf"
run fw_committee_on
check_rc "on: ufw inactive rc 1" 1 "$RC"
printf 'ENABLED=yes\n' > "$R/etc/ufw/ufw.conf"
# a tool taken off PATH (hash -r: bash would still find it at the old path)
mv "$T/bin/nft" "$T/nft.off"; hash -r
if command -v nft > /dev/null 2>&1; then
    skip "on: no nft rc 1" "an nft outside the fixture is on PATH ($(command -v nft))"
else
    run fw_committee_on
    check_rc "on: no nft on PATH rc 1" 1 "$RC"
    check_in "on: no nft on PATH says why" "nft is not on PATH (not found), and firewall-setup.sh runs it from there" "$OUT"
fi
mv "$T/nft.off" "$T/bin/nft"; hash -r
# the nft on PATH is there, the one the tool runs is not: on refuses and names it
rm -f "${R}${NFTBIN}"
run fw_committee_on
check_rc "on: no /usr/sbin/nft rc 1" 1 "$RC"
check_in "on: no /usr/sbin/nft says why" "The P2P committee allowlist needs /usr/sbin/nft (the path tn-p2p-allow-sync runs); install the nftables package (sudo apt-get install nftables) and run this again. Nothing was changed." "$OUT"
check "on: no /usr/sbin/nft, no tool call" "" "$(reclog)"
check "on: no /usr/sbin/nft, no state dir" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
# not executable counts as missing
printf '#!/bin/sh\n' > "${R}${NFTBIN}"; chmod 0644 "${R}${NFTBIN}"
run fw_committee_on
check_rc "on: /usr/sbin/nft not executable rc 1" 1 "$RC"
check_in "on: /usr/sbin/nft not executable says why" "needs /usr/sbin/nft (the path tn-p2p-allow-sync runs)" "$OUT"
mkdir -p "$R/usr/sbin" && cp -f "$T/bin/nft" "${R}${NFTBIN}" && chmod 0755 "${R}${NFTBIN}"
# no flock: the host's own flock is hidden behind a directory that links every
# other command of the fixture PATH.
mkdir -p "$T/pathx"
for dir in /usr/local/bin /usr/bin /bin; do
    [[ -d "$dir" ]] && ln -s "$dir"/* "$T/pathx/" 2>/dev/null
done
rm -f "$T/pathx/flock"
mv "$T/bin/flock" "$T/flock.off"
PATH="$T/bin:$T/pathx"; hash -r
if command -v flock > /dev/null 2>&1; then
    skip "on: no flock rc 1" "a flock outside the fixture is on PATH ($(command -v flock))"
else
    run fw_committee_on
    check_rc "on: no flock rc 1" 1 "$RC"
    check_in "on: no flock says why" "flock is not installed, so P2P committee mode cannot be turned on" "$OUT"
fi
mv "$T/flock.off" "$T/bin/flock"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"; hash -r
( unset -f tn_p2p_allow_install; RC=0; fw_committee_on > "$T/out" 2>&1 || RC=$?; echo "$RC" > "$T/rc" )
check_rc "on: older library rc 2" 2 "$(cat "$T/rc")"
check_in "on: older library names update-scripts.sh" "update-scripts.sh" "$(cat "$T/out")"
check "on: preconditions changed nothing" "" "$(reclog)$(grep -v '^status' "$UFW_LOG")"
check "on: preconditions left no state dir" "no" "$([[ -e "$D" ]] && echo yes || echo no)"

# --- on: a step after the sync fails -> undone (rc 2) -------------------------------
fixture
before="$(snap)"
WRITE_FAIL="$SYNCU" run fw_committee_on
check_rc "on: unit write fails rc 2" 2 "$RC"
check_in "on: unit write fails, said undone" "It was turned off again" "$OUT"
check "on: unit write fails, units gone" "no" "$([[ -e "$BOOTU" || -e "$SYNCU" || -e "$TIMERU" ]] && echo yes || echo no)"
check "on: unit write fails, state dir gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
check "on: unit write fails, rules and limit as before" "$before" "$(snap)"
check_lacks "on: unit write fails, no P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
check "on: unit write fails, binary kept" "yes" "$([[ -x "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)"
fixture
TN_P2P_STUB_RC_SYNC=2 run fw_committee_on
check_rc "on: sync error rc 2" 2 "$RC"
check "on: sync error, state dir gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"

# --- off: lock not free -> partial, state stays ------------------------------------------
fixture
run fw_committee_on
simulate_apply
FLOCK_RC=1 run fw_committee_off
check_rc "off: lock busy rc 3" 3 "$RC"
check "off: lock busy, state dir stays" "yes" "$([[ -d "$D" ]] && echo yes || echo no)"
check_has "off: lock busy, P2P_COMMITTEE stays on" "P2P_COMMITTEE=on" "$(cat "$META")"
check_has "off: lock busy, table stays" "table inet tn_p2p_allow" "$(nft list tables)"
run fw_committee_off
check_rc "off: rerun rc 0" 0 "$RC"

# --- an in-flight on or off is finished by fw_allow_on_exit -----------------------------
fixture
before="$(snap)"
run fw_committee_on
simulate_apply
meta_unset P2P_COMMITTEE > /dev/null 2>&1
FW_ALLOW_INFLIGHT=on
RC=0; fw_allow_on_exit 143 > "$T/out" 2>&1 || RC=$?
check_rc "on_exit (on): rc 0" 0 "$RC"
check_in "on_exit (on): said" "it was turned off again" "$(cat "$T/out")"
check "on_exit (on): state dir gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"
check_lacks "on_exit (on): table gone" "tn_p2p_allow" "$(nft list tables)"
check "on_exit (on): rules and limit as before" "$before" "$(snap)"
fixture
run fw_committee_on
simulate_apply
FW_ALLOW_INFLIGHT=off
RC=0; fw_allow_on_exit 130 > "$T/out" 2>&1 || RC=$?
check_in "on_exit (off): said" "the removal was finished" "$(cat "$T/out")"
check_has "on_exit (off): P2P_COMMITTEE=off" "P2P_COMMITTEE=off" "$(cat "$META")"
check "on_exit (off): state dir gone" "no" "$([[ -e "$D" ]] && echo yes || echo no)"

# --- the sync unit hides a data dir elsewhere -------------------------------------------
check_has "sync text: data dir elsewhere hidden" "InaccessiblePaths=/etc/telcoin -/var/lib/telcoin -/data/tn" "$(fw_allow_unit_sync_text telcoin.service /data/tn/)"
check_has "sync text: data dir under /var/lib/telcoin not repeated" "InaccessiblePaths=/etc/telcoin -/var/lib/telcoin
" "$(fw_allow_unit_sync_text telcoin.service /var/lib/telcoin/x)
"
check_has "sync text: a parent of the state dir is not hidden" "InaccessiblePaths=/etc/telcoin -/var/lib/telcoin
" "$(fw_allow_unit_sync_text telcoin.service /var/lib)
"
check_has "sync text: a path with a space is not hidden" "InaccessiblePaths=/etc/telcoin -/var/lib/telcoin
" "$(fw_allow_unit_sync_text telcoin.service '/data/t n')
"

# --- sync quiet while off is a no-op ------------------------------------------------------
fixture
rm -f "$REC.log"
run fw_committee_sync quiet
check_rc "sync quiet (off): rc 0" 0 "$RC"
check "sync quiet (off): nothing" "" "$OUT$(reclog)$(cat "$WRITES")"
run fw_committee_sync
check_rc "sync (off): rc 1" 1 "$RC"

# --- the sync line decides: exit 0 needs result=applied or result=unchanged --------------
LINE_TAIL="epoch=42 v4=10 v6=2 static=0 floor=1 keys=7 dns_skipped=0 unparsed=0"
fixture
before="$(snap)"
TN_P2P_STUB_OUT_SYNC="" run fw_committee_on
check_rc "on: exit 0 without a result line rc 2" 2 "$RC"
check_in "on: exit 0 without a result line, said and undone" "P2P committee mode was not turned on: tn-p2p-allow-sync sync exited 0 without a result=applied or result=unchanged line. It was turned off again" "$OUT"
check "on: exit 0 without a result line, no state dir, no unit" "no no" \
    "$([[ -e "$D" ]] && echo yes || echo no) $([[ -e "$BOOTU" || -e "$SYNCU" || -e "$TIMERU" ]] && echo yes || echo no)"
check "on: exit 0 without a result line, rules and limit as before" "$before" "$(snap)"
check_lacks "on: exit 0 without a result line, no P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
fixture
TN_P2P_STUB_OUT_SYNC="result=stale reason=rpc-unreachable ${LINE_TAIL}" run fw_committee_on
check_rc "on: exit 0 with result=stale rc 2" 2 "$RC"
check_in "on: exit 0 with result=stale names the reason" "without a result=applied or result=unchanged line (reason=rpc-unreachable). It was turned off again" "$OUT"
fixture
TN_P2P_STUB_RC_SYNC=3 TN_P2P_STUB_OUT_SYNC="result=stale reason=rpc-unreachable ${LINE_TAIL}" run fw_committee_on
check_rc "on: exit 3 under --require-authoritative rc 2" 2 "$RC"
check_in "on: exit 3 names the reason" "tn-p2p-allow-sync sync failed (exit 3, reason=rpc-unreachable). It was turned off again" "$OUT"
fixture
TN_P2P_STUB_OUT_SYNC="result=unchanged reason= ${LINE_TAIL}" run fw_committee_on
check_rc "on: result=unchanged rc 0" 0 "$RC"
check_has "on: result=unchanged, P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
simulate_apply
TN_P2P_STUB_OUT_SYNC="" run fw_committee_sync
check_rc "sync: exit 0 without a result line rc 2" 2 "$RC"
check_in "sync: exit 0 without a result line, said" "tn-p2p-allow-sync sync exited 0 without a result=applied or result=unchanged line; the P2P committee allowlist keeps the table it has loaded." "$OUT"
check_lacks "sync: exit 0 without a result line, no ok line" "[OK]" "$OUT"
TN_P2P_STUB_OUT_SYNC="" run fw_committee_sync quiet
check_rc "sync quiet: exit 0 without a result line rc 2, said" "2 yes" \
    "$RC $(grep -qF 'exited 0 without a result=applied or result=unchanged line' <<< "$OUT" && echo yes || echo no)"
TN_P2P_STUB_RC_SYNC=2 TN_P2P_STUB_OUT_SYNC="result=error reason=config-invalid ${LINE_TAIL}" run fw_committee_sync
check_rc "sync: exit 2 rc 2" 2 "$RC"
check_in "sync: exit 2 names the reason" "tn-p2p-allow-sync sync failed (exit 2, reason=config-invalid);" "$OUT"
TN_P2P_STUB_OUT_SYNC="result=unchanged reason= ${LINE_TAIL}" run fw_committee_sync
check_rc "sync: result=unchanged rc 0" 0 "$RC"
check_in "sync: result=unchanged said" "P2P committee allowlist unchanged: epoch 42" "$OUT"
run fw_committee_off

# --- the host baseline after this run installed or upgraded the binary ------------------
REFRESH="$T/refresh"
fw_baseline_refresh() { printf 'refresh\n' >> "$REFRESH"; }
# old_bin -- an installed binary of another release, which fw_allow_bin_ensure replaces
old_bin() { printf '#!/bin/sh\necho "tn-p2p-allow-sync 0.0.9"\n' > "$TN_P2P_ALLOW_BIN"; chmod +x "$TN_P2P_ALLOW_BIN"; }
refreshes() { if [[ -e "$REFRESH" ]]; then wc -l < "$REFRESH" | tr -d ' '; else echo 0; fi; }
fixture; old_bin; rm -f "$REFRESH"
_tn_root_layout_dir() { return 1; }
run fw_committee_on
_tn_root_layout_dir() { printf 'layout %s %s %s\n' "$1" "$2" "$3" >> "$WRITES"; mkdir -p "$1" && chmod "$3" "$1"; }
check "on: state dir refused after an upgrade: rc 2, installed, one refresh" "2|install fw_baseline_say|1" "$RC|$(cat "$INSTALLS")|$(refreshes)"
fixture; old_bin; rm -f "$REFRESH"
TN_P2P_STUB_RC_CAPTURE_FLOOR=2 run fw_committee_on
check "on: capture-floor fails after an upgrade: rc 2, upgrade kept, one refresh" "2|install fw_baseline_say|yes|1" \
    "$RC|$(cat "$INSTALLS")|$(cmp -s "$TN_P2P_ALLOW_BIN" "$T/bin/tn-p2p-allow-sync" && echo yes || echo no)|$(refreshes)"
fixture; rm -f "$TN_P2P_ALLOW_BIN" "$REFRESH"
TN_P2P_STUB_RC_CAPTURE_FLOOR=2 run fw_committee_on
check "on: capture-floor fails after a fresh install: rc 2, binary removed, no refresh" "2|no|0" \
    "$RC|$([[ -e "$TN_P2P_ALLOW_BIN" ]] && echo yes || echo no)|$(refreshes)"
fixture; old_bin; rm -f "$REFRESH"
TN_P2P_STUB_RC_SYNC=1 TN_P2P_STUB_OUT_SYNC="result=stale reason=empty-set ${LINE_TAIL}" run fw_committee_on
check "on: refused after an upgrade: rc 1, one refresh" "1|1" "$RC|$(refreshes)"
fixture; run fw_committee_on; simulate_apply
old_bin; rm -f "$REFRESH"; : > "$INSTALLS"
TN_P2P_STUB_RC_CAPTURE_FLOOR=2 run fw_committee_sync
check "sync: capture-floor fails after an upgrade: rc 2, one refresh" "2|install fw_baseline_say|1" "$RC|$(cat "$INSTALLS")|$(refreshes)"
old_bin; rm -f "$REFRESH"; printf 'old\n' > "$TIMERU"
WRITE_FAIL="$TIMERU" run fw_committee_sync
check "sync: a unit write fails after an upgrade: rc 2, one refresh" "2|1" "$RC|$(refreshes)"
old_bin; rm -f "$REFRESH"
TN_P2P_STUB_RC_CAPTURE_FLOOR=2 run fw_committee_sync quiet
check "sync quiet: a step fails after an upgrade: rc 2, the caller refreshes" "2|0" "$RC|$(refreshes)"
rm -f "$REFRESH"
TN_P2P_STUB_RC_CAPTURE_FLOOR=2 run fw_committee_sync
check "sync: a step fails, binary unchanged: no refresh" "2|0" "$RC|$(refreshes)"
old_bin; rm -f "$REFRESH"
run fw_committee_sync
check "sync: through after an upgrade: one refresh" "0|1" "$RC|$(refreshes)"
run fw_committee_off
eval "$(sed -n '/^fw_baseline_refresh() {$/,/^}$/p' "$T/fw/firewall-setup.sh")"

# --- the installed binary is judged by the install's own --version check ----------------
fixture; run fw_committee_on; simulate_apply
: > "$INSTALLS"
TN_P2P_STUB_VERSION_TEXT="tn-p2p-allow-sync ${TN_P2P_ALLOW_VERSION#v}
commit 0123456789abcdef0123456789abcdef01234567
target x86_64-unknown-linux-musl
snapshot-versions 1
config-version 2" run fw_committee_sync
check "sync: the pinned version with config-version 2 is replaced" "install fw_baseline_say" "$(cat "$INSTALLS")"
: > "$INSTALLS"
TN_P2P_STUB_VERSION_TEXT="tn-p2p-allow-sync ${TN_P2P_ALLOW_VERSION#v}
commit 0123456789abcdef0123456789abcdef01234567
config-version 1" run fw_committee_sync
check "sync: no snapshot-versions line is replaced" "install fw_baseline_say" "$(cat "$INSTALLS")"
: > "$INSTALLS"
run fw_committee_sync
check "sync: the pinned release is kept" "" "$(cat "$INSTALLS")"
run fw_committee_off
( unset -f _tn_p2p_allow_version_ok; RC=0; fw_committee_on > "$T/out" 2>&1 || RC=$?; echo "$RC" > "$T/rc" )
check "on: a library without _tn_p2p_allow_version_ok rc 2, named" "2 yes" \
    "$(cat "$T/rc") $(grep -qF '_tn_p2p_allow_version_ok' "$T/out" && echo yes || echo no)"

# --- the tool never sees TN_BLS_PASSPHRASE ----------------------------------------------
fixture
export TN_BLS_PASSPHRASE="not-for-the-tool"
run fw_allow_capture_floor
check "capture-floor: rc 0, the tool's environment lacks TN_BLS_PASSPHRASE" "0|no" \
    "$RC|$(grep -q '^TN_BLS_PASSPHRASE=' "$REC.env" && echo yes || echo no)"
run fw_allow_bin_ensure
check "--version probe: the tool's environment lacks TN_BLS_PASSPHRASE" "0|--version|no" \
    "$RC|$(cat "$REC.argv")|$(grep -q '^TN_BLS_PASSPHRASE=' "$REC.env" && echo yes || echo no)"
unset TN_BLS_PASSPHRASE

# --- off makes a missing tool lock 0600 whatever the caller's umask ----------------------
fixture; run fw_committee_on; simulate_apply
rm -f "$D/lock"
umask_before="$(umask)"
umask 022
FLOCK_RC=1 run fw_allow_uninstall keep-binary
check "off: a lock it creates is 0600 under umask 022, and the umask is back" "2|600|0022" \
    "$RC|$(stat -c '%a' "$D/lock" 2>/dev/null)|$(umask)"
umask "$umask_before"
run fw_committee_off

# --- off opens only a missing or regular lock --------------------------------------------
# A FIFO at the lock would block the open for good, a directory would print a raw
# shell error (and end a POSIX-mode shell), a symlink is never followed: each is
# refused, said, and the table and the state dir stay. A hang is cut off after
# 10 seconds.
LOCK_OPEN_FW="/var/lib/telcoin-p2p-allow/lock cannot be opened, so the P2P committee allowlist was left in place."
for kind in fifo dir dir-posix symlink; do
    fixture; run fw_committee_on; simulate_apply
    rm -f "$D/lock"
    case "$kind" in
        fifo) mkfifo "$D/lock" ;;
        dir*) mkdir "$D/lock" ;;
        symlink) ln -s "$T/lock-target" "$D/lock" ;;
    esac
    : > "$FLOCK_LOG"
    ( [[ "$kind" != *-posix ]] || set -o posix
      RC=0; fw_allow_uninstall keep-binary || RC=$?; echo "rc=$RC" ) > "$T/out" 2>&1 &
    pid=$!; n=0
    while kill -0 "$pid" 2>/dev/null && [[ $n -lt 10 ]]; do sleep 1; n=$((n + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; echo "HUNG" >> "$T/out"; fi
    wait "$pid" 2>/dev/null
    OUT="$(cat "$T/out")"
    check "off, ${kind} lock: no hang, rc 2" "no yes" \
        "$(grep -q HUNG <<< "$OUT" && echo yes || echo no) $(grep -qx 'rc=2' <<< "$OUT" && echo yes || echo no)"
    check_in "off, ${kind} lock: said" "$LOCK_OPEN_FW" "$OUT"
    check_lacks "off, ${kind} lock: no raw shell error" "Is a directory" "$OUT"
    check "off, ${kind} lock: no lock taken" "" "$(flocks)"
    check "off, ${kind} lock: the table and the state dir stay" "yes yes" \
        "$([[ -s "$R/.nft.allow" ]] && echo yes || echo no) $([[ -d "$D" ]] && echo yes || echo no)"
    check "off, ${kind} lock: nothing made through a symlink" "no" "$([[ -e "$T/lock-target" ]] && echo yes || echo no)"
    rm -rf "$D/lock"
    run fw_committee_off
done

# =============================================================================
# the real dispatch: firewall-setup.sh --p2p-committee VERB as its own
# process, through a driver that replaces check_root and the same host probes as
# above; then committee mode on the other paths (--enable, --reset, --json,
# Manage node ports, the status screen, the preflight).
# =============================================================================
export WRITES INSTALLS
export STUB_TOOL="$T/bin/tn-p2p-allow-sync"
export KILL_MARK="$T/killed"
cat > "$T/fw/driver.sh" <<'DRV'
# shellcheck shell=bash
# shellcheck source=/dev/null
source "$(dirname "$0")/firewall-setup.sh"
check_root() { :; }
tn_migrate_ownership() { printf 'migrate\n' >> "$WRITES"; return 0; }
# KILL_AT=PATH: that write goes through, then the run gets TERM (once per KILL_MARK).
tn_write_root_file() {
    printf '%s %s\n' "$1" "$2" >> "$WRITES"
    if [[ -n "${WRITE_FAIL:-}" && "$1" == "$WRITE_FAIL" ]]; then
        cat > /dev/null
        return 2
    fi
    mkdir -p "${1%/*}"
    cat > "$1"
    if [[ -n "${KILL_AT:-}" && "$1" == "$KILL_AT" && ! -e "$KILL_MARK" ]]; then
        : > "$KILL_MARK"
        kill -TERM $$
    fi
    return 0
}
_tn_root_layout_dir() { printf 'layout %s %s %s\n' "$1" "$2" "$3" >> "$WRITES"; mkdir -p "$1" && chmod "$3" "$1"; }
tn_p2p_allow_install() {
    printf 'install %s\n' "${1:-}" >> "$INSTALLS"
    [[ "${INSTALL_RC:-0}" -eq 0 ]] || return "$INSTALL_RC"
    cp "$STUB_TOOL" "$TN_P2P_ALLOW_BIN"
}
detect_installed_nodes() { echo "telcoin.service"; }
fw_p2p_ports() { printf '49590 primary\n49594 worker-0\n'; }
caddy_serves_public_edge() { return 1; }
ip() { return 1; }
if [[ -n "${OLDLIB:-}" ]]; then
    unset -f tn_p2p_allow_install
fi
main "$@"
DRV
# drun ARG... -- run the driver; RC and OUT (stdout and stderr).
drun() { RC=0; bash "$T/fw/driver.sh" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?; OUT="$(cat "$T/out")"; }
limit_present() { [[ -e "$R/etc/telcoin/p2p-limit.nft" || -e "$R/etc/systemd/system/telcoin-p2p-limit.service" ]] || grep -qx 'table inet tn_p2p' <<< "$(nft list tables)"; }
allow_present() { [[ -e "$D" || -e "$BOOTU" || -e "$SYNCU" || -e "$TIMERU" || -e "$TN_P2P_ALLOW_BIN" ]]; }
yn() { if "$@"; then echo yes; else echo no; fi; }

# --- dispatch: on, status, sync, off; kill switch without a list ------------------
fixture
before="$(snap)"
drun --p2p-committee on
check_rc "dispatch on: rc 0" 0 "$RC"
check "dispatch on: capture-floor, then one authoritative sync" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --require-authoritative --wait 30" "$(reclog)"
check_has "dispatch on: the tool's lock probed at the sync" "free --state-dir ${D} sync --require-authoritative --wait 30" "$(cat "$LOCK_REC")"
check "dispatch on: the tool's lock was free at every tool call" "" "$(lock_held)"
check_has "dispatch on: P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
check_has "dispatch on: ownership migration first (fw_wants_meta_write on)" "migrate" "$(cat "$WRITES")"
check "dispatch on: limit table, file and unit gone" "no" "$(yn limit_present)"
check "dispatch on: open P2P rules kept" "allow 22/tcp
allow 49590/udp
allow 49594/udp" "$(cat "$R/etc/ufw/user.rules")"
check "dispatch on: units written" "yes" "$(yn test -f "$BOOTU" -a -f "$SYNCU" -a -f "$TIMERU")"
check_in "dispatch on: summary" "P2P committee mode is on" "$OUT"
simulate_apply
TN_P2P_STUB_OUT_STATUS="$(printf 'LOADED=true\nALLOWED_V4=10\nALLOWED_V6=2\nKEYS=7\nFLOOR=1\nEPOCH=42')" drun --p2p-committee status
check_rc "dispatch status: rc 0" 0 "$RC"
check_in "dispatch status: the report" "P2P committee allowlist: on; table inet tn_p2p_allow holds 10 IPv4 and 2 IPv6 sources" "$OUT"
drun --p2p-committee=status
check_rc "dispatch --p2p-committee=status: rc 0" 0 "$RC"
rm -f "$REC.log"
drun --p2p-committee sync
check_rc "dispatch sync: rc 0" 0 "$RC"
check "dispatch sync: one plain sync" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --wait 30" "$(reclog)"
check "dispatch sync: the tool's lock was free at every tool call" "" "$(lock_held)"
TN_P2P_STUB_RC_SYNC=3 drun --p2p-committee sync
check_rc "dispatch sync: stale passed through as 3" 3 "$RC"
TN_P2P_STUB_RC_SYNC=2 drun --p2p-committee sync
check_rc "dispatch sync: error passed through as 2" 2 "$RC"
rm -f "$REC.log"; : > "$WRITES"
drun --p2p-committee off
check_rc "dispatch off: rc 0" 0 "$RC"
check "dispatch off: never runs the tool" "" "$(reclog)"
check "dispatch off: user.rules and limit files byte-identical to before on" "$before" "$(snap)"
check "dispatch off: binary, state dir and units gone" "no" "$(yn allow_present)"
check_has "dispatch off: P2P_COMMITTEE=off" "P2P_COMMITTEE=off" "$(cat "$META")"
check_has "dispatch off: ownership migration first (fw_wants_meta_write off)" "migrate" "$(cat "$WRITES")"
drun --p2p-committee off
check_rc "dispatch off again: rc 0" 0 "$RC"

# --- dispatch: kill switch with a static list -----------------------------------------
fixture "P2P_ALLOW_FROM=203.0.113.0/24"
fw_p2p_allow > /dev/null 2>&1; fw_p2p_limit_sync telcoin.service > /dev/null 2>&1; FW_P2P_LOADED=false
before="$(snap)"
drun --p2p-committee on
check_rc "dispatch on (list): rc 0" 0 "$RC"
check "dispatch on (list): open rules added, per-source rules kept" "allow 22/tcp
allow from 203.0.113.0/24 to any port 49590 proto udp
allow from 203.0.113.0/24 to any port 49594 proto udp
allow 49590/udp
allow 49594/udp" "$(cat "$R/etc/ufw/user.rules")"
check_has "dispatch on (list): static list in config" "P2P_ALLOW_FROM=203.0.113.0/24" "$(cat "$D/config")"
simulate_apply
rm -f "$REC.log"
drun --p2p-committee off
check_rc "dispatch off (list): rc 0" 0 "$RC"
check "dispatch off (list): user.rules and limit files byte-identical to before on" "$before" "$(snap)"
check "dispatch off (list): never runs the tool" "" "$(reclog)"
check "dispatch off (list): binary, state dir and units gone" "no" "$(yn allow_present)"

# --- --enable, --reset and --json with committee mode on -------------------------------
fixture
drun --p2p-committee on
simulate_apply
: > "$WRITES"; rm -f "$REC.log"; : > "$UFW_LOG"
drun --enable --ssh-anywhere
check_rc "enable (committee on): rc 0" 0 "$RC"
check "enable (committee on): limit stays off" "no" "$(yn limit_present)"
check_lacks "enable (committee on): no P2P rule deleted" "delete allow 4959" "$(cat "$UFW_LOG")"
check_has "enable (committee on): config rewritten" "${D}/config 0600" "$(cat "$WRITES")"
check "enable (committee on): resynced" "--state-dir ${D} capture-floor ${R}/etc/telcoin/bootstrap-peers.yaml
--state-dir ${D} sync --wait 30" "$(reclog)"
check "enable (committee on): the tool's lock was free at every tool call" "" "$(lock_held)"
: > "$WRITES"; rm -f "$REC.log"
drun --reset --ssh-anywhere
check_rc "reset (committee on): rc 0" 0 "$RC"
check "reset (committee on): limit stays off" "no" "$(yn limit_present)"
check "reset (committee on): open P2P rules back" "allow 22/tcp
allow 49590/udp
allow 49594/udp" "$(cat "$R/etc/ufw/user.rules")"
check_has "reset (committee on): config rewritten" "${D}/config 0600" "$(cat "$WRITES")"
check_in "reset (committee on): resynced" "sync --wait 30" "$(reclog)"
rm -f "$REC.log"
drun --enable --ssh-anywhere --p2p-from 198.51.100.7
check_rc "enable --p2p-from (committee on): rc 0" 0 "$RC"
check_has "enable --p2p-from (committee on): the new list recorded" "P2P_ALLOW_FROM=198.51.100.7" "$(cat "$META")"
check_has "enable --p2p-from (committee on): config takes the new list" "P2P_ALLOW_FROM=198.51.100.7" "$(cat "$D/config")"
check_lacks "enable --p2p-from (committee on): no per-source ufw rule" "198.51.100.7" "$(cat "$R/etc/ufw/user.rules")"
check_has "enable --p2p-from (committee on): open rule kept" "allow 49590/udp" "$(cat "$R/etc/ufw/user.rules")"
check "enable --p2p-from (committee on): limit stays off" "no" "$(yn limit_present)"
rm -f "$REC.log"
drun --json --enable --ssh-anywhere
check_rc "json enable (committee on): rc 0" 0 "$RC"
check_in "json enable (committee on): done ok" '"event":"done","ok":true' "$OUT"
check_in "json enable (committee on): resynced" "sync --wait 30" "$(reclog)"
drun --json --port 49590/udp on
check_rc "json port on (committee on, list): rc 0" 0 "$RC"
check_in "json port on (committee on, list): done ok" '"ok":true' "$OUT"
check_in "json status (committee on): limit reason committee" '"reason":"committee"' "$(bash "$T/fw/driver.sh" --json --status 2>/dev/null)"
drun --p2p-committee off
check_rc "off (list): rc 0" 0 "$RC"
drun --json --port 49590/udp on
check_rc "json port on (committee off, list): refused" 1 "$RC"
check_in "json port on (committee off, list): says why" "limited to P2P_ALLOW_FROM" "$OUT"

# --- dispatch: refusals change nothing -----------------------------------------------
fixture
before="$(snap)"
for args in "--p2p-committee" "--p2p-committee bogus" "--p2p-committee on --enable" "--json --p2p-committee status" \
    "--p2p-committee=on --reset" "--status --p2p-committee on" "--p2p-committee on --p2p-from 198.51.100.7"; do
    : > "$UFW_LOG"; rm -f "$REC.log"
    # shellcheck disable=SC2086
    drun $args
    check_rc "dispatch refuses '${args}': rc 1" 1 "$RC"
    check "dispatch refuses '${args}': nothing run" "" "$(grep -v '^status' "$UFW_LOG")$(reclog)"
done
check "dispatch refusals: rules and limit as before" "$before" "$(snap)"
check_lacks "dispatch refusals: no P2P_COMMITTEE" "P2P_COMMITTEE" "$(cat "$META")"
OLDLIB=1 drun --p2p-committee on
check_rc "dispatch on, older library: rc 2" 2 "$RC"
check_in "dispatch on, older library: names update-scripts.sh" "update-scripts.sh" "$OUT"
check "dispatch on, older library: nothing changed" "$before" "$(snap)"
check "dispatch on, older library: no tool call, no state dir" "no" "$(yn test -n "$(reclog)" -o -e "$D")"
OLDLIB=1 drun --p2p-committee status
check_rc "dispatch status, older library: rc 0" 0 "$RC"

# --- dispatch: a stop in flight is finished by fw_on_exit ------------------------------
fixture
before="$(snap)"
rm -f "$KILL_MARK"
KILL_AT="$SYNCU" drun --p2p-committee on
check_rc "dispatch on stopped (TERM at a unit write): rc 143" 143 "$RC"
check_in "dispatch on stopped: said" "Stopped (exit 143) while P2P committee mode was being turned on; it was turned off again" "$OUT"
check "dispatch on stopped: binary kept, state dir and units gone" "yes no" "$(yn test -x "$TN_P2P_ALLOW_BIN") $(yn test -e "$D" -o -e "$BOOTU" -o -e "$SYNCU" -o -e "$TIMERU")"
check_lacks "dispatch on stopped: no P2P_COMMITTEE=on" "P2P_COMMITTEE=on" "$(cat "$META")"
check "dispatch on stopped: rules and limit as before" "$before" "$(snap)"
drun --p2p-committee on
check_rc "dispatch on after the stop: rc 0" 0 "$RC"
simulate_apply
rm -f "$KILL_MARK"
KILL_AT="$R/etc/telcoin/p2p-limit.nft" drun --p2p-committee off
check_rc "dispatch off stopped (TERM at the limit boot copy): rc 143" 143 "$RC"
check_in "dispatch off stopped: said" "while P2P committee mode was being turned off; the removal was finished" "$OUT"
check_has "dispatch off stopped: P2P_COMMITTEE=off" "P2P_COMMITTEE=off" "$(cat "$META")"
check "dispatch off stopped: binary, state dir and units gone" "no" "$(yn allow_present)"
check "dispatch off stopped: rules and limit as before on" "$before" "$(snap)"
rm -f "$KILL_MARK"

# --- Manage node ports, the preflight and the status screen in committee mode ------------
fixture "P2P_ALLOW_FROM=203.0.113.0/24" "P2P_COMMITTEE=on"
: > "$UFW_LOG"
run fw_menu_p2p_apply telcoin.service true
check_rc "menu (committee on, list): rc 0" 0 "$RC"
check "menu (committee on, list): open rules only, nothing deleted" "allow 49590/udp
allow 49594/udp" "$(grep -v '^status' "$UFW_LOG")"
check "menu (committee on, list): limit off" "no" "$(yn limit_present)"
fixture "P2P_COMMITTEE=on"
run fw_menu_p2p_apply telcoin.service false
check_rc "menu (committee on): rc 0" 0 "$RC"
check "menu (committee on): the limit is taken off" "no" "$(yn limit_present)"
fixture "P2P_COMMITTEE=on" "P2P_COMMITTEE=off"
run fw_menu_p2p_apply telcoin.service true
check_rc "menu: P2P_COMMITTEE twice refused" 1 "$RC"
check "menu: P2P_COMMITTEE twice, no ufw call" "" "$(grep -v '^status' "$UFW_LOG")"
run fw_preflight
check_rc "preflight: P2P_COMMITTEE twice refused" 1 "$RC"
check_in "preflight: says why" "P2P_COMMITTEE is set more than once" "$OUT"
check "limit reason: P2P_COMMITTEE twice is unreadable" "off unreadable" "$(printf 'table inet tn_p2p\ndelete table inet tn_p2p\n' | nft -f - > /dev/null 2>&1; fw_p2p_limit_live)"
fixture "P2P_COMMITTEE=on"
FW_SSH_ANYWHERE=true
run fw_preflight
FW_SSH_ANYWHERE=false
check_rc "preflight (committee on): rc 0" 0 "$RC"
check "preflight (committee on): FW_COMMITTEE_ACTIVE" "true" "$FW_COMMITTEE_ACTIVE"
FW_COMMITTEE_ACTIVE=false
run view_status < /dev/null
check_in "status screen: the committee report" "P2P committee allowlist: on" "$OUT"
fixture
run view_status < /dev/null
check_in "status screen (off): the committee line" "P2P committee allowlist: off" "$OUT"

# --- --json --status: the p2p_committee object -------------------------------------------
# the last key of the status object: firewall-setup.sh's four keys come first,
# then, with committee mode on, the one line the tool prints for `status --json`
# spliced into the same object; otherwise the four alone, with reason saying
# why; nothing parses JSON here: the exact bytes are compared, each key is
# counted, and tn_json_field (the library's JSON matcher) reads every value back.
# pc TEXT -- the p2p_committee object of a --json --status line (the last key).
pc() { local s="$1"; s="${s#*\"p2p_committee\":}"; printf '%s\n' "${s%\}}"; }
jstatus() { JS="$(bash "$T/fw/driver.sh" --json --status 2>/dev/null)"; PC="$(pc "$JS")"; }
# jfields OBJ KEY... -- what tn_json_field reads for each KEY in OBJ, "-" where it
# reads nothing (null, an object, an array or no such key).
jfields() {
    local o="$1" k v out=""
    shift
    for k in "$@"; do
        v="$(tn_json_field "$o" "$k")" || v="-"
        out="$out $v"
    done
    printf '%s\n' "${out# }"
}
# shape TEXT -- one line, as many "{" as "}" and "[" as "]", no empty member.
shape() {
    local s="$1" ob cb os cs
    ob="${s//[!\{]/}"; cb="${s//[!\}]/}"; os="${s//[!\[]/}"; cs="${s//[!\]]/}"
    if [[ "$s" == *$'\n'* || ${#ob} -ne ${#cb} || ${#os} -ne ${#cs} || "$s" == *',}'* || "$s" == *'{,'* || "$s" == *',,'* ]]; then
        echo bad
    else
        echo ok
    fi
}
TOOL_LINE='{"loaded":true,"epoch":42,"allowed_v4":10,"allowed_v6":2,"static":3,"floor":1,"keys":7,"dns_skipped":0,"last_good":1762300000,"age_secs":120,"stale":false,"stale_since":null,"stale_reason":null,"counters":{"accepted":1234,"dropped":56}}'
ALL_KEYS="enabled persistent timer reason loaded epoch allowed_v4 allowed_v6 static floor keys dns_skipped last_good age_secs stale stale_since stale_reason counters accepted dropped"
fixture
jstatus
check "json committee off: four keys only, reason off" '{"enabled":false,"persistent":false,"timer":false,"reason":"off"}' "$PC"
check "json committee off: the line keeps its shape" ok "$(shape "$JS")"
check "json committee off: read back" "false false false off" "$(jfields "$PC" enabled persistent timer reason)"
check "json committee off: no tool call" "" "$(reclog)"
check_in "json committee off: the limit is on" '"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null' "$JS"
drun --p2p-committee on
check_rc "json committee on: rc 0" 0 "$RC"
simulate_apply
rm -f "$REC.log"
export TN_P2P_STUB_OUT_STATUS_JSON="$TOOL_LINE"
jstatus
check "json committee on: the four keys first, then the tool's line" '{"enabled":true,"persistent":true,"timer":true,"reason":null,'"${TOOL_LINE#\{}" "$PC"
check "json committee on: the line keeps its shape" ok "$(shape "$JS")"
check "json committee on: one status --json call" "--state-dir ${D} status --json" "$(reclog)"
check "json committee on: the tool's lock was free" "" "$(lock_held)"
check_in "json committee on: limit reason committee" '"p2p_new_flow_limit":{"active":false,"rate":null,"burst":null,"reason":"committee"' "$JS"
for k in $ALL_KEYS; do
    n="$(grep -o "\"$k\":" <<< "$PC" | wc -l | tr -d ' ')"
    check "json committee on: key $k once" 1 "$n"
done
# shellcheck disable=SC2086
check "json committee on: read back" "true true true - true 42 10 2 3 1 7 0 1762300000 120 false - - - 1234 56" "$(jfields "$PC" $ALL_KEYS)"
# a line that is not one object in the grammar of the tool's values, or that
# carries one of the four keys, is never spliced.
for bad in '' '{}' ' {"loaded":true}' "$(printf '{"loaded":true}\n{"loaded":false}')" '{"loaded":true,"reason":"x"}' \
    '{"loaded":true,"timer":1}' '{"enabled":false}' '{"loaded":true,"persistent":true}' '{"loaded":true' 'loaded=true' \
    '{"loaded":"a b"}' '{"loaded":"a\"b"}' '{"loaded":true,"counters":{"accepted":1}' '{"loaded":true}}' \
    '{"a":1},{"b":2}' '{"loaded":true,}' '{"loaded":}' '{"loaded"}' '{"loaded":tru}' '{"loaded":true"x":1}' \
    '{"loaded"::true}' '{"loaded":"}' '{"a":{,"b":1}}' '{"a":1}{"b":2}'; do
    export TN_P2P_STUB_OUT_STATUS_JSON="$bad"
    jstatus
    check "json committee on, line [$bad]: tool-error" '{"enabled":true,"persistent":true,"timer":true,"reason":"tool-error"}' "$PC"
    check "json committee on, line [$bad]: the line keeps its shape" ok "$(shape "$JS")"
done
export TN_P2P_STUB_OUT_STATUS_JSON="$TOOL_LINE"
for rc in 1 2 3 4 101; do
    TN_P2P_STUB_RC_STATUS_JSON=$rc jstatus
    check "json committee on, tool exit $rc: tool-error" '{"enabled":true,"persistent":true,"timer":true,"reason":"tool-error"}' "$PC"
done
mv "$TN_P2P_ALLOW_BIN" "$T/bin.away"
rm -f "$REC.log"
jstatus
check "json committee on, binary missing: tool-missing" '{"enabled":true,"persistent":true,"timer":true,"reason":"tool-missing"}' "$PC"
check "json committee on, binary missing: read back" "true true true tool-missing" "$(jfields "$PC" enabled persistent timer reason)"
check "json committee on, binary missing: no tool call" "" "$(reclog)"
mv "$T/bin.away" "$TN_P2P_ALLOW_BIN"
printf 'P2P_COMMITTEE=on\n' >> "$META"
jstatus
check "json P2P_COMMITTEE twice: unreadable, enabled null" '{"enabled":null,"persistent":true,"timer":true,"reason":"unreadable"}' "$PC"
check "json P2P_COMMITTEE twice: the line keeps its shape" ok "$(shape "$JS")"
grep -v '^P2P_COMMITTEE=on$' "$META" > "$T/meta.tmp"
printf 'P2P_COMMITTEE=on\n' >> "$T/meta.tmp"
cat "$T/meta.tmp" > "$META"
# the systemctl stub answers is-active for every unit, so disabling is what
# makes the timer read false.
systemctl disable "$FW_ALLOW_TIMER" > /dev/null
systemctl disable "$FW_ALLOW_SVC" > /dev/null
jstatus
check "json committee on, units disabled: persistent and timer false" '{"enabled":true,"persistent":false,"timer":false,"reason":null,'"${TOOL_LINE#\{}" "$PC"
rm -f "$TIMERU"
systemctl enable "$FW_ALLOW_TIMER" > /dev/null
jstatus
check "json committee on, timer unit file gone: timer false" '{"enabled":true,"persistent":false,"timer":false,"reason":null,'"${TOOL_LINE#\{}" "$PC"
unset TN_P2P_STUB_OUT_STATUS_JSON

finish
